-- |
-- Module      : Routing.ParseSpec
-- Description : WU0 red-phase scaffold for parser DoDs (P-series).
--
-- Enumerates the P-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Parser & LLM-free invariant (P-series)" as
-- 'pending' tests. The production module @PureClaw.Routing.Parse@ does
-- not exist yet — WU2 lands the parser and flips these tests green.
--
-- DoD identifiers (P1..P18, P15a) appear in each test's description so
-- WU2 can grep for them when implementing.
module Routing.ParseSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "P-series — parser & LLM-free invariant (WU0 scaffold; WU2 fills in)" $ do
    it "P1: parseInput \"/0\" yields Switch (TabIndex 0)" pending
    it "P2: parseInput \"/12\" yields Switch (TabIndex 12) (greedy digits)" pending
    it "P3: parseInput \"/0 run tests\" yields Inject (TabIndex 0) \"run tests\"" pending
    it "P4: parseInput \"/0 0 run\" yields Inject (TabIndex 0) \"0 run\" (payload digits preserved)" pending
    it "P5: parseInput \"hello world\" yields Default \"hello world\"" pending
    it "P6: parseInput \"/01\" yields Left ParseErrorLeadingZero" pending
    it "P7: parseInput (rc{_rc_maxTabs=10}) \"/9999\" yields Left ParseErrorIndexOutOfRange" pending
    it "P8: parseInput \"/tabs\" yields SlashCmd CmdTabList" pending
    it "P9: parseInput \"/tab list\" yields SlashCmd CmdTabList (alias of /tabs)" pending
    it "P10: parseInput \"/tab new 3\" yields SlashCmd (CmdTabNew (TabIndex 3) Nothing Nothing)" pending
    it "P11: parseInput \"/tab new 3 shell\" yields SlashCmd (CmdTabNew (TabIndex 3) (Just KindShell) Nothing)" pending
    it "P12: parseInput \"/tab close 3\" yields SlashCmd (CmdTabClose (TabIndex 3) ForceNo)" pending
    it "P13: parseInput \"/tab close 3 --force\" yields SlashCmd (CmdTabClose (TabIndex 3) ForceYes)" pending
    it "P14: parseInput \"/tab focus 3\" yields SlashCmd (CmdTabFocus (TabIndex 3))" pending
    it "P15: parseInput \"/tab resume <session-id>\" yields SlashCmd (CmdTabResume id) for valid id" pending
    it "P15a: parseInput \"/tab resume ../etc/passwd\" yields Left ParseErrorInvalidSessionId (corpus: /, \\, .., NUL, non-[a-zA-Z0-9_-])" pending
    it "P16: parseInput \"/tab rename 3 my-shell\" yields SlashCmd (CmdTabRename (TabIndex 3) \"my-shell\")" pending
    it "P17: no-regression — each existing slash command (/help, /status, /session, /target, /provider, /model, /vault, /harness, /mcp, /channel, /transcript, /agent, /new, /last) routes unchanged" pending
    it "P18: LLM-free invariant — property test: switch | inject | slash-cmd inputs never invoke Provider.complete (uses T1 fake provider)" pending
