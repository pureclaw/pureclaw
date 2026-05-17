-- |
-- Module      : Routing.ChannelOutSpec
-- Description : WU0 red-phase scaffold for channel emission DoDs (D-series).
--
-- Enumerates the D-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Channel emission & focused-only display
-- (D-series)" as 'pending' tests. The production module
-- @PureClaw.Routing.ChannelOut@ lands in WU4; backend FullMsg drainer
-- paths land in WU7/WU8.
module Routing.ChannelOutSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "D-series — channel emission & focused-only display (WU0 scaffold; WU4 fills in)" $ do
    it "D1: only focused tab writes to channel — /0 + /1 producing output with _env_focus = Just 0, fake ChannelHandle sees only /0" pending
    it "D2: non-focused tab output still lands in its transcript — /1's _sh_transcript contains complete response even though channel saw none" pending
    it "D3: channel writes are serialized — single writer thread consumes bounded TBQueue (_env_channelOutQ, capacity _rc_channelOutQBound); writer is authoritative focus gate, SrcDispatcher events always emit" pending
    it "D4: producer-side focus pre-check is optimization — non-focused tab streaming 10k chunks keeps _env_channelOutQ length under small bound (writer-side gate per D3 is authoritative)" pending
    it "D5: mid-stream switch breadcrumb (AI only) — focus moves mid-StreamStart/ChunkOf/StreamEnd; exactly one SrcDispatcher BannerLine '/N has new output' emitted per StreamId; non-AI FullMsg drops emit zero breadcrumbs" pending
    it "D6: no other proactive non-focus notifications — non-focused tab crash/finish emits zero channel messages beyond in-flight breadcrumb" pending
