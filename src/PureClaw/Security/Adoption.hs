module PureClaw.Security.Adoption
  ( -- * Adopted-harness capability token (constructor intentionally NOT exported)
    AdoptedHarness
  , adoptedSession
    -- * Consent channel
  , ConsentChannel (..)
    -- * Adoption errors
  , AdoptError (..)
    -- * The default-deny, consent-gated adoption gate (pure — no IO)
  , authorizeAdoption
  ) where

import Data.Text (Text)

import PureClaw.Security.Policy

-- | Where the run that is attempting an adoption is being driven from.
--
-- Adoption is a trust-boundary expansion (PureClaw begins managing\/capturing
-- an external, unmanaged tmux window), so it requires a human at an interactive
-- confirm dialog. Any non-interactive invocation — a gateway\/bot server, an
-- import, a future cron\/daemon\/background mode — has no such human, so it maps
-- to 'ConsentHeadless' and is denied (fail-closed).
data ConsentChannel
  = ConsentInteractive  -- ^ foreground interactive run; a human can confirm
  | ConsentHeadless     -- ^ no human at a confirm dialog; adoption denied
  deriving stock (Show, Eq)

-- | Why an adoption attempt was refused.
data AdoptError
  = AdoptNoConsentChannel
    -- ^ the run has no interactive consent channel ('ConsentHeadless').
    -- Checked FIRST, so it dominates 'AdoptNotAllowed': a headless run is
    -- denied even if the session is allow-listed.
  | AdoptNotAllowed !Text
    -- ^ the session name is not covered by the policy's adoptable-session
    -- allow-list ('_sp_adoptableSessionPatterns'). The default (empty list)
    -- denies everything.
  deriving stock (Show, Eq)

-- | A capability token proving that adopting a particular tmux session has
-- passed the security gate.
--
-- The value constructor is intentionally NOT exported — the ONLY way to obtain
-- an 'AdoptedHarness' is 'authorizeAdoption', which enforces the consent +
-- allow-list checks. Downstream adoption mechanism code (later work units)
-- REQUIRES an 'AdoptedHarness' argument, so it is impossible by construction to
-- adopt a window without first passing this gate. This mirrors the
-- @AuthorizedCommand@ \/ @SafePath@ precedent in "PureClaw.Security.Command"
-- and "PureClaw.Security.Path".
newtype AdoptedHarness = AdoptedHarness { _unAdoptedHarness :: Text }
  deriving stock (Show, Eq)

-- | The tmux session name that was authorized for adoption.
adoptedSession :: AdoptedHarness -> Text
adoptedSession = _unAdoptedHarness

-- | The typed, default-deny, consent-gated adoption gate. Pure — no IO.
--
-- Checks, IN ORDER (the order is load-bearing — headless-deny dominates):
--
--   1. If the run is 'ConsentHeadless' → 'Left' 'AdoptNoConsentChannel'.
--      This is checked FIRST so a headless run is denied even when the session
--      IS allow-listed (no allow-list entry can grant a non-interactive run an
--      adoption).
--   2. Otherwise, if the session name is not matched by the policy's
--      'matchesSessionPattern' allow-list → 'Left' ('AdoptNotAllowed' session).
--      The default policy carries an empty list, so this DENIES by default.
--   3. Otherwise → 'Right' an 'AdoptedHarness' token for the session.
authorizeAdoption
  :: SecurityPolicy
  -> ConsentChannel
  -> Text                -- ^ tmux session name to adopt
  -> Either AdoptError AdoptedHarness
authorizeAdoption policy consent session =
  case consent of
    ConsentHeadless -> Left AdoptNoConsentChannel
    ConsentInteractive
      | matchesSessionPattern (_sp_adoptableSessionPatterns policy) session ->
          Right (AdoptedHarness session)
      | otherwise ->
          Left (AdoptNotAllowed session)
