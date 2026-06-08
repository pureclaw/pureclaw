-- | Registry-based reconcile loop (Harness Registry & Lifecycle, Phase 1 — WU5).
--
-- This module is the registry's source of truth for harness /health/ and the
-- single authoritative updater of each entry's coordinate + liveness. It
-- replaces the legacy harness-map activity probe ("PureClaw.Frontend.ActivityProbe")
-- with a loop that reconciles the durable registry against tmux reality.
--
-- == What the loop does, each tick
--
--   1. ONE server sweep per session ('_rd_sweep') — never per-I\/O.
--   2. /Ownership filter/ (§8 C4 \/ D5.5\/D5.7): retain only rows whose
--      @\@pcl_id@ matches a registry entry AND is PID-corroborated against the
--      entry's recorded shell\/harness PID. A spoofed marker (collision or PID
--      mismatch) is logged and treated as "not ours" — never captured, never
--      marked live. A row with no recorded shell PID falls back to a second
--      signal (the window-name prefix) to defend against PID reuse.
--   3. Liveness classification (ours only): @Exited@ on @pane_dead@ or a dead
--      harness PID; @Idle@\/@Thinking@ via a screen capture + 'isIdle'; an
--      entry whose corroborated window is absent from the sweep → @Orphaned@.
--   4. 'Reg.mergeReconcile' the observed fields into the registry atomically.
--   5. /Symmetric diff/ (D5.2): emit one 'ActivityChanged' per entry whose
--      liveness changed since the previous tick — INCLUDING entries that
--      disappeared (now @Orphaned@\/@Exited@), fixing the disappearance gap.
--      The first tick establishes the baseline and emits nothing.
--
-- == Resilience (D5.3)
--
-- A transient sweep\/capture failure marks the affected entries '_he_stale'
-- and the loop CONTINUES — it never dies except on 'AsyncCancelled', which is
-- re-raised so 'Async.withAsync' cleanup runs (the project-wide invariant; cf.
-- "PureClaw.Frontend.ActivityProbe").
--
-- == Boot reconstruction (D5.6)
--
-- 'bootReconstruct' runs one sweep at startup and registers an entry for every
-- window carrying our @\@pcl_id@ (the PCL-restart reconnect path), and lazily
-- stamps a fresh 'Reg.HarnessId' onto legacy @claude-code-\<idx\>@ windows that
-- carry no marker. The legacy harness map is still seeded in parallel by the
-- unchanged @discoverHarnesses@; the registry is the new parallel path this
-- loop owns.
module PureClaw.Harness.Reconcile
  ( -- * Dependencies (the IO seam)
    ReconcileDeps (..)
  , defaultReconcileDeps
    -- * Orphan grace policy
  , defaultOrphanGraceTicks
    -- * Pure classification + corroboration
  , CorroborationResult (..)
  , corroborate
  , classifyLiveness
  , livenessToActivity
  , diffLiveness
    -- * Reconcile tick + loop
  , reconcileTick
  , runReconcileLoopWith
  , runReconcileLoop
  , defaultTickMicros
    -- * Boot reconstruction
  , bootReconstruct
    -- * Legacy window-name recognition (exposed for unit coverage)
  , isLegacyWindowName
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (SomeException, fromException, handle, throwIO, try)
import Control.Monad (forM, forM_)
import Data.Char (isDigit)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  )
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Harness.ClaudeCode (isIdle)
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux
  ( TmuxWindowRow (..)
  , captureWindowNamed
  , harnessPidOf
  , listTmuxSessions
  , readMarkers
  , setWindowMarker
  )

-- ---------------------------------------------------------------------------
-- Dependencies (IO seam — tests inject deterministic fakes)
-- ---------------------------------------------------------------------------

