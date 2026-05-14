-- |
-- Module      : Backend.LocalSpec
-- Description : WU0 red-phase scaffold for local backend DoDs.
--
-- Covers DoDs #1 (local pipe one-shot @echo hi@) and #2 (local PTY bash
-- three-turn @cd /tmp; pwd@) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- See @.beads/plans/active-plan.md@ WU0 / WU8 for the scaffold contract.
module Backend.LocalSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (local backends)" $ do
    -- docs/terminal-backend-abstractions.md line 50: local echo hi
    it "DoD #1: runBackend on mkLocalBackendHandle (echo hi) returns RecvSettled \"hi\\n\"" $
      pendingWith "WU8: mkLocalBackendHandle pipe-kind one-shot against authorized echo."

    -- docs/terminal-backend-abstractions.md line 51: local bash 3-turn
    it "DoD #2: mkLocalPtyBackendHandle bash survives 'cd /tmp; pwd' across three turns" $
      pendingWith
        "WU8: mkLocalPtyBackendHandle conversational PTY; turns 1-3 issue 'cd /tmp', \
        \then 'pwd', then read new cwd."
