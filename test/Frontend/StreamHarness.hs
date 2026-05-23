-- | Test harness for WS streaming integration tests — WU3.
--
-- Provides:
--   * 'withStreamServer' — spin up a Warp server on an ephemeral port
--     using 'Warp.testWithApplication' and run an action with the port.
--   * 'openWSClient' — open a WebSocket from a Haskell client with an
--     optional Origin override.
--   * Helpers to assemble a minimal 'FrontendEnv' for tests.
module Frontend.StreamHarness
  ( -- * Server lifecycle
    withStreamServer
  , mkTestFrontendEnv
  , testAllowedOrigins
    -- * WS client helpers
  , openWSClient
  , defaultOrigin
  , awaitTextMessage
    -- * Re-exports
  , module PureClaw.Frontend.API
  , module PureClaw.Frontend.StreamBroker
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types (status404)
import Network.HTTP.Types.Header (HeaderName)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import System.Timeout (timeout)

import PureClaw.Frontend.API
import PureClaw.Frontend.Stream (streamApp)
import PureClaw.Frontend.StreamBroker
import PureClaw.Handles.Log (mkNoOpLogHandle)

-- | The default Origin used by tests. Tests that exercise the Origin
-- allowlist may pass a different value via 'openWSClient'.
defaultOrigin :: Text
defaultOrigin = "http://localhost:8080"

-- | The default list of allowed Origins used by the harness. Tests that
-- need a restricted allowlist supply their own when constructing the
-- WAI application.
testAllowedOrigins :: [Text]
testAllowedOrigins = [defaultOrigin, "http://127.0.0.1:8080"]

-- | Construct a minimal 'FrontendEnv' with the given broker / guard, a
-- temporary sessions dir, and no-op logger.
mkTestFrontendEnv
  :: FilePath               -- ^ sessions dir
  -> StreamBroker
  -> StreamGuard
  -> IO FrontendEnv
mkTestFrontendEnv sessionsDir broker guard = do
  harnesses    <- newIORef Map.empty
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  pure FrontendEnv
    { _fe_harnesses    = harnesses
    , _fe_sessionsDir  = sessionsDir
    , _fe_recentLimit  = 20
    , _fe_provider     = providerRef
    , _fe_model        = modelRef
    , _fe_systemPrompt = Nothing
    , _fe_logger       = mkNoOpLogHandle
    , _fe_agentsDir    = sessionsDir   -- not used by stream tests
    , _fe_defaultAgent = Nothing
    , _fe_broker       = Just broker
    , _fe_streamGuard  = Just guard
    }

-- | Build the WAI app that routes @\/api\/stream@ WS upgrades to
-- 'streamApp' with the provided allowlist.
mkStreamWaiApp :: [Text] -> FrontendEnv -> Application
mkStreamWaiApp allowed env = WaiWS.websocketsOr
  WS.defaultConnectionOptions
  (streamApp allowed env)
  rejectOther
  where
    rejectOther _req respond = respond
      $ responseLBS status404
          [("Content-Type", "text/plain")]
          "stream-only test harness"

-- | Spawn a Warp server on a free local port via
-- 'Warp.testWithApplication', run @action port@, then tear it down.
withStreamServer
  :: [Text]
  -> FrontendEnv
  -> (Int -> IO a)
  -> IO a
withStreamServer allowed env =
  Warp.testWithApplication (pure (mkStreamWaiApp allowed env))

-- | Open a WS client to @ws://localhost:<port>/api/stream@. The Origin
-- header defaults to 'defaultOrigin' unless overridden. The connection
-- closes when @clientApp@ returns.
openWSClient
  :: Int
  -> Maybe Text   -- ^ Origin override
  -> WS.ClientApp a
  -> IO a
openWSClient port mOrigin clientApp = do
  let origin = fromMaybe defaultOrigin mOrigin
      headers :: [(HeaderName, BS.ByteString)]
      headers = [("Origin", BC.pack (T.unpack origin))]
  WS.runClientWith
    "127.0.0.1"
    port
    "/api/stream"
    WS.defaultConnectionOptions
    headers
    clientApp

-- | Wait up to @us@ microseconds for a text message; return 'Nothing'
-- on timeout. Useful for D9's 50 ms focus-switch budget.
awaitTextMessage :: Int -> WS.Connection -> IO (Maybe LBS.ByteString)
awaitTextMessage us conn =
  timeout us $ do
    msg <- try @SomeException (WS.receiveData conn)
    case msg of
      Left _    -> pure LBS.empty
      Right bs  -> pure bs

