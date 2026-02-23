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
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Errors
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
