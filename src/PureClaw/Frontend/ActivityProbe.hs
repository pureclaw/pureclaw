-- | Activity probe loop — WU4 of the live-transcript-streaming feature.
--
-- The loop walks the process-wide @IORef (Map Text HarnessHandle)@ every
-- two seconds, derives each harness's current 'HarnessActivity' via the
-- same 'probeHarness' logic the HTTP API uses, and publishes one
-- 'ActivityChanged' event per state /transition/ (not per probe tick) to
-- the 'StreamBroker'.
--
-- /First-tick semantics./ The very first probe establishes the baseline;
-- zero events are emitted on that tick. From the second tick onward only
-- harnesses whose state differs from the previous snapshot produce events.
-- This is the v1 source of truth for 'SaHarnessStatus' events — see
-- @docs\/transcript-streaming.md@ §"Activity event source" and DoD D17.
--
-- /Lifecycle./ The loop is forked under 'Async.withAsync' alongside the WAI
-- server in @startWithChannel@ ("PureClaw.CLI.Commands"). When the
-- enclosing 'Async' scope exits, 'AsyncCancelled' is delivered; the
-- exception handler /re-raises/ it (per project memory) so bracket-style
-- cleanup runs. Any other 'SomeException' is logged via '_lh_logError' and
-- the loop terminates — v1 prefers "loud failure" to silent restart (D24,
-- @docs\/transcript-streaming.md@ §"Lifecycle and Shutdown").
--
-- /Test seam./ 'runActivityProbeLoopWith' exposes the tick interval and the
-- probe action so unit tests can drive the loop deterministically. The
-- production entry point 'runActivityProbeLoop' supplies the standard wiring
-- — a 2-second tick and the harness-map snapshot via 'probeHarness'.
module PureClaw.Frontend.ActivityProbe
  ( runActivityProbeLoop
  , runActivityProbeLoopWith
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (SomeException, fromException, handle, throwIO, try)
import Control.Monad (forM_, forever)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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
import PureClaw.Handles.Harness (HarnessHandle (..), HarnessStatus (..))
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Harness.ClaudeCode (isIdle)
import PureClaw.Harness.Tmux (captureWindow)

-- ---------------------------------------------------------------------------
-- Production entry point
-- ---------------------------------------------------------------------------

-- | Run the activity probe loop with the production tick interval (2 s) and
-- the standard harness-snapshot action. The harness snapshot mirrors the
-- semantics of 'PureClaw.Frontend.API.probeHarness': for each harness in
-- the map, it derives 'HarnessActivity' from process status + a tmux
-- capture. See 'runActivityProbeLoopWith' for the test seam.
runActivityProbeLoop
  :: StreamBroker
  -> IORef (Map Text HarnessHandle)
  -> LogHandle
  -> IO ()
runActivityProbeLoop broker harnessesRef =
  runActivityProbeLoopWith
    defaultTickMicros
    (snapshotHarnesses harnessesRef)
    broker

-- | Production tick interval: 2 seconds, matching @docs\/transcript-streaming.md@
-- §"Activity event source" (sole source of 'SaHarnessStatus' events; the
-- 2 s lag is the documented v1 tradeoff).
defaultTickMicros :: Int
defaultTickMicros = 2_000_000

-- ---------------------------------------------------------------------------
-- Test-friendly entry point
-- ---------------------------------------------------------------------------

-- | The probe loop with explicit tick interval and a caller-supplied probe
-- action. Unit tests pass a controllable probe (e.g. reading a mutable
-- 'IORef') so the loop is deterministic without forking tmux. The
-- @probe@ action MUST be exception-safe; the loop catches any
-- 'SomeException' except 'AsyncCancelled', logs it, and terminates (no
-- restart in v1).
runActivityProbeLoopWith
  :: Int
  -- ^ Tick interval in microseconds.
  -> IO (Map Text HarnessActivity)
  -- ^ Probe action: returns the current per-harness activity snapshot.
  -> StreamBroker
  -> LogHandle
  -> IO ()
runActivityProbeLoopWith tickMicros probe broker logger = handle outer $ do
  -- First tick: establish the baseline, emit nothing. The sleep happens
  -- BEFORE the probe so a test that cancels immediately doesn't race the
  -- first probe (and so D17's "no events on the first tick" holds even if
  -- the harness map is changing concurrently).
  threadDelay tickMicros
  initial <- probe
  lastStatesRef <- newIORef initial
  forever $ do
    threadDelay tickMicros
    next <- probe
    prev <- readIORef lastStatesRef
    -- Emit one event per harness whose state changed since the previous
    -- snapshot. @Map.differenceWith f m1 m2@ keeps every key of @m1@: if
    -- @m2@ also has the key, @f new old@ decides whether to keep
    -- (@Just new@) or drop (@Nothing@); if @m2@ does not, the entry is
    -- kept as-is. So this single call captures both "transitioned"
    -- harnesses and newly-appeared harnesses (first-observed state).
    -- Harnesses that /disappear/ between ticks emit no event — their
    -- absence is a separable v1.5 concern.
    let transitions :: Map Text HarnessActivity
        transitions =
          Map.differenceWith
            (\new old -> if new == old then Nothing else Just new)
            next
            prev
    forM_ (Map.toList transitions) $ \(name, status) ->
      _streamBroker_publish broker
        (ActivityChanged (sessionIdFromHarnessName name) (SaHarnessStatus status))
    writeIORef lastStatesRef next
  where
    -- AsyncCancelled MUST be re-raised so 'Async.withAsync' / 'Async.cancel'
    -- can complete cleanly (project-wide invariant; see
    -- 'PureClaw.Frontend.BroadcastingTranscript' for the same pattern).
    outer :: SomeException -> IO ()
    outer e
      | Just AsyncCancelled <- fromException e = throwIO e
      | otherwise = _lh_logError logger
          ("activity-probe crashed: " <> T.pack (show e))

-- ---------------------------------------------------------------------------
-- Harness → SessionId mapping
-- ---------------------------------------------------------------------------

-- | Convert a harness-map key (the harness "name", e.g. @claude-code-0@) to
-- a 'SessionId'. The activity events flow over the wire keyed by
-- 'SessionId'; the harness map is keyed by 'Text'. v1 uses the harness
-- name as the session id verbatim — frontends that need to map "harness
-- name" back to "session id" can do so client-side. A richer mapping (e.g.
-- looking up '_hh_session' on the handle) is a follow-up if real session
-- ids ever diverge from harness names.
sessionIdFromHarnessName :: Text -> SessionId
sessionIdFromHarnessName = SessionId

