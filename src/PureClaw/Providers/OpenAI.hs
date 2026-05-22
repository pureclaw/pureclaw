module PureClaw.Providers.OpenAI
  ( -- * Provider type
    OpenAIProvider
  , mkOpenAIProvider
    -- * Errors
  , OpenAIError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
    -- * Model listing (exported for testing)
  , isChatEligibleOpenAIModel
  , parseOpenAIModelIds
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
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

-- | OpenAI API provider.
data OpenAIProvider = OpenAIProvider
  { _oai_manager :: HTTP.Manager
  , _oai_apiKey  :: ApiKey
  , _oai_baseUrl :: String
  }

-- | Create an OpenAI provider. Uses the standard OpenAI API base URL.
mkOpenAIProvider :: HTTP.Manager -> ApiKey -> OpenAIProvider
mkOpenAIProvider mgr key = OpenAIProvider mgr key "https://api.openai.com/v1/chat/completions"

instance Provider OpenAIProvider where
  complete = openAIComplete
  listModels = openAIListModels

-- | Errors from the OpenAI API.
data OpenAIError
  = OpenAIAPIError Int ByteString
  | OpenAIParseError Text
  deriving stock (Show)

instance Exception OpenAIError

instance ToPublicError OpenAIError where
  toPublicError (OpenAIAPIError 429 _) = RateLimitError
  toPublicError (OpenAIAPIError 401 _) = NotAllowedError
  toPublicError _                       = TemporaryError "Provider error"

openAIComplete :: OpenAIProvider -> CompletionRequest -> IO CompletionResponse
openAIComplete provider req = do
  initReq <- HTTP.parseRequest (_oai_baseUrl provider)
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders =
            [ ("Authorization", "Bearer " <> withApiKey (_oai_apiKey provider) id)
            , ("content-type", "application/json")
            ]
        }
  resp <- HTTP.httpLbs httpReq (_oai_manager provider)
  let status = Status.statusCode (HTTP.responseStatus resp)
  if status /= 200
    then throwIO (OpenAIAPIError status (BL.toStrict (HTTP.responseBody resp)))
    else case decodeResponse (HTTP.responseBody resp) of
      Left err -> throwIO (OpenAIParseError (T.pack err))
      Right response -> pure response

-- | Encode a completion request as OpenAI Chat Completions JSON.
encodeRequest :: CompletionRequest -> BL.ByteString
encodeRequest req = encode $ object $
  [ "model"    .= unModelId (_cr_model req)
  , "messages" .= encodeMessages req
  ]
  ++ maybe [] (\mt -> ["max_tokens" .= mt]) (_cr_maxTokens req)
  ++ ["tools" .= map encodeTool (_cr_tools req) | not (null (_cr_tools req))]
  ++ maybe [] (\tc -> ["tool_choice" .= encodeToolChoice tc]) (_cr_toolChoice req)

-- | OpenAI puts system prompt as a system message in the messages array.
encodeMessages :: CompletionRequest -> [Value]
encodeMessages req =
  maybe [] (\s -> [object ["role" .= ("system" :: Text), "content" .= s]]) (_cr_systemPrompt req)
  ++ map encodeMsg (_cr_messages req)

encodeMsg :: Message -> Value
encodeMsg msg = case _msg_content msg of
  [TextBlock t] ->
    -- Simple text message — use string content for compatibility
    object ["role" .= roleToText (_msg_role msg), "content" .= t]
  blocks ->
    object [ "role"    .= roleToText (_msg_role msg)
           , "content" .= map encodeContentBlock blocks
           ]

encodeContentBlock :: ContentBlock -> Value
encodeContentBlock (TextBlock t) = object
  [ "type" .= ("text" :: Text), "text" .= t ]
encodeContentBlock (ImageBlock mediaType imageData) = object
  [ "type" .= ("image_url" :: Text)
  , "image_url" .= object
      [ "url" .= ("data:" <> mediaType <> ";base64," <> TE.decodeUtf8 imageData) ]
  ]
encodeContentBlock (ToolUseBlock callId name input) = object
  [ "type" .= ("function" :: Text)
  , "id"   .= unToolCallId callId
  , "function" .= object ["name" .= name, "arguments" .= TE.decodeUtf8 (BL.toStrict (encode input))]
  ]
encodeContentBlock (ToolResultBlock callId parts _) = object
  [ "type"         .= ("tool_result" :: Text)
  , "tool_call_id" .= unToolCallId callId
  , "content"      .= T.intercalate "\n" [t | TRPText t <- parts]
  ]

encodeTool :: ToolDefinition -> Value
encodeTool td = object
  [ "type" .= ("function" :: Text)
  , "function" .= object
      [ "name"        .= _td_name td
      , "description" .= _td_description td
      , "parameters"  .= _td_inputSchema td
      ]
  ]

