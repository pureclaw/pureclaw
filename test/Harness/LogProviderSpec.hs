-- | Tests for "PureClaw.Harness.LogProvider" — the turn-content provider seam
-- (Task 4). The tmux provider must preserve today's behavior verbatim; the null
-- provider is the handle-less fallback.
module Harness.LogProviderSpec (spec) where

import Test.Hspec

import PureClaw.Handles.Harness (mkNoOpHarnessHandle, _hh_snapshotTurn)
import PureClaw.Harness.LogProvider

spec :: Spec
spec = do
  describe "tmuxProvider" $ do
    it "preserves _hh_snapshotTurn text and never finalizes/derives id" $ do
      let hh = mkNoOpHarnessHandle { _hh_snapshotTurn = pure "snapshot" }
          p  = tmuxProvider hh
      (txt, fin) <- _tp_snapshot p
      mid <- _tp_turnId p
      (txt, fin, mid) `shouldBe` ("snapshot", False, Nothing)

  describe "nullProvider" $ do
    it "yields empty text, never finalizes, derives no id" $ do
      (txt, fin) <- _tp_snapshot nullProvider
      mid <- _tp_turnId nullProvider
      (txt, fin, mid) `shouldBe` ("", False, Nothing)