-- | The injectable tmux operations the reconcile loop needs. Tests supply
-- fakes (a queue of sweeps, a capture recorder) so the loop is deterministic
-- and never forks a real tmux server. The production set is
-- 'defaultReconcileDeps'.
data ReconcileDeps = ReconcileDeps
  { _rd_sessions :: IO [Text]
    -- ^ Enumerate the sessions to sweep (production: the @\"pureclaw\"@ session
    --   plus any other session on the server, via 'listTmuxSessions').
  , _rd_sweep :: Text -> IO [TmuxWindowRow]
    -- ^ One server sweep of a session (production: 'readMarkers'). May throw on
    --   a transient tmux failure; the loop catches it and marks entries stale.
  , _rd_capture :: Text -> Text -> IO Bool
    -- ^ Capture @session windowName@ and report whether the screen reads idle
    --   (production: 'captureWindowNamed' + 'isIdle'). Only called for
    --   corroborated, live (not pane_dead) windows.
  , _rd_harnessAlive :: Int -> IO Bool
    -- ^ Whether a recorded harness PID is still alive (production: a
    --   'harnessPidOf'-style liveness probe). Distinguishes @Exited@
    --   (harness gone, shell present) from @Idle@\/@Thinking@.
  , _rd_stampLegacy :: Text -> Text -> IO (Maybe Reg.HarnessId)
    -- ^ Lazily stamp a legacy @claude-code-\<idx\>@ window (no @\@pcl_id@) with
    --   a fresh marker + id, returning the new id (production: generate an id,
    --   'setWindowMarker'). 'Nothing' for a window we do not own.
  , _rd_evict :: Reg.HarnessId -> Text -> IO ()
    -- ^ Auto-eviction seam (design §5\/§10 Q2). Called with the
    --   @(harnessId, label)@ of an entry that has been Orphaned for
    --   'defaultOrphanGraceTicks' consecutive ticks. Production wires this to
    --   drop the entry from the LEGACY @_env_harnesses@ map (the registry
    --   delete is done by the loop itself, in 'reconcileTick'); it must NOT
    --   touch @session.json@ so the session reappears in Recent Sessions.
    --   Tests inject a recorder to assert the @(id, label)@ that was evicted.
  }

-- | Production dependency set. Sweeps the @\"pureclaw\"@ session plus any other
-- session on the server; capture\/idle via 'captureWindowNamed' + 'isIdle';
-- harness liveness via 'harnessPidOf'; legacy stamping via 'setWindowMarker'.
defaultReconcileDeps :: ReconcileDeps
defaultReconcileDeps = ReconcileDeps
  { _rd_sessions = do
      others <- listTmuxSessions
      -- Always include the default session even if it has no windows yet.
      pure (dedup ("pureclaw" : others))
  , _rd_sweep = readMarkers
  , _rd_capture = \session windowName -> do
      bytes <- captureWindowNamed session windowName 50
      pure (isIdle (TE.decodeUtf8Lenient bytes))
  , _rd_harnessAlive = \shellPid -> do
      -- Re-derive the harness PID by descending from the recorded shell PID and
      -- matching the flavour comm. If the descent still finds the agent binary
      -- the harness is alive; if it has exited, the descent returns 'Nothing'
      -- (the shell may still be present — that is exactly the @Exited@ case the
      -- @pane_dead@ flag also covers under @remain-on-exit on@).
      mPid <- harnessPidOf shellPid "claude"
      pure (isJust mPid)
  , _rd_stampLegacy = \session windowName ->
      if isLegacyWindowName windowName
        then do
          hid <- Reg.newHarnessId
          setWindowMarker session windowName (Reg.harnessIdToText hid)
          pure (Just hid)
        else pure Nothing
    -- Default eviction is a no-op: the loop itself deletes the evicted entry
    -- from the registry; the legacy-map drop is wired in CLI.Commands (which
    -- overrides this seam via 'runReconcileLoopWith'). Crucially this never
    -- deletes @session.json@.
  , _rd_evict = \_hid _label -> pure ()
  }
  where
    dedup = go []
      where
        go seen [] = reverse seen
        go seen (x : xs)
          | x `elem` seen = go seen xs
          | otherwise     = go (x : seen) xs

-- ---------------------------------------------------------------------------
-- Pure corroboration (§8 C4 / D5.7)
-- ---------------------------------------------------------------------------

