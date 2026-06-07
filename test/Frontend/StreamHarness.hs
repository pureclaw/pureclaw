-- | Test harness for WS streaming integration tests — WU3.
--
-- Provides:
--   * 'withStreamServer' — spin up a Warp server on an ephemeral port
--     using 'Warp.testWithApplication' and run an action with the port.
--   * 'openWSClient' — open a WebSocket from a Haskell client with an
--     optional Origin override.
--   * Helpers to assemble a minimal 'FrontendEnv' for tests.
--   * 'readGoldenFixture' — read a JSON fixture from
--     @test\/Frontend\/fixtures\/stream-events@.
module Frontend.StreamHarness
  ( -- * Server lifecycle
    withStreamServer
  , withStreamServerCustom
  , mkTestFrontendEnv
  , mkTestFrontendEnvWith
  , testAllowedOrigins
    -- * WS client helpers
  , openWSClient
  , openWSClientNoOrigin
  , defaultOrigin
  , awaitTextMessage
    -- * Golden fixture helpers
  , readGoldenFixture
  , goldenFixturePath
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
import System.FilePath ((</>))
import System.Timeout (timeout)

import PureClaw.Frontend.API
import PureClaw.Frontend.Stream (streamApp)
import PureClaw.Handles.Harness (HarnessError (..))
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Frontend.StreamBroker
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Security.Adoption (ConsentChannel (..))
import PureClaw.Tools.Registry (emptyRegistry)

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
  harnessReg   <- Registry.newRegistry
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  tabCountRef  <- newIORef 0
  pure FrontendEnv
    { _fe_harnesses    = harnesses
    , _fe_harnessRegistry = harnessReg
    , _fe_consentChannel = ConsentHeadless  -- tests fail-closed
    , _fe_adopt        = \_ _ -> pure (Left (HarnessBinaryNotFound "adopt not wired in test"))
    , _fe_releaseTmux  = ReleaseTmux (\_ _ -> pure Nothing) (\_ _ -> pure ()) (\_ _ _ -> pure ())
    , _fe_killWindow   = \_ _ -> pure ()
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
    , _fe_maxTabs      = 0
    , _fe_tabCount     = tabCountRef
    , _fe_listTabs     = pure []
    , _fe_closeTab     = \_ -> pure (Left "not wired in test")
    , _fe_startHarness = \_ _ -> pure (Left (HarnessBinaryNotFound "harness start not wired"))
    , _fe_listModels   = \_ -> pure []
    , _fe_listProviders = pure []
    , _fe_registry    = emptyRegistry
    , _fe_maxToolIterations = 90
    }

-- | Variant of 'mkTestFrontendEnv' that lets the caller construct the
-- broker + guard from explicit caps. Used by integration tests that
-- need to exercise cap-reached behaviour (D30, D35) without exhausting
-- the production defaults (32 / 8). Returns the constructed broker and
-- guard alongside the env so tests can interact with them directly.
mkTestFrontendEnvWith
  :: FilePath               -- ^ sessions dir
  -> BrokerConfig           -- ^ broker config (often a small-cap variant)
  -> Int                    -- ^ per-origin cap for the StreamGuard
  -> IO (FrontendEnv, StreamBroker, StreamGuard)
mkTestFrontendEnvWith sessionsDir bcfg perOriginCap = do
  broker <- mkInProcessBroker bcfg
  guard  <- mkStreamGuard perOriginCap
  env    <- mkTestFrontendEnv sessionsDir broker guard
  pure (env, broker, guard)

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

-- | Variant of 'withStreamServer' that accepts an explicit WAI
-- 'Application'. Used by tests that need to verify path-routing
-- behaviour (e.g. that only @\/api\/stream@ accepts WS upgrades).
withStreamServerCustom
  :: Application
  -> (Int -> IO a)
  -> IO a
withStreamServerCustom app = Warp.testWithApplication (pure app)

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

-- | Open a WS client without any Origin header. Used by tests that
-- exercise the missing-Origin reject path.
openWSClientNoOrigin
  :: Int
  -> WS.ClientApp a
  -> IO a
openWSClientNoOrigin port =
  WS.runClientWith
    "127.0.0.1"
    port
    "/api/stream"
    WS.defaultConnectionOptions
    []

-- | Wait up to @us@ microseconds for a text message; return 'Nothing'
-- on timeout. Useful for D9's 50 ms focus-switch budget.
awaitTextMessage :: Int -> WS.Connection -> IO (Maybe LBS.ByteString)
awaitTextMessage us conn =
  timeout us $ do
    msg <- try @SomeException (WS.receiveData conn)
    case msg of
      Left _    -> pure LBS.empty
      Right bs  -> pure bs

-- | Absolute path of a JSON fixture file by short name (without the
-- @.json@ suffix).
goldenFixturePath :: FilePath -> FilePath
goldenFixturePath name =
  "test" </> "Frontend" </> "fixtures" </> "stream-events" </> (name <> ".json")

-- | Read a wire-protocol golden fixture file as a lazy 'LBS.ByteString'.
-- Tests typically decode the result via 'Data.Aeson.eitherDecode' and
-- compare as 'Data.Aeson.Value' to remain insensitive to key order or
-- whitespace differences.
readGoldenFixture :: FilePath -> IO LBS.ByteString
readGoldenFixture name = LBS.readFile (goldenFixturePath name)
