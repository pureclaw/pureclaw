module PureClaw.Security.Command
  ( -- * Authorized command type (constructor intentionally NOT exported)
    AuthorizedCommand
    -- * Command errors
  , CommandError (..)
    -- * Authorization (pure — no IO)
  , authorize
  , authorizeShell
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

-- | Get the program path from an authorized command.
getCommandProgram :: AuthorizedCommand -> FilePath
getCommandProgram = fst . unAuthorizedCommand

-- | Get the arguments from an authorized command.
getCommandArgs :: AuthorizedCommand -> [Text]
getCommandArgs = snd . unAuthorizedCommand
