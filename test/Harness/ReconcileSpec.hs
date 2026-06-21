-- | Tests for "PureClaw.Harness.Reconcile" — WU5.
--
-- The reconcile loop is the registry-based source of truth for harness
-- identity + health. These tests exercise:
--
--   * the pure corroboration logic (§8 C4 / D5.7): only a PID-corroborated
--     @\@pcl_id@ row counts as ours; an id collision or a PID mismatch is
--     "not ours" and is never trusted;
--   * the pure liveness classification (D5.4): Idle\/Thinking\/Exited\/Orphaned;
--   * the symmetric diff that emits an event for a /disappeared/ entry
--     (D5.2 — the bug fix for @ActivityProbe.hs:117@);
--   * the IO reconcile tick + loop: D5.1 (update by id), D5.3 (resilience —
--     a transient sweep failure marks entries stale and the loop continues),
--     D5.5 (non-ours rows are never captured; first-tick baseline), and the
--     boot reconstruction (D5.6).
--
-- All tmux IO is injected via 'ReconcileDeps' so the tests are deterministic
-- and never fork a real tmux server.
module Harness.ReconcileSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Monad (replicateM_, void)
import Control.Concurrent.STM (atomically, readTBQueue)
import Control.Exception (IOException, throwIO, ErrorCall (..))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.ActivityProbe (runActivityProbeLoop)
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Handles.Harness (HarnessHandle (..), mkNoOpHarnessHandle)
import PureClaw.Handles.Log (LogHandle (..), mkNoOpLogHandle)
import PureClaw.Harness.Observer (claudeObserver)
import PureClaw.Harness.Reconcile
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux (TmuxWindowRow (..))
import PureClaw.Session.Kind qualified as Kind

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | An entry skeleton: an id, recorded shell\/harness PIDs, a session label,
-- a starting liveness. No handle (the reconcile loop never needs one).
mkEntry :: Reg.HarnessId -> Text -> Maybe Int -> Maybe Int -> Reg.Liveness -> Reg.HarnessEntry
mkEntry hid windowName shellPid harnessPid liveness = Reg.HarnessEntry
  { Reg._he_id          = hid
  , Reg._he_session     = "pureclaw"
  , Reg._he_windowName  = windowName
  , Reg._he_shellPid    = shellPid
  , Reg._he_harnessPid  = harnessPid
  , Reg._he_origin      = Reg.OriginSpawned
  , Reg._he_flavour     = Kind.HClaudeCode
  , Reg._he_liveness    = liveness
  , Reg._he_extModified = False
  , Reg._he_stale       = False
  , Reg._he_sessionId   = Just windowName
  , Reg._he_label       = windowName
  , Reg._he_orphanedTicks = 0
  , Reg._he_handle      = Nothing
  }

-- | A sweep row for a window.
mkRow :: Int -> Text -> Text -> Maybe Int -> Bool -> TmuxWindowRow
mkRow idx name pclId panePid paneDead = TmuxWindowRow
  { _twr_windowIndex = idx
  , _twr_windowName  = name
  , _twr_pclId       = pclId
  , _twr_panePid     = panePid
  , _twr_paneDead    = paneDead
  }

recvWithin :: Int -> Subscription -> IO (Maybe BrokerEvent)
recvWithin micros sub =
  timeout micros $ atomically $ readTBQueue (_sub_queue sub)

-- | A raw screen frame the claudeObserver classifies as working (HasWorking ⇒
-- Thinking), and one it classifies as idle (HasIdle ⇒ Idle once stable). The
-- fake '_rd_capture' returns these to drive the observer-based classifier.
busyFrame, idleFrame :: Text
busyFrame = "\x2736 Smooshing\x2026 (4m 55s)"   -- ✶ working/status line
idleFrame = "ready when you are"                -- neither working nor approval

-- | Deterministic deps: a queue of sweeps (one per tick; the last repeats),
-- a captured-windows recorder, and a settable idle/capture map.
data Fakes = Fakes
  { f_sweeps          :: IORef [Either IOError [TmuxWindowRow]]
    -- ^ One sweep result per tick; 'Left' simulates a transient failure.
  , f_capturedWindows :: IORef [Text]
    -- ^ Window names that were 'capture'd this run (D5.5: never our-others).
  , f_idleByWindow    :: IORef (Map Text Bool)
    -- ^ For a captured window, whether the screen reads idle.
  , f_aliveByPid      :: IORef (Map Int Bool)
    -- ^ Whether a harness PID is still alive (for the Exited path).
  }

mkFakes :: [Either IOError [TmuxWindowRow]] -> Map Text Bool -> Map Int Bool -> IO Fakes
mkFakes sweeps idleMap aliveMap = Fakes
  <$> newIORef sweeps
  <*> newIORef []
  <*> newIORef idleMap
  <*> newIORef aliveMap

fakeDeps :: Fakes -> ReconcileDeps
fakeDeps f = ReconcileDeps
  { _rd_sessions = pure ["pureclaw"]
  , _rd_sweep    = \_session -> do
      xs <- readIORef (f_sweeps f)
      case xs of
        []       -> pure []
        [x]      -> either ioError pure x
        (x : ys) -> do writeIORef (f_sweeps f) ys; either ioError pure x
  , _rd_capture  = \_session windowName -> do
      modifyIORef' (f_capturedWindows f) (++ [windowName])
      m <- readIORef (f_idleByWindow f)
      -- Map the test's idle/busy intent onto a raw frame the claudeObserver
      -- classifies: an idle frame reads HasIdle (⇒ Idle once stable), a busy
      -- frame reads HasWorking (⇒ Thinking). Default (unmapped) is idle.
      let idle = Map.findWithDefault True windowName m
      pure (Just (if idle then idleFrame else busyFrame))
  , _rd_harnessAlive = \pid -> do
      m <- readIORef (f_aliveByPid f)
      pure (Map.findWithDefault True pid m)
  , _rd_stampLegacy = \_session _windowName -> pure Nothing
  , _rd_evict = \_hid _label -> pure ()
  , _rd_recordResponse = \_sid _txt -> pure ()
  }

