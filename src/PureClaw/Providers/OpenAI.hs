module PureClaw.Providers.OpenAI
  ( -- * Provider type
    OpenAIProvider
  , mkOpenAIProvider
    -- * Errors
  , OpenAIError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
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
