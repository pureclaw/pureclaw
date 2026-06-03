module PureClaw.Security.Adoption
  ( -- * Adopted-harness capability token (constructor intentionally NOT exported)
    AdoptedHarness
  , adoptedSession
    -- * Consent channel
  , ConsentChannel (..)
    -- * Adoption errors
  , AdoptError (..)
    -- * The consent-only adoption gate (pure — no IO)
  , authorizeAdoption
  ) where

import Data.Text (Text)

-- | Where the run that is attempting an adoption is being driven from.
--
-- Adoption is a trust-boundary expansion (PureClaw begins managing\/capturing
-- an external, unmanaged tmux window). In the interactive path the human
-- /picking a session in the foreground New-Tab form IS the consent/, so any
-- interactive run may adopt the session it picked. Any non-interactive
-- invocation — a gateway\/bot server, an import, a future cron\/daemon\/
-- background mode — has no human at a confirm dialog, so it maps to
-- 'ConsentHeadless' and is denied (fail-closed). This headless-deny is the
-- single, load-bearing remaining control on this gate.
data ConsentChannel
  = ConsentInteractive  -- ^ foreground interactive run; a human can confirm
  | ConsentHeadless     -- ^ no human at a confirm dialog; adoption denied
  deriving stock (Show, Eq)

-- | Why an adoption attempt was refused.
--
-- After the allow-list was dropped (the foreground session pick IS the
-- consent), the ONLY reason the gate refuses is the absence of an interactive
-- consent channel.
data AdoptError
  = AdoptNoConsentChannel
    -- ^ the run has no interactive consent channel ('ConsentHeadless'); a
    -- headless\/gateway\/import\/cron run cannot adopt (fail-closed).
  deriving stock (Show, Eq)

-- | A capability token proving that adopting a particular tmux session has
-- passed the security gate.
--
-- The value constructor is intentionally NOT exported — the ONLY way to obtain
-- an 'AdoptedHarness' is 'authorizeAdoption', which enforces the consent check.
-- Downstream adoption mechanism code REQUIRES an 'AdoptedHarness' argument, so
-- it is impossible by construction to adopt a window without first passing this
-- gate. This mirrors the @AuthorizedCommand@ \/ @SafePath@ precedent in
-- "PureClaw.Security.Command" and "PureClaw.Security.Path".
newtype AdoptedHarness = AdoptedHarness { _unAdoptedHarness :: Text }
  deriving stock (Show, Eq)

-- | The tmux session name that was authorized for adoption.
adoptedSession :: AdoptedHarness -> Text
adoptedSession = _unAdoptedHarness

-- | The typed, consent-only adoption gate. Pure — no IO.
--
-- The allow-list was deliberately dropped (an explicit security-model
-- relaxation): in the interactive path the user picking a session in the
-- foreground New-Tab form IS the consent, so adoption is gated by consent
-- alone:
--
--   * 'ConsentHeadless' → 'Left' 'AdoptNoConsentChannel' (a headless\/gateway\/
--     import\/cron run has no human at the confirm dialog — fail-closed; this
--     is the single remaining control).
--   * 'ConsentInteractive' → 'Right' an 'AdoptedHarness' token for ANY session.
--
-- The capability-token construction (unexported ctor) and the downstream adopt
-- mechanism's own identifier hygiene (@send-keys -l --@ + @validateTmuxIdent@,
-- §8 C3) remain unchanged.
authorizeAdoption
  :: ConsentChannel
  -> Text                -- ^ tmux session name to adopt
  -> Either AdoptError AdoptedHarness
authorizeAdoption consent session =
  case consent of
    ConsentHeadless    -> Left AdoptNoConsentChannel
    ConsentInteractive -> Right (AdoptedHarness session)
