-- |
-- Module      : Routing.RegistrySpec
-- Description : WU0 red-phase scaffold for Registry + AgentEnv DoDs (E-series).
--
-- Enumerates the E-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Registry & AgentEnv (E-series)" as 'pending'
-- tests. The production modules @PureClaw.Routing.Registry@ and the
-- AgentEnv additions land in WU3.
module Routing.RegistrySpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "E-series — registry + AgentEnv (WU0 scaffold; WU3 fills in)" $ do
    it "E1: AgentEnv gains _env_tabs, _env_focus, _env_routingConfig, _env_channelOutQ (bounded TBQueue capacity _rc_channelOutQBound=1024)" pending
    it "E2: existing _env_target/_env_session/_env_provider/_env_model remain as focused-tab projections (read only inside dispatcher's message-processing window)" pending
    it "E3: focus invariant — _env_focus is written only by dispatcher between message cycles (concurrent-emitter test asserts end-of-cycle consistency)" pending
    it "E4: _env_fork :: IO () -> IO TabRunner is part of AgentEnv (test seam; default wraps Control.Concurrent.Async.async)" pending
    it "E5: per-tab Context mutations go through tab loop's input queue (single-writer model); dispatcher enqueues SlashCmd InputEvent, never writes _ats_context directly" pending
