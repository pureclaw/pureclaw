module PureClaw.Security.Command
  ( -- * Authorized command type (constructor intentionally NOT exported)
    AuthorizedCommand
    -- * Command errors
  , CommandError (..)
    -- * Authorization (pure — no IO)
  , authorize
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

-- | Get the program path from an authorized command.
getCommandProgram :: AuthorizedCommand -> FilePath
getCommandProgram = fst . unAuthorizedCommand

-- | Get the arguments from an authorized command.
getCommandArgs :: AuthorizedCommand -> [Text]
getCommandArgs = snd . unAuthorizedCommand
