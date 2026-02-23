module PureClaw.Security.Policy
  ( -- * Policy type
    SecurityPolicy (..)
    -- * Constructors and combinators
  , defaultPolicy
  , allowCommand
  , denyCommand
  , withAutonomy
    -- * Pure evaluation
  , isCommandAllowed
  ) where

import Data.Set qualified as Set

import PureClaw.Core.Types
  ( AllowList (..)
  , AutonomyLevel (..)
  , CommandName (..)
  , isAllowed
  )

-- | Security policy governing what an agent can do.
-- Policy evaluation is pure — no IO, fully testable with QuickCheck.
data SecurityPolicy = SecurityPolicy
  { policyAllowedCommands :: AllowList CommandName
  , policyAutonomy        :: AutonomyLevel
  }
  deriving stock (Show, Eq)

-- | Default policy: deny everything. Start here and open up explicitly.
defaultPolicy :: SecurityPolicy
defaultPolicy = SecurityPolicy
  { policyAllowedCommands = AllowList Set.empty
  , policyAutonomy        = Deny
  }

-- | Add a command to the allowed set.
-- If the policy already uses 'AllowAll', this is a no-op.
allowCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
allowCommand cmd policy =
  case policyAllowedCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { policyAllowedCommands = AllowList (Set.insert cmd s) }

-- | Remove a command from the allowed set.
-- If the policy uses 'AllowAll', this has no effect (you cannot deny
-- individual commands from an AllowAll policy — switch to explicit list first).
denyCommand :: CommandName -> SecurityPolicy -> SecurityPolicy
denyCommand cmd policy =
  case policyAllowedCommands policy of
    AllowAll    -> policy
    AllowList s -> policy { policyAllowedCommands = AllowList (Set.delete cmd s) }

-- | Set the autonomy level on a policy.
withAutonomy :: AutonomyLevel -> SecurityPolicy -> SecurityPolicy
withAutonomy level policy = policy { policyAutonomy = level }

-- | Check whether a command is allowed by this policy. Pure.
isCommandAllowed :: SecurityPolicy -> CommandName -> Bool
isCommandAllowed policy = isAllowed (policyAllowedCommands policy)
