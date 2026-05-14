-- |
-- Module      : Backend.PtySpec
-- Description : WU0 red-phase scaffold for PTY-internal DoDs.
--
-- Covers DoDs in @docs/terminal-backend-abstractions.md@ that concern
-- Pty-kind backends specifically — truncation-latch semantics and the
-- idle state machine's @RecvTimedOut ""@ no-bytes path.
--
-- See @.beads/plans/active-plan.md@ WU0 / WU7 for the scaffold contract.
module Backend.PtySpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (Pty-internal DoDs)" $ do
    -- docs/terminal-backend-abstractions.md line 62: RecvTruncated latches
    it "DoD #13: oversized read past _pto_recvBufferCap latches RecvTruncated until _bh_close" $
      pendingWith
        "WU7: drainer + STM latch (_ds_truncated :: TVar Bool). Property test against \
        \fakePtyIO + testIdleSpec."

    -- docs/terminal-backend-abstractions.md line 69: idle timeout no bytes
    it "DoD #22: Pty _bh_recv returns RecvTimedOut \"\" when idleTimeoutMs expires with no bytes" $
      pendingWith
        "WU7: idle state-machine waiting-for-first-byte branch; property-tested with \
        \fakePtyIO + FakeClock advancing past idleTimeoutMs."
