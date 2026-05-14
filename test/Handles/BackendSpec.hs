-- |
-- Module      : Handles.BackendSpec
-- Description : WU0 red-phase scaffold for BackendHandle DoDs.
--
-- This module enumerates the cross-backend Definition-of-Done items from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1) as
-- pending Hspec tests. Each test is annotated with the DoD number from the
-- design doc; the body is @pendingWith@ so the suite compiles without any
-- production code from @PureClaw.Handles.Backend@ existing yet.
--
-- See @.beads/plans/active-plan.md@ WU0 for the scaffold contract.
module Handles.BackendSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (cross-backend DoDs)" $ do
    -- docs/terminal-backend-abstractions.md line 61: idempotent close
    it "DoD #12: _bh_close is idempotent and never throws on any backend" $
      pendingWith "WU3: implemented when mkNoOpBackendHandle + mkInMemoryBackendHandle land."

    -- docs/terminal-backend-abstractions.md line 63: no-op backend shapes
    it "DoD #14: mkNoOpBackendHandle Pty returns RecvSettled \"\" on _bh_recv Nothing" $
      pendingWith "WU3: mkNoOpBackendHandle Pty / Pipe recv shape."

    -- docs/terminal-backend-abstractions.md line 63: no-op resize silent
    it "DoD #14: mkNoOpBackendHandle Pipe likewise yields RecvSettled \"\"" $
      pendingWith "WU3: mkNoOpBackendHandle Pipe recv shape."

    -- docs/terminal-backend-abstractions.md line 64: in-memory round-trip
    it "DoD #15: mkInMemoryBackendHandle round-trips bytes deterministically" $
      pendingWith "WU3: mkInMemoryBackendHandle deterministic round-trip + fake-clock idle property."

    -- docs/terminal-backend-abstractions.md line 66: show redaction
    it "DoD #17: Show BackendException / BackendError / SshConnectFailure redacts hostnames + paths" $
      pendingWith "WU2: redactErr + hand-written Show instances in PureClaw.Internal.Redact."

    -- docs/terminal-backend-abstractions.md line 73: haddock decision tree
    it "DoD #20: module-level haddock documents Pipe/Pty/decision tree (doctest)" $
      pendingWith "WU1: haddock decision tree in PureClaw.Handles.Backend; doctest asserts presence."

    -- docs/terminal-backend-abstractions.md line 70: process-wide buffer quota
    it "DoD #23: oversubscribed process-wide recv-buffer cap returns Left (BackendBufferQuotaExceeded n)" $
      pendingWith "WU7: QSem-based process-wide quota in PureClaw.Handles.Backend."

    -- docs/terminal-backend-abstractions.md line 71: no-op resize is a silent no-op
    it "DoD #24: mkNoOpBackendHandle Pipe and Pty _bh_resize is a silent no-op" $
      pendingWith "WU3: silent no-op resize on both kinds; observable via test."

  describe "WU0 orchestrator-only gates (documented; not run here)" $ do
    -- docs/terminal-backend-abstractions.md line 67: SecurityPolicy construction sites
    it "DoD #18: every SecurityPolicy construction site sets _sp_allowedRemoteCommands" $
      pendingWith
        "WU6 / CI-gated: enforced by -Werror -Wmissing-fields and -Wincomplete-record-updates \
        \across src/, test/, app/. Not a runtime test."

    -- docs/terminal-backend-abstractions.md line 72: coverage thresholds
    it "DoD #19: coverage on new modules meets .coverage-thresholds.json" $
      pendingWith
        "WU11 / orchestrator-enforced: gated by .coverage-thresholds.json \
        \(100% lines/branches/functions/statements on new modules). Not a runtime test."
