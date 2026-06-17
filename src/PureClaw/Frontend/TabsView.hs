-- |
-- Module      : PureClaw.Frontend.TabsView
-- Description : Pure projection layer for the Active-Tabs list view.
--
-- This leaf module holds the 'TabSnapshot' type (the JSON-friendly
-- point-in-time view of one tab), its 'ToJSON' instance, the text-mapping
-- helpers that convert registry vocabulary ('Registry.Liveness',
-- 'Registry.HarnessOrigin') to snapshot status strings, and the pure
-- projection function 'tabSnapshotsFromRegistry' that drives the
-- @GET /api/tabs@ response.
--
-- Everything here is /pure/ (no IO). The only callers that do IO are in
-- "PureClaw.Frontend.API" (which reads the 'TabList' and registry into
-- memory, then delegates to this module) and the tests (which inject
-- in-memory lookup functions directly).
--
-- See the Tabs-as-View refactor (GitHub #79, WU3-FE) for the design context.
module PureClaw.Frontend.TabsView
  ( -- * Snapshot type
    TabSnapshot (..)
    -- * Vocabulary helpers
  , livenessToTabStatus
  , harnessOriginToText
    -- * Pure projection
  , tabSnapshotsFromRegistry
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)

import PureClaw.Core.Types (unSessionId)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Tabs.Types
  ( Tab (..)
  , TabList
  , TabRef (..)
  , TabStatus (..)
  , toList
  )
import PureClaw.Handles.Tab (unTabIndex)

-- ---------------------------------------------------------------------------
-- TabSnapshot
-- ---------------------------------------------------------------------------

-- | A point-in-time snapshot of a single tab, pre-resolved to
-- JSON-friendly text values. The snapshot callback in 'FrontendEnv'
-- produces these; the API layer simply serializes them.
data TabSnapshot = TabSnapshot
  { _ts_index     :: !Int
  , _ts_kind      :: !Text
    -- ^ @\"provider\"@, @\"harness\"@, or @\"raw_shell\"@.
  , _ts_label     :: !(Maybe Text)
    -- ^ Harness label fallback so a harness tab (whose session id can be
    -- 'Nothing') never renders blank. 'Nothing' for session-backed tabs —
    -- their display title derives from the session (via '_ts_sessionId').
  , _ts_status    :: !Text
    -- ^ Liveness word: @\"running\"@, @\"idle\"@, @\"exited\"@, or
    -- @\"orphaned\"@ (Phase 2 split Exited\/Orphaned; see
    -- 'livenessToTabStatus').
  , _ts_sessionId :: !(Maybe Text)
    -- ^ Session ID for session-backed tabs; 'Nothing' for raw shells.
  , _ts_extModified :: !Bool
    -- ^ The harness window was renamed out-of-band (the §7 ⚠ \"edited\"
    -- pill). Orthogonal to liveness.
  , _ts_stale :: !Bool
    -- ^ Health could not be refreshed this cycle; the frontend holds the
    -- last-known icon with a dimmed cue (§7).
  , _ts_origin :: !Text
    -- ^ How the harness entered the registry: @\"spawned\"@,
    -- @\"discovered\"@, or @\"adopted\"@ (the §7 origin pill).
  , _ts_attachCommand :: !(Maybe Text)
    -- ^ Copyable @tmux attach@ command for live harness rows;
    -- 'Nothing' for non-harness tabs.
  }
  deriving stock (Show, Eq)

-- | Serialize a 'TabSnapshot'. The per-tab @name@ key is GONE — a tab's
-- display title now derives from its bound session (frontend resolves it from
-- @session_id@). Harness tabs keep a @label@ fallback so they never render
-- blank. The Phase-2 health fields (@ext_modified@\/@stale@\/@origin@\/
-- @attach_command@) remain. Consumers that ignore unknown keys keep working.
instance ToJSON TabSnapshot where
  toJSON ts = object
    [ "index"          .= _ts_index ts
    , "kind"           .= _ts_kind ts
    , "label"          .= _ts_label ts
    , "status"         .= _ts_status ts
    , "session_id"     .= _ts_sessionId ts
    , "ext_modified"   .= _ts_extModified ts
    , "stale"          .= _ts_stale ts
    , "origin"         .= _ts_origin ts
    , "attach_command" .= _ts_attachCommand ts
    ]

