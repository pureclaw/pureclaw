-- |
-- Module      : Handles.TabSpec
-- Description : WU0 red-phase scaffold for TabHandle DoDs (H-series).
--
-- Enumerates the H-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"TabHandle abstraction (H-series)" as 'pending'
-- tests. The production module @PureClaw.Handles.Tab@ lands in WU1, the
-- factories (KindAi/KindHarness/KindBackend) in WU6/WU7/WU8.
--
-- DoD identifiers (H1..H14) appear in each test's description so
-- subsequent WUs can grep for them.
module Handles.TabSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "H-series — TabHandle abstraction (WU0 scaffold; WU1+ fill in)" $ do
    it "H1: TabHandle is a record of IO actions with _tabHandle_* field prefix" pending
    it "H2: factories mkTabAi, mkTabHarness, mkTabBackend exist with IO (Either TabError TabHandle) return type" pending
    it "H3: TabError enumerates exactly TabIndexInUse, TabIndexOutOfRange, TabLimitExceeded, TabBackendConstructFailed, TabSessionCreateFailed, TabSpawnAuthDenied, TabNotFound, TabConcurrencyLimit, TabInvalidName, TabUnsupportedCommand" pending
    it "H4: _tabHandle_send is non-blocking (TBQueue bounded by _rc_inputQueueBound); overflow surfaces 'tab input queue full' PublicError" pending
    it "H5: _tabHandle_status returns Active | Idle UTCTime | Crashed PublicTabError" pending
    it "H6: _tabHandle_close is idempotent" pending
    it "H7: _tabHandle_close never throws (mirrors _bh_close contract)" pending
    it "H8: _tabHandle_close is kind-specific — KindAi archives via _sh_save, KindHarness/KindBackend destroy via _hh_stop/_bh_close" pending
    it "H9: _tabHandle_close --force on KindAi skips archive; on other kinds is a no-op" pending
    it "H10: _tabHandle_close cancels in-flight provider/recv via throwTo AsyncCancelled inside bracket" pending
    it "H11: _tabHandle_name is constructed via sanitizeTabName (length cap, control-byte reject, ANSI reject, hostname/path/ssh-stderr redaction) — property test covers every construction path" pending
    it "H12: _tabHandle_kind is a pure field (no IO read)" pending
    it "H13: _tabHandle_enqueueSlash on KindAi enqueues SlashCmd InputEvent; on non-AI returns Left TabUnsupportedCommand" pending
    it "H14: Show TabError is manual (NOT derived) — argument values elided, constructor names only; redaction projection toPublicTabError exists" pending
