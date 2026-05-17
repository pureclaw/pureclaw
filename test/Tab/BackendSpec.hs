-- |
-- Module      : Tab.BackendSpec
-- Description : WU0 red-phase scaffold for backend-tab DoDs (L/I subsets).
--
-- Enumerates backend-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the KindShell/KindSsh/KindTmux subsets of
-- L-series and I-series. Production code lands in WU8 (factories) and
-- WU9 (close handler).
--
-- DoD identifiers appear in each test's description. Note: the security
-- DoDs S1–S4 that govern backend spawn authorization also produce tests
-- here once the factories land; they are scaffolded in
-- @Security.TabSpec@ at WU0 so the S-series remains contiguous.
module Tab.BackendSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "L-series (Backend subset) — close lifecycle (WU0 scaffold; WU8/WU9 fill in)" $ do
    it "L3: /tab close 3 on KindBackend (Shell/Ssh/Tmux) — destructive: _bh_close runs, registry entry removed, transcript NOT archived" pending

  describe "I-series (Backend subset) — direct-inject opaque-text passthrough (WU0 scaffold; WU8 fills in)" $ do
    it "I4: non-AI tab (Backend) treats slash-prefix on direct-inject as opaque text — /0 /pwd written via _bh_send as literal '/pwd'; no slash-command parser in non-AI tabs" pending