-- ---------------------------------------------------------------------------
-- Vocabulary helpers
-- ---------------------------------------------------------------------------

-- | Map a registry 'Registry.Liveness' to the @TabSnapshot@ status vocabulary.
-- Phase 2 (§7) SPLITS the former \"crashed\" bucket: 'Registry.LivenessExited'
-- (the process exited; offer Restart\/Dismiss) and 'Registry.LivenessOrphaned'
-- (the window vanished out-of-band; greyed, offer Dismiss) now map to distinct
-- words so the frontend can render the state→visual table.
livenessToTabStatus :: Registry.Liveness -> Text
livenessToTabStatus lv = case lv of
  Registry.LivenessIdle     -> "idle"
  Registry.LivenessThinking -> "running"
  Registry.LivenessExited   -> "exited"
  Registry.LivenessOrphaned -> "orphaned"

-- | Map a registry 'Registry.HarnessOrigin' to the @TabSnapshot@ origin
-- vocabulary (the §7 origin pill): @\"spawned\"@ (we launched it),
-- @\"discovered\"@ (boot-reconstructed from a tagged window), or
-- @\"adopted\"@ (taken over from another controller).
harnessOriginToText :: Registry.HarnessOrigin -> Text
harnessOriginToText o = case o of
  Registry.OriginSpawned    -> "spawned"
  Registry.OriginDiscovered -> "discovered"
  Registry.OriginAdopted    -> "adopted"

-- ---------------------------------------------------------------------------
-- Pure projection
-- ---------------------------------------------------------------------------

-- | Project the tab registry and the harness-entry lookup into a list of
-- 'TabSnapshot' values, one per tab, in slot order.
--
-- The lookup argument is injected so this function is fully pure and
-- testable without IO:
--
-- * @harnOf hid@ — look up the live 'Registry.HarnessEntry' for a harness-
--   backed tab. 'Nothing' means the entry has vanished from the registry
--   since the tab was created; the tab is projected as @exited\/stale@.
--
-- Provider tabs ('BoundSession') are projected purely from the 'Tab' record
-- itself — no session-meta lookup is needed. This is a structural guarantee:
-- the function takes no session-meta input, so no session metadata
-- (@_sm_source@, channelUserId, credentials, etc.) can appear in a
-- 'TabSnapshot' by construction.
tabSnapshotsFromRegistry
  :: TabList
  -> (Registry.HarnessId -> Maybe Registry.HarnessEntry)
  -> [TabSnapshot]
tabSnapshotsFromRegistry tl harnOf = map project (toList tl)
  where
    project :: Tab -> TabSnapshot
    project tab = case _tab_ref tab of
      BoundSession sid ->
        TabSnapshot
          { _ts_index         = unTabIndex (_tab_slot tab)
          , _ts_kind          = "provider"
          , _ts_label         = Nothing
          , _ts_status        = case _tab_status tab of
                                  Live -> "idle"
                                  Dead -> "exited"
          , _ts_sessionId     = Just (unSessionId sid)
          , _ts_extModified   = False
          , _ts_stale         = False
          , _ts_origin        = ""
          , _ts_attachCommand = Nothing
          }
      BoundHarness hid ->
        case harnOf hid of
          Just e ->
            TabSnapshot
              { _ts_index         = unTabIndex (_tab_slot tab)
              , _ts_kind          = "harness"
              , _ts_label         = Just (Registry._he_label e)
              , _ts_status        = livenessToTabStatus (Registry._he_liveness e)
              , _ts_sessionId     = Registry._he_sessionId e
              , _ts_extModified   = Registry._he_extModified e
              , _ts_stale         = Registry._he_stale e
              , _ts_origin        = harnessOriginToText (Registry._he_origin e)
              , _ts_attachCommand = Just
                  ("tmux attach -t "
                    <> Registry._he_session e
                    <> ":"
                    <> Registry._he_windowName e)
              }
          Nothing ->
            TabSnapshot
              { _ts_index         = unTabIndex (_tab_slot tab)
              , _ts_kind          = "harness"
              , _ts_label         = Nothing
              , _ts_status        = "exited"
              , _ts_sessionId     = Nothing
              , _ts_extModified   = False
              , _ts_stale         = True
              , _ts_origin        = ""
              , _ts_attachCommand = Nothing
              }
