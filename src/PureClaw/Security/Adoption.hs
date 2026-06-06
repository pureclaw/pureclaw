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
-- an external, unmanaged tmux window). The consent is the human's explicit
-- /pick/ of a window to take over:
--
--   * In the foreground TUI, picking a session in the New-Tab form IS the
--     consent ('ConsentInteractive').
--   * In the web UI served by the gateway, choosing \"Existing Harness\" and
--     selecting a window in the browser IS the consent ('ConsentWeb'). The
--     @POST \/api\/adopt@ request carries that selection (@consent_confirmed@).
--
-- Only a truly unattended invocation with NO human picking a window — a
-- bot\/cron\/import\/daemon run, or a test default — maps to 'ConsentHeadless'
-- and is denied (fail-closed). That headless-deny is the single, load-bearing
-- remaining control on this gate.
data ConsentChannel
  = ConsentInteractive  -- ^ foreground interactive TUI; a human picks the window
  | ConsentWeb          -- ^ gateway-served web UI; the browser selection is the consent
  | ConsentHeadless     -- ^ no human picking a window (bot\/cron\/import\/test); denied
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
--   * 'ConsentHeadless' → 'Left' 'AdoptNoConsentChannel' (a bot\/cron\/import\/
--     test run has no human picking a window — fail-closed; the single
--     remaining control).
--   * 'ConsentInteractive' (foreground TUI) and 'ConsentWeb' (gateway web UI)
--     → 'Right' an 'AdoptedHarness' token for ANY session. In both, a human
--     explicitly picked the window to take over, which IS the consent.
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
    ConsentWeb         -> Right (AdoptedHarness session)
