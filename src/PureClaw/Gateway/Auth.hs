module PureClaw.Gateway.Auth
  ( -- * Authentication
    authenticateRequest
  , AuthError (..)
    -- * Pairing
  , handlePairRequest
  , PairRequest (..)
  , PairResponse (..)
  ) where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString qualified as BS

import PureClaw.Core.Errors
import PureClaw.Handles.Log
import PureClaw.Security.Pairing
import PureClaw.Security.Secrets

-- | Authentication errors.
data AuthError
  = MissingToken
  | InvalidToken
  | MalformedHeader
  deriving stock (Show, Eq)

instance ToPublicError AuthError where
  toPublicError _ = NotAllowedError

-- | Extract and validate a bearer token from an Authorization header value.
-- Expects the format: "Bearer <token>"
authenticateRequest :: PairingState -> ByteString -> LogHandle -> IO (Either AuthError ())
authenticateRequest ps authHeader lh =
  case extractToken authHeader of
    Nothing -> do
      _lh_logWarn lh "Auth: malformed Authorization header"
      pure (Left MalformedHeader)
    Just tokenBytes -> do
      let rawBytes = Base16.decodeLenient tokenBytes
          token = mkBearerToken rawBytes
      valid <- verifyToken ps token
      if valid
        then pure (Right ())
        else do
          _lh_logWarn lh "Auth: invalid bearer token"
          pure (Left InvalidToken)

-- | Extract the raw token bytes from a "Bearer <token>" header value.
extractToken :: ByteString -> Maybe ByteString
extractToken header =
  let prefix = "Bearer "
  in if BS.isPrefixOf prefix header
     then Just (BS.drop (BS.length prefix) header)
     else Nothing

-- | Request body for the /pair endpoint.
newtype PairRequest = PairRequest
  { _pr_code :: Text
  }
  deriving stock (Show, Eq)

instance FromJSON PairRequest where
  parseJSON = withObject "PairRequest" $ \o ->
    PairRequest <$> o .: "code"

-- | Response body for a successful pairing.
newtype PairResponse = PairResponse
  { _prsp_token :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON PairResponse where
  toJSON pr = object ["token" .= _prsp_token pr]

-- | Handle a pairing request: validate the code and return a bearer token.
handlePairRequest :: PairingState -> Text -> PairRequest -> LogHandle -> IO (Either PairingError PairResponse)
handlePairRequest ps clientId req lh = do
  let code = mkPairingCode (_pr_code req)
  _lh_logInfo lh $ "Pair: attempt from client " <> clientId
  result <- attemptPair ps clientId code
  case result of
    Left err -> do
      _lh_logWarn lh $ "Pair: failed for client " <> clientId
      pure (Left err)
    Right token ->
      withBearerToken token $ \tokenBytes -> do
        _lh_logInfo lh $ "Pair: success for client " <> clientId
        pure (Right (PairResponse (TE.decodeUtf8 (Base16.encode tokenBytes))))
