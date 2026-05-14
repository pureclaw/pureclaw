-- |
-- Module      : Backend.SSHSpec
-- Description : WU0 red-phase scaffold for SSH backend DoDs.
--
-- Covers DoDs #3 (remote 3-turn bash), #4 (unresolvable host), #5
-- (argv flag set), and #16 (SshHost rejects leading @-@) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- See @.beads/plans/active-plan.md@ WU0 / WU9 for the scaffold contract.
module Backend.SSHSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "WU0 red-phase scaffold (SSH backends)" $ do
    -- docs/terminal-backend-abstractions.md line 52: ssh bash 3-turn
    it "DoD #3: mkSshBackendHandle bash three-turn sequence against a configured test host" $
      pendingWith
        "WU9: mkSshBackendHandle against a CI-provided test host running passphrase-less \
        \key auth; mirrors DoD #2 over ssh."

    -- docs/terminal-backend-abstractions.md line 53: unresolvable host
    it "DoD #4: mkSshBackendHandle with unresolvable host returns Left (BackendSshConnectFailed _)" $
      pendingWith
        "WU9: must not throw; structured BackendError surfaced via the Left branch."

    -- docs/terminal-backend-abstractions.md line 54: ssh argv hardening
    it "DoD #5: mkSshBackendHandle argv includes hardened flag set (no -X/-Y/-A)" $
      pendingWith
        "WU9: argv prefix includes -F /dev/null, StrictHostKeyChecking=accept-new, BatchMode=yes, \
        \IdentitiesOnly=yes, ConnectTimeout=10, ServerAliveInterval=30, ForwardX11=no, \
        \ForwardX11Trusted=no, ForwardAgent=no; no -X, no -Y, no -A."

    -- docs/terminal-backend-abstractions.md line 65: SshHost validation
    it "DoD #16: SshHost rejects leading '-' (e.g. -oProxyCommand=evil) at mkSshTarget" $
      pendingWith "WU9: mkSshHost / SshTarget construction surfaces BackendInvalidOption."
