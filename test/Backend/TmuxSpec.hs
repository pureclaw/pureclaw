-- |
-- Module      : Backend.TmuxSpec
-- Description : WU0 red-phase scaffold for Tmux backend DoDs.
--
-- Covers DoDs #6 (local attach + close survives), #7 (remote attach + close
-- survives), #8 (missing window), #9 (invalid session), #10 (RemoteHost
-- two-auth + ssh fail surfaces correctly), #11 (program + arg quoting),
-- and #21 (mid-session destruction → BackendBrokenTmuxTarget) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- See @.beads/plans/active-plan.md@ WU0 / WU10 for the scaffold contract.
module Backend.TmuxSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (Tmux backends)" $ do
    -- docs/terminal-backend-abstractions.md line 55: local attach + close survives
    it "DoD #6: local mkTmuxBackendHandle attach/send/recv/close leaves target window present" $
      pendingWith
        "WU10: LocalHost mkTmuxBackendHandle; _bh_close detaches via TmuxDetach only; \
        \target window verified present after close."

    -- docs/terminal-backend-abstractions.md line 56: remote attach + close survives
    it "DoD #7: remote mkTmuxBackendHandle (RemoteHost) attach + close leaves window present" $
      pendingWith
        "WU10: RemoteHost path through ssh; window survival verified via a second \
        \short-lived ssh + tmux list-windows from the test harness."

    -- docs/terminal-backend-abstractions.md line 57: missing window
    it "DoD #8: mkTmuxBackendHandle against a non-existent window returns Left (BackendTmuxTargetMissing _)" $
      pendingWith
        "WU10: factory does NOT auto-create the window; structured Left branch returned."

    -- docs/terminal-backend-abstractions.md line 58: invalid session at construction
    it "DoD #9: mkTmuxBackendHandle rejects unsafe TmuxSession (whitespace/metachars/leading-dash/NUL)" $
      pendingWith
        "WU10: mkTmuxSession smart constructor; BackendInvalidOption returned; no subprocess spawned."

    -- docs/terminal-backend-abstractions.md line 59: remote two-auth + ssh fail
    it "DoD #10: RemoteHost requires outer AuthorizedCommand + inner RemoteCommand; ssh fail surfaces BackendSshConnectFailed" $
      pendingWith
        "WU10: SshLocation type-enforces auth split; ssh-hop failure must surface as \
        \BackendSshConnectFailed (not BackendTmuxTargetMissing)."

    -- docs/terminal-backend-abstractions.md line 60: program + arg quoting
    it "DoD #11: remote argv shell-quotes both program path (with space) and each arg" $
      pendingWith
        "WU10: shellQuote applied to program path and args; '/opt/my tools/tmux' round-trips."

    -- docs/terminal-backend-abstractions.md line 68: mid-session destruction
    it "DoD #21: mid-session destruction of pinned @window_id fails closed with BackendBrokenTmuxTarget" $
      pendingWith
        "WU10: fakePtyIO simulation; subsequent _bh_send/_bh_recv/_bh_close fails closed \
        \with BackendException carrying BackendBrokenTmuxTarget — does NOT silently write \
        \to the new (potentially different-owner) window."
