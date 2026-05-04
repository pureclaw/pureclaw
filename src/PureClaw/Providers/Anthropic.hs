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
  , splitSSELines
    -- * Stream accumulation (exported for testing)
  , StreamState
  , initialStreamState
  , runStreamLine
  , processStreamLine
  , finalizeStreamState
  ) where

import Control.Exception
import Control.Monad (foldM)
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
encodeRequest = encodeRequestWith False

-- | Internal: shared encoder for streaming and non-streaming requests.
encodeRequestWith :: Bool -> CompletionRequest -> BL.ByteString
encodeRequestWith stream req = encode $ object $
  [ "model"      .= unModelId (_cr_model req)
  , "max_tokens" .= fromMaybe 4096 (_cr_maxTokens req)
  , "messages"   .= map encodeMsg (_cr_messages req)
  ]
  ++ ["stream" .= True | stream]
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
encodeStreamRequest = encodeRequestWith True

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
      else
        let body = HTTP.responseBody resp
            go st buf = do
              chunk <- HTTP.brRead body
              if BS.null chunk
                then callback (StreamDone (finalizeStreamState st))
                else do
                  let (lines', remaining) = splitSSELines (buf <> chunk)
                  st' <- foldM (processStreamLine callback) st lines'
                  go st' remaining
        in go initialStreamState BS.empty

-- | Split a buffer into complete SSE lines and remaining partial data.
-- Strips a trailing CR from each complete line so CRLF-delimited
-- streams parse identically to LF-delimited ones.
--
-- The last element of 'BS.split' is everything after the final newline
-- (possibly empty) — that becomes the carry-forward partial line. The
-- preceding elements are complete lines.
splitSSELines :: ByteString -> ([ByteString], ByteString)
splitSSELines bs = go [] (BS.split 0x0a bs)
  where
    go acc []     = (reverse acc, BS.empty)
    go acc [tl]   = (reverse acc, tl)
    go acc (l:ls) = go (stripCR l : acc) ls
    stripCR b = case BS.unsnoc b of
      Just (rest, 0x0d) -> rest
      _                 -> b

-- | Pure accumulator for streaming SSE responses. Tracks the evolving
-- list of content blocks, the model id, token counts (which arrive in
-- separate events), and any tool_use block currently being assembled
-- (whose JSON input arrives across multiple deltas).
data StreamState = StreamState
  { _ss_blocks       :: [ContentBlock]    -- ^ Reversed: head is most-recent block
  , _ss_model        :: ModelId
  , _ss_inputTokens  :: Maybe Int         -- ^ From @message_start@
  , _ss_outputTokens :: Maybe Int         -- ^ From @message_delta@
  , _ss_tool         :: Maybe ToolBuilder
  }
  deriving stock (Show, Eq)

-- | A tool_use block being assembled mid-stream. Inputs arrive as
-- a sequence of @input_json_delta@ fragments which must be concatenated
-- and parsed once @content_block_stop@ closes the block.
data ToolBuilder = ToolBuilder
  { _tb_id    :: ToolCallId
  , _tb_name  :: Text
  , _tb_input :: ByteString
  }
  deriving stock (Show, Eq)

-- | Initial state at the start of a stream.
initialStreamState :: StreamState
initialStreamState = StreamState [] (ModelId "") Nothing Nothing Nothing

-- | Pure step: apply one parsed SSE event to the state and return any
-- 'StreamEvent's that should be emitted to the caller's callback.
stepStreamState :: SSEEvent -> StreamState -> (StreamState, [StreamEvent])
stepStreamState evt st = case evt of
  SSEContentText t ->
    -- Accumulate streamed text into a single TextBlock rather than
    -- creating one per chunk (which would insert spurious newlines
    -- when 'responseText' joins them with "\n").
    let blocks' = case _ss_blocks st of
          (TextBlock prev : rest) -> TextBlock (prev <> t) : rest
          _                       -> TextBlock t : _ss_blocks st
    in (st { _ss_blocks = blocks' }, [StreamText t])
  SSEToolStart callId name ->
    -- Defensive: close any tool that didn't get an explicit stop.
    let st' = closeOpenTool st
    in (st' { _ss_tool = Just (ToolBuilder callId name BS.empty) },
        [StreamToolUse callId name])
  SSEToolDelta t ->
    let st' = st { _ss_tool = fmap (appendToolInput t) (_ss_tool st) }
    in (st', [StreamToolInput t])
  SSEContentBlockStop -> (closeOpenTool st, [])
  SSEMessageStart model mInTokens ->
    (st { _ss_model = model, _ss_inputTokens = mInTokens }, [])
  SSEOutputUsage outToks ->
    (st { _ss_outputTokens = Just outToks }, [])
  SSEMessageStop -> (st, [])

appendToolInput :: Text -> ToolBuilder -> ToolBuilder
appendToolInput t tb = tb { _tb_input = _tb_input tb <> TE.encodeUtf8 t }

-- | Close the in-progress tool block (if any), parsing its accumulated
-- JSON input. A malformed or empty buffer falls back to 'object []' so
-- the block isn't lost — downstream tool execution will surface any
-- schema mismatch as a normal tool error.
closeOpenTool :: StreamState -> StreamState
closeOpenTool st = case _ss_tool st of
  Nothing -> st
  Just tb ->
    let input = fromMaybe (object []) (decode (BL.fromStrict (_tb_input tb)))
        block = ToolUseBlock (_tb_id tb) (_tb_name tb) input
    in st { _ss_blocks = block : _ss_blocks st, _ss_tool = Nothing }

-- | Pure: parse a single SSE line and step the state. Non-data lines,
-- unparseable JSON, and unknown event types yield no state change and
-- no events.
runStreamLine :: ByteString -> StreamState -> (StreamState, [StreamEvent])
runStreamLine line st = case parseSSELine line of
  Nothing   -> (st, [])
  Just json -> case parseEither parseStreamEvent json of
    Left _    -> (st, [])
    Right evt -> stepStreamState evt st

-- | IO wrapper around 'runStreamLine': step the state, emit any
-- resulting 'StreamEvent's via the callback.
processStreamLine :: (StreamEvent -> IO ()) -> StreamState -> ByteString -> IO StreamState
processStreamLine cb st line = do
  let (st', evs) = runStreamLine line st
  mapM_ cb evs
  pure st'

-- | Finalize the accumulator into a 'CompletionResponse'. Any
-- still-open tool block is closed defensively. Usage is reported only
-- if at least one of input/output tokens was observed.
finalizeStreamState :: StreamState -> CompletionResponse
finalizeStreamState st0 =
  let st = closeOpenTool st0
      mUsage = case (_ss_inputTokens st, _ss_outputTokens st) of
        (Nothing, Nothing) -> Nothing
        (mi, mo)           -> Just (Usage (fromMaybe 0 mi) (fromMaybe 0 mo))
  in CompletionResponse
       { _crsp_content = reverse (_ss_blocks st)
       , _crsp_model   = _ss_model st
       , _crsp_usage   = mUsage
       }

-- | Parse an SSE "data: ..." line into a JSON value. Tolerates a
-- trailing CR for callers that didn't pre-strip CRLF.
parseSSELine :: ByteString -> Maybe Value
parseSSELine bs0
  | BS.isPrefixOf "data: " bs = decode (BL.fromStrict (BS.drop 6 bs))
  | otherwise                 = Nothing
  where
    bs = case BS.unsnoc bs0 of
      Just (rest, 0x0d) -> rest
      _                 -> bs0

-- | Internal SSE event types.
data SSEEvent
  = SSEContentText Text
  | SSEToolStart ToolCallId Text
  | SSEToolDelta Text
  | SSEContentBlockStop
  | SSEMessageStart ModelId (Maybe Int)  -- ^ model, input_tokens (if present)
  | SSEOutputUsage Int                   -- ^ output_tokens from @message_delta@
  | SSEMessageStop
  deriving stock (Show, Eq)

-- | Parse a JSON SSE event.
parseStreamEvent :: Value -> Parser SSEEvent
parseStreamEvent = withObject "SSEEvent" $ \o -> do
  eventType <- o .: "type"
  case (eventType :: Text) of
    "message_start" -> do
      msg     <- o .: "message"
      model   <- msg .: "model"
      mUsage  <- msg .:? "usage"
      mInToks <- case mUsage of
        Nothing -> pure Nothing
        Just u  -> u .:? "input_tokens"
      pure (SSEMessageStart (ModelId model) mInToks)
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
        Just u  -> SSEOutputUsage <$> u .: "output_tokens"
        Nothing -> pure SSEMessageStop
    "message_stop" -> pure SSEMessageStop
    _ -> fail $ "Unknown event type: " <> T.unpack eventType
