-- | Activity probe loop — now a thin shim over the registry-based reconcile
-- loop ("PureClaw.Harness.Reconcile", WU5 of the Harness Registry feature).
--
-- /History./ This module originally walked the process-wide
-- @IORef (Map Text HarnessHandle)@ every two seconds and published one
-- 'PureClaw.Frontend.StreamBroker.ActivityChanged' per state transition. That
-- legacy probe had a structural gap: it used a one-way map diff, so a harness
-- that /disappeared/ between ticks emitted no event (the bug at the old
-- @ActivityProbe.hs:117@).
--
-- /Now./ The 'PureClaw.Harness.Registry' is the source of truth for harness
-- identity + health, and 'PureClaw.Harness.Reconcile' owns the loop: it sweeps
-- tmux, corroborates ownership by PID (§8 C4), classifies liveness, and emits a
-- /symmetric/-diff stream of 'ActivityChanged' events that INCLUDES
-- disappearances. This module re-exports that loop under the historical name so
-- the CLI wiring in "PureClaw.CLI.Commands" reads unchanged at the call site.
--
-- The loop's behavioural contract (first-tick baseline, cancellation re-raise,
-- transient-failure resilience) and its deterministic test seam now live in
-- "PureClaw.Harness.Reconcile" ('Reconcile.runReconcileLoopWith') and are
-- covered by @test\/Harness\/ReconcileSpec.hs@.
module PureClaw.Frontend.ActivityProbe
  ( runActivityProbeLoop
  ) where

import PureClaw.Frontend.StreamBroker (StreamBroker)
import PureClaw.Handles.Log (LogHandle)
import PureClaw.Harness.Reconcile (runReconcileLoop)
import PureClaw.Harness.Registry (HarnessRegistry)

-- | Run the activity probe loop. Delegates to the registry-based reconcile loop
-- ('runReconcileLoop'): a 2-second cadence over the durable 'HarnessRegistry',
-- publishing 'ActivityChanged' events (transitions + disappearances) to the
-- 'StreamBroker'. The registry — not the legacy harness map — is the source of
-- truth, so a harness that vanishes out-of-band now emits an event.
runActivityProbeLoop :: StreamBroker -> HarnessRegistry -> LogHandle -> IO ()
runActivityProbeLoop = runReconcileLoop
