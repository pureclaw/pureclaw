module PureClaw.Security.Policy
  ( -- * Policy type
    SecurityPolicy (..)
    -- * Adoption allow-list (default-deny, no implicit allow-all)
  , SessionPattern
  , parseSessionPattern
  , partitionSessionPatterns
  , matchesSessionPattern
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
import Data.Text (Text)
import Data.Text qualified as T

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
  , _sp_adoptableSessionPatterns :: [SessionPattern]
    -- ^ Allow-list of tmux session-name patterns eligible for /adoption/
    -- (see "PureClaw.Security.Adoption"). The DEFAULT is the empty list,
    -- which denies ALL adoption. This list is INTENTIONALLY not routed through
    -- 'AllowList'\/'AllowAll' — there must be no implicit allow-all path for a
    -- trust-boundary expansion like adopting an external (unmanaged) window.
  }
  deriving stock (Show, Eq)

-- | A validated tmux session-name pattern used by the adoption allow-list.
--
-- The value constructor is intentionally NOT exported — the only way to obtain
-- a 'SessionPattern' is 'parseSessionPattern', which REJECTS a bare @*@ and the
-- empty string. This makes an implicit allow-all pattern unrepresentable: there
-- is no in-band value that matches everything (mirrors the @AuthorizedCommand@
-- / @SafePath@ "smart constructor, hidden ctor" precedent).
--
-- A pattern is one of two shapes (matching is anchored \/ full-string):
--
--   * a /literal/ session name, matched by exact equality; or
--   * a non-empty /prefix/ followed by a single trailing @*@, matched by
--     prefix on the part before the @*@.
data SessionPattern
  = LiteralPattern !Text
    -- ^ exact-equality match against the whole session name
  | PrefixPattern !Text
    -- ^ prefix match; invariant: the carried prefix is non-empty
  deriving stock (Show, Eq)

-- | Parse a configured pattern string into a 'SessionPattern'.
--
-- Returns 'Nothing' (rejected — contributes nothing to the allow-list) for:
--
--   * the empty string, and
--   * a bare @*@ (or any @prefix*@ whose prefix is empty).
--
-- A bare @*@ is rejected precisely so a misconfiguration can NEVER become an
-- implicit allow-all. A trailing @*@ on a non-empty prefix yields a
-- 'PrefixPattern'; anything else (including names containing an interior @*@)
-- is treated as a 'LiteralPattern'. There is no regex (so no ReDoS) and the
-- function is total.
parseSessionPattern :: Text -> Maybe SessionPattern
parseSessionPattern t
  | T.null t           = Nothing      -- empty: rejected
  | t == "*"           = Nothing      -- bare star: rejected (no allow-all)
  | Just prefix <- T.stripSuffix "*" t =
      if T.null prefix
        then Nothing                  -- empty prefix before '*': rejected
        else Just (PrefixPattern prefix)
  | otherwise          = Just (LiteralPattern t)

-- | Parse a batch of configured pattern strings, separating the ones that were
-- rejected from the ones that parsed. Returns @(invalids, valids)@ — @invalids@
-- is the list of raw strings that 'parseSessionPattern' rejected (a bare @*@,
-- the empty string, etc.) so the caller can log them; @valids@ is the resulting
-- allow-list. Pure and total; preserves input order.
--
-- This keeps the drop-invalid decision logic pure and unit-testable; the only
-- thing left to the IO caller is the actual warning emission.
partitionSessionPatterns :: [Text] -> ([Text], [SessionPattern])
partitionSessionPatterns = foldr step ([], [])
  where
    step raw (invalids, valids) =
      case parseSessionPattern raw of
        Nothing -> (raw : invalids, valids)
        Just p  -> (invalids, p : valids)

-- | Does any pattern in the allow-list match the given session name?
--
-- Pure and total, no regex. An empty list matches NOTHING (default-deny):
--
--   * a 'LiteralPattern' matches by exact equality;
--   * a 'PrefixPattern' @p@ matches any session of which @p@ is a prefix
--     (including the bare prefix itself, e.g. @"work*"@ matches both @"work"@
--     and @"work-1"@, but not @"wor"@ nor @"home-1"@).
matchesSessionPattern :: [SessionPattern] -> Text -> Bool
matchesSessionPattern pats session = any matches1 pats
  where
    matches1 (LiteralPattern lit)    = session == lit
    matches1 (PrefixPattern prefix)  = prefix `T.isPrefixOf` session

-- | Default policy: deny everything (local and remote). Start here and
-- open up explicitly.
defaultPolicy :: SecurityPolicy
defaultPolicy = SecurityPolicy
  { _sp_allowedCommands       = AllowList Set.empty
  , _sp_autonomy              = Deny
  , _sp_allowedRemoteCommands = AllowList Set.empty
  , _sp_adoptableSessionPatterns = []
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
