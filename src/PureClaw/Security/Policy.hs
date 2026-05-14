module PureClaw.Security.Policy
  ( -- * Policy type
    SecurityPolicy (..)
    -- * Constructors and combinators
  , defaultPolicy
  , allowCommand
  , denyCommand
  , allowRemoteCommand
  , denyRemoteCommand
  , withAutonomy
    -- * Pure evaluation
  , isCommandAllowed
  , isRemoteCommandAllowed
  ) where

import Data.Set qualified as Set

import PureClaw.Core.Types

-- | Security policy governing what an agent can do.
-- Policy evaluation is pure — no IO, fully testable with QuickCheck.
--
-- Local subprocess authorization consults '_sp_allowedCommands'.
-- Remote subprocess authorization (e.g. ssh-dispatched commands)
-- consults '_sp_allowedRemoteCommands'; the two allowlists are
-- independent so granting "git" locally does not silently grant
-- "git" remotely.
--
-- __Construction-site enforcement:__ adding a new field to
-- 'SecurityPolicy' is intentionally a breaking change. With
-- @-Werror -Wall@ (which implies @-Wmissing-fields@) any brace-form
-- construction site that forgets the new field fails to compile.
-- Positional construction sites (e.g. @SecurityPolicy AllowAll Full _@)
-- fail to compile because the arity changes. This is the type-level
-- migration safety net referenced in 'docs\/SECURITY_PRACTICES.md' §5.2
-- and 'docs\/terminal-backend-abstractions.md' § \"SecurityPolicy
-- field migration\".
data SecurityPolicy = SecurityPolicy
  { _sp_allowedCommands       :: AllowList CommandName
  , _sp_autonomy              :: AutonomyLevel
  , _sp_allowedRemoteCommands :: AllowList CommandName
  }
  deriving stock (Show, Eq)

-- | Default policy: deny everything (local and remote). Start here and
-- open up explicitly.
defaultPolicy :: SecurityPolicy
defaultPolicy = SecurityPolicy
  { _sp_allowedCommands       = AllowList Set.empty
  , _sp_autonomy              = Deny
  , _sp_allowedRemoteCommands = AllowList Set.empty
  }

-- | Add a command to the local allowed set.
-- If the policy already uses 'AllowAll', this is a no-op.
allowCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
allowCommand cmd policy =
  case _sp_allowedCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { _sp_allowedCommands = AllowList (Set.insert cmd s) }

-- | Remove a command from the local allowed set.
-- If the policy uses 'AllowAll', this has no effect (you cannot deny
-- individual commands from an AllowAll policy — switch to explicit list first).
denyCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
denyCommand cmd policy =
  case _sp_allowedCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { _sp_allowedCommands = AllowList (Set.delete cmd s) }

-- | Add a command to the remote allowed set.
-- If the policy already uses 'AllowAll' for remote commands, this is a no-op.
allowRemoteCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
allowRemoteCommand cmd policy =
  case _sp_allowedRemoteCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { _sp_allowedRemoteCommands = AllowList (Set.insert cmd s) }

-- | Remove a command from the remote allowed set.
-- If the policy uses 'AllowAll' for remote commands, this has no effect
-- (switch to an explicit list first).
denyRemoteCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
denyRemoteCommand cmd policy =
  case _sp_allowedRemoteCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { _sp_allowedRemoteCommands = AllowList (Set.delete cmd s) }

-- | Set the autonomy level on a policy.
withAutonomy :: AutonomyLevel -> SecurityPolicy -> SecurityPolicy
withAutonomy level policy = policy { _sp_autonomy = level }

-- | Check whether a command is allowed for local execution by this policy. Pure.
isCommandAllowed :: SecurityPolicy -> CommandName -> Bool
isCommandAllowed policy = isAllowed (_sp_allowedCommands policy)

-- | Check whether a command is allowed for remote execution by this policy. Pure.
isRemoteCommandAllowed :: SecurityPolicy -> CommandName -> Bool
isRemoteCommandAllowed policy = isAllowed (_sp_allowedRemoteCommands policy)
