module PureClaw.Auth.AnthropicOAuth
  ( -- * Configuration
    OAuthConfig (..)
  , defaultOAuthConfig
    -- * Tokens and handle
  , OAuthTokens (..)
  , OAuthHandle (..)
  , mkOAuthHandle
    -- * PKCE (exported for testing)
  , generateCodeVerifier
  , computeCodeChallenge
    -- * URL building (exported for testing)
  , buildAuthorizationUrl
    -- * Token parsing (exported for testing)
  , parseTokenResponse
    -- * Vault serialization (exported for testing)
  , serializeTokens
  , deserializeTokens
    -- * OAuth flows
  , runOAuthFlow
  , refreshOAuthToken
    -- * Error type
  , OAuthError (..)
  ) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (withAsync)
import Control.Exception (Exception, throwIO, try, SomeException)
import Control.Monad (join)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random qualified as CR
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (renderSimpleQuery, status200)
import Network.HTTP.Types.Status qualified as Status
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.Info (os)
import System.Process.Typed qualified as P
import System.IO (hFlush, stdout)

import PureClaw.Security.Secrets

-- | Configuration for the Anthropic OAuth 2.0 PKCE flow.
data OAuthConfig = OAuthConfig
  { _oac_clientId     :: Text   -- ^ OAuth client ID
  , _oac_authUrl      :: String -- ^ Authorization endpoint URL
  , _oac_tokenUrl     :: String -- ^ Token endpoint URL
  , _oac_callbackPort :: Int    -- ^ Local port for the redirect callback
  }

-- | Default config matching Claude Code's OAuth endpoints and client ID.
defaultOAuthConfig :: OAuthConfig
defaultOAuthConfig = OAuthConfig
  { _oac_clientId     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  , _oac_authUrl      = "https://claude.ai/oauth/authorize"
  , _oac_tokenUrl     = "https://console.anthropic.com/v1/oauth/token"
  , _oac_callbackPort = 54321
  }

-- | OAuth tokens returned from a successful flow or refresh.
data OAuthTokens = OAuthTokens
  { _oat_accessToken  :: BearerToken -- ^ Access token for API calls
  , _oat_refreshToken :: ByteString  -- ^ Refresh token (opaque, stored for renewal)
  , _oat_expiresAt    :: UTCTime     -- ^ When the access token expires
  }

instance Show OAuthTokens where
  show t = "OAuthTokens { expiresAt = " <> show (_oat_expiresAt t) <> ", <tokens redacted> }"

-- | Handle wrapping a mutable token store and a refresh function.
-- Passed to 'mkAnthropicProviderOAuth' so the provider can refresh tokens
-- automatically when they expire.
data OAuthHandle = OAuthHandle
  { _oah_tokensRef :: IORef OAuthTokens
    -- ^ Mutable reference — updated after each successful refresh.
  , _oah_refresh   :: ByteString -> IO OAuthTokens
    -- ^ Given a refresh token, obtain fresh tokens.
  }

-- | Construct an 'OAuthHandle' from an initial token set.
mkOAuthHandle :: OAuthConfig -> HTTP.Manager -> OAuthTokens -> IO OAuthHandle
mkOAuthHandle cfg manager initialTokens = do
  ref <- newIORef initialTokens
  pure OAuthHandle
    { _oah_tokensRef = ref
    , _oah_refresh   = refreshOAuthToken cfg manager
    }

-- | OAuth errors.
newtype OAuthError = OAuthError Text
  deriving stock (Show)

instance Exception OAuthError

-- ---------------------------------------------------------------------------
-- PKCE helpers
-- ---------------------------------------------------------------------------

-- | Generate a PKCE code verifier: 32 random bytes encoded as URL-safe
-- base64 without padding (43 characters).
generateCodeVerifier :: IO ByteString
generateCodeVerifier = do
  bytes <- CR.getRandomBytes 32
  pure (stripPadding (B64URL.encode bytes))

-- | Compute the PKCE code challenge: BASE64URL(SHA256(verifier)).
-- The verifier is treated as raw bytes (it is already ASCII-safe base64url).
computeCodeChallenge :: ByteString -> ByteString
computeCodeChallenge verifier =
  let digest    = hash verifier :: Digest SHA256
      digestBs  = convert digest :: ByteString
  in stripPadding (B64URL.encode digestBs)

-- | Strip '=' padding from a base64url-encoded string.
stripPadding :: ByteString -> ByteString
stripPadding = BS.filter (/= 0x3d)

-- ---------------------------------------------------------------------------
-- Authorization URL
-- ---------------------------------------------------------------------------

