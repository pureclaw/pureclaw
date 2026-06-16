-- | Tests for "PureClaw.Frontend.ActivityProbe" and adjacent broker wiring.
--
-- /Scope note (WU5)./ The activity-probe LOOP was replaced by the
-- registry-based reconcile loop ("PureClaw.Harness.Reconcile"). Its behavioural
-- DoDs — D17 (no events on the first tick; one per transition), D24 (cancels
-- within 1 s), the exception discipline, AND the new D5.2 disappearance event —
-- are now exercised against the reconcile loop in @test\/Harness\/ReconcileSpec.hs@.
-- "PureClaw.Frontend.ActivityProbe.runActivityProbeLoop" is now a thin shim over
-- 'PureClaw.Harness.Reconcile.runReconcileLoop'.
--
-- What remains here is the broker wiring this module's neighbours rely on:
--
--   * D18 — @POST \/api\/tabs\/new@ publishes @ActivityChanged sid (SaSessionCreated)@.
--   * a subscription-liveness sanity check on the helper machinery.
module Frontend.ActivityProbeSpec (spec) where

import Control.Concurrent.STM (atomically, readTBQueue)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Network.HTTP.Types (methodPost)
import Network.Wai (Application, defaultRequest, requestMethod, pathInfo, setRequestBodyChunks)
import Network.Wai.Internal (ResponseReceived (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.API
  ( FrontendEnv (..)
  , ReleaseTmux (..)
  , apiApp
  )
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Handles.Harness (HarnessError (..))
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Security.Adoption (ConsentChannel (..))
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Tabs (newTabRegistry)
import Support.AgentEnv (mkTestAgentEnv)
import PureClaw.Tabs.Exec (newExec)
import PureClaw.Tabs.Types (emptyCursors)
import PureClaw.Tools.Registry (emptyRegistry)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Receive one broker event with a millisecond deadline.
recvWithin :: Int -> Subscription -> IO (Maybe BrokerEvent)
recvWithin micros sub =
  timeout micros $ atomically $ readTBQueue (_sub_queue sub)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "handleNewTab — D18 (publishes SaSessionCreated to the broker)" $
    it "POST /api/tabs/new publishes ActivityChanged sid (SaSessionCreated meta)" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      withSystemTempDirectory "pureclaw-d18" $ \tmp -> do
        env <- mkFrontendEnvForD18 broker tmp
        let app   = apiApp env
            -- POST /api/tabs/new with a session kind (TkSession SkProvider).
            -- Main deprecated POST /api/sessions/new to 410 Gone during the
            -- merge; the broker-publish behavior moved into handleNewTab's
            -- TkSession branch (see Frontend.API ActivityChanged publish
            -- after _sh_save sh).
            body  = "{\"kind\":{\"tag\":\"session\",\"session_kind\":\
                    \{\"tag\":\"provider\",\"provider\":\"anthropic\",\
                    \\"model\":\"claude-3-7-sonnet\"}}}"
            path  = ["api", "tabs", "new"]
        runWaiApp app methodPost path body
        -- Drain queued events; the publish ordering for D18 is
        -- "publish then write meta" or "write meta then publish" — we
        -- only assert that exactly one SaSessionCreated event is
        -- present for the newly-created session.
        evs <- drainQueueWithBudget 500_000 sub
        let created =
              [ (sid, m)
              | ActivityChanged sid (SaSessionCreated m) <- evs ]
        case created of
          [(sid, m)] -> do
            sid           `shouldBe` _sm_id m
            _sm_channel m `shouldBe` "web"
          other -> expectationFailure $
            "expected exactly one SaSessionCreated event, got: " <> show (length other)

  describe "subscription liveness" $
    it "subscription overflow flag is observable via STM after publish" $ do
      -- Sanity check: the helper machinery used by the other tests behaves.
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      _streamBroker_publish broker
        (ActivityChanged (SessionId "h-x") (SaHarnessStatus HarnessIdle))
      mEv <- recvWithin 50_000 sub
      case mEv of
        Just (ActivityChanged sid (SaHarnessStatus _)) ->
          sid `shouldBe` SessionId "h-x"
        other -> expectationFailure $ "unexpected: " <> show other

-- ---------------------------------------------------------------------------
-- D18 fixtures
-- ---------------------------------------------------------------------------

-- | Construct a minimal 'FrontendEnv' suitable for exercising
-- 'handleNewSession'. The provider/model are 'Nothing'; the harness map is
-- empty. Only the broker and sessions dir are load-bearing for D18.
mkFrontendEnvForD18 :: StreamBroker -> FilePath -> IO FrontendEnv
mkFrontendEnvForD18 broker sessionsDir = do
  harnessesRef <- newIORef Map.empty
  harnessReg   <- Registry.newRegistry
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  tabReg       <- newTabRegistry
  cursorsRef   <- newIORef emptyCursors
  exec         <- newExec
  agentEnv     <- mkTestAgentEnv
  pure FrontendEnv
    { _fe_harnesses    = harnessesRef
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
    , _fe_agentsDir    = sessionsDir
    , _fe_defaultAgent = Nothing
    , _fe_broker       = Just broker
    , _fe_streamGuard  = Nothing
    , _fe_maxTabs      = 32  -- non-zero so handleNewTab doesn't return 409
    , _fe_tabRegistry  = tabReg
    , _fe_cursors      = cursorsRef
    , _fe_exec         = exec
    , _fe_closeTab     = \_ -> pure (Left "not wired in test")
    , _fe_startHarness = \_ _ -> pure (Left (HarnessBinaryNotFound "harness start not wired"))
    , _fe_listModels   = \_ -> pure []
    , _fe_listProviders = pure []
    , _fe_registry    = emptyRegistry
    , _fe_maxToolIterations = 90
    , _fe_agentEnv     = agentEnv
    }

-- | Run a WAI 'Application' with a one-shot request body.
runWaiApp
  :: Application
  -> BS.ByteString          -- ^ HTTP method
  -> [Text]                 -- ^ path segments
  -> BS.ByteString          -- ^ request body
  -> IO ()
runWaiApp app method path body = do
  bodyRef <- newIORef (Just body)
  let getBody = do
        mb <- readIORef bodyRef
        case mb of
          Nothing -> pure BS.empty
          Just b  -> do writeIORef bodyRef Nothing; pure b
      req = setRequestBodyChunks getBody defaultRequest
        { requestMethod = method
        , pathInfo      = path
        }
  _ <- app req $ \_resp -> pure ResponseReceived
  pure ()

-- | Read every event currently in the queue, waiting up to @budgetMicros@
-- for the first arrival. Returns the accumulated list in publish order.
drainQueueWithBudget :: Int -> Subscription -> IO [BrokerEvent]
drainQueueWithBudget budgetMicros sub = do
  -- Wait up to the budget for the first event.
  first <- timeout budgetMicros $ atomically (readTBQueue (_sub_queue sub))
  case first of
    Nothing  -> pure []
    Just ev0 -> do
      rest <- drainNonBlocking
      pure (ev0 : rest)
  where
    drainNonBlocking :: IO [BrokerEvent]
    drainNonBlocking = do
      mEv <- timeout 10_000 $ atomically (readTBQueue (_sub_queue sub))
      case mEv of
        Nothing -> pure []
        Just ev -> (ev :) <$> drainNonBlocking
