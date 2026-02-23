module PureClaw.Gateway.Routes
  ( -- * WAI Application
    mkApp
    -- * Request/Response types
  , WebhookRequest (..)
  , WebhookResponse (..)
  , ErrorResponse (..)
  , HealthResponse (..)
  ) where

import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
import Network.Wai

import PureClaw.Core.Errors
import PureClaw.Gateway.Auth
import PureClaw.Handles.Log
import PureClaw.Security.Pairing

-- | Health check response.
newtype HealthResponse = HealthResponse
  { _hr_status :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON HealthResponse where
  toJSON hr = object ["status" .= _hr_status hr]

-- | Error response (safe for external consumers).
newtype ErrorResponse = ErrorResponse
  { _er_error :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON ErrorResponse where
  toJSON er = object ["error" .= _er_error er]

-- | Webhook request body.
data WebhookRequest = WebhookRequest
  { _wr_userId  :: Text
  , _wr_content :: Text
  }
  deriving stock (Show, Eq)

instance FromJSON WebhookRequest where
  parseJSON = withObject "WebhookRequest" $ \o ->
    WebhookRequest <$> o .: "userId" <*> o .: "content"

-- | Webhook response body.
newtype WebhookResponse = WebhookResponse
  { _wrs_status :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON WebhookResponse where
  toJSON wr = object ["status" .= _wrs_status wr]

-- | Build a WAI Application from the gateway dependencies.
mkApp :: PairingState -> LogHandle -> Application
mkApp ps lh request respond = do
  let method = requestMethod request
      path = pathInfo request
  case (method, path) of
    ("GET",  ["health"])  -> handleHealth respond
    ("POST", ["pair"])    -> handlePair ps lh request respond
    ("POST", ["webhook"]) -> handleWebhook ps lh request respond
    _                     -> respondError respond status404 "Not found"

handleHealth :: (Response -> IO ResponseReceived) -> IO ResponseReceived
handleHealth respond =
  respond $ jsonResponse status200 (HealthResponse "ok")

handlePair :: PairingState -> LogHandle -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handlePair ps lh req respond = do
  body <- consumeRequestBody req
  case eitherDecode body of
    Left _ -> respondError respond status400 "Invalid JSON"
    Right pairReq -> do
      let clientId = clientIdFromRequest req
      result <- handlePairRequest ps clientId pairReq lh
      case result of
        Left err -> respondPairingError respond err
        Right pairResp -> respond $ jsonResponse status200 pairResp

handleWebhook :: PairingState -> LogHandle -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleWebhook ps lh req respond =
  case lookup hAuthorization (requestHeaders req) of
    Nothing -> do
      _lh_logWarn lh "Webhook: missing Authorization header"
      respondError respond status401 (publicErrorText NotAllowedError)
    Just authHeader -> do
      authResult <- authenticateRequest ps authHeader lh
      case authResult of
        Left _ -> respondError respond status401 (publicErrorText NotAllowedError)
        Right () -> do
          body <- consumeRequestBody req
          case eitherDecode body :: Either String WebhookRequest of
            Left _ -> respondError respond status400 "Invalid JSON"
            Right _webhookReq -> do
              _lh_logInfo lh "Webhook: received message"
              respond $ jsonResponse status200 (WebhookResponse "received")

-- | Consume the full request body into a lazy ByteString.
consumeRequestBody :: Request -> IO LBS.ByteString
consumeRequestBody req = LBS.fromChunks <$> collectChunks
  where
    collectChunks = do
      chunk <- getRequestBodyChunk req
      if BS.null chunk
        then pure []
        else (chunk :) <$> collectChunks

-- | Build a JSON response with the given status code.
jsonResponse :: ToJSON a => Status -> a -> Response
jsonResponse st body =
  responseLBS st [(hContentType, "application/json")] (encode body)

-- | Build an error response.
respondError :: (Response -> IO ResponseReceived) -> Status -> Text -> IO ResponseReceived
respondError respond st msg =
  respond $ jsonResponse st (ErrorResponse msg)

-- | Map PairingError to HTTP response.
respondPairingError :: (Response -> IO ResponseReceived) -> PairingError -> IO ResponseReceived
respondPairingError respond InvalidCode = respondError respond status400 "InvalidCode"
respondPairingError respond LockedOut   = respondError respond status429 "LockedOut"
respondPairingError respond CodeExpired = respondError respond status400 "CodeExpired"

-- | Convert PublicError to user-facing text.
publicErrorText :: PublicError -> Text
publicErrorText (TemporaryError msg) = msg
publicErrorText RateLimitError = "Rate limit exceeded"
publicErrorText NotAllowedError = "Not allowed"

-- | Extract a client identifier from the request (X-Forwarded-For or remote host).
clientIdFromRequest :: Request -> Text
clientIdFromRequest req =
  case lookup "X-Forwarded-For" (requestHeaders req) of
    Just xff -> TE.decodeUtf8 xff
    Nothing  -> T.pack (show (remoteHost req))
