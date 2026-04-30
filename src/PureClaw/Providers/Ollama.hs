module PureClaw.Providers.Ollama
  ( -- * Provider type
    OllamaProvider
  , mkOllamaProvider
  , mkOllamaProviderWithUrl
    -- * Errors
  , OllamaError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
    -- * Model listing (exported for testing)
  , parseModelNames
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe qualified
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Providers.Class

-- | Ollama provider for local model inference.
data OllamaProvider = OllamaProvider
  { _ol_manager :: HTTP.Manager
  , _ol_baseUrl :: String    -- ^ Base URL without endpoint path (e.g. "http://localhost:11434")
  }

-- | Create an Ollama provider. Defaults to localhost:11434.
mkOllamaProvider :: HTTP.Manager -> OllamaProvider
mkOllamaProvider mgr = OllamaProvider mgr "http://localhost:11434"

-- | Create an Ollama provider with a custom base URL.
-- The URL should be the base (e.g. @http://myhost:11434@).
mkOllamaProviderWithUrl :: HTTP.Manager -> String -> OllamaProvider
mkOllamaProviderWithUrl mgr url =
  let trimmed = reverse (dropWhile (== '/') (reverse url))
  in OllamaProvider mgr trimmed

instance Provider OllamaProvider where
  complete = ollamaComplete
  listModels = ollamaListModels

-- | Errors from the Ollama API.
data OllamaError
  = OllamaAPIError Int ByteString
  | OllamaParseError Text
  deriving stock (Show)

instance Exception OllamaError

instance ToPublicError OllamaError where
  toPublicError _ = TemporaryError "Provider error"

ollamaComplete :: OllamaProvider -> CompletionRequest -> IO CompletionResponse
ollamaComplete provider req = do
  initReq <- HTTP.parseRequest (_ol_baseUrl provider ++ "/api/chat")
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders = [("content-type", "application/json")]
        , HTTP.responseTimeout = HTTP.responseTimeoutMicro (5 * 60 * 1000000)  -- 5 minutes
        }
  resp <- HTTP.httpLbs httpReq (_ol_manager provider)
  let status = Status.statusCode (HTTP.responseStatus resp)
  if status /= 200
    then throwIO (OllamaAPIError status (BL.toStrict (HTTP.responseBody resp)))
    else case decodeResponse (HTTP.responseBody resp) of
      Left err -> throwIO (OllamaParseError (T.pack err))
      Right response -> pure response

-- | Encode a request for the Ollama /api/chat endpoint.
-- Ollama uses system messages in the messages array and a simpler
-- tool format than OpenAI.
encodeRequest :: CompletionRequest -> BL.ByteString
encodeRequest req = encode $ object $
  [ "model"    .= unModelId (_cr_model req)
  , "messages" .= encodeMessages req
  , "stream"   .= False
  ]
  ++ ["tools" .= map encodeTool (_cr_tools req) | not (null (_cr_tools req))]

encodeMessages :: CompletionRequest -> [Value]
encodeMessages req =
  maybe [] (\s -> [object ["role" .= ("system" :: Text), "content" .= s]]) (_cr_systemPrompt req)
  ++ map encodeMsg (_cr_messages req)

encodeMsg :: Message -> Value
encodeMsg msg = case _msg_content msg of
  [TextBlock t] ->
    object ["role" .= roleToText (_msg_role msg), "content" .= t]
  blocks ->
    -- Ollama supports content as string only; concatenate text blocks
    let textParts = concatMap blockText blocks
    in object ["role" .= roleToText (_msg_role msg), "content" .= T.intercalate "\n" textParts]

blockText :: ContentBlock -> [Text]
blockText (TextBlock t) = [t]
blockText (ImageBlock _ _) = ["[image]"]
blockText (ToolUseBlock _ name _) = ["[tool:" <> name <> "]"]
blockText (ToolResultBlock _ parts _) = [t | TRPText t <- parts]

encodeTool :: ToolDefinition -> Value
encodeTool td = object
  [ "type" .= ("function" :: Text)
  , "function" .= object
      [ "name"        .= _td_name td
      , "description" .= _td_description td
      , "parameters"  .= _td_inputSchema td
      ]
  ]

-- | Decode an Ollama /api/chat response.
decodeResponse :: BL.ByteString -> Either String CompletionResponse
decodeResponse bs = eitherDecode bs >>= parseEither parseResp
  where
    parseResp :: Value -> Parser CompletionResponse
    parseResp = withObject "OllamaResponse" $ \o -> do
      msg <- o .: "message"
      content <- msg .: "content"
      modelText <- o .: "model"
      -- Ollama tool calls come as tool_calls array in the message
      toolCalls <- msg .:? "tool_calls" .!= ([] :: [Value])
      toolBlocks <- mapM parseToolCall toolCalls
      let textBlocks = [TextBlock content | not (T.null content)]
      pure CompletionResponse
        { _crsp_content = textBlocks ++ toolBlocks
        , _crsp_model   = ModelId modelText
        , _crsp_usage   = Nothing  -- Ollama doesn't report usage in chat endpoint
        }

    parseToolCall :: Value -> Parser ContentBlock
    parseToolCall = withObject "ToolCall" $ \tc -> do
      fn <- tc .: "function"
      name <- fn .: "name"
      args <- fn .: "arguments"
      -- Ollama doesn't return a call ID, so generate a placeholder
      pure (ToolUseBlock (ToolCallId ("ollama-" <> name)) name args)

-- | List available models via Ollama's /api/tags endpoint.
-- Returns an empty list on any error (network, parse, etc.).
ollamaListModels :: OllamaProvider -> IO [ModelId]
ollamaListModels provider = do
  result <- try @SomeException $ do
    initReq <- HTTP.parseRequest (_ol_baseUrl provider ++ "/api/tags")
    let tagsReq = initReq { HTTP.responseTimeout = HTTP.responseTimeoutMicro (30 * 1000000) }  -- 30 seconds
    resp <- HTTP.httpLbs tagsReq (_ol_manager provider)
    let status = Status.statusCode (HTTP.responseStatus resp)
    if status /= 200
      then pure []
      else case eitherDecode (HTTP.responseBody resp) of
        Left _    -> pure []
        Right val -> pure (parseModelNames val)
  case result of
    Left _  -> pure []
    Right models -> pure models

-- | Parse model names from Ollama /api/tags response.
-- Expected format: { "models": [{ "name": "llama3:latest", ... }, ...] }
parseModelNames :: Value -> [ModelId]
parseModelNames = Data.Maybe.fromMaybe [] . parseMaybe parseModels
  where
    parseModels :: Value -> Parser [ModelId]
    parseModels = withObject "OllamaTagsResponse" $ \o -> do
      models <- o .: "models"
      mapM (withObject "Model" (\m -> ModelId <$> m .: "name")) models
