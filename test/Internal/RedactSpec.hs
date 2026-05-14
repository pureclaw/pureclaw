-- |
-- Module      : Internal.RedactSpec
-- Description : WU0 red-phase scaffold for redaction property tests.
--
-- Covers DoD #17 from @docs/terminal-backend-abstractions.md@ § Acceptance
-- Criteria (v1) — @Show BackendError@ / @Show BackendException@ /
-- @Show SshConnectFailure@ never reveal raw hostnames, paths, or ssh stderr.
-- Property-tested in WU2 once 'PureClaw.Internal.Redact' lands.
--
-- See @.beads/plans/active-plan.md@ WU0 / WU2.
module Internal.RedactSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (Internal.Redact)" $ do
    -- docs/terminal-backend-abstractions.md line 66: redaction
    it "DoD #17: redactErr strips hostnames, IPs, workspace/keys/runtime paths, ssh stderr fragments" $
      pendingWith
        "WU2: QuickCheck property — fuzz BackendException with embedded hostname + key-path \
        \basename; assert neither substring appears in the rendered Show output."

    it "DoD #17: Show BackendError routes through redactBackendError" $
      pendingWith "WU2: hand-written Show BackendError; round-trips via redactBackendError."

    it "DoD #17: Show BackendException routes through redactBackendException" $
      pendingWith "WU2: hand-written Show BackendException; round-trips via redactBackendException."
