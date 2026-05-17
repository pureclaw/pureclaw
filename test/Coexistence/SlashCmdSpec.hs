-- |
-- Module      : Coexistence.SlashCmdSpec
-- Description : WU0 red-phase scaffold for slash-command coexistence DoDs (K-series).
--
-- Enumerates the K-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Coexistence with existing slash commands
-- (K-series)" as 'pending' tests. Production wiring lands in WU10
-- (Agent.Loop refactor + SlashCommands focused-tab projections).
module Coexistence.SlashCmdSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "K-series — coexistence with existing slash commands (WU0 scaffold; WU10 fills in)" $ do
    it "K1: /session new with focused KindAi — creates new SessionHandle and attaches to focused tab; focused non-AI tab yields PublicError 'this tab does not own a session.'" pending
    it "K2: /tab new N ai — automatically creates a new SessionHandle for the tab (tab-creation -> session-creation direction)" pending
    it "K3: /session new with empty registry — implicitly spawns a KindAi tab at the lowest free index (default behavior)" pending
    it "K4: /target <name> while focused on KindAi — sets that tab's target via focused-tab projection; per-tab target is in-memory only (no restart persistence)" pending
    it "K5: /target <name> while focused on KindHarness or KindBackend — PublicError 'tab kind does not support /target.'" pending
    it "K6.1: /provider while focused on KindAi — updates focused tab's _ats_provider IORef via focused-tab projection; only focused tab's provider changes" pending
    it "K6.2: /model while focused on KindAi — updates focused tab's _ats_model IORef; same-tab-only assertion" pending
    it "K6.3: /vault while focused on KindAi — operates on AgentEnv-level _env_vault (process-wide, not per-tab); vault access works from any focused AI tab" pending
    it "K6.4: /transcript while focused on KindAi — renders focused tab's transcript (_sh_transcript); with two AI tabs, shows focused tab's history not the other's" pending
    it "K6.5: /agent <name> while focused on KindAi — changes focused tab's agent label (spawn factory uses it for agent-specific defaults); same-tab-only assertion" pending
    it "K6.6: /new while focused on KindAi — dispatcher calls _tabHandle_enqueueSlash focusedTab CmdNew; tab loop processes the event, clears _ats_context; /1's history intact" pending
    it "K6.7: /last while focused on KindAi — read-only; dispatcher reads _ats_context directly (best-effort point-in-time read); same-tab-only assertion" pending
    it "K6.8: /compact while focused on KindAi — dispatcher enqueues CmdCompact via _tabHandle_enqueueSlash; tab loop calls compactContext against _ats_context; same-tab-only assertion" pending
    it "K7: /session resume <id> while focused on KindAi — replaces focused tab's _tabHandle_session in place by spawning new AI tab loop with resumed session and closing old; index preserved" pending
    it "K8: /session last while focused on KindAi — shows last completion of focused tab's session; routes through the same path as K6.7 (/last)" pending
