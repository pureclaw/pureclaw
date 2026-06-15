-- |
-- Module      : PureClaw.Tabs.Wizard
-- Description : The @\/tab@ attach-wizard state machine (Tabs-as-View, WU6).
--
-- A small, pure-ish state machine for the @\/tab@ attach wizard (design §11).
-- When @\/tab@ runs, the dispatcher snapshots the currently-running harnesses
-- and the most-recent sessions ('mkWizardSnapshot'), numbers them with
-- single-character keys drawn from 'wizardKeys' (@[1-9a-z]@ — @0@ is reserved
-- for /cancel/), renders the menu ('renderMenu'), and shows it. The
-- conversation then sits in a transient 'WizardState' until the user replies.
--
-- Each reply is fed to 'stepWizard', which decides the next state and the
-- visible 'WizardStep':
--
--   * A bare key present in the snapshot binds the __exact__ id captured at
--     snapshot time — never re-resolved by list position (§11). For a harness
--     target the injected liveness probe ('_wz_live') is consulted; if the
--     harness has vanished since the snapshot, the wizard re-prompts with a
--     refreshed list rather than attaching to nothing. Sessions live on disk,
--     so a session pick is always valid (no probe).
--   * @0@\/@cancel@ exits; a @\/@-prefixed reply cancels the wizard and asks
--     the caller to run that command instead (no modal lock-in, §9.2); any
--     other reply re-prompts with the state unchanged.
--
-- The /only/ IO is the injected 'WizardEnv' liveness probe, so the engine is
-- driven deterministically in unit tests. Dispatcher interception (consuming a
-- conversation's next message before @parseInput@) is __not__ here — that is
-- WU8. This module is purely additive.
--
-- Leaf module: depends on 'PureClaw.Core.Types' ('SessionId') and
-- 'PureClaw.Harness.Registry' ('HarnessId') only.
module PureClaw.Tabs.Wizard
  ( -- * Targets & state
    WizardTarget (..)
  , WizardState (..)
  , WizardStep (..)
  , WizardEnv (..)
    -- * Building & rendering the menu
  , mkWizardSnapshot
  , renderMenu
  , wizardKeys
    -- * Driving the wizard
  , stepWizard
    -- * Overflow query filter
  , filterCandidates
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Core.Types (SessionId)
import PureClaw.Harness.Registry (HarnessId)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | What a completed wizard binds to: an existing running harness, or a past
-- session to reopen (continue\/append). The dispatcher (WU8) turns this into a
-- new tab at the next free slot.
data WizardTarget
  = AttachHarness !HarnessId
  | ReopenSession !SessionId
  deriving stock (Eq, Show)

-- | A wizard snapshot: the numbered options as shown to the user. The numbering
-- is stable for the lifetime of this state — a reply binds the id captured
-- here, never re-resolved by position (§11).
newtype WizardState = WizardState
  { _wz_options :: [(Char, WizardTarget)]
  }
  deriving stock (Eq, Show)

-- | The visible outcome of one wizard turn.
data WizardStep
  = Prompt !Text
    -- ^ The rendered menu to show when the wizard first opens.
  | Done !WizardTarget
    -- ^ The user picked a still-valid target; bind it.
  | Cancelled
    -- ^ The user cancelled (@0@ or @cancel@).
  | Reprompt !Text
    -- ^ Invalid reply, or the picked target vanished: re-render the menu with a
    --   one-line notice.
  | RunCommand !Text
    -- ^ The reply began with @\/@: cancel the wizard and run that command.
  deriving stock (Eq, Show)

-- | The wizard's only effect seam: probe whether a harness is still running.
-- Injected so the engine is unit-testable without a live tmux server.
newtype WizardEnv = WizardEnv
  { _wz_live :: HarnessId -> IO Bool
  }

-- ---------------------------------------------------------------------------
-- Key namespace
-- ---------------------------------------------------------------------------

-- | The single-character option keys, in assignment order: @1..9@ then @a..z@.
-- @0@ is deliberately excluded — it is reserved for /cancel/ (§11), so a bare
-- @0@ is never ambiguous. This yields 35 assignable options; the snapshot is
-- capped to this length.
wizardKeys :: [Char]
wizardKeys = ['1' .. '9'] ++ ['a' .. 'z']

-- ---------------------------------------------------------------------------
-- Building & rendering
-- ---------------------------------------------------------------------------

-- | Build a wizard snapshot from the running harnesses and recent sessions,
-- each paired with its display label. Options are numbered with 'wizardKeys' —
-- harnesses first, then sessions — and the total is capped at @length
-- 'wizardKeys'@ (harnesses are kept first, sessions truncated). Overflow beyond
-- the cap is reachable via 'filterCandidates' before snapshotting (§11).
mkWizardSnapshot :: [(HarnessId, Text)] -> [(SessionId, Text)] -> WizardState
mkWizardSnapshot harnesses sessions =
  WizardState (zip wizardKeys targets)
  where
    targets =
      map (AttachHarness . fst) harnesses
        ++ map (ReopenSession . fst) sessions
    -- 'zip' against the finite 'wizardKeys' truncates to the cap automatically,
    -- keeping harnesses (which come first) ahead of sessions.

-- | Render the numbered menu plus a @0  cancel@ line (the user-facing prompt).
-- 'mkWizardSnapshot' keeps only the binding-relevant '(Char, WizardTarget)' and
-- discards friendly labels, so this engine-level renderer shows the target id
-- text. The dispatcher (WU8) may render a richer label menu from the raw
-- candidate lists; this label-free renderer exists so the wizard is
-- self-describing in tests.
renderMenu :: WizardState -> Text
renderMenu (WizardState opts) =
  T.unlines (header : map line opts ++ [cancelLine])
  where
    header     = "Attach a tab — reply with a number:"
    cancelLine = " 0  cancel"
    line (k, t) = " " <> T.singleton k <> "  " <> targetLabel t

-- | A terse label for a target, used by the engine-level 'renderMenu'.
targetLabel :: WizardTarget -> Text
targetLabel (AttachHarness h) = "harness " <> tshow h
targetLabel (ReopenSession s) = "session " <> tshow s

-- ---------------------------------------------------------------------------
-- Driving the wizard
-- ---------------------------------------------------------------------------

-- | Process one wizard reply against the current snapshot. Returns the next
-- state (@Nothing@ ⇒ the wizard ends) and the visible 'WizardStep'.
--
-- Resolution order (the reply is trimmed first):
--
--   1. A @\/@-prefixed reply ⇒ @(Nothing, 'RunCommand' reply)@ — cancel + run it.
--   2. @0@ or @cancel@ (case-insensitive) ⇒ @(Nothing, 'Cancelled')@.
--   3. A single key present in '_wz_options':
--
--        * 'AttachHarness' whose '_wz_live' is False ⇒ the target vanished:
--          @('Just' st', 'Reprompt' notice)@ where @st'@ drops that harness.
--        * otherwise ⇒ @(Nothing, 'Done' target)@.
--
--   4. Anything else (unknown key, empty, multi-char non-command) ⇒
--      @('Just' st, 'Reprompt' …)@ — invalid; re-prompt, state unchanged.
stepWizard :: WizardEnv -> WizardState -> Text -> IO (Maybe WizardState, WizardStep)
stepWizard env st@(WizardState opts) raw
  | "/" `T.isPrefixOf` reply = pure (Nothing, RunCommand reply)
  | isCancel reply           = pure (Nothing, Cancelled)
  | Just target <- singleKeyTarget = resolvePick env st target
  | otherwise                = pure (Just st, Reprompt invalidNotice)
  where
    reply = T.strip raw

    isCancel r = r == "0" || T.toLower r == "cancel"

    -- A single-character reply that names an option.
    singleKeyTarget = case T.unpack reply of
      [c] -> lookup c opts
      _   -> Nothing

-- | Resolve a picked target: harnesses are liveness-checked (a dead one
-- re-prompts with a refreshed, harness-dropped snapshot); sessions are always
-- valid (they live on disk — no probe).
resolvePick :: WizardEnv -> WizardState -> WizardTarget -> IO (Maybe WizardState, WizardStep)
resolvePick env st target = case target of
  ReopenSession _ -> pure (Nothing, Done target)
  AttachHarness h -> do
    alive <- _wz_live env h
    if alive
      then pure (Nothing, Done target)
      else pure (Just (dropTarget target st), Reprompt vanishedNotice)

-- | Drop a vanished target from a snapshot and re-key the survivors with
-- 'wizardKeys' (so the refreshed menu stays contiguous). Used when a picked
-- harness has died.
dropTarget :: WizardTarget -> WizardState -> WizardState
dropTarget gone (WizardState opts) =
  WizardState (zip wizardKeys [ t | (_, t) <- opts, t /= gone ])

-- ---------------------------------------------------------------------------
-- Overflow query filter
-- ---------------------------------------------------------------------------

-- | A sanitised, case-insensitive substring filter on candidate labels, used by
-- the @\/tab \<query\>@ overflow path (§11) before 'mkWizardSnapshot'. The query
-- is trimmed and lowercased; an empty\/whitespace-only query keeps everything.
filterCandidates :: Text -> [(a, Text)] -> [(a, Text)]
filterCandidates query cands
  | T.null q  = cands
  | otherwise = [ c | c@(_, label) <- cands, q `T.isInfixOf` T.toLower label ]
  where
    q = T.toLower (T.strip query)

-- ---------------------------------------------------------------------------
-- Notices (pinned copy — design §14)
-- ---------------------------------------------------------------------------

-- | The vanished-target notice (§14).
vanishedNotice :: Text
vanishedNotice = "that target is gone — list refreshed"

-- | The invalid-reply notice.
invalidNotice :: Text
invalidNotice = "not a valid choice — reply with a number, or 0 to cancel"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | 'Show' a value as 'Text'.
tshow :: Show a => a -> Text
tshow = T.pack . show
