-- |
-- Module      : Internal.ShellQuoteSpec
-- Description : WU0 placeholder for ShellQuote tests added in WU4.
--
-- The canonical shell-quoter ('PureClaw.Internal.ShellQuote.shellQuote')
-- lands in WU4 with property tests that round-trip adversarial inputs
-- through @bash -c@. This module is a placeholder so the test-suite
-- structure mirrors the eventual module layout from day 1.
--
-- See @.beads/plans/active-plan.md@ WU0 / WU4.
module Internal.ShellQuoteSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (Internal.ShellQuote placeholder)" $ do
    it "WU4: shellQuote round-trips through bash -c for adversarial inputs" $
      pendingWith
        "WU4: property test in PureClaw.Internal.ShellQuote — single-quote wrapping with \
        \embedded-quote escaping; metacharacters never interpreted."