-- | The result of corroborating a marker row against a registry entry.
data CorroborationResult
  = Corroborated
    -- ^ The row is genuinely this entry's window: PID-provenance (or, for a
    --   provenance-less entry, the window-name prefix) confirms it.
  | PidMismatch
    -- ^ The marker matches but the recorded shell PID does not (or the second
    --   signal fails) — a spoof\/PID-reuse: treat as NOT ours, never trust.
  deriving stock (Eq, Show)

-- | Corroborate a marker row (already known to carry this entry's @\@pcl_id@)
-- against the entry's recorded provenance (§8 C4):
--
--   * If we recorded a shell PID, the row's @#{pane_pid}@ MUST match it.
--   * If we recorded NO shell PID (legacy\/adopted), require a SECOND signal —
--     the @claude-code-\<idx\>@-style window-name prefix matching the entry's
--     label — to defend against PID reuse.
corroborate :: Reg.HarnessEntry -> TmuxWindowRow -> CorroborationResult
corroborate e row =
  case Reg._he_shellPid e of
    Just recordedPid
      | _twr_panePid row == Just recordedPid -> Corroborated
      | otherwise                            -> PidMismatch
    Nothing
      -- No recorded provenance: fall back to the window-name prefix as the
      -- second corroborating signal.
      | _twr_windowName row == Reg._he_label e -> Corroborated
      | otherwise                              -> PidMismatch

-- ---------------------------------------------------------------------------
-- Pure liveness classification (D5.4)
-- ---------------------------------------------------------------------------

-- | Classify a corroborated window's liveness from @(paneDead, harnessAlive,
-- isIdle)@:
--
--   * @pane_dead@ OR a dead harness PID ⇒ 'Reg.LivenessExited' (the window is
--     present but the agent is gone).
--   * otherwise the screen capture decides: idle ⇒ 'Reg.LivenessIdle',
--     busy ⇒ 'Reg.LivenessThinking'.
--
-- 'Reg.LivenessOrphaned' is NOT produced here — it is assigned to entries whose
-- corroborated window is /absent/ from the sweep (see 'reconcileTick').
classifyLiveness :: Bool -> Bool -> Bool -> Reg.Liveness
classifyLiveness paneDead harnessAlive idle
  | paneDead || not harnessAlive = Reg.LivenessExited
  | idle                         = Reg.LivenessIdle
  | otherwise                    = Reg.LivenessThinking

-- | Map a registry 'Reg.Liveness' to the broker's 'HarnessActivity' vocabulary.
-- Both @Exited@ and @Orphaned@ collapse to 'HarnessStopped' (the frontend's
-- richer state→glyph mapping is Phase 2).
livenessToActivity :: Reg.Liveness -> HarnessActivity
livenessToActivity Reg.LivenessIdle     = HarnessIdle
livenessToActivity Reg.LivenessThinking = HarnessThinking
livenessToActivity Reg.LivenessExited   = HarnessStopped
livenessToActivity Reg.LivenessOrphaned = HarnessStopped

-- ---------------------------------------------------------------------------
-- Pure symmetric diff (D5.2)
-- ---------------------------------------------------------------------------

-- | Compute the @(sessionId, liveness)@ transitions between two ticks' liveness
-- snapshots, keyed by 'Reg.HarnessId' (rendered as 'Text' for test ergonomics).
-- Each value carries the SessionId the event should be published under plus the
-- current liveness.
--
-- An entry whose liveness CHANGED (or that is newly present) emits its new
-- liveness. Crucially, an entry that went 'Reg.LivenessOrphaned'\/'Reg.LivenessExited'
-- (because its window vanished from the sweep) is still present in @next@ — the
-- registry retains it — so the transition surfaces, fixing the disappearance
-- gap (@ActivityProbe.hs:117@). A dropped key (registry entry removed entirely)
-- emits nothing; eviction is a Phase-2 concern.
diffLiveness
  :: Map Text (Text, Reg.Liveness)  -- ^ previous tick
  -> Map Text (Text, Reg.Liveness)  -- ^ current tick
  -> [(Text, Reg.Liveness)]         -- ^ @(sessionId, newLiveness)@ to publish