-- | Build the authorization URL. Opens in the user's browser to start login.
-- Takes the code verifier bytes (computes the challenge internally).
buildAuthorizationUrl :: OAuthConfig -> ByteString -> ByteString -> Text
buildAuthorizationUrl cfg verifier state =
  let challenge   = computeCodeChallenge verifier
      port        = _oac_callbackPort cfg
      redirectUri = "http://localhost:" <> BS8.pack (show port) <> "/oauth/callback"
      qs = renderSimpleQuery True
             [ ("response_type",          "code")
             , ("client_id",              TE.encodeUtf8 (_oac_clientId cfg))
             , ("redirect_uri",           redirectUri)
             , ("scope",                  "user:inference")
             , ("state",                  state)
             , ("code_challenge",         challenge)
             , ("code_challenge_method",  "S256")
             ]
  in T.pack (_oac_authUrl cfg) <> TE.decodeUtf8 qs

-- ---------------------------------------------------------------------------
-- Token response parsing
-- ---------------------------------------------------------------------------

-- | Parse a token response from the Anthropic token endpoint.
-- 'now' is the current time, used to compute the absolute expiry.
parseTokenResponse :: UTCTime -> BL.ByteString -> Either Text OAuthTokens
parseTokenResponse now bs =
  case eitherDecode bs of
    Left err  -> Left (T.pack err)
    Right val -> case parseEither parseTokens val of
      Left err -> Left (T.pack err)
      Right t  -> Right t
  where
    parseTokens = withObject "TokenResponse" $ \o -> do
      accessText  <- o .: "access_token"
      refreshText <- o .: "refresh_token"
      expiresIn   <- o .: "expires_in"
      let expiresAt = addUTCTime (fromIntegral (expiresIn :: Int)) now
      pure OAuthTokens
        { _oat_accessToken  = mkBearerToken (TE.encodeUtf8 accessText)
        , _oat_refreshToken = TE.encodeUtf8 refreshText
        , _oat_expiresAt    = expiresAt
        }

-- ---------------------------------------------------------------------------
-- Vault serialization
-- ---------------------------------------------------------------------------

-- | Serialize tokens to JSON bytes for vault storage.
serializeTokens :: OAuthTokens -> ByteString
serializeTokens tokens = BL.toStrict $ encode $ object
  [ "access_token"  .= TE.decodeUtf8 (withBearerToken (_oat_accessToken  tokens) id)
  , "refresh_token" .= TE.decodeUtf8 (_oat_refreshToken tokens)
  , "expires_at"    .= (round (utcTimeToPOSIXSeconds (_oat_expiresAt tokens)) :: Int)
  ]

-- | Deserialize tokens from vault-stored JSON bytes.
deserializeTokens :: ByteString -> Either Text OAuthTokens
deserializeTokens bs =
  case eitherDecodeStrict bs of
    Left err  -> Left (T.pack err)
    Right val -> case parseEither parseStored val of
      Left err -> Left (T.pack err)
      Right t  -> Right t
  where
    parseStored = withObject "StoredTokens" $ \o -> do
      accessText  <- o .: "access_token"
      refreshText <- o .: "refresh_token"
      expiresInt  <- o .: "expires_at"
      let expiresAt = posixSecondsToUTCTime (fromIntegral (expiresInt :: Int))
      pure OAuthTokens
        { _oat_accessToken  = mkBearerToken (TE.encodeUtf8 accessText)
        , _oat_refreshToken = TE.encodeUtf8 refreshText
        , _oat_expiresAt    = expiresAt
        }

-- ---------------------------------------------------------------------------
-- OAuth flows
-- ---------------------------------------------------------------------------

-- | Run the full OAuth 2.0 PKCE authorization code flow:
--   1. Generate PKCE verifier + state
--   2. Print the authorization URL (and try to open the browser)
--   3. Start a local callback server to receive the redirect
--   4. Exchange the authorization code for tokens
runOAuthFlow :: OAuthConfig -> HTTP.Manager -> IO OAuthTokens
runOAuthFlow cfg manager = do
  verifier    <- generateCodeVerifier
  stateBytes  <- generateCodeVerifier  -- reuse random generator for state
  let state   = stateBytes  -- already URL-safe base64
      authUrl = buildAuthorizationUrl cfg verifier state
  putStrLn "Anthropic OAuth login required."
  putStrLn "Visit this URL to authenticate:"
  TIO.putStrLn authUrl
  putStr "(Attempting to open browser...) " >> hFlush stdout
  _ <- tryOpenBrowser (T.unpack authUrl)
  putStrLn ""
  putStrLn $ "Waiting for OAuth callback on port " <> show (_oac_callbackPort cfg) <> "..."
  result <- receiveCallback (_oac_callbackPort cfg)
  case result of
    Left err   -> throwIO (OAuthError ("OAuth authorization denied: " <> err))
    Right code -> do
      now <- getCurrentTime
      exchangeCodeForTokens cfg manager verifier code now