encodeToolChoice :: ToolChoice -> Value
encodeToolChoice AutoTool = String "auto"
encodeToolChoice AnyTool = String "required"
encodeToolChoice (SpecificTool name) = object
  [ "type" .= ("function" :: Text)
  , "function" .= object ["name" .= name]
  ]

-- | Decode an OpenAI Chat Completions response.
decodeResponse :: BL.ByteString -> Either String CompletionResponse
decodeResponse bs = eitherDecode bs >>= parseEither parseResp
  where
    parseResp :: Value -> Parser CompletionResponse
    parseResp = withObject "OpenAIResponse" $ \o -> do
      choices <- o .: "choices"
      case choices of
        [] -> fail "No choices in response"
        (firstChoice : _) -> do
          msg <- firstChoice .: "message"
          blocks <- parseMessage msg
          modelText <- o .: "model"
          usageObj <- o .:? "usage"
          usage <- case usageObj of
            Nothing -> pure Nothing
            Just u -> do
              inToks <- u .: "prompt_tokens"
              outToks <- u .: "completion_tokens"
              pure (Just (Usage inToks outToks))
          pure CompletionResponse
            { _crsp_content = blocks
            , _crsp_model   = ModelId modelText
            , _crsp_usage   = usage
            }

    parseMessage :: Value -> Parser [ContentBlock]
    parseMessage = withObject "Message" $ \m -> do
      contentVal <- m .:? "content"
      toolCalls <- m .:? "tool_calls" .!= ([] :: [Value])
      let textBlocks = case contentVal of
            Just (String t) | not (T.null t) -> [TextBlock t]
            _ -> []
      toolBlocks <- mapM parseToolCall toolCalls
      pure (textBlocks ++ toolBlocks)

    parseToolCall :: Value -> Parser ContentBlock
    parseToolCall = withObject "ToolCall" $ \tc -> do
      callId <- tc .: "id"
      fn <- tc .: "function"
      name <- fn .: "name"
      argsStr <- fn .: "arguments"
      let input = fromMaybe (object []) (decode (BL.fromStrict (TE.encodeUtf8 argsStr)))
      pure (ToolUseBlock (ToolCallId callId) name input)

-- | OpenAI Models listing endpoint.
openAIModelsUrl :: String
openAIModelsUrl = "https://api.openai.com/v1/models"

-- | List available models for the authenticated OpenAI account, filtered
-- to chat-completion-eligible IDs. Returns an empty list on any error.
openAIListModels :: OpenAIProvider -> IO [ModelId]
openAIListModels provider = do
  result <- try @SomeException $ do
    initReq <- HTTP.parseRequest openAIModelsUrl
    let httpReq = initReq
          { HTTP.method = "GET"
          , HTTP.requestHeaders =
              [ ("Authorization", "Bearer " <> withApiKey (_oai_apiKey provider) id)
              , ("content-type", "application/json")
              ]
          , HTTP.responseTimeout = HTTP.responseTimeoutMicro (30 * 1000000)
          }
    resp <- HTTP.httpLbs httpReq (_oai_manager provider)
    let status = Status.statusCode (HTTP.responseStatus resp)
    if status /= 200
      then pure []
      else case eitherDecode (HTTP.responseBody resp) of
        Left  _   -> pure []
        Right val -> pure (filter (isChatEligibleOpenAIModel . unModelId) (parseOpenAIModelIds val))
  case result of
    Left  _   -> pure []
    Right ids -> pure ids

-- | Extract model IDs from an OpenAI /v1/models response body.
-- Expected shape: @{"object":"list","data":[{"id":"gpt-4o","object":"model",...},...]}@
parseOpenAIModelIds :: Value -> [ModelId]
parseOpenAIModelIds = fromMaybe [] . parseMaybe parseList
  where
    parseList :: Value -> Parser [ModelId]
    parseList = withObject "OpenAIModelsResponse" $ \o -> do
      arr <- o .: "data"
      mapM (withObject "Model" (\m -> ModelId <$> m .: "id")) arr

-- | Filter to chat-completion-eligible OpenAI model IDs.
-- The /v1/models endpoint returns hundreds of entries spanning embeddings,
-- audio, image, moderation, and fine-tuning models — most of which can't
-- be used with /chat/completions. We keep IDs that start with a known
-- chat-family prefix and don't contain a known non-chat substring.
isChatEligibleOpenAIModel :: Text -> Bool
isChatEligibleOpenAIModel mid =
  any (`T.isPrefixOf` mid) chatPrefixes
    && not (any (`T.isInfixOf` mid) nonChatSubstrings)
  where
    chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
    nonChatSubstrings =
      [ "-instruct"
      , "audio"
      , "realtime"
      , "tts"
      , "whisper"
      , "dall-e"
      , "embedding"
      , "moderation"
      , "search-preview"
      , "transcribe"
      , "image"
      ]