diffLiveness prev next =
  [ (sid, liveness)
  | (key, (sid, liveness)) <- Map.toList next
  , case Map.lookup key prev of
      Nothing            -> True                  -- newly observed
      Just (_, oldLive)  -> oldLive /= liveness   -- transitioned
  ]

-- ---------------------------------------------------------------------------
-- Reconcile tick (IO)
-- ---------------------------------------------------------------------------

-- | A single reconcile pass: sweep, corroborate, classify, merge, and return
-- the per-entry liveness snapshot keyed by 'Reg.HarnessId' text (for the loop's
-- diff). On a transient sweep failure the registry's entries are marked
-- '_he_stale' (holding last-known liveness) and the snapshot reflects the held
-- state; the tick never throws on a sweep failure.
reconcileTick
  :: ReconcileDeps
  -> Reg.HarnessRegistry
  -> LogHandle
  -> IO (Map Text (Text, Reg.Liveness), [Text])
  -- ^ @(liveness snapshot keyed by id-text, sessionIds of entries auto-evicted
  --   this tick)@. Evicted entries are removed from the snapshot map (so the
  --   next diff does not re-report them) and the loop emits one final
  --   disappearance event per returned sessionId.
reconcileTick deps reg logger = do
  sessions <- _rd_sessions deps
  -- Sweep every session; a failed sweep yields Nothing (we then hold stale).
  sweepResults <- forM sessions $ \session -> do
    r <- try @SomeException (_rd_sweep deps session)
    case r of
      Left err -> do
        _lh_logWarn logger
          ("reconcile: sweep of session " <> session <> " failed: " <> T.pack (show err))
        pure Nothing
      Right rows -> pure (Just rows)
  let sweepFailed = Nothing `elem` sweepResults
      allRows     = concat (catMaybes sweepResults)
  entries <- Reg.snapshot reg
  -- Build, per entry, its observed fields (or the stale/orphaned fallback).
  observedPairs <- forM entries $ \e -> do
    let idText  = Reg.harnessIdToText (Reg._he_id e)
        matches = [ row | row <- allRows, _twr_pclId row == idText ]
    case matches of
      [] | sweepFailed ->
            -- No row AND a sweep failed: we cannot conclude the window is gone.
            -- Hold last-known liveness; mark stale.
            pure (mkObservedHeld e)
         | otherwise ->
            -- Sweep succeeded and our window is absent ⇒ Orphaned.
            pure (mkObservedOrphaned e)
      _ -> do
        -- Corroborate each candidate; trust only the first corroborated row.
        let corroboratedRows =
              [ row | row <- matches, corroborate e row == Corroborated ]
        case corroboratedRows of
          [] -> do
            -- A marker matched but corroboration failed (spoof / PID mismatch):
            -- log + treat as not ours; the entry is Orphaned, never captured.
            _lh_logWarn logger
              ("reconcile: @pcl_id " <> idText
                 <> " matched a window with no corroborating PID — treating as not ours (§8 C4)")
            pure (mkObservedOrphaned e)
          (row : _) -> do
            -- The per-window capture + harness-alive probe is the only other
            -- tmux IO in the tick (besides the sweep, handled above). A
            -- transient failure here must NOT kill the loop (D5.3): hold this
            -- entry's last-known liveness and mark it stale, exactly as a sweep
            -- failure does — never repaint it from a capture error, never let
            -- the exception propagate to the loop's crash handler.
            r <- try @SomeException (classifyRow deps e row)
            case r of
              Left err -> do
                _lh_logWarn logger
                  ("reconcile: capture/liveness probe for @pcl_id " <> idText
                     <> " failed: " <> T.pack (show err) <> " — holding last-known liveness")
                pure (mkObservedHeld e)
              Right liveness ->
                pure (mkObservedLive e row liveness)
  let observed = map snd observedPairs
  Reg.mergeReconcile reg observed
  let snapMap = Map.fromList [ (k, v) | (k, v) <- map fst observedPairs ]
  -- Orphan grace policy (design §5 / §10 Q2): after the merge, evict any entry
  -- that has now been Orphaned for 'defaultOrphanGraceTicks' consecutive ticks.
  -- Eviction drops the entry from the registry (here) and from the legacy map
  -- (via the injectable '_rd_evict' seam, wired in CLI.Commands) — but never
  -- touches @session.json@. The evicted ids are removed from the returned
  -- snapshot so the next tick's diff does not re-report them; their sessionIds
  -- are returned so the loop can emit one final disappearance event.
  merged <- Reg.snapshot reg
  let toEvict =
        [ e | e <- merged, Reg._he_orphanedTicks e >= defaultOrphanGraceTicks ]
  evictedSids <- forM toEvict $ \e -> do
    _lh_logInfo logger
      ("reconcile: evicting harness " <> Reg.harnessIdToText (Reg._he_id e)
         <> " (label " <> Reg._he_label e <> ") after "
         <> T.pack (show (Reg._he_orphanedTicks e))
         <> " orphaned ticks; session.json retained")
    _rd_evict deps (Reg._he_id e) (Reg._he_label e)
    Reg.deleteEntry reg (Reg._he_id e)
    pure (Reg.harnessIdToText (Reg._he_id e), sidOf e)
  let evictedKeys = map fst evictedSids
      snapMap'    = foldr Map.delete snapMap evictedKeys
  pure (snapMap', map snd evictedSids)
  where
    -- Each result is ((keyText, (sessionId, liveness)), ObservedHarness).
    mkObservedHeld :: Reg.HarnessEntry -> ((Text, (Text, Reg.Liveness)), Reg.ObservedHarness)
    mkObservedHeld e =
      let live = Reg._he_liveness e
      in ( (Reg.harnessIdToText (Reg._he_id e), (sidOf e, live))
         , (baseObserved e live) { Reg._oh_stale = True } )

    mkObservedOrphaned :: Reg.HarnessEntry -> ((Text, (Text, Reg.Liveness)), Reg.ObservedHarness)
    mkObservedOrphaned e =
      ( (Reg.harnessIdToText (Reg._he_id e), (sidOf e, Reg.LivenessOrphaned))
      , (baseObserved e Reg.LivenessOrphaned)
          { Reg._oh_liveness = Reg.LivenessOrphaned
            -- The corroborated window is absent this tick: advance the
            -- consecutive-orphaned counter so the grace policy can fire.
          , Reg._oh_orphanedTicks = Reg._he_orphanedTicks e + 1
          } )

    mkObservedLive
      :: Reg.HarnessEntry -> TmuxWindowRow -> Reg.Liveness
      -> ((Text, (Text, Reg.Liveness)), Reg.ObservedHarness)
    mkObservedLive e row liveness =
      let extMod = _twr_windowName row /= Reg._he_windowName e
      in ( (Reg.harnessIdToText (Reg._he_id e), (sidOf e, liveness))
         , Reg.ObservedHarness
             { Reg._oh_id          = Reg._he_id e
             , Reg._oh_session     = Reg._he_session e
             , Reg._oh_windowName  = _twr_windowName row
             , Reg._oh_shellPid    = _twr_panePid row
             , Reg._oh_harnessPid  = Reg._he_harnessPid e
             , Reg._oh_liveness    = liveness
             , Reg._oh_extModified = Reg._he_extModified e || extMod
             , Reg._oh_stale       = False
               -- The window is present + corroborated this tick: the entry is
               -- live again, so reset the consecutive-orphaned counter.
             , Reg._oh_orphanedTicks = 0
             } )

    -- A held-state observed record reusing the entry's current coordinate.
    baseObserved :: Reg.HarnessEntry -> Reg.Liveness -> Reg.ObservedHarness
    baseObserved e liveness = Reg.ObservedHarness
      { Reg._oh_id          = Reg._he_id e
      , Reg._oh_session     = Reg._he_session e
      , Reg._oh_windowName  = Reg._he_windowName e
      , Reg._oh_shellPid    = Reg._he_shellPid e
      , Reg._oh_harnessPid  = Reg._he_harnessPid e
      , Reg._oh_liveness    = liveness
      , Reg._oh_extModified = Reg._he_extModified e
      , Reg._oh_stale       = False
        -- Hold the current counter: a held (stale) observation neither advances
        -- nor resets the grace clock; only a definite Orphaned/live tick does.
      , Reg._oh_orphanedTicks = Reg._he_orphanedTicks e
      }

    sidOf :: Reg.HarnessEntry -> Text
    sidOf e = fromMaybe (Reg._he_label e) (Reg._he_sessionId e)

-- | Classify a corroborated window's liveness, capturing the screen only when
-- the window is alive (not pane_dead and the harness PID is present). A
-- @pane_dead@ window is NEVER captured (D5.4\/D5.5).
classifyRow :: ReconcileDeps -> Reg.HarnessEntry -> TmuxWindowRow -> IO Reg.Liveness
classifyRow deps e row
  | _twr_paneDead row = pure Reg.LivenessExited
  | otherwise = do
      -- Liveness of the agent process: re-derive it by descending from the live
      -- shell PID (the row's @#{pane_pid}@). We only bother when we recorded a
      -- harness PID at spawn (a provenance-less/legacy entry has none, so we
      -- assume alive and rely on @pane_dead@ for Exited).
      alive <- case (Reg._he_harnessPid e, _twr_panePid row) of
        (Just _, Just shellPid) -> _rd_harnessAlive deps shellPid
        _                       -> pure True
      if not alive
        then pure Reg.LivenessExited
        else do
          idle <- _rd_capture deps (Reg._he_session e) (_twr_windowName row)
          pure (classifyLiveness False True idle)

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

-- | Production reconcile loop: 2-second cadence, real tmux deps.
runReconcileLoop :: StreamBroker -> Reg.HarnessRegistry -> LogHandle -> IO ()
runReconcileLoop broker reg =
  runReconcileLoopWith defaultTickMicros defaultReconcileDeps reg broker

-- | Production tick interval: 2 seconds (matches the legacy probe cadence).
defaultTickMicros :: Int
defaultTickMicros = 2_000_000

-- | The orphan grace window, in consecutive reconcile ticks (design §5\/§10
-- Q2). Once an entry has been classified 'Reg.LivenessOrphaned' for this many
-- ticks in a row (i.e. '_he_orphanedTicks' reaches this value) the reconcile
-- loop auto-evicts it from the registry and the legacy harness map and emits a
-- final disappearance event — but never deletes @session.json@.
--
-- We count ticks rather than wall-clock so the policy is deterministic and
-- test-injectable. At the production 2-second 'defaultTickMicros' cadence, 15
-- ticks ≈ 30 seconds of continuous orphaning before eviction — long enough to
-- ride out a transient tmux-server blip (which is held '_he_stale' and does
-- NOT advance the counter), short enough that a genuinely gone harness clears
-- from Active Tabs promptly.
defaultOrphanGraceTicks :: Int
defaultOrphanGraceTicks = 15

-- | The reconcile loop with an explicit tick interval + injected deps. The
-- first tick establishes the baseline (emits nothing); from the second tick on,
-- one 'ActivityChanged' is published per entry whose liveness changed
-- (including disappearances). Resilient: a transient sweep failure is absorbed
-- by 'reconcileTick' (entries held stale); the loop only exits on
-- 'AsyncCancelled', which it re-raises.
runReconcileLoopWith
  :: Int
  -> ReconcileDeps
  -> Reg.HarnessRegistry
  -> StreamBroker
  -> LogHandle
  -> IO ()
runReconcileLoopWith tickMicros deps reg broker logger = handle outer $ do
  threadDelay tickMicros
  -- Baseline tick: emits no transitions. Any eviction on this first tick still
  -- emits its final disappearance event (an eviction is not a diff transition).
  (initial, evicted0) <- reconcileTick deps reg logger
  publishEvictions evicted0
  loop initial
  where
    loop prev = do
      threadDelay tickMicros
      (next, evicted) <- reconcileTick deps reg logger
      forM_ (diffLiveness prev next) $ \(sid, liveness) ->
        _streamBroker_publish broker
          (ActivityChanged (SessionId sid) (SaHarnessStatus (livenessToActivity liveness)))
      -- One final disappearance event per auto-evicted entry. The entry was
      -- already Orphaned, so the diff above does NOT re-emit it; this guarantees
      -- the frontend sees it leave even though no liveness transition occurred.
      publishEvictions evicted
      loop next

    publishEvictions = mapM_ $ \sid ->
      _streamBroker_publish broker
        (ActivityChanged (SessionId sid) (SaHarnessStatus (livenessToActivity Reg.LivenessOrphaned)))

    -- AsyncCancelled MUST be re-raised so 'Async.withAsync'/'Async.cancel'
    -- complete cleanly (project-wide invariant).
    outer :: SomeException -> IO ()
    outer ex
      | Just AsyncCancelled <- fromException ex = throwIO ex
      | otherwise = _lh_logError logger
          ("reconcile loop crashed: " <> T.pack (show ex))

-- ---------------------------------------------------------------------------
-- Boot reconstruction (D5.6)
-- ---------------------------------------------------------------------------

-- | At startup, run one sweep and register an entry for every window we own:
--
--   * a window carrying our @\@pcl_id@ → an 'Reg.OriginDiscovered' entry (the
--     PCL-restart reconnect path);
--   * a legacy @claude-code-\<idx\>@ window with no marker → lazily stamped a
--     fresh id (via '_rd_stampLegacy') and registered as 'Reg.OriginDiscovered'.
--
-- The legacy harness map is seeded separately by the unchanged
-- @discoverHarnesses@; this builds the parallel registry the reconcile loop
-- owns. Idempotent-ish: an already-registered id is overwritten with the
-- freshly observed coordinate (boot runs once).
bootReconstruct :: ReconcileDeps -> Reg.HarnessRegistry -> LogHandle -> IO ()
bootReconstruct deps reg logger = do
  sessions <- _rd_sessions deps
  forM_ sessions $ \session -> do
    r <- try @SomeException (_rd_sweep deps session)
    case r of
      Left err ->
        _lh_logWarn logger
          ("bootReconstruct: sweep of " <> session <> " failed: " <> T.pack (show err))
      Right rows -> forM_ rows $ \row -> do
        case Reg.parseHarnessId (_twr_pclId row) of
          Just hid ->
            registerEntry session row hid
          Nothing -> do
            mHid <- _rd_stampLegacy deps session (_twr_windowName row)
            for_ mHid (registerEntry session row)  -- 'Nothing' ⇒ not ours
  where
    registerEntry session row hid = do
      let live = if _twr_paneDead row then Reg.LivenessExited else Reg.LivenessIdle
      Reg.insertEntry reg Reg.HarnessEntry
        { Reg._he_id          = hid
        , Reg._he_session     = session
        , Reg._he_windowName  = _twr_windowName row
        , Reg._he_shellPid    = _twr_panePid row
        , Reg._he_harnessPid  = Nothing
        , Reg._he_origin      = Reg.OriginDiscovered
        , Reg._he_liveness    = live
        , Reg._he_extModified = False
        , Reg._he_stale       = False
        , Reg._he_sessionId   = Nothing
        , Reg._he_label       = _twr_windowName row
        , Reg._he_orphanedTicks = 0
        , Reg._he_handle      = Nothing
        }

-- ---------------------------------------------------------------------------
-- Legacy window-name recognition
-- ---------------------------------------------------------------------------

-- | A legacy harness window name is @\<canonical\>-\<idx\>@ for a known flavour
-- (Phase 1: only @claude-code@). Used by the default 'ReconcileDeps' to decide
-- whether an unmarked window should be lazily stamped.
isLegacyWindowName :: Text -> Bool
isLegacyWindowName name =
  case T.stripPrefix "claude-code-" name of
    Just suffix -> not (T.null suffix) && T.all isDigit suffix
    Nothing     -> False
