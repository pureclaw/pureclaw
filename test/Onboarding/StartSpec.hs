-- |
-- Module      : Onboarding.StartSpec
-- Description : WU0 red-phase scaffold for onboarding DoDs (O-series).
--
-- Enumerates the O-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Onboarding (O-series)" as 'pending' tests.
-- Production wiring lands in WU11 (PureClaw.Routing.Onboarding,
-- Telegram BotFather registration, /help rendering extension).
module Onboarding.StartSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "O-series — onboarding (WU0 scaffold; WU11 fills in)" $ do
    it "O1: /start (Telegram convention) — registered as a slash command; response contains value prop, /0 shortcut for AI, /tab new 0 shell for shell users, /tabs for dashboard (all three slash-prefix mentions present)" pending
    it "O2: /help rendering includes a 'Tab commands' subsection enumerating /N, /N <payload>, /tabs, /tab new, /tab close, /tab focus, /tab resume, /tab rename — contains literal 'Tab commands' and '/tabs'" pending
    it "O3: BotFather command descriptions — registration payload (list of (command, description) tuples) matches golden file for /0–/9, /tab, /tabs, /start" pending
