-- |
-- Module      : Tab.AiSpec
-- Description : WU0 red-phase scaffold for AI-tab DoDs (L/X/I subsets).
--
-- Enumerates AI-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the AI-kind subset of L-series (close
-- lifecycle), X-series (crashed UX), and the I-series (direct-inject /
-- in-tab-loop slash-command re-parse). Production code lands in WU6
-- (factory + loop) and WU9 (close handler, crashed UX).
--
-- DoD identifiers appear in each test's description.
module Tab.AiSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "L-series (AI subset) — close lifecycle (WU0 scaffold; WU9 fills in)" $ do
    it "L1: /tab close 3 on KindAi — archives session via _sh_save, registry entry removed, index freed, _tabHandle_close runs" pending
    it "L4: /tab close 3 --force on KindAi — skips archive (transcript deleted from disk), registry entry removed" pending
    it "L5: /tab close 99 (non-existent index) — Left TabNotFound 99 as PublicError; no side effects (no _sh_save, no _hh_stop, no _bh_close, no registry mutation)" pending
    it "L6: /tab close of focused tab — new focus is highest-indexed remaining, or Nothing if empty; next Default text input on empty registry implicitly spawns _rc_defaultKind at index 0" pending
    it "L7: /tab resume <session-id> — validates via mkSessionId, routes through Session.resolveSessionRef; /tab resume ../../etc/passwd yields ParseErrorInvalidSessionId; archived id creates new tab at lowest free index" pending

  describe "X-series — crashed tab UX (WU0 scaffold; WU9 fills in)" $ do
    it "X1: /3 on a Crashed tab — dispatcher emits one-line PublicError summary plus [1] retry [2] close prompt; source tag SrcDispatcher; message uses toPublicTabError (no raw TabError Show)" pending
    it "X2: retry on KindAi — re-runs spawn factory with original args; session/transcript preserved (continuation, not new)" pending
    it "X3: retry on KindHarness/KindBackend — re-runs spawn factory with original args; status returns to Active; previous process gone (no continuation)" pending

  describe "I-series — direct-inject + in-tab-loop slash-command re-parse (WU0 scaffold; WU6 fills in)" $ do
    it "I1: direct-inject payload — /N <payload> enqueues UserText payload to tab N's input queue via _tabHandle_send; dispatcher does NOT re-classify" pending
    it "I2: AI tab loop processes both event types — UserText starting with '/' is re-parsed via parseSlashCommand and treated as SlashCmd; otherwise fed to provider" pending
    it "I3: LLM-free invariant under direct-inject — '/0 /new' routed through AI tab loop's re-parse path NEVER invokes Provider.complete (uses T1 fake provider)" pending
    it "I5: dispatcher routes E5 commands via _tabHandle_enqueueSlash — focused-AI tab's input queue receives SlashCmd CmdNew; dispatcher returns immediately (no blocking wait); focused-non-AI yields PublicError with no enqueue" pending