-- | Exchange an authorization code for tokens.
exchangeCodeForTokens
  :: OAuthConfig -> HTTP.Manager -> ByteString -> Text -> UTCTime -> IO OAuthTokens
exchangeCodeForTokens cfg manager verifier code now = do
  let port        = _oac_callbackPort cfg
      redirectUri = "http://localhost:" <> show port <> "/oauth/callback"
      body        = renderSimpleQuery False
                      [ ("grant_type",    "authorization_code")
                      , ("client_id",     TE.encodeUtf8 (_oac_clientId cfg))
                      , ("code",          TE.encodeUtf8 code)
                      , ("redirect_uri",  BS8.pack redirectUri)
                      , ("code_verifier", verifier)
                      ]
  req <- HTTP.parseRequest (_oac_tokenUrl cfg)
  let httpReq = req
        { HTTP.method         = "POST"
        , HTTP.requestBody    = HTTP.RequestBodyBS body
        , HTTP.requestHeaders = [("content-type", "application/x-www-form-urlencoded")]
        }
  resp <- HTTP.httpLbs httpReq manager
  let statusCode = Status.statusCode (HTTP.responseStatus resp)
  if statusCode /= 200
    then throwIO (OAuthError ("Token exchange failed with HTTP " <> T.pack (show statusCode)))
    else case parseTokenResponse now (HTTP.responseBody resp) of
      Left err     -> throwIO (OAuthError ("Token parse error: " <> err))
      Right tokens -> pure tokens

-- | Refresh an access token using a stored refresh token.
refreshOAuthToken :: OAuthConfig -> HTTP.Manager -> ByteString -> IO OAuthTokens
refreshOAuthToken cfg manager refreshTok = do
  now <- getCurrentTime
  let body = renderSimpleQuery False
               [ ("grant_type",    "refresh_token")
               , ("client_id",     TE.encodeUtf8 (_oac_clientId cfg))
               , ("refresh_token", refreshTok)
               ]
  req <- HTTP.parseRequest (_oac_tokenUrl cfg)
  let httpReq = req
        { HTTP.method         = "POST"
        , HTTP.requestBody    = HTTP.RequestBodyBS body
        , HTTP.requestHeaders = [("content-type", "application/x-www-form-urlencoded")]
        }
  resp <- HTTP.httpLbs httpReq manager
  let statusCode = Status.statusCode (HTTP.responseStatus resp)
  if statusCode /= 200
    then throwIO (OAuthError ("Token refresh failed with HTTP " <> T.pack (show statusCode)))
    else case parseTokenResponse now (HTTP.responseBody resp) of
      Left err     -> throwIO (OAuthError ("Token parse error: " <> err))
      Right tokens -> pure tokens

-- ---------------------------------------------------------------------------
-- Local callback server
-- ---------------------------------------------------------------------------

-- | Start a temporary Warp server that captures the OAuth redirect callback.
-- Returns the authorization code on success, or an error message on failure.
receiveCallback :: Int -> IO (Either Text Text)
receiveCallback port = do
  mvar <- newEmptyMVar
  withAsync (Warp.run port (callbackApp mvar)) $ \_ -> takeMVar mvar

-- | WAI application that extracts the 'code' or 'error' from the callback.
callbackApp :: MVar (Either Text Text) -> Wai.Application
callbackApp mvar req respond = do
  let params = Wai.queryString req
      code   = join (lookup "code"  params)
      err    = join (lookup "error" params)
  case (code, err) of
    (Just c, _) -> do
      putMVar mvar (Right (TE.decodeUtf8 c))
      respond $ Wai.responseLBS status200
        [("Content-Type", "text/html")]
        "<html><body><h1>Authentication successful</h1><p>You may close this tab and return to PureClaw.</p></body></html>"
    (_, Just e) -> do
      putMVar mvar (Left (TE.decodeUtf8 e))
      respond $ Wai.responseLBS status200
        [("Content-Type", "text/html")]
        "<html><body><h1>Authentication failed</h1><p>You may close this tab.</p></body></html>"
    _ ->
      respond $ Wai.responseLBS status200 [] "Waiting for OAuth callback..."

-- ---------------------------------------------------------------------------
-- Browser helper
-- ---------------------------------------------------------------------------

-- | Try to open a URL in the default browser. Ignores failures silently.
tryOpenBrowser :: String -> IO ()
tryOpenBrowser url = do
  let cmd = case os of
        "darwin"  -> "open"
        "mingw32" -> "start"
        _         -> "xdg-open"
  _ <- try @SomeException (P.runProcess_ (P.proc cmd [url]))
  pure ()
