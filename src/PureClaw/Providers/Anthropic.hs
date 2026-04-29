module PureClaw.Providers.Anthropic
  ( -- * Provider type (constructor intentionally NOT exported)
    AnthropicProvider
  , mkAnthropicProvider
  , mkAnthropicProviderOAuth
    -- * Auth headers (exported for testing)
  , buildAuthHeaders
    -- * Errors
  , AnthropicError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
    -- * SSE parsing (exported for testing)
  , parseSSELine
    -- * Stream accumulation (exported for testing)
  , StreamState
  , newStreamState
  , processStreamLine
  , finalizeStream
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header qualified as Header
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Auth.AnthropicOAuth
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Security.Secrets

-- | Authentication method for the Anthropic provider.
data AnthropicAuth
  = ApiKeyAuth ApiKey
    -- ^ Authenticate with a static API key via the @x-api-key@ header.
  | OAuthAuth OAuthHandle
    -- ^ Authenticate via OAuth 2.0; access tokens are refreshed automatically.

-- | Anthropic API provider. Constructor is not exported — use
-- 'mkAnthropicProvider' or 'mkAnthropicProviderOAuth'.
data AnthropicProvider = AnthropicProvider
  { _ap_manager :: HTTP.Manager
  , _ap_auth    :: AnthropicAuth
  }

-- | Create an Anthropic provider authenticated with an API key.
mkAnthropicProvider :: HTTP.Manager -> ApiKey -> AnthropicProvider
mkAnthropicProvider m k = AnthropicProvider m (ApiKeyAuth k)

-- | Create an Anthropic provider authenticated via OAuth.
-- Tokens are refreshed automatically when they expire.
mkAnthropicProviderOAuth :: HTTP.Manager -> OAuthHandle -> AnthropicProvider
mkAnthropicProviderOAuth m h = AnthropicProvider m (OAuthAuth h)

-- | Build the authentication headers for a request.
-- For OAuth, checks token expiry and refreshes if needed.
buildAuthHeaders :: AnthropicProvider -> IO [Header.Header]
buildAuthHeaders p = case _ap_auth p of
  ApiKeyAuth key ->
    pure [ ("x-api-key",          withApiKey key id)
         , ("anthropic-version",  "2023-06-01")
         , ("content-type",       "application/json")
         ]
  OAuthAuth oauthHandle -> do
    tokens <- readIORef (_oah_tokensRef oauthHandle)
    now    <- getCurrentTime
    freshTokens <-
      if _oat_expiresAt tokens <= now
        then do
          newT <- _oah_refresh oauthHandle (_oat_refreshToken tokens)
          writeIORef (_oah_tokensRef oauthHandle) newT
          pure newT
        else pure tokens
    pure [ ("authorization",     "Bearer " <> withBearerToken (_oat_accessToken freshTokens) id)
         , ("anthropic-version", "2023-06-01")
         , ("anthropic-beta",    "oauth-2025-04-20")
         , ("content-type",      "application/json")
         ]

instance Provider AnthropicProvider where
  complete = anthropicComplete
  completeStream = anthropicCompleteStream

-- | Errors from the Anthropic API.
data AnthropicError
  = AnthropicAPIError Int ByteString   -- ^ HTTP status code + response body
  | AnthropicParseError Text           -- ^ JSON parse/decode error
  deriving stock (Show)

instance Exception AnthropicError

instance ToPublicError AnthropicError where
  toPublicError (AnthropicAPIError 429 _) = RateLimitError
  toPublicError (AnthropicAPIError 401 _) = NotAllowedError
  toPublicError _                         = TemporaryError "Provider error"

-- | Anthropic Messages API base URL.
anthropicBaseUrl :: String
anthropicBaseUrl = "https://api.anthropic.com/v1/messages"

-- | Call the Anthropic Messages API.
anthropicComplete :: AnthropicProvider -> CompletionRequest -> IO CompletionResponse
anthropicComplete provider req = do
  authHeaders <- buildAuthHeaders provider
  initReq <- HTTP.parseRequest anthropicBaseUrl
  let httpReq = initReq
        { HTTP.method         = "POST"
        , HTTP.requestBody    = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders = authHeaders
        }
  resp <- HTTP.httpLbs httpReq (_ap_manager provider)
  let status = Status.statusCode (HTTP.responseStatus resp)
  if status /= 200
    then throwIO (AnthropicAPIError status (BL.toStrict (HTTP.responseBody resp)))
    else case decodeResponse (HTTP.responseBody resp) of
      Left err -> throwIO (AnthropicParseError (T.pack err))
      Right response -> pure response

-- | Encode a completion request as JSON for the Anthropic API.
encodeRequest :: CompletionRequest -> BL.ByteString
encodeRequest req = encode $ object $
  [ "model"      .= unModelId (_cr_model req)
  , "max_tokens" .= fromMaybe 4096 (_cr_maxTokens req)
  , "messages"   .= map encodeMsg (_cr_messages req)
  ]
  ++ maybe [] (\s -> ["system" .= s]) (_cr_systemPrompt req)
  ++ if null (_cr_tools req)
     then maybe [] (\tc -> ["tool_choice" .= encodeToolChoice tc]) (_cr_toolChoice req)
     else ("tools" .= map encodeTool (_cr_tools req))
        : maybe [] (\tc -> ["tool_choice" .= encodeToolChoice tc]) (_cr_toolChoice req)

encodeMsg :: Message -> Value
encodeMsg msg = object
  [ "role"    .= roleToText (_msg_role msg)
  , "content" .= map encodeContentBlock (_msg_content msg)
  ]

encodeContentBlock :: ContentBlock -> Value
encodeContentBlock (TextBlock t) = object
  [ "type" .= ("text" :: Text)
  , "text" .= t
  ]
encodeContentBlock (ToolUseBlock callId name input) = object
  [ "type"  .= ("tool_use" :: Text)
  , "id"    .= unToolCallId callId
  , "name"  .= name
  , "input" .= input
  ]
encodeContentBlock (ImageBlock mediaType imageData) = object
  [ "type" .= ("image" :: Text)
  , "source" .= object
      [ "type"       .= ("base64" :: Text)
      , "media_type" .= mediaType
      , "data"       .= TE.decodeUtf8 imageData
      ]
  ]
encodeContentBlock (ToolResultBlock callId parts isErr) = object $
  [ "type"        .= ("tool_result" :: Text)
  , "tool_use_id" .= unToolCallId callId
  , "content"     .= map encodeToolResultPart parts
  ]
  ++ ["is_error" .= True | isErr]

encodeToolResultPart :: ToolResultPart -> Value
encodeToolResultPart (TRPText t) = object
  [ "type" .= ("text" :: Text), "text" .= t ]
encodeToolResultPart (TRPImage mediaType imageData) = object
  [ "type" .= ("image" :: Text)
  , "source" .= object
      [ "type"       .= ("base64" :: Text)
      , "media_type" .= mediaType
      , "data"       .= TE.decodeUtf8 imageData
      ]
  ]

encodeTool :: ToolDefinition -> Value
encodeTool td = object
  [ "name"         .= _td_name td
  , "description"  .= _td_description td
  , "input_schema" .= _td_inputSchema td
  ]

encodeToolChoice :: ToolChoice -> Value
encodeToolChoice AutoTool = object ["type" .= ("auto" :: Text)]
encodeToolChoice AnyTool = object ["type" .= ("any" :: Text)]
encodeToolChoice (SpecificTool name) = object
  [ "type" .= ("tool" :: Text)
  , "name" .= name
  ]

-- | Decode an Anthropic API response into a 'CompletionResponse'.
decodeResponse :: BL.ByteString -> Either String CompletionResponse
decodeResponse bs = eitherDecode bs >>= parseEither parseResp
  where
    parseResp :: Value -> Parser CompletionResponse
    parseResp = withObject "AnthropicResponse" $ \o -> do
      contentArr <- o .: "content"
      blocks <- mapM parseBlock contentArr
      modelText <- o .: "model"
      usageObj <- o .: "usage"
      inToks <- usageObj .: "input_tokens"
      outToks <- usageObj .: "output_tokens"
      pure CompletionResponse
        { _crsp_content = blocks
        , _crsp_model   = ModelId modelText
        , _crsp_usage   = Just (Usage inToks outToks)
        }

    parseBlock :: Value -> Parser ContentBlock
    parseBlock = withObject "ContentBlock" $ \b -> do
      bType <- b .: "type"
      case (bType :: Text) of
        "text" -> TextBlock <$> b .: "text"
        "tool_use" -> do
          callId <- b .: "id"
          name <- b .: "name"
          input <- b .: "input"
          pure (ToolUseBlock (ToolCallId callId) name input)
        other -> fail $ "Unknown content block type: " <> T.unpack other

-- | Encode a streaming completion request (adds "stream": true).
encodeStreamRequest :: CompletionRequest -> BL.ByteString
encodeStreamRequest req = encode $ object $
  [ "model"      .= unModelId (_cr_model req)
  , "max_tokens" .= fromMaybe 4096 (_cr_maxTokens req)
  , "messages"   .= map encodeMsg (_cr_messages req)
  , "stream"     .= True
  ]
  ++ maybe [] (\s -> ["system" .= s]) (_cr_systemPrompt req)
  ++ if null (_cr_tools req)
     then maybe [] (\tc -> ["tool_choice" .= encodeToolChoice tc]) (_cr_toolChoice req)
     else ("tools" .= map encodeTool (_cr_tools req))
        : maybe [] (\tc -> ["tool_choice" .= encodeToolChoice tc]) (_cr_toolChoice req)

-- | Stream a completion from the Anthropic API.
-- Processes SSE events and emits StreamEvent callbacks. Accumulates
-- the full response for the final StreamDone event.
anthropicCompleteStream :: AnthropicProvider -> CompletionRequest -> (StreamEvent -> IO ()) -> IO ()
anthropicCompleteStream provider req callback = do
  authHeaders <- buildAuthHeaders provider
  initReq <- HTTP.parseRequest anthropicBaseUrl
  let httpReq = initReq
        { HTTP.method         = "POST"
        , HTTP.requestBody    = HTTP.RequestBodyLBS (encodeStreamRequest req)
        , HTTP.requestHeaders = authHeaders
        }
  HTTP.withResponse httpReq (_ap_manager provider) $ \resp -> do
    let status = Status.statusCode (HTTP.responseStatus resp)
    if status /= 200
      then do
        body <- BL.toStrict <$> HTTP.brReadSome (HTTP.responseBody resp) (1024 * 1024)
        throwIO (AnthropicAPIError status body)
      else do
        st <- newStreamState
        bufRef <- newIORef BS.empty
        let readChunks = do
              chunk <- HTTP.brRead (HTTP.responseBody resp)
              if BS.null chunk
                then do
                  finalResp <- finalizeStream st
                  callback (StreamDone finalResp)
                else do
                  buf <- readIORef bufRef
                  let fullBuf = buf <> chunk
                      (lines', remaining) = splitSSELines fullBuf
                  writeIORef bufRef remaining
                  mapM_ (processStreamLine st callback) lines'
                  readChunks
        readChunks

-- | Split a buffer into complete SSE lines and remaining partial data.
splitSSELines :: ByteString -> ([ByteString], ByteString)
splitSSELines bs =
  let parts = BS.splitWith (== 0x0a) bs  -- split on newline
  in case parts of
    [] -> ([], BS.empty)
    _ -> (init parts, last parts)

-- | Mutable accumulator for streaming SSE responses. Tracks the
-- evolving list of content blocks, the model id, usage stats, and any
-- tool_use block currently being assembled (whose JSON input arrives
-- across multiple deltas).
data StreamState = StreamState
  { _ss_blocksRef :: IORef [ContentBlock]   -- ^ Reversed: head is most-recent block
  , _ss_modelRef  :: IORef ModelId
  , _ss_usageRef  :: IORef (Maybe Usage)
  , _ss_toolRef   :: IORef (Maybe ToolBuilder)
  }

-- | A tool_use block being assembled mid-stream. Inputs arrive as
-- a sequence of @input_json_delta@ fragments which must be concatenated
-- and parsed once @content_block_stop@ closes the block.
data ToolBuilder = ToolBuilder
  { _tb_id    :: ToolCallId
  , _tb_name  :: Text
  , _tb_input :: ByteString
  }

newStreamState :: IO StreamState
newStreamState = StreamState
  <$> newIORef []
  <*> newIORef (ModelId "")
  <*> newIORef Nothing
  <*> newIORef Nothing

-- | Process a single SSE 'data:' line, updating state and emitting
-- 'StreamEvent' callbacks. Non-data lines, unparseable JSON, and
-- unknown event types are silently ignored.
processStreamLine :: StreamState -> (StreamEvent -> IO ()) -> ByteString -> IO ()
processStreamLine st callback line =
  case parseSSELine line of
    Nothing -> pure ()
    Just json -> case parseEither parseStreamEvent json of
      Left _ -> pure ()
      Right evt -> case evt of
        SSEContentText t -> do
          callback (StreamText t)
          -- Accumulate streamed text into a single TextBlock rather than
          -- creating one per chunk (which would insert spurious newlines
          -- when responseText joins them with "\n").
          modifyIORef (_ss_blocksRef st) $ \blocks -> case blocks of
            (TextBlock prev : rest) -> TextBlock (prev <> t) : rest
            _                       -> TextBlock t : blocks
        SSEToolStart callId name -> do
          -- Defensive: close any tool that didn't get an explicit stop.
          finalizeCurrentTool st
          writeIORef (_ss_toolRef st)
            (Just (ToolBuilder callId name BS.empty))
          callback (StreamToolUse callId name)
        SSEToolDelta t -> do
          modifyIORef (_ss_toolRef st) $ fmap $ \tb ->
            tb { _tb_input = _tb_input tb <> TE.encodeUtf8 t }
          callback (StreamToolInput t)
        SSEContentBlockStop -> finalizeCurrentTool st
        SSEMessageStart model -> writeIORef (_ss_modelRef st) model
        SSEUsage usage -> writeIORef (_ss_usageRef st) (Just usage)
        SSEMessageStop -> pure ()

-- | Close out any in-progress tool_use block: parse the accumulated
-- JSON input and push the completed 'ToolUseBlock' onto blocks.
-- A malformed or empty buffer falls back to an empty object so the
-- block isn't lost — downstream tool execution will surface any
-- schema mismatch as a normal tool error.
finalizeCurrentTool :: StreamState -> IO ()
finalizeCurrentTool st = do
  mTool <- readIORef (_ss_toolRef st)
  case mTool of
    Nothing -> pure ()
    Just tb -> do
      let input = case decode (BL.fromStrict (_tb_input tb)) of
            Just v  -> v
            Nothing -> object []
      modifyIORef (_ss_blocksRef st)
        (ToolUseBlock (_tb_id tb) (_tb_name tb) input :)
      writeIORef (_ss_toolRef st) Nothing

-- | Finalize the accumulator into a 'CompletionResponse'. Any
-- still-open tool block is closed defensively.
finalizeStream :: StreamState -> IO CompletionResponse
finalizeStream st = do
  finalizeCurrentTool st
  blocks <- readIORef (_ss_blocksRef st)
  model  <- readIORef (_ss_modelRef st)
  usage  <- readIORef (_ss_usageRef st)
  pure CompletionResponse
    { _crsp_content = reverse blocks
    , _crsp_model   = model
    , _crsp_usage   = usage
    }

-- | Parse an SSE "data: ..." line into a JSON value.
parseSSELine :: ByteString -> Maybe Value
parseSSELine bs
  | BS.isPrefixOf "data: " bs =
      let jsonBs = BS.drop 6 bs
      in decode (BL.fromStrict jsonBs)
  | otherwise = Nothing

-- | Internal SSE event types.
data SSEEvent
  = SSEContentText Text
  | SSEToolStart ToolCallId Text
  | SSEToolDelta Text
  | SSEContentBlockStop
  | SSEMessageStart ModelId
  | SSEUsage Usage
  | SSEMessageStop

-- | Parse a JSON SSE event.
parseStreamEvent :: Value -> Parser SSEEvent
parseStreamEvent = withObject "SSEEvent" $ \o -> do
  eventType <- o .: "type"
  case (eventType :: Text) of
    "message_start" -> do
      msg <- o .: "message"
      model <- msg .: "model"
      pure (SSEMessageStart (ModelId model))
    "content_block_delta" -> do
      delta <- o .: "delta"
      deltaType <- delta .: "type"
      case (deltaType :: Text) of
        "text_delta" -> SSEContentText <$> delta .: "text"
        "input_json_delta" -> SSEToolDelta <$> delta .: "partial_json"
        _ -> fail $ "Unknown delta type: " <> T.unpack deltaType
    "content_block_start" -> do
      block <- o .: "content_block"
      blockType <- block .: "type"
      case (blockType :: Text) of
        "tool_use" -> do
          callId <- block .: "id"
          name <- block .: "name"
          pure (SSEToolStart (ToolCallId callId) name)
        _ -> fail "Ignored block start"
    "content_block_stop" -> pure SSEContentBlockStop
    "message_delta" -> do
      usage <- o .:? "usage"
      case usage of
        Just u -> do
          outToks <- u .: "output_tokens"
          pure (SSEUsage (Usage 0 outToks))
        Nothing -> pure SSEMessageStop
    "message_stop" -> pure SSEMessageStop
    _ -> fail $ "Unknown event type: " <> T.unpack eventType
