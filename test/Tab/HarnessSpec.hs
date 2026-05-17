-- |
-- Module      : Tab.HarnessSpec
-- Description : WU0 red-phase scaffold for harness-tab DoDs (L/I subsets).
--
-- Enumerates harness-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the KindHarness subsets of L-series and
-- I-series. Production code lands in WU7 (factory) and WU9 (close
-- handler).
--
-- DoD identifiers appear in each test's description.
module Tab.HarnessSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "L-series (Harness subset) — close lifecycle (WU0 scaffold; WU7/WU9 fill in)" $ do
    it "L2: /tab close 3 on KindHarness — destructive: _hh_stop runs, registry entry removed, transcript NOT archived" pending

  describe "I-series (Harness subset) — direct-inject opaque-text passthrough (WU0 scaffold; WU7 fills in)" $ do
    it "I4: non-AI tab (Harness) treats slash-prefix on direct-inject as opaque text — /0 /pwd sent to harness as literal '/pwd'; no slash-command parser in non-AI tabs" pending