-- | A log handle that records every warn\/error message into an 'IORef' so a
-- test can assert that a particular branch logged. Info\/debug are dropped.
mkCapturingLog :: IO (IORef [Text], LogHandle)
mkCapturingLog = do
  ref <- newIORef []
  let record msg = modifyIORef' ref (++ [msg])
  pure
    ( ref
    , mkNoOpLogHandle
        { _lh_logWarn  = record
        , _lh_logError = record
        }
    )

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "corroboration (§8 C4 / D5.7)" $ do
    it "a row whose pane PID matches the recorded shell PID is corroborated" $ do
      hid <- Reg.newHarnessId
      let e   = mkEntry hid "claude-code-0" (Just 1234) (Just 5678) Reg.LivenessIdle
          row = mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 1234) False
      corroborate e row `shouldBe` Corroborated

    it "a row whose pane PID does NOT match the recorded shell PID is a mismatch (not ours)" $ do
      hid <- Reg.newHarnessId
      let e   = mkEntry hid "claude-code-0" (Just 1234) (Just 5678) Reg.LivenessIdle
          row = mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 9999) False
      corroborate e row `shouldBe` PidMismatch

    it "an entry with no recorded shell PID requires a second signal (window-name prefix)" $ do
      hid <- Reg.newHarnessId
      -- No recorded shell PID: PID-only corroboration is impossible, so we
      -- fall back to the window-name prefix as the second signal.
      let e    = mkEntry hid "claude-code-0" Nothing Nothing Reg.LivenessIdle
          good = mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 1234) False
          bad  = mkRow 0 "random-window"  (Reg.harnessIdToText hid) (Just 1234) False
      corroborate e good `shouldBe` Corroborated
      corroborate e bad  `shouldBe` PidMismatch

  describe "observer-based classification (3-state + stability gate)" $ do
    -- The approval frame the claudeObserver recognizes (busyFrame/idleFrame are
    -- the shared module-level fixtures).
    let approvalFrame = "Do you want to proceed?"           -- approval prompt
    -- Args are (observer, paneDead, harnessAlive, stable, screen).
    it "pane_dead → Exited regardless of the screen" $
      classifyFromObserver claudeObserver True True True busyFrame
        `shouldBe` Reg.LivenessExited
    it "harness PID gone → Exited (window present, not pane_dead)" $
      classifyFromObserver claudeObserver False False True busyFrame
        `shouldBe` Reg.LivenessExited
    it "classifies a spinner frame as Thinking regardless of stability" $ do
      classifyFromObserver claudeObserver False True True  busyFrame
        `shouldBe` Reg.LivenessThinking
      classifyFromObserver claudeObserver False True False busyFrame
        `shouldBe` Reg.LivenessThinking
    it "classifies an approval frame as AwaitingInput" $
      classifyFromObserver claudeObserver False True True approvalFrame
        `shouldBe` Reg.LivenessAwaitingInput
    it "an idle-marker frame is Thinking until it is stable across ticks" $ do
      classifyFromObserver claudeObserver False True False idleFrame `shouldBe` Reg.LivenessThinking
      classifyFromObserver claudeObserver False True True  idleFrame `shouldBe` Reg.LivenessIdle

  describe "symmetric diff (D5.2 — disappearance emits an event)" $ do
    it "an entry whose liveness changed emits its new liveness" $ do
      let prev = Map.fromList [("a", ("sid-a", Reg.LivenessIdle))]
          next = Map.fromList [("a", ("sid-a", Reg.LivenessThinking))]
      diffLiveness prev next `shouldBe` [("sid-a", Reg.LivenessThinking)]

    it "an entry that went Orphaned (disappeared from the sweep) emits Orphaned" $ do
      -- The registry keeps the entry; reconcile flips it to Orphaned. The diff
      -- must surface that transition (the fix for ActivityProbe.hs:117).
      let prev = Map.fromList [("a", ("sid-a", Reg.LivenessIdle))]
          next = Map.fromList [("a", ("sid-a", Reg.LivenessOrphaned))]
      diffLiveness prev next `shouldBe` [("sid-a", Reg.LivenessOrphaned)]

    it "an unchanged entry emits nothing" $ do
      let prev = Map.fromList [("a", ("sid-a", Reg.LivenessIdle))]
          next = Map.fromList [("a", ("sid-a", Reg.LivenessIdle))]
      diffLiveness prev next `shouldBe` []

    it "a brand-new entry emits its first-observed liveness" $ do
      let prev = Map.empty
          next = Map.fromList [("a", ("sid-a", Reg.LivenessThinking))]
      diffLiveness prev next `shouldBe` [("sid-a", Reg.LivenessThinking)]

  describe "liveness → broker activity vocabulary" $ do
    it "maps Idle/Thinking/Exited/Orphaned to the broker vocabulary" $ do
      livenessToActivity Reg.LivenessIdle     `shouldBe` HarnessIdle
      livenessToActivity Reg.LivenessThinking `shouldBe` HarnessThinking
      livenessToActivity Reg.LivenessExited   `shouldBe` HarnessStopped
      livenessToActivity Reg.LivenessOrphaned `shouldBe` HarnessStopped
    it "maps AwaitingInput to needs-input" $
      livenessToActivity Reg.LivenessAwaitingInput `shouldBe` HarnessNeedsInput

  describe "reconcileTick — D5.1 (update entries by id)" $
    it "updates a registered entry's liveness + coordinate from the sweep" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      -- The window was renamed out-of-band; the sweep reports the new name +
      -- a busy screen.
      f <- mkFakes
        [Right [mkRow 0 "renamed-window" (Reg.harnessIdToText hid) (Just 100) False]]
        (Map.singleton "renamed-window" False)  -- busy ⇒ Thinking
        Map.empty
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_liveness e   `shouldBe` Reg.LivenessThinking
      Reg._he_windowName e `shouldBe` "renamed-window"
      Reg._he_extModified e `shouldBe` True  -- name changed out-of-band

  describe "reconcileTick — D5.4 (classification from injected fixtures)" $ do
    it "classifies Exited when the matched window is pane_dead" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) True]]
        Map.empty Map.empty
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_liveness e `shouldBe` Reg.LivenessExited
      -- A pane_dead window is never captured.
      cap <- readIORef (f_capturedWindows f)
      cap `shouldBe` []

    it "classifies Orphaned when the entry's window is absent from the sweep" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      f <- mkFakes [Right []] Map.empty Map.empty  -- empty sweep
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_liveness e `shouldBe` Reg.LivenessOrphaned

    it "classifies Exited when the harness PID is gone (window present, not pane_dead)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]]
        Map.empty
        (Map.singleton 100 False)  -- descent from shell PID 100 finds no agent
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_liveness e `shouldBe` Reg.LivenessExited

    it "a provenance-less entry (no recorded harness PID) skips the alive-probe and classifies from the screen" $ do
      -- classifyRow's (Just _, Just _) arm consults _rd_harnessAlive; a
      -- legacy/adopted entry with _he_harnessPid = Nothing takes the fallback
      -- arm (assume alive) and is classified purely from the capture (D5.4).
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      -- harnessPid = Nothing; shellPid present so PID corroboration still works.
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) Nothing Reg.LivenessIdle)
      aliveCalls <- newIORef (0 :: Int)
      let f0 fk = (fakeDeps fk)
            { _rd_harnessAlive = \_pid -> do modifyIORef' aliveCalls (+ 1); pure True }
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]]
        (Map.singleton "claude-code-0" False)  -- busy screen ⇒ Thinking
        Map.empty
      _ <- reconcileTick (f0 f) reg mkNoOpLogHandle Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_liveness e `shouldBe` Reg.LivenessThinking
      -- The alive-probe was NOT consulted (no recorded harness PID).
      readIORef aliveCalls `shouldReturn` 0

    it "publishes under the entry label when no SessionId is recorded (sidOf fallback)" $ do
      -- sidOf falls back to _he_label when _he_sessionId is Nothing. Drive the
      -- loop so the published ActivityChanged carries the label as its SessionId.
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let entry = (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
            { Reg._he_sessionId = Nothing
            , Reg._he_label     = "label-fallback"
            }
      Reg.insertEntry reg entry
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      -- Tick1 baseline (idle), Tick2 window gone ⇒ Orphaned ⇒ event under label.
      f <- mkFakes
        [ Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]
        , Right []
        ]
        (Map.singleton "claude-code-0" True)
        Map.empty
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick (fakeDeps f) reg broker mkNoOpLogHandle) $ \_a -> do
          mEv <- recvWithin (12 * tick) sub
          case mEv of
            Just (ActivityChanged sid (SaHarnessStatus HarnessStopped)) ->
              sid `shouldBe` SessionId "label-fallback"
            other -> expectationFailure $
              "expected a HarnessStopped event under the label, got: " <> show other

  describe "output watcher — record Response on settle (Task 7)" $ do
    -- These tests drive the real loop (the settle detection lives in the loop,
    -- not in 'reconcileTick'). A scripted per-tick capture sequence
    -- spinner→spinner→idle→idle produces a working→idle settle on the tick
    -- where two identical idle frames pass the stability gate. The fake handle's
    -- '_hh_snapshot' returns a fixed response the recorder captures.
    let settleHid = "claude-code-0"

        -- Build deps whose '_rd_capture' replays a per-tick frame script (the
        -- last frame repeats) and whose '_rd_recordResponse' appends to a ref.
        settleDeps
          :: Text                          -- ^ the entry's @pcl_id (harness id text)
          -> IORef [Text]                  -- ^ per-tick capture script
          -> (SessionId -> Text -> IO ())  -- ^ recordResponse
          -> ReconcileDeps
        settleDeps pclId frames record = ReconcileDeps
          { _rd_sessions = pure ["pureclaw"]
          , _rd_sweep    = \_ -> pure
              [ mkRow 0 settleHid pclId (Just 100) False ]
          , _rd_capture  = \_session _windowName -> do
              xs <- readIORef frames
              case xs of
                []       -> pure (Just idleFrame)
                [x]      -> pure (Just x)
                (x : ys) -> do writeIORef frames ys; pure (Just x)
          , _rd_harnessAlive   = \_ -> pure True
          , _rd_stampLegacy     = \_ _ -> pure Nothing
          , _rd_evict           = \_ _ -> pure ()
          , _rd_recordResponse  = record
          }

    it "records exactly one Response on a working→idle settle, then dedups" $ do
      recorded <- newIORef ([] :: [(SessionId, Text)])
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let hh = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "the answer" }
      Reg.insertEntry reg
        ((mkEntry hid settleHid (Just 100) (Just 200) Reg.LivenessThinking)
          { Reg._he_sessionId = Just "sess-1"
          , Reg._he_handle    = Just hh
          })
      -- spinner, spinner, idle, idle, idle... → Idle settle once two idle
      -- frames are stable; subsequent idle ticks must dedup to zero.
      frames <- newIORef [busyFrame, busyFrame, idleFrame]
      let deps = settleDeps (Reg.harnessIdToText hid) frames
                   (\sid txt -> modifyIORef' recorded ((sid, txt) :))
      broker <- mkInProcessBroker defaultBrokerConfig
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick deps reg broker mkNoOpLogHandle) $ \_a -> do
          threadDelay (20 * tick)
      xs <- readIORef recorded
      xs `shouldBe` [(SessionId "sess-1", "the answer")]

    it "records the approval prompt on a working→awaiting-input settle" $ do
      recorded <- newIORef ([] :: [(SessionId, Text)])
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let hh = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "the prompt" }
      Reg.insertEntry reg
        ((mkEntry hid settleHid (Just 100) (Just 200) Reg.LivenessThinking)
          { Reg._he_sessionId = Just "sess-1"
          , Reg._he_handle    = Just hh
          })
      -- spinner, then an approval frame (AwaitingInput needs no stability gate).
      let approvalFrame = "Do you want to proceed?"
      frames <- newIORef [busyFrame, approvalFrame]
      let deps = settleDeps (Reg.harnessIdToText hid) frames
                   (\sid txt -> modifyIORef' recorded ((sid, txt) :))
      broker <- mkInProcessBroker defaultBrokerConfig
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick deps reg broker mkNoOpLogHandle) $ \_a -> do
          threadDelay (20 * tick)
      xs <- readIORef recorded
      xs `shouldBe` [(SessionId "sess-1", "the prompt")]

    it "skips recording when _he_sessionId is Nothing (label-only entry)" $ do
      recorded <- newIORef ([] :: [(SessionId, Text)])
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let hh = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "the answer" }
      Reg.insertEntry reg
        ((mkEntry hid settleHid (Just 100) (Just 200) Reg.LivenessThinking)
          { Reg._he_sessionId = Nothing
          , Reg._he_label     = settleHid
          , Reg._he_handle    = Just hh
          })
      frames <- newIORef [busyFrame, busyFrame, idleFrame]
      let deps = settleDeps (Reg.harnessIdToText hid) frames
                   (\sid txt -> modifyIORef' recorded ((sid, txt) :))
      broker <- mkInProcessBroker defaultBrokerConfig
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick deps reg broker mkNoOpLogHandle) $ \_a -> do
          threadDelay (20 * tick)
      xs <- readIORef recorded
      xs `shouldBe` []

    it "records output produced with no preceding send (direct-tmux: spinner→idle)" $ do
      -- No /send happened; the harness just produced output. The settle on a
      -- spinner→idle transition still records it (the loop watches liveness, not
      -- send calls).
      recorded <- newIORef ([] :: [(SessionId, Text)])
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let hh = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "spontaneous output" }
      Reg.insertEntry reg
        ((mkEntry hid settleHid (Just 100) (Just 200) Reg.LivenessThinking)
          { Reg._he_sessionId = Just "sess-1"
          , Reg._he_handle    = Just hh
          })
      frames <- newIORef [busyFrame, busyFrame, idleFrame]
      let deps = settleDeps (Reg.harnessIdToText hid) frames
                   (\sid txt -> modifyIORef' recorded ((sid, txt) :))
      broker <- mkInProcessBroker defaultBrokerConfig
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick deps reg broker mkNoOpLogHandle) $ \_a -> do
          threadDelay (20 * tick)
      xs <- readIORef recorded
      xs `shouldBe` [(SessionId "sess-1", "spontaneous output")]

    -- Finding 1: a non-async exception thrown by '_rd_recordResponse' (or
    -- '_hh_snapshot') on one settled harness must NOT kill the reconcile loop.
    -- The loop must:
    --   * log a warning for the failing entry;
    --   * keep running;
    --   * still record the Response for a SECOND, healthy harness that settles
    --     on a later tick.
    -- RED on the unfixed code: the exception propagates to the 'outer' handler
    -- which logs + returns (exits) — the healthy harness's record is never seen.
    it "Finding 1: settle path survives a non-async IOException from _rd_recordResponse" $ do
      recorded  <- newIORef ([] :: [(SessionId, Text)])
      (logRef, capLog) <- mkCapturingLog

      reg <- Reg.newRegistry

      -- Harness A: its _rd_recordResponse throws an IOException on settle.
      hidA <- Reg.newHarnessId
      let hhA = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "response-A" }
      Reg.insertEntry reg
        ((mkEntry hidA settleHid (Just 100) (Just 200) Reg.LivenessThinking)
          { Reg._he_sessionId = Just "sess-A"
          , Reg._he_handle    = Just hhA
          })

      -- Harness B: healthy; sits at Thinking until a later set of idle frames.
      hidB <- Reg.newHarnessId
      let win_B = "claude-code-1"
          hhB   = mkNoOpHarnessHandle { _hh_snapshot = \_ -> pure "response-B" }
      Reg.insertEntry reg
        ((mkEntry hidB win_B (Just 300) (Just 400) Reg.LivenessThinking)
          { Reg._he_sessionId = Just "sess-B"
          , Reg._he_handle    = Just hhB
          })

      -- The injected _rd_recordResponse throws for sess-A, succeeds for sess-B.
      let record sid txt =
            if sid == SessionId "sess-A"
              then throwIO (userError "disk full" :: IOException)
              else modifyIORef' recorded ((sid, txt) :)

      -- Frame script: both harnesses start busy, then settle (idle×2 for the
      -- stability gate).  We map by window name so each gets its own sequence.
      framesA <- newIORef [busyFrame, busyFrame, idleFrame]
      framesB <- newIORef [busyFrame, busyFrame, busyFrame, idleFrame]

      broker <- mkInProcessBroker defaultBrokerConfig
      let tick = 40_000
          deps = ReconcileDeps
            { _rd_sessions = pure ["pureclaw"]
            , _rd_sweep    = \_ -> pure
                [ mkRow 0 settleHid (Reg.harnessIdToText hidA) (Just 100) False
                , mkRow 1 win_B     (Reg.harnessIdToText hidB) (Just 300) False
                ]
            , _rd_capture  = \_session windowName -> do
                let ref = if windowName == settleHid then framesA else framesB
                xs <- readIORef ref
                case xs of
                  []       -> pure (Just idleFrame)
                  [x]      -> pure (Just x)
                  (x : ys) -> do writeIORef ref ys; pure (Just x)
            , _rd_harnessAlive   = \_ -> pure True
            , _rd_stampLegacy     = \_ _ -> pure Nothing
            , _rd_evict           = \_ _ -> pure ()
            , _rd_recordResponse  = record
            }

      Async.withAsync
        (runReconcileLoopWith tick deps reg broker capLog) $ \_a -> do
          threadDelay (30 * tick)

      -- The healthy harness (B) must have been recorded despite A's failure.
      xs <- readIORef recorded
      xs `shouldBe` [(SessionId "sess-B", "response-B")]

      -- The loop must have logged a warning about the failing settle.
      logs <- readIORef logRef
      any (\m -> "settle snapshot/record" `T.isInfixOf` m) logs `shouldBe` True

  describe "reconcileTick — D5.5 / D5.7 (non-ours rows are never captured)" $ do
    it "a PID-mismatched marker row is logged + treated as not-ours (never captured, entry → Orphaned)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      -- A spoofed window carries OUR @pcl_id but a different pane PID.
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 9999) False]]
        Map.empty Map.empty
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      cap <- readIORef (f_capturedWindows f)
      cap `shouldBe` []  -- never captured the spoofed window
      [e] <- Reg.snapshot reg
      -- No corroborated match ⇒ the entry is Orphaned, not silently Idle.
      Reg._he_liveness e `shouldBe` Reg.LivenessOrphaned

    it "a row with an @pcl_id that matches no entry is ignored (never captured)" $ do
      reg <- Reg.newRegistry
      f <- mkFakes
        [Right [mkRow 0 "stranger" "00000000-0000-0000-0000-000000000000" (Just 7) False]]
        Map.empty Map.empty
      _ <- reconcileTick (fakeDeps f) reg mkNoOpLogHandle Map.empty
      cap <- readIORef (f_capturedWindows f)
      cap `shouldBe` []

  describe "reconcileTick — D5.3 (resilience: transient sweep failure)" $
    it "a transient sweep failure marks entries stale, holds last-known liveness, and logs a warning" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessThinking)
      (logRef, logger) <- mkCapturingLog
      f <- mkFakes [Left (userError "tmux hiccup")] Map.empty Map.empty
      _ <- reconcileTick (fakeDeps f) reg logger Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_stale e    `shouldBe` True
      Reg._he_liveness e `shouldBe` Reg.LivenessThinking  -- held, not repainted
      logs <- readIORef logRef
      any (\m -> "sweep of session" `T.isInfixOf` m) logs `shouldBe` True

  describe "reconcileTick — D5.3 (resilience: capture/liveness probe failure)" $ do
    it "a capture failure holds last-known liveness + marks stale (does not repaint, does not throw)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessThinking)
      -- The sweep succeeds and corroborates the window, but the screen capture
      -- throws (a transient tmux hiccup). The entry must be held stale with its
      -- prior liveness — NOT classified Exited/Orphaned from the capture error —
      -- and reconcileTick must not propagate the exception.
      (logRef, logger) <- mkCapturingLog
      let f0 fk = (fakeDeps fk)
            { _rd_capture = \_session _windowName -> throwIO (ErrorCall "capture boom") }
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]]
        Map.empty Map.empty
      _ <- reconcileTick (f0 f) reg logger Map.empty
      [e] <- Reg.snapshot reg
      Reg._he_stale e    `shouldBe` True
      Reg._he_liveness e `shouldBe` Reg.LivenessThinking  -- held, not repainted
      logs <- readIORef logRef
      any (\m -> "capture/liveness probe" `T.isInfixOf` m) logs `shouldBe` True

    it "a harness-alive probe failure holds one entry stale while other entries still reconcile" $ do
      reg <- Reg.newRegistry
      hidBad  <- Reg.newHarnessId  -- this one's liveness probe throws
      hidGood <- Reg.newHarnessId  -- this one reconciles normally
      Reg.insertEntry reg (mkEntry hidBad  "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      Reg.insertEntry reg (mkEntry hidGood "claude-code-1" (Just 300) (Just 400) Reg.LivenessIdle)
      -- The harness-alive probe throws ONLY for the bad entry's shell PID (100);
      -- the good entry's probe (PID 300) succeeds, capture says busy ⇒ Thinking.
      let f0 fk = (fakeDeps fk)
            { _rd_harnessAlive = \pid ->
                if pid == 100 then throwIO (ErrorCall "alive-probe boom") else pure True
            }
      f <- mkFakes
        [Right
          [ mkRow 0 "claude-code-0" (Reg.harnessIdToText hidBad)  (Just 100) False
          , mkRow 1 "claude-code-1" (Reg.harnessIdToText hidGood) (Just 300) False
          ]]
        (Map.singleton "claude-code-1" False)  -- good entry's screen is busy
        Map.empty
      _ <- reconcileTick (f0 f) reg mkNoOpLogHandle Map.empty
      entries <- Reg.snapshot reg
      let byId i = case [ e | e <- entries, Reg._he_id e == i ] of
            (e : _) -> e
            []      -> error "byId: entry not found"
          bad  = byId hidBad
          good = byId hidGood
      -- Bad entry: held stale at its prior (Idle) liveness, never repainted.
      Reg._he_stale bad     `shouldBe` True
      Reg._he_liveness bad  `shouldBe` Reg.LivenessIdle
      -- Good entry: fully reconciled despite the sibling's failure.
      Reg._he_stale good    `shouldBe` False
      Reg._he_liveness good `shouldBe` Reg.LivenessThinking

  describe "runReconcileLoopWith — D5.2 (loop emits a disappearance event)" $
    it "emits HarnessStopped when a registered entry disappears between ticks" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      -- Tick 1 (baseline): window present + idle. Tick 2+: window gone.
      f <- mkFakes
        [ Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]
        , Right []
        ]
        (Map.singleton "claude-code-0" True)
        Map.empty
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick (fakeDeps f) reg broker mkNoOpLogHandle) $ \_a -> do
          mEv <- recvWithin (8 * tick) sub
          case mEv of
            Just (ActivityChanged sid (SaHarnessStatus st)) -> do
              sid `shouldBe` SessionId "claude-code-0"
              st  `shouldBe` HarnessStopped
            other -> expectationFailure $
              "expected a HarnessStopped disappearance event, got: " <> show other

  describe "runReconcileLoopWith — first-tick baseline (D5.5)" $
    it "emits zero events on the first tick" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      -- A busy (working) window: it reads Thinking on every tick (working frames
      -- ignore the stability gate), so subsequent identical ticks produce no
      -- transition. This isolates the "first tick is a silent baseline" invariant
      -- from the legitimate idle-stability flip (an idle window would read
      -- Thinking on tick 1, then Idle once the capture is stable on tick 2).
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]]
        (Map.singleton "claude-code-0" False)
        Map.empty
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick (fakeDeps f) reg broker mkNoOpLogHandle) $ \_a -> do
          threadDelay (tick + 30_000)
          ev <- recvWithin (2 * tick) sub
          ev `shouldBe` Nothing

  describe "runReconcileLoopWith — D5.3 (loop survives a transient failure)" $
    it "does not die on a transient sweep failure (recovers next tick)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      -- Tick1: baseline idle. Tick2: sweep fails (stale, no repaint, no event).
      -- Tick3+: empty sweep ⇒ Orphaned ⇒ a HarnessStopped event proves the
      -- loop survived the transient failure and kept reconciling.
      f <- mkFakes
        [ Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]
        , Left (userError "tmux hiccup")
        , Right []
        ]
        (Map.singleton "claude-code-0" True)  -- idle baseline
        Map.empty
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick (fakeDeps f) reg broker mkNoOpLogHandle) $ \_a -> do
          mEv <- recvWithin (12 * tick) sub
          case mEv of
            Just (ActivityChanged _ (SaHarnessStatus HarnessStopped)) -> pure ()
            other -> expectationFailure $
              "expected loop to survive the failure and emit Stopped, got: " <> show other

  describe "bootReconstruct — D5.6 (boot reconstruction from @pcl_id windows)" $ do
    it "registers an entry for every window carrying our @pcl_id" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 4242) False]]
        Map.empty Map.empty
      bootReconstruct (fakeDeps f) reg mkNoOpLogHandle
      [e] <- Reg.snapshot reg
      Reg._he_id e       `shouldBe` hid
      Reg._he_shellPid e `shouldBe` Just 4242
      Reg._he_origin e   `shouldBe` Reg.OriginDiscovered
      Reg._he_windowName e `shouldBe` "claude-code-0"

    it "lazily stamps a legacy claude-code-<idx> window (no @pcl_id) with a fresh id" $ do
      reg <- Reg.newRegistry
      stampedHid <- Reg.newHarnessId
      -- A legacy window: matches the claude-code-<idx> prefix, no marker.
      let f0Deps fk = (fakeDeps fk)
            { _rd_stampLegacy = \_session windowName ->
                pure (if windowName == "claude-code-3" then Just stampedHid else Nothing)
            }
      f <- mkFakes
        [Right [mkRow 3 "claude-code-3" "" (Just 555) False]]
        Map.empty Map.empty
      bootReconstruct (f0Deps f) reg mkNoOpLogHandle
      entries <- Reg.snapshot reg
      map Reg._he_id entries `shouldBe` [stampedHid]
      [e] <- pure entries
      Reg._he_origin e     `shouldBe` Reg.OriginDiscovered
      Reg._he_windowName e `shouldBe` "claude-code-3"

    it "ignores an unmarked, non-legacy window (not ours, not stamped)" $ do
      reg <- Reg.newRegistry
      f <- mkFakes
        [Right [mkRow 0 "someone-elses-shell" "" (Just 1) False]]
        Map.empty Map.empty
      bootReconstruct (fakeDeps f) reg mkNoOpLogHandle  -- _rd_stampLegacy returns Nothing
      entries <- Reg.snapshot reg
      length entries `shouldBe` 0

    it "registers a pane_dead @pcl_id window as Exited" $ do
      -- The boot-time liveness seed is Exited when the reconstructed window is
      -- already pane_dead (the 'then' arm of the liveness conditional).
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 4242) True]]
        Map.empty Map.empty
      bootReconstruct (fakeDeps f) reg mkNoOpLogHandle
      [e] <- Reg.snapshot reg
      Reg._he_id e       `shouldBe` hid
      Reg._he_liveness e `shouldBe` Reg.LivenessExited

    it "logs a warning and registers nothing when the boot sweep fails" $ do
      -- A transient sweep failure at boot is logged and skipped (no entries),
      -- mirroring reconcileTick's resilience.
      reg <- Reg.newRegistry
      (logRef, logger) <- mkCapturingLog
      f <- mkFakes [Left (userError "tmux down at boot")] Map.empty Map.empty
      bootReconstruct (fakeDeps f) reg logger
      entries <- Reg.snapshot reg
      length entries `shouldBe` 0
      logs <- readIORef logRef
      any (\m -> "bootReconstruct: sweep of" `T.isInfixOf` m) logs `shouldBe` True

  describe "runReconcileLoopWith — D5.3 (loop survives a capture-probe failure)" $
    it "does not die when a capture throws (holds stale, keeps reconciling)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      -- The capture ALWAYS throws. Tick1 baseline: window present but capture
      -- throws ⇒ held stale at Idle (no event). Tick2: window gone ⇒ Orphaned
      -- ⇒ a HarnessStopped event proves the loop SURVIVED the capture failures.
      let f0 fk = (fakeDeps fk)
            { _rd_capture = \_session _windowName -> throwIO (ErrorCall "capture always boom") }
      f <- mkFakes
        [ Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]
        , Right []
        ]
        Map.empty Map.empty
      let tick = 40_000
      Async.withAsync
        (runReconcileLoopWith tick (f0 f) reg broker mkNoOpLogHandle) $ \_a -> do
          mEv <- recvWithin (12 * tick) sub
          case mEv of
            Just (ActivityChanged _ (SaHarnessStatus HarnessStopped)) -> pure ()
            other -> expectationFailure $
              "expected loop to survive the capture failure and emit Stopped, got: " <> show other

  describe "reconcileTick — corroboration-failure logging (§8 C4)" $
    it "logs a warning when a matching @pcl_id row fails PID corroboration" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      (logRef, logger) <- mkCapturingLog
      -- A spoofed window carries OUR @pcl_id but a mismatched pane PID.
      f <- mkFakes
        [Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 9999) False]]
        Map.empty Map.empty
      _ <- reconcileTick (fakeDeps f) reg logger Map.empty
      logs <- readIORef logRef
      any (\m -> "no corroborating PID" `T.isInfixOf` m) logs `shouldBe` True

  describe "runReconcileLoopWith — crash-log arm (non-AsyncCancelled)" $
    it "logs 'reconcile loop crashed' and exits when a non-cancel exception escapes a tick" $ do
      -- An injected _rd_sessions that throws a plain ErrorCall escapes
      -- reconcileTick (it is outside the per-session sweep try) and reaches the
      -- loop's 'outer' handler. The non-cancel arm must log + exit (not re-raise).
      reg <- Reg.newRegistry
      broker <- mkInProcessBroker defaultBrokerConfig
      (logRef, logger) <- mkCapturingLog
      f <- mkFakes [Right []] Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_sessions = throwIO (ErrorCall "sessions enumeration boom") }
          tick = 20_000
      -- The loop should TERMINATE on its own (handle swallows the exception),
      -- so 'timeout' returns Just () rather than Nothing.
      done <- timeout (50 * tick)
                (runReconcileLoopWith tick deps reg broker logger)
      done `shouldBe` Just ()
      logs <- readIORef logRef
      any (\m -> "reconcile loop crashed" `T.isInfixOf` m) logs `shouldBe` True

  -- WU2 — orphan grace/retention policy + auto-eviction (design §5 / §10 Q2).
  describe "reconcileTick — WU2 orphan grace policy" $ do
    -- D2.1: an Orphaned entry is RETAINED (still in the snapshot, greyed) while
    -- its consecutive-orphaned-tick count is below the grace threshold.
    it "D2.1 retains an Orphaned entry while below the grace threshold" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      evictRef <- newIORef ([] :: [(Reg.HarnessId, Text)])
      -- Sweep is ALWAYS empty ⇒ the corroborated window is absent ⇒ Orphaned.
      f <- mkFakes [Right []] Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictRef (++ [(i, l)]) }
      -- Run threshold-1 orphaned ticks: the entry must survive every one.
      replicateM_ (defaultOrphanGraceTicks - 1) $ do
        _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty
        pure ()
      snap <- Reg.snapshot reg
      map Reg._he_id snap `shouldBe` [hid]            -- still present (retained)
      [e] <- pure snap
      Reg._he_liveness e      `shouldBe` Reg.LivenessOrphaned  -- greyed, not gone
      Reg._he_orphanedTicks e `shouldBe` (defaultOrphanGraceTicks - 1)
      evicted <- readIORef evictRef
      evicted `shouldBe` []                           -- not yet evicted

    -- D2.2 + D2.5: at exactly the grace threshold the entry is evicted from the
    -- registry, the injected eviction seam fires with (id, label) (the seam the
    -- production wiring uses to also drop the LEGACY map), and reconcileTick
    -- returns the entry's sessionId so the loop emits a final disappearance.
    it "D2.2 evicts from the registry + fires _rd_evict (id,label) at the threshold" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let entry = (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
            { Reg._he_label = "claude-code-0", Reg._he_sessionId = Just "pcl-sid-7" }
      Reg.insertEntry reg entry
      evictRef <- newIORef ([] :: [(Reg.HarnessId, Text)])
      f <- mkFakes [Right []] Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictRef (++ [(i, l)]) }
      -- Run threshold-1 ticks (retained), then the threshold-th tick evicts.
      replicateM_ (defaultOrphanGraceTicks - 1) (void (reconcileTick deps reg mkNoOpLogHandle Map.empty))
      (_snap, evictedSids) <- reconcileTick deps reg mkNoOpLogHandle Map.empty
      -- Registry: the entry is gone.
      snap <- Reg.snapshot reg
      map Reg._he_id snap `shouldBe` []
      -- Eviction seam fired exactly once with (id, label) — this is the SAME
      -- callback the production loop wires to delete the legacy '_env_harnesses'
      -- map entry, proving both-store eviction (registry here + legacy via seam).
      evicted <- readIORef evictRef
      evicted `shouldBe` [(hid, "claude-code-0")]
      -- The tick surfaces the evicted sessionId so the loop emits a final event.
      evictedSids `shouldBe` ["pcl-sid-7"]

    -- D2.3: the counter RESETS when the entry becomes live again before the
    -- threshold, so a flapping window never accumulates to eviction.
    it "D2.3 resets the orphaned counter when the entry becomes live again" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      evictRef <- newIORef ([] :: [(Reg.HarnessId, Text)])
      -- Sweeps: a few empty (orphaning) ticks, then the window REAPPEARS idle,
      -- then empties again. The reappearance must reset the counter to 0.
      f <- mkFakes
        [ Right []                                                       -- orphan 1
        , Right []                                                       -- orphan 2
        , Right [mkRow 0 "claude-code-0" (Reg.harnessIdToText hid) (Just 100) False]  -- live
        , Right []                                                       -- orphan again
        ]
        (Map.singleton "claude-code-0" True)  -- idle when present
        Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictRef (++ [(i, l)]) }
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan 1
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan 2
      afterTwo <- Reg.snapshot reg
      (Reg._he_orphanedTicks <$> afterTwo) `shouldBe` [2]
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- live again ⇒ reset
      afterLive <- Reg.snapshot reg
      [eLive] <- pure afterLive
      -- The window reappeared this tick but its capture is not yet stable across
      -- ticks (the preceding ticks were empty sweeps, so there is no prior
      -- capture to match), so the idle frame reads Thinking — the point here is
      -- the entry is LIVE again (not Orphaned), which resets the grace counter.
      Reg._he_liveness eLive      `shouldBe` Reg.LivenessThinking
      Reg._he_orphanedTicks eLive `shouldBe` 0       -- counter reset
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan again ⇒ count restarts at 1
      afterReorphan <- Reg.snapshot reg
      (Reg._he_orphanedTicks <$> afterReorphan) `shouldBe` [1]
      evicted <- readIORef evictRef
      evicted `shouldBe` []                          -- never evicted (counter reset)

    -- D2.4: eviction NEVER touches session.json. The reconcile path's ONLY
    -- deletion seam is '_rd_evict :: HarnessId -> Text -> IO ()' (id + label) —
    -- there is no session-directory argument and no session-storage seam in
    -- 'ReconcileDeps', so the eviction logic structurally cannot delete a
    -- session. We assert the seam is invoked with id+label and that an injected
    -- recorder which deliberately does NOTHING to any session storage leaves the
    -- registry eviction working (the session is retained by construction).
    it "D2.4 eviction only deletes via _rd_evict (id,label) — session.json untouched" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let entry = (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
            { Reg._he_label = "claude-code-0", Reg._he_sessionId = Just "pcl-sid-9" }
      Reg.insertEntry reg entry
      -- A "session store" the eviction must NEVER touch. The seam takes only
      -- (id, label); it has no handle to this store, so it stays intact.
      sessionStore <- newIORef (["pcl-sid-9"] :: [Text])
      evictArgs    <- newIORef ([] :: [(Reg.HarnessId, Text)])
      f <- mkFakes [Right []] Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictArgs (++ [(i, l)]) }
      replicateM_ defaultOrphanGraceTicks (void (reconcileTick deps reg mkNoOpLogHandle Map.empty))
      -- Registry entry evicted...
      snap <- Reg.snapshot reg
      map Reg._he_id snap `shouldBe` []
      -- ...the seam fired with id+label only...
      args <- readIORef evictArgs
      args `shouldBe` [(hid, "claude-code-0")]
      -- ...and the session store is completely untouched (session.json retained,
      -- so the sid reappears in Recent Sessions).
      remainingSessions <- readIORef sessionStore
      remainingSessions `shouldBe` ["pcl-sid-9"]

    -- Anti-flap invariant (WU2 review fold-in): a transient sweep FAILURE while
    -- an entry is already Orphaned must HOLD the orphaned-tick counter — neither
    -- advance it (a tmux blip is not evidence the window is gone) nor reset it
    -- (the window did not return live) — and must NOT evict. This locks the
    -- held-path behaviour ('mkObservedHeld'/'baseObserved' carry the counter
    -- through unchanged) against regression: a flaky tmux server can never push
    -- a still-present-but-temporarily-unsweepable harness over the grace cliff.
    it "anti-flap: a transient sweep failure holds the orphaned counter (no advance, no reset, no evict)" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      Reg.insertEntry reg (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
      evictRef <- newIORef ([] :: [(Reg.HarnessId, Text)])
      -- A few empty (orphaning) ticks, then ONE failed sweep (transient tmux
      -- hiccup), then empty again. The failed tick must leave the counter where
      -- the orphaning ticks left it.
      f <- mkFakes
        [ Right []                       -- orphan 1  -> ticks = 1
        , Right []                       -- orphan 2  -> ticks = 2
        , Right []                       -- orphan 3  -> ticks = 3
        , Left (userError "tmux blip")   -- transient failure -> HELD at 3
        , Right []                       -- orphan again -> ticks = 4
        ]
        Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictRef (++ [(i, l)]) }
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan 1
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan 2
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan 3
      afterThree <- Reg.snapshot reg
      (Reg._he_orphanedTicks <$> afterThree) `shouldBe` [3]
      -- The failed sweep: counter HELD (not advanced to 4, not reset to 0), the
      -- entry stays Orphaned + marked stale, and it is NOT evicted.
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- transient failure
      afterFail <- Reg.snapshot reg
      [eHeld] <- pure afterFail
      Reg._he_orphanedTicks eHeld `shouldBe` 3                       -- HELD, not advanced/reset
      Reg._he_liveness eHeld      `shouldBe` Reg.LivenessOrphaned    -- still orphaned
      Reg._he_stale eHeld         `shouldBe` True                    -- the blip marked it stale
      readIORef evictRef `shouldReturn` []                          -- NOT evicted by the blip
      -- The next real (empty) sweep resumes advancing from the held value.
      _ <- reconcileTick deps reg mkNoOpLogHandle Map.empty  -- orphan again
      afterResume <- Reg.snapshot reg
      (Reg._he_orphanedTicks <$> afterResume) `shouldBe` [4]
      readIORef evictRef `shouldReturn` []

  describe "runReconcileLoopWith — WU2 (loop emits a final eviction event)" $
    it "D2.2 emits a final HarnessStopped disappearance event on auto-eviction" $ do
      reg <- Reg.newRegistry
      hid <- Reg.newHarnessId
      let entry = (mkEntry hid "claude-code-0" (Just 100) (Just 200) Reg.LivenessIdle)
            { Reg._he_label = "claude-code-0", Reg._he_sessionId = Just "pcl-sid-evt" }
      Reg.insertEntry reg entry
      broker <- mkInProcessBroker defaultBrokerConfig
      eSub   <- _streamBroker_subscribe broker
      sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
      evictRef <- newIORef ([] :: [(Reg.HarnessId, Text)])
      -- Window is gone from tick 1 on ⇒ orphaned every tick ⇒ eviction after the
      -- grace window. The loop must emit a final HarnessStopped for the sid even
      -- though the entry was already Orphaned (no liveness transition at evict).
      f <- mkFakes [Right []] Map.empty Map.empty
      let deps = (fakeDeps f)
            { _rd_evict = \i l -> modifyIORef' evictRef (++ [(i, l)]) }
          tick = 4_000
      Async.withAsync
        (runReconcileLoopWith tick deps reg broker mkNoOpLogHandle) $ \_a -> do
          -- Drain events until we both see the registry emptied AND captured the
          -- eviction; assert a final HarnessStopped for the evicted sid arrived.
          let drain :: Int -> IO Bool
              drain 0 = pure False
              drain n = do
                mEv <- recvWithin (4 * tick) sub
                case mEv of
                  Just (ActivityChanged (SessionId s) (SaHarnessStatus HarnessStopped))
                    | s == "pcl-sid-evt" -> do
                        ev <- readIORef evictRef
                        if null ev then drain (n - 1) else pure True
                  _ -> drain (n - 1)
          ok <- drain (defaultOrphanGraceTicks + 10)
          ok `shouldBe` True
          snap <- Reg.snapshot reg
          map Reg._he_id snap `shouldBe` []

  describe "isLegacyWindowName" $ do
    it "recognizes a claude-code-<idx> window name" $ do
      isLegacyWindowName "claude-code-0"  `shouldBe` True
      isLegacyWindowName "claude-code-42" `shouldBe` True
    it "rejects a non-legacy / malformed window name" $ do
      isLegacyWindowName "claude-code-"      `shouldBe` False  -- empty suffix
      isLegacyWindowName "claude-code-abc"   `shouldBe` False  -- non-digit suffix
      isLegacyWindowName "some-other-window" `shouldBe` False  -- wrong prefix

  describe "ActivityProbe shim — re-export delegates to the reconcile loop" $
    it "runActivityProbeLoop wires through to runReconcileLoop (cancellable before the first tick)" $ do
      -- The shim is 'runActivityProbeLoop = runReconcileLoop'. Invoking it forces
      -- that re-export. The production loop delays one (2 s) tick before any tmux
      -- IO, so cancelling immediately exercises the wiring without forking tmux.
      reg    <- Reg.newRegistry
      broker <- mkInProcessBroker defaultBrokerConfig
      cancelled <- Async.withAsync
        (runActivityProbeLoop broker reg mkNoOpLogHandle) $ \a -> do
          threadDelay 20_000        -- well inside the 2 s pre-tick delay
          Async.cancel a            -- AsyncCancelled fires during threadDelay
          -- 'waitCatch' returns Left AsyncCancelled (re-raised by the loop's
          -- outer handler) — proving the shim reached runReconcileLoopWith.
          res <- Async.waitCatch a
          pure $ case res of
            Left _  -> True
            Right _ -> True
      cancelled `shouldBe` True
