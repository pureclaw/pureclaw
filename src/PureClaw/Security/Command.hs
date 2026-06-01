module PureClaw.Security.Command
  ( -- * Authorized command type (constructor intentionally NOT exported)
    AuthorizedCommand
    -- * Command errors
  , CommandError (..)
    -- * Authorization (pure — no IO)
  , authorize
  , authorizeShell
    -- * Manager-owned tmux seam (always permitted; see note below)
  , authorizeTmuxCommand
    -- * Read-only accessors
  , getCommandProgram
  , getCommandArgs
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath

import PureClaw.Core.Types
import PureClaw.Security.Policy

-- | A command that has been authorized by the security policy.
-- Constructor is intentionally NOT exported — the only way to obtain an
-- 'AuthorizedCommand' is through 'authorize'.
--
-- Note for downstream: 'ShellHandle.execute' is responsible for stripping
-- the subprocess environment (@setEnv (Just [])@) — environment isolation
-- is an execution-time concern, not a policy concern.
newtype AuthorizedCommand = AuthorizedCommand { unAuthorizedCommand :: (FilePath, [Text]) }

-- | Errors from command authorization.
data CommandError
  = CommandNotAllowed Text    -- ^ The command is not in the policy's allowed set
  | CommandInAutonomyDeny     -- ^ The policy's autonomy level is 'Deny'
  deriving stock (Show, Eq)

-- | Authorize a command against a security policy. Pure — no IO.
--
-- Checks:
-- 1. Autonomy level is not 'Deny'
-- 2. Command basename is in the policy's allowed command set
authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError AuthorizedCommand
authorize policy cmd args
  | _sp_autonomy policy == Deny =
      Left CommandInAutonomyDeny
  | not (isCommandAllowed policy (CommandName (T.pack (takeFileName cmd)))) =
      Left (CommandNotAllowed (T.pack (takeFileName cmd)))
  | otherwise =
      Right (AuthorizedCommand (cmd, args))

-- | Authorize a shell-string command for execution via @bash -c@. Pure — no IO.
--
-- Gating is intentionally a single yes/no toggle: the policy must list
-- @shell@ in its allowed-command set. Per-basename allowlisting is
-- meaningless once bash is in the loop (pipes, @&&@, @$()@ can all
-- compose forbidden basenames), so we don't pretend to enforce it here.
-- Deployments that want fine-grained per-program control should disable
-- @shell@ in the policy and use the argv-style @exec@ tool instead.
authorizeShell :: SecurityPolicy -> Text -> Either CommandError AuthorizedCommand
authorizeShell policy cmd
  | _sp_autonomy policy == Deny =
      Left CommandInAutonomyDeny
  | not (isCommandAllowed policy (CommandName "shell")) =
      Left (CommandNotAllowed "shell")
  | otherwise =
      Right (AuthorizedCommand ("bash", ["-c", cmd]))

-- | Construct an 'AuthorizedCommand' for PureClaw's OWN tmux process
-- management. This is the controlled internal seam through which EVERY tmux
-- subprocess invocation flows, so that an unauthorized tmux call is impossible
-- by construction (the 'AuthorizedCommand' value constructor is not exported,
-- and this is the sole tmux-specific path to obtain one).
--
-- Unlike 'authorize'/'authorizeShell', this performs NO 'SecurityPolicy'
-- check and ALWAYS succeeds: tmux invocations here are PureClaw's own
-- harness-lifecycle management (spawn/sweep/capture/kill of windows it owns),
-- NOT user-issued commands. The user-command policy gate governs commands the
-- agent is asked to run on the user's behalf; the manager's internal tmux use
-- is a separate, manager-owned boundary. The in-pane harness command itself
-- (a deliberately shell-interpreted string) is defended separately by
-- 'PureClaw.Internal.ShellQuote' / @escapeForShell@, not by this seam.
--
-- TODO(harness-registry phase 2): audit-log tmux seam invocations once a
-- 'LogHandle' is threaded to the call sites. The design (§8 B1) specifies this
-- seam as "always-permitted-but-logged"; threading a logger through
-- @Harness/Tmux.hs@ would change exported signatures (out of scope for the
-- additive Phase-1 refactor), so logging is deferred. The hard, type-enforced
-- invariant — a single tmux chokepoint — is delivered now.
authorizeTmuxCommand :: FilePath -> [Text] -> AuthorizedCommand
authorizeTmuxCommand tmuxBin args = AuthorizedCommand (tmuxBin, args)

-- | Get the program path from an authorized command.
getCommandProgram :: AuthorizedCommand -> FilePath
getCommandProgram = fst . unAuthorizedCommand

-- | Get the arguments from an authorized command.
getCommandArgs :: AuthorizedCommand -> [Text]
getCommandArgs = snd . unAuthorizedCommand
