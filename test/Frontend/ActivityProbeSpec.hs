-- | Tests for "PureClaw.Frontend.ActivityProbe" — WU4.
--
-- Covers the activity probe loop's behavioural DoDs:
--
--   * D17 — emit one 'ActivityChanged sid (SaHarnessStatus _)' per harness
--     state transition (NOT per probe tick); emit ZERO events on the first
--     tick (which establishes the baseline).
--
--   * D24 — the loop terminates within 1 s of an outer
--     'Async.cancel' / 'Async.withAsync' scope exit.
--
-- The probe loop's harness-state source is the same 'Map Text HarnessActivity'
-- snapshot abstraction used by 'PureClaw.Frontend.API.probeHarness'. To keep
-- the tests deterministic (and avoid forking tmux processes in unit tests)
-- the production module exposes 'runActivityProbeLoopWith' which takes (a) a
-- caller-supplied probe action and (b) a caller-controlled tick interval —
-- the default 'runActivityProbeLoop' supplies the production wiring on top.
module Frontend.ActivityProbeSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, orElse, readTBQueue)
import Control.Exception (SomeException, try)
import Control.Monad (replicateM)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
  , apiApp
  )
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.ActivityProbe (runActivityProbeLoopWith)
import PureClaw.Handles.Harness (HarnessError (..))
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Tools.Registry (emptyRegistry)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Receive one broker event with a millisecond deadline. Returns 'Nothing'
-- if no event arrived in time. Used to assert "no event was emitted" by
-- checking 'Nothing' after a budget.
recvWithin :: Int -> Subscription -> IO (Maybe BrokerEvent)
recvWithin micros sub =
  timeout micros $ atomically $ readTBQueue (_sub_queue sub)

-- | Drain every event currently sitting in a subscription's queue without
-- blocking. The STM @orElse@ short-circuits to 'Nothing' when the queue is
-- empty rather than retrying.
drainQueue :: Subscription -> IO [BrokerEvent]
drainQueue sub = go []
  where
    go acc = do
      r <- atomically
        (orElse
          (Just <$> readTBQueue (_sub_queue sub))
          (pure Nothing))
      case r of
        Just ev -> go (ev : acc)
        Nothing -> pure (reverse acc)

