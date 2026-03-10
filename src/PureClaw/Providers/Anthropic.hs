module PureClaw.Providers.Anthropic
  ( -- * Provider type (constructor intentionally NOT exported)
    AnthropicProvider
  , mkAnthropicProvider
    -- * Errors
  , AnthropicError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
    -- * SSE parsing (exported for testing)
  , parseSSELine
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
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Security.Secrets

-- | Anthropic API provider. Constructor is not exported — use
-- 'mkAnthropicProvider'.
data AnthropicProvider = AnthropicProvider
  { _ap_manager :: HTTP.Manager
  , _ap_apiKey  :: ApiKey
  }

-- | Create an Anthropic provider with an HTTP manager and API key.
mkAnthropicProvider :: HTTP.Manager -> ApiKey -> AnthropicProvider
mkAnthropicProvider = AnthropicProvider

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
  initReq <- HTTP.parseRequest anthropicBaseUrl
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders =
            [ ("x-api-key", withApiKey (_ap_apiKey provider) id)
            , ("anthropic-version", "2023-06-01")
            , ("content-type", "application/json")
            ]
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
  initReq <- HTTP.parseRequest anthropicBaseUrl
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeStreamRequest req)
        , HTTP.requestHeaders =
            [ ("x-api-key", withApiKey (_ap_apiKey provider) id)
            , ("anthropic-version", "2023-06-01")
            , ("content-type", "application/json")
            ]
        }
  HTTP.withResponse httpReq (_ap_manager provider) $ \resp -> do
    let status = Status.statusCode (HTTP.responseStatus resp)
    if status /= 200
      then do
        body <- BL.toStrict <$> HTTP.brReadSome (HTTP.responseBody resp) (1024 * 1024)
        throwIO (AnthropicAPIError status body)
      else do
        -- Accumulate content blocks and usage as events arrive
        blocksRef <- newIORef ([] :: [ContentBlock])
        modelRef <- newIORef (ModelId "")
        usageRef <- newIORef (Nothing :: Maybe Usage)
        bufRef <- newIORef BS.empty
        let readChunks = do
              chunk <- HTTP.brRead (HTTP.responseBody resp)
              if BS.null chunk
                then do
                  -- Stream ended — emit final response
                  blocks <- readIORef blocksRef
                  model <- readIORef modelRef
                  usage <- readIORef usageRef
                  callback $ StreamDone CompletionResponse
                    { _crsp_content = reverse blocks
                    , _crsp_model   = model
                    , _crsp_usage   = usage
                    }
                else do
                  buf <- readIORef bufRef
                  let fullBuf = buf <> chunk
                      (lines', remaining) = splitSSELines fullBuf
                  writeIORef bufRef remaining
                  mapM_ (processSSELine blocksRef modelRef usageRef callback) lines'
                  readChunks
        readChunks

-- | Split a buffer into complete SSE lines and remaining partial data.
splitSSELines :: ByteString -> ([ByteString], ByteString)
splitSSELines bs =
  let parts = BS.splitWith (== 0x0a) bs  -- split on newline
  in case parts of
    [] -> ([], BS.empty)
    _ -> (init parts, last parts)

-- | Process a single SSE line.
processSSELine :: IORef [ContentBlock] -> IORef ModelId -> IORef (Maybe Usage) -> (StreamEvent -> IO ()) -> ByteString -> IO ()
processSSELine blocksRef modelRef usageRef callback line =
  case parseSSELine line of
    Nothing -> pure ()
    Just json -> case parseEither parseStreamEvent json of
      Left _ -> pure ()
      Right evt -> case evt of
        SSEContentText t -> do
          callback (StreamText t)
          modifyIORef blocksRef (TextBlock t :)
        SSEToolStart callId name ->
          callback (StreamToolUse callId name)
        SSEToolDelta t ->
          callback (StreamToolInput t)
        SSEMessageStart model -> writeIORef modelRef model
        SSEUsage usage -> writeIORef usageRef (Just usage)
        SSEMessageStop -> pure ()

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
    "message_delta" -> do
      usage <- o .:? "usage"
      case usage of
        Just u -> do
          outToks <- u .: "output_tokens"
          pure (SSEUsage (Usage 0 outToks))
        Nothing -> pure SSEMessageStop
    "message_stop" -> pure SSEMessageStop
    _ -> fail $ "Unknown event type: " <> T.unpack eventType
