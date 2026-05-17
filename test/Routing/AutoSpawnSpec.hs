-- |
-- Module      : Routing.AutoSpawnSpec
-- Description : WU0 red-phase scaffold for auto-spawn behavior DoDs (A-series).
--
-- Enumerates the A-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Auto-spawn behavior (A-series)" as 'pending'
-- tests. The production module @PureClaw.Routing.AutoSpawn@ lands in
-- WU9; channel-specific prompt rendering also lands in WU9.
module Routing.AutoSpawnSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "A-series — auto-spawn behavior (WU0 scaffold; WU9 fills in)" $ do
    it "A1: /3 when N exists — switch focus, emit recap of last _rc_switchRecap messages from N's transcript" pending
    it "A2: /3 payload when N exists — enqueue payload to N's input, focus unchanged, channel sees no immediate output" pending
    it "A3: /3 when N missing, default set — spawn with default kind, focus, one-line confirmation" pending
    it "A4: /3 when N missing, default unset — dispatcher returns NeedsKindPrompt 3 Nothing; renders prompt UI via channel-specific renderer" pending
    it "A5: /3 payload when N missing, default set — spawn with default, focus, enqueue payload, single-message confirmation" pending
    it "A6: /3 payload when N missing, default unset — dispatcher returns NeedsKindPrompt 3 (Just \"payload\"); payload buffered, enqueued after user picks kind" pending
    it "A7: /tab new 3 (no kind) when N missing — force-prompt; ignores _rc_defaultKind" pending
    it "A8: /tab new 3 (no kind) when N exists — error '/3 already exists. Use /tab close 3 to replace.'" pending
    it "A9: /tab new 3 shell when N missing — spawn with KindShell, focus" pending
    it "A10: /tab new 3 shell when N exists — error as A8" pending
    it "A11: /tab new 11 when _rc_maxTabs = 10 — Left TabLimitExceeded 10 as PublicError; no process spawned" pending
    it "A12: after /tab close 3, index 3 is immediately reusable; next /tab new <kind> (no explicit index) allocates the lowest free index" pending

  describe "B-series — dashboard (WU0 scaffold; WU9 fills in)" $ do
    it "B1: /tabs (or /tab list) with empty registry emits 'No tabs open. Use /N or /tab new N <kind> to create one.'" pending
    it "B2: /tabs with N tabs emits one line per tab (index, kind, redacted name, status, asterisk for focused) — golden-file match for 3 tabs" pending
    it "B3: /tabs rendering for >= 8 tabs uses bullets (no fixed-width table) so it wraps cleanly on small mobile screens" pending
