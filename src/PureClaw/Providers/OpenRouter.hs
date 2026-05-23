module PureClaw.Providers.OpenRouter
  ( -- * Provider type
    OpenRouterProvider
  , mkOpenRouterProvider
    -- * Errors
  , OpenRouterError (..)
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
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Providers.OpenAI qualified as OAI
import PureClaw.Security.Secrets

-- | OpenRouter provider. Uses the OpenAI-compatible API with a
-- different base URL and authentication header.
data OpenRouterProvider = OpenRouterProvider
  { _or_manager :: HTTP.Manager
  , _or_apiKey  :: ApiKey
  }

-- | Create an OpenRouter provider.
mkOpenRouterProvider :: HTTP.Manager -> ApiKey -> OpenRouterProvider
mkOpenRouterProvider = OpenRouterProvider

instance Provider OpenRouterProvider where
  complete = openRouterComplete
  listModels = openRouterListModels

-- | Errors from the OpenRouter API.
data OpenRouterError
  = OpenRouterAPIError Int ByteString
  | OpenRouterParseError Text
  deriving stock (Show)

instance Exception OpenRouterError

instance ToPublicError OpenRouterError where
  toPublicError (OpenRouterAPIError 429 _) = RateLimitError
  toPublicError (OpenRouterAPIError 401 _) = NotAllowedError
  toPublicError _                           = TemporaryError "Provider error"

openRouterBaseUrl :: String
openRouterBaseUrl = "https://openrouter.ai/api/v1/chat/completions"

openRouterComplete :: OpenRouterProvider -> CompletionRequest -> IO CompletionResponse
openRouterComplete provider req = do
  initReq <- HTTP.parseRequest openRouterBaseUrl
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders =
            [ ("Authorization", "Bearer " <> withApiKey (_or_apiKey provider) id)
            , ("content-type", "application/json")
            , ("HTTP-Referer", "https://github.com/pureclaw/pureclaw")
            , ("X-Title", "PureClaw")
            ]
        }
  resp <- HTTP.httpLbs httpReq (_or_manager provider)
  let status = Status.statusCode (HTTP.responseStatus resp)
  if status /= 200
    then throwIO (OpenRouterAPIError status (BL.toStrict (HTTP.responseBody resp)))
    else case decodeResponse (HTTP.responseBody resp) of
      Left err -> throwIO (OpenRouterParseError (T.pack err))
      Right response -> pure response

-- | Encode request — reuses OpenAI format.
encodeRequest :: CompletionRequest -> BL.ByteString
encodeRequest = OAI.encodeRequest

-- | Decode response — reuses OpenAI format.
decodeResponse :: BL.ByteString -> Either String CompletionResponse
decodeResponse = OAI.decodeResponse

-- | OpenRouter Models listing endpoint.
openRouterModelsUrl :: String
openRouterModelsUrl = "https://openrouter.ai/api/v1/models"

-- | List available models on OpenRouter. Returns an empty list on any error.
openRouterListModels :: OpenRouterProvider -> IO [ModelId]
openRouterListModels provider = do
  result <- try @SomeException $ do
    initReq <- HTTP.parseRequest openRouterModelsUrl
    let httpReq = initReq
          { HTTP.method = "GET"
          , HTTP.requestHeaders =
              [ ("Authorization", "Bearer " <> withApiKey (_or_apiKey provider) id)
              , ("HTTP-Referer", "https://github.com/pureclaw/pureclaw")
              , ("X-Title", "PureClaw")
              ]
          , HTTP.responseTimeout = HTTP.responseTimeoutMicro (30 * 1000000)
          }
    resp <- HTTP.httpLbs httpReq (_or_manager provider)
    let status = Status.statusCode (HTTP.responseStatus resp)
    if status /= 200
      then pure []
      else case eitherDecode (HTTP.responseBody resp) of
        Left  _   -> pure []
        Right val -> pure (parseOpenRouterModelIds val)
  case result of
    Left  _   -> pure []
    Right ids -> pure ids

-- | Extract model IDs from an OpenRouter /v1/models response body.
-- Expected shape: @{"data":[{"id":"anthropic/claude-3.5-sonnet","name":"...",...},...]}@
parseOpenRouterModelIds :: Value -> [ModelId]
parseOpenRouterModelIds = fromMaybe [] . parseMaybe parseList
  where
    parseList :: Value -> Parser [ModelId]
    parseList = withObject "OpenRouterModelsResponse" $ \o -> do
      arr <- o .: "data"
      mapM (withObject "Model" (\m -> ModelId <$> m .: "id")) arr