-- ---------------------------------------------------------------------------
-- Production probe (mirrors Frontend.API.probeHarness, sans HarnessInfo wrapper)
-- ---------------------------------------------------------------------------

-- | Snapshot the current per-harness 'HarnessActivity'. Exception-safe per
-- harness: a probe failure on one entry yields 'HarnessIdle' rather than
-- propagating, matching the HTTP @\/harnesses@ probe's behaviour and
-- preserving the loop's "best-effort" contract.
snapshotHarnesses
  :: IORef (Map Text HarnessHandle)
  -> IO (Map Text HarnessActivity)
snapshotHarnesses ref = do
  harnesses <- readIORef ref
  pairs <- traverse probeOne (Map.toList harnesses)
  pure (Map.fromList pairs)
  where
    probeOne :: (Text, HarnessHandle) -> IO (Text, HarnessActivity)
    probeOne (name, hh) = do
      st <- _hh_status hh
      activity <- case st of
        HarnessExited _ -> pure HarnessStopped
        HarnessRunning  -> probeRunning (_hh_session hh) name
      pure (name, activity)

-- | Same shape as 'PureClaw.Frontend.API.probeActivity': tmux capture
-- distinguishes idle vs thinking; capture failures degrade to idle so the
-- loop never crashes on a transient tmux hiccup.
probeRunning :: Text -> Text -> IO HarnessActivity
probeRunning tmuxSession windowName = do
  let target = tmuxSession <> ":" <> extractWindowIdx windowName
  result <- try @SomeException (captureWindow target 50)
  case result of
    Left _        -> pure HarnessIdle
    Right capture ->
      pure $
        if isIdle (TE.decodeUtf8Lenient capture)
          then HarnessIdle
          else HarnessThinking

-- | Extract the window-index suffix from a harness name like
-- @"claude-code-0"@. Mirrors 'PureClaw.Frontend.API.extractWindowIdx' so
-- the probe loop produces the same captures the HTTP @\/harnesses@
-- endpoint does.
extractWindowIdx :: Text -> Text
extractWindowIdx name =
  case T.splitOn "-" name of
    parts | length parts >= 2 -> last parts
    _                         -> "0"