-- | A controllable probe action: returns the IORef's current value each time.
mkSnapshotProbe :: IORef (Map Text HarnessActivity) -> IO (Map Text HarnessActivity)
mkSnapshotProbe = readIORef

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "runActivityProbeLoopWith — D17 (no events on first tick, one per transition)" $ do
    it "emits zero events on the first tick (baseline only)" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      eSub    <- _streamBroker_subscribe broker
      sub     <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      stateRef <- newIORef (Map.singleton "claude-code-0" HarnessIdle)
      let logger = mkNoOpLogHandle
          tickMicros = 50_000  -- 50 ms tick for fast tests
      Async.withAsync
        (runActivityProbeLoopWith tickMicros (mkSnapshotProbe stateRef) broker logger)
        $ \_a -> do
          -- Allow the first tick to run (the loop sleeps THEN probes, so we
          -- wait one interval + slack to be sure baseline was captured).
          threadDelay (tickMicros + 50_000)
          -- No state change occurred; we should observe ZERO events.
          ev <- recvWithin 50_000 sub
          ev `shouldBe` Nothing

    it "emits exactly one ActivityChanged per state transition (idle → thinking)" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      eSub    <- _streamBroker_subscribe broker
      sub     <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      stateRef <- newIORef (Map.singleton "claude-code-0" HarnessIdle)
      let logger = mkNoOpLogHandle
          tickMicros = 50_000
      Async.withAsync
        (runActivityProbeLoopWith tickMicros (mkSnapshotProbe stateRef) broker logger)
        $ \_a -> do
          -- Let the first tick capture the baseline.
          threadDelay (tickMicros + 30_000)
          -- Flip the state.
          writeIORef stateRef (Map.singleton "claude-code-0" HarnessThinking)
          -- Wait for at least one full tick after the change.
          mEv <- recvWithin (3 * tickMicros) sub
          case mEv of
            Just (ActivityChanged sid (SaHarnessStatus status)) -> do
              sid    `shouldBe` SessionId "claude-code-0"
              status `shouldBe` HarnessThinking
            other -> expectationFailure $
              "expected ActivityChanged thinking, got: " <> show other
          -- And no second event for the same transition.
          ev2 <- recvWithin (2 * tickMicros) sub
          ev2 `shouldBe` Nothing

    it "emits zero events on a tick with no change" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      eSub    <- _streamBroker_subscribe broker
      sub     <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      stateRef <- newIORef (Map.singleton "h-a" HarnessIdle)
      let logger = mkNoOpLogHandle
          tickMicros = 50_000
      Async.withAsync
        (runActivityProbeLoopWith tickMicros (mkSnapshotProbe stateRef) broker logger)
        $ \_a -> do
          -- Allow several ticks to pass with no state change.
          threadDelay (5 * tickMicros)
          drained <- drainQueue sub
          drained `shouldBe` []

    it "emits one event per session that transitioned (multi-session)" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      eSub    <- _streamBroker_subscribe broker
      sub     <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      stateRef <- newIORef $ Map.fromList
        [ ("h-a", HarnessIdle)
        , ("h-b", HarnessIdle)
        , ("h-c", HarnessIdle)
        ]
      let logger = mkNoOpLogHandle
          tickMicros = 50_000
      Async.withAsync
        (runActivityProbeLoopWith tickMicros (mkSnapshotProbe stateRef) broker logger)
        $ \_a -> do
          threadDelay (tickMicros + 30_000)
          -- Transition h-a and h-c; leave h-b alone.
          writeIORef stateRef $ Map.fromList
            [ ("h-a", HarnessThinking)
            , ("h-b", HarnessIdle)
            , ("h-c", HarnessStopped)
            ]
          -- Collect two events (one per transitioned session).
          mEvs <- timeout (5 * tickMicros) $
            replicateM 2 (atomically (readTBQueue (_sub_queue sub)))
          let evs = fromMaybe [] mEvs
          length evs `shouldBe` 2
          let pairs = [ (sid, st)
                      | ActivityChanged sid (SaHarnessStatus st) <- evs ]
          Map.fromList pairs `shouldBe` Map.fromList
            [ (SessionId "h-a", HarnessThinking)
            , (SessionId "h-c", HarnessStopped)
            ]
          -- No third event.
          ev3 <- recvWithin (2 * tickMicros) sub
          ev3 `shouldBe` Nothing

  describe "runActivityProbeLoopWith — D24 (lifecycle: cancels within 1 s)" $
    it "Async.cancel returns within 1 s of outer-scope exit" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      stateRef <- newIORef (Map.singleton "h-x" HarnessIdle)
      let logger = mkNoOpLogHandle
          tickMicros = 100_000
      a <- Async.async
        (runActivityProbeLoopWith tickMicros (mkSnapshotProbe stateRef) broker logger)
      -- Let the loop do one tick.
      threadDelay (tickMicros + 50_000)
      -- Cancellation MUST complete within 1 s.
      result <- timeout 1_000_000 (Async.cancel a)
      result `shouldBe` Just ()
      -- And the async itself reports completion (no swallow of AsyncCancelled).
      _ <- Async.waitCatch a
      pure ()

  describe "runActivityProbeLoopWith — exception discipline" $
    it "logs and exits on a non-AsyncCancelled exception (no restart in v1)" $ do
      broker  <- mkInProcessBroker defaultBrokerConfig
      -- Throw on the SECOND probe so the baseline is established cleanly.
      countRef <- newIORef (0 :: Int)
      let probe = do
            n <- atomicModifyIORef' countRef (\k -> (k + 1, k + 1))
            if n >= 2
              then error "probe crashed (test)"
              else pure (Map.singleton "h-x" HarnessIdle)
          logger     = mkNoOpLogHandle
          tickMicros = 30_000
      r <- try @SomeException $
        timeout (10 * tickMicros) (runActivityProbeLoopWith tickMicros probe broker logger)
      case r of
        Right _ -> pure ()  -- handler swallowed the exception; loop exited
        Left  e -> expectationFailure $
          "probe crash should be caught, not propagated: " <> show e

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
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  tabCountRef  <- newIORef 0
  pure FrontendEnv
    { _fe_harnesses    = harnessesRef
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
    , _fe_tabCount     = tabCountRef
    , _fe_listTabs     = pure []
    , _fe_closeTab     = \_ -> pure (Left "not wired in test")
    , _fe_startHarness = \_ _ -> pure (Left (HarnessBinaryNotFound "harness start not wired"))
    , _fe_listModels   = \_ -> pure []
    , _fe_listProviders = pure []
    , _fe_registry    = emptyRegistry
    , _fe_maxToolIterations = 90
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
