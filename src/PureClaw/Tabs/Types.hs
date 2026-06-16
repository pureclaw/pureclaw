-- |
-- Module      : PureClaw.Tabs.Types
-- Description : First-class tab registry — core value types & pure operations.
--
-- A /tab/ is a pure binding over ground truth: it names a 'TabRef' (a live
-- 'SessionId' or 'HarnessId'), the slot it currently occupies, a friendly
-- label, and a liveness 'TabStatus'. The ordered collection of tabs is a
-- 'TabList' that maintains two invariants:
--
--   * __I1 (contiguity)__ — the slots of a 'TabList' are exactly
--     @[0 .. n-1]@ at all times. 'removeSlot' compacts (tmux-window style):
--     every tab above the removed slot shifts down by one.
--   * __I2 (uniqueness)__ — no two tabs bind the same 'TabRef'. 'appendTab'
--     of an already-bound ref is rejected with @'Left' ('AlreadyBound' i)@,
--     reporting the ref's /current/ slot.
--
-- There is also a hard cap of 36 slots (@0..35@), matching the validated
-- 'TabIndex' range. Appending past it returns @'Left' 'SlotsFull'@.
--
-- This module is pure (no IO). The thin IORef handle that mutates a 'TabList'
-- lives in "PureClaw.Tabs". The 0–35 'TabIndex' arithmetic is reused from
-- "PureClaw.Handles.Tab" ('TabIndex'\/'mkTabIndex'\/'unTabIndex') rather than
-- redefined, so there is a single validated index type across the codebase.
--
-- See the Tabs-as-View refactor (GitHub #79) for the design context.
module PureClaw.Tabs.Types
  ( -- * Tab binding
    TabRef (..)
  , TabStatus (..)
  , Tab (..)
    -- * Ordered tab list (invariants I1\/I2)
  , TabList
  , TabsError (..)
  , emptyTabs
  , toList
  , appendTab
  , removeSlot
  , lookupSlot
  , lookupRef
  , setStatus
  , rebindSlot
    -- * Cap
  , maxTabSlots
    -- * Per-conversation cursors & relay (I3)
  , ConversationKey
  , RelayMode (..)
  , CursorState (..)
  , emptyCursors
  , setCursor
  , clearCursor
  , resolveCursorSlot
  , conversationsOn
  , pruneDangling
  , relayModeFor
    -- * @\/tab@ command ADTs (parsed form; shared by the dispatcher seam)
  , TabKindArg (..)
  , ForceMode (..)
  , TabSlashCommand (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import PureClaw.Core.Types (ChannelKind, ConversationId, SessionId)
import PureClaw.Handles.Tab (TabIndex, mkTabIndex, unTabIndex)
import PureClaw.Harness.Registry (HarnessId)

-- ---------------------------------------------------------------------------
-- TabRef / TabStatus / Tab
-- ---------------------------------------------------------------------------

-- | The ground-truth entity a tab binds to: either an LLM-backed
-- 'SessionId' or an external 'HarnessId'. A tab is a /view/ over one of
-- these; it owns no lifecycle of its own.
data TabRef
  = BoundSession !SessionId
  | BoundHarness !HarnessId
  deriving stock (Eq, Ord, Show)

-- | Liveness of a tab's bound ground truth.
--
-- * 'Live' — the bound session\/harness is believed alive; messages route.
-- * 'Dead' — the bound harness has exited (a tombstone). The tab persists
--   in the list (visible in @\/tabs@) until it is explicitly removed; routing
--   to a 'Dead' tab is handled by the dispatcher (deferred warning + drop).
data TabStatus
  = Live
  | Dead
  deriving stock (Eq, Show)

-- | A single tab: a pure binding over ground truth.
data Tab = Tab
  { _tab_slot   :: !TabIndex
    -- ^ The tab's position in the 'TabList'. Maintained contiguous (I1);
    --   never set directly by callers — derived by 'appendTab'\/'removeSlot'.
  , _tab_ref    :: !TabRef
    -- ^ The bound ground-truth entity (unique across the list, I2).
  , _tab_name   :: !Text
    -- ^ Friendly label. (Sanitisation is the caller's responsibility — this
    --   module stores the text verbatim.)
  , _tab_status :: !TabStatus
    -- ^ Liveness of the binding.
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- TabList
-- ---------------------------------------------------------------------------

-- | An ordered list of tabs maintaining invariants I1 (contiguous slots
-- @[0..n-1]@) and I2 (unique 'TabRef's). The constructor is not exported;
-- all mutation goes through the smart operations below, which preserve the
-- invariants by construction.
newtype TabList = TabList [Tab]
  deriving stock (Eq, Show)

-- | Why a 'TabList' mutation was rejected.
data TabsError
  = SlotsFull
    -- ^ All 36 slots are occupied; the next append would be slot 36.
  | AlreadyBound !TabIndex
    -- ^ The 'TabRef' is already bound; the payload is its /current/ slot.
  deriving stock (Eq, Show)

-- | The hard slot cap. Slots are @0 .. 'maxTabSlots' - 1@ (i.e. 36 slots,
-- matching the validated 'TabIndex' range used elsewhere).
maxTabSlots :: Int
maxTabSlots = 36

-- | The empty tab list.
emptyTabs :: TabList
emptyTabs = TabList []

-- | The tabs in slot order (slot @0@ first). Total; never partial.
toList :: TabList -> [Tab]
toList (TabList ts) = ts

-- | Append a new tab binding @ref@ with label @name@ at the next free slot.
--
-- * If @ref@ is already bound, returns @'Left' ('AlreadyBound' i)@ where @i@
--   is its current slot (I2 — no duplicate refs).
-- * If all 36 slots are taken, returns @'Left' 'SlotsFull'@.
-- * Otherwise the new tab lands at slot @length@ (preserving I1) with status
--   'Live', and the new slot index is returned alongside the updated list.
appendTab :: TabRef -> Text -> TabList -> Either TabsError (TabIndex, TabList)
appendTab ref name tl@(TabList ts) =
  case lookupRef ref tl of
    Just i  -> Left (AlreadyBound i)
    Nothing ->
      let n = length ts
      in if n >= maxTabSlots
           then Left SlotsFull
           else
             -- @0 <= n < 36@ here, so slot @n@ is valid. Append the new tab
             -- (with a provisional slot 'reindex' overwrites) and 'reindex' to
             -- stamp contiguous slots @0..n@ (I1). The new tab is last, so its
             -- slot is the last stamped index, read back via 'NE.last'.
             let placed = NE.fromList (reindex (ts ++ [Tab firstSlot ref name Live]))
             in Right (_tab_slot (NE.last placed), TabList (NE.toList placed))

-- | The infinite stream of valid slots @0, 1, 2, …@ as a 'NonEmpty'. Built
-- via the comprehension-filter trick so the impossible @'mkTabIndex' n ==
-- Nothing@ (n negative) case introduces no uncoverable alternative; the
-- 'NonEmpty' shape makes 'firstSlot' total (no partial 'head').
slotStream :: NonEmpty TabIndex
slotStream = NE.fromList [ s | n <- [0 :: Int ..], Just s <- [mkTabIndex n] ]

-- | The first slot (@0@), used as the provisional slot for a freshly-appended
-- tab before 'reindex' stamps the real one.
firstSlot :: TabIndex
firstSlot = NE.head slotStream

-- | Remove the tab at @slot@ (if present) and compact: every tab above the
-- removed slot shifts down by one, so the result still satisfies I1. A no-op
-- when no tab occupies @slot@.
removeSlot :: TabIndex -> TabList -> TabList
removeSlot slot (TabList ts) =
  TabList (reindex (filter ((/= unTabIndex slot) . unTabIndex . _tab_slot) ts))

-- | Re-stamp a list of tabs with contiguous slots @0..n-1@ in their current
-- order. Used after a removal to restore I1. Total: 'slotStream' supplies a
-- valid 'TabIndex' for every position, so 'zipWith' stamps every tab.
reindex :: [Tab] -> [Tab]
reindex = zipWith (\s t -> t { _tab_slot = s }) (NE.toList slotStream)

-- | Look up the tab currently at @slot@.
lookupSlot :: TabIndex -> TabList -> Maybe Tab
lookupSlot slot (TabList ts) =
  case filter ((== unTabIndex slot) . unTabIndex . _tab_slot) ts of
    (t : _) -> Just t
    []      -> Nothing

-- | Look up the slot currently occupied by @ref@ (I2 guarantees at most one).
lookupRef :: TabRef -> TabList -> Maybe TabIndex
lookupRef ref (TabList ts) =
  case filter ((== ref) . _tab_ref) ts of
    (t : _) -> Just (_tab_slot t)
    []      -> Nothing

-- | Set the 'TabStatus' of the tab bound to @ref@. A no-op when @ref@ is not
-- bound. Slots are unaffected.
setStatus :: TabRef -> TabStatus -> TabList -> TabList
setStatus ref status (TabList ts) =
  TabList (map upd ts)
  where
    upd t =
      if _tab_ref t == ref
        then t { _tab_status = status }
        else t

-- | Rebind the tab at @slot@ to a new @ref@ and @name@, /in place/ — the
-- slot, and the slots of every other tab, are unchanged (I1 preserved). The
-- rebound tab's status is reset to 'Live'. This backs @\/new@'s "reset the
-- active tab to a fresh session" semantics (design §6.1).
--
-- The new @ref@ is dedup-checked against I2:
--
--   * If @ref@ is already bound to a /different/ slot, the rebind is rejected
--     with @'Left' ('AlreadyBound' i)@ (@i@ = that other slot) and the list is
--     unchanged.
--   * Rebinding a slot to the ref it /already/ holds is allowed — it is just a
--     relabel (and a status reset) in place.
--
-- If no tab occupies @slot@, this is a no-op returning the list unchanged
-- (@'Right'@) — callers that already verified an active tab never hit this,
-- but it keeps the function total.
rebindSlot :: TabIndex -> TabRef -> Text -> TabList -> Either TabsError TabList
rebindSlot slot ref name tl@(TabList ts) =
  case lookupSlot slot tl of
    Nothing -> Right tl
    Just _  ->
      case lookupRef ref tl of
        Just other | other /= slot -> Left (AlreadyBound other)
        _ -> Right (TabList (map upd ts))
  where
    upd t =
      if unTabIndex (_tab_slot t) == unTabIndex slot
        then t { _tab_ref = ref, _tab_name = name, _tab_status = Live }
        else t

-- ---------------------------------------------------------------------------
-- Per-conversation cursors & relay (I3)
-- ---------------------------------------------------------------------------

-- | The identity of a conversation: its originating 'ChannelKind' paired with
-- a server-derived 'ConversationId'. Two messages sharing a key belong to the
-- same conversation and therefore share a tab cursor and a 'RelayMode'.
type ConversationKey = (ChannelKind, ConversationId)

-- | How a conversation's output relay fans tab output out to it. Persisted
-- per 'ConversationKey'; the global default lives in config (see the
-- Tabs-as-View design §9.3).
--
-- * 'FocusedOnly' (default) — only the conversation's focused tab is relayed.
-- * 'ActivityDigest' — focused tab full; other live tabs get an activity ping.
-- * 'Firehose' — full content from all live tabs.
data RelayMode
  = FocusedOnly
  | ActivityDigest
  | Firehose
  deriving stock (Eq, Show)

-- | The per-conversation routing state the dispatcher owns: which 'TabRef'
-- each conversation is focused on ('_cs_cursors'), and any per-conversation
-- 'RelayMode' override ('_cs_relay'). Both maps are keyed by 'ConversationKey'.
--
-- Cursors key by 'TabRef', not by slot — this is invariant __I3__: a cursor
-- survives slot compaction ('removeSlot') because it names ground truth, not a
-- position. 'resolveCursorSlot' resolves the ref to its /current/ slot at read
-- time.
data CursorState = CursorState
  { _cs_cursors :: !(Map ConversationKey TabRef)
    -- ^ The 'TabRef' each conversation is currently focused on.
  , _cs_relay   :: !(Map ConversationKey RelayMode)
    -- ^ Per-conversation 'RelayMode' overrides (absent ⇒ use the global default).
  }
  deriving stock (Eq, Show)

-- | The empty cursor state: no cursors, no relay overrides.
emptyCursors :: CursorState
emptyCursors = CursorState Map.empty Map.empty

-- | Focus a conversation on a 'TabRef', replacing any prior cursor for that key.
-- The relay map is untouched.
setCursor :: ConversationKey -> TabRef -> CursorState -> CursorState
setCursor k ref cs = cs { _cs_cursors = Map.insert k ref (_cs_cursors cs) }

-- | Drop a conversation's cursor (a no-op if it had none). The relay map is
-- untouched.
clearCursor :: ConversationKey -> CursorState -> CursorState
clearCursor k cs = cs { _cs_cursors = Map.delete k (_cs_cursors cs) }

-- | Resolve a conversation's cursor to the slot its bound 'TabRef' currently
-- occupies (__I3__). Returns 'Nothing' when the key has no cursor or when the
-- cursor's ref is no longer present in the 'TabList' (a dangling cursor).
resolveCursorSlot :: ConversationKey -> CursorState -> TabList -> Maybe TabIndex
resolveCursorSlot k cs tl =
  case Map.lookup k (_cs_cursors cs) of
    Nothing  -> Nothing
    Just ref -> lookupRef ref tl

-- | All conversation keys whose cursor is focused on the given 'TabRef'.
conversationsOn :: TabRef -> CursorState -> [ConversationKey]
conversationsOn ref cs =
  [ k | (k, r) <- Map.toList (_cs_cursors cs), r == ref ]

-- | Drop every cursor whose 'TabRef' is no longer present in the 'TabList'.
-- Valid cursors and the entire relay map are preserved.
pruneDangling :: TabList -> CursorState -> CursorState
pruneDangling tl cs =
  cs { _cs_cursors = Map.filter present (_cs_cursors cs) }
  where
    present ref = case lookupRef ref tl of
      Just _  -> True
      Nothing -> False

-- | The 'RelayMode' for a conversation: its per-conversation override if one is
-- set, otherwise the supplied global default.
relayModeFor :: ConversationKey -> RelayMode -> CursorState -> RelayMode
relayModeFor k def cs = Map.findWithDefault def k (_cs_relay cs)

-- ---------------------------------------------------------------------------
-- @/tab@ command ADTs (parsed form)
-- ---------------------------------------------------------------------------

-- | A redacted enumeration of @TabKind@ as it appears in the @/tab new@
-- command. Local to this module to avoid an import cycle through
-- 'PureClaw.Handles.Tab' (which imports this module for 'SlashCommand'
-- in its 'TabUnsupportedCommand' constructor). WU2 introduces this type
-- alongside the @/tab@ command family; downstream WUs that need a
-- 'PureClaw.Handles.Tab.TabKind' translate via a trivial total
-- conversion at the handler layer (WU9).
data TabKindArg
  = TkaAi
  | TkaProvider
  | TkaHarness
  | TkaShell
  | TkaSsh
  | TkaTmux
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | Whether @/tab close N@ was passed the @--force@ flag.
--
-- For @KindAi@ tabs, @ForceYes@ skips the session archive on close
-- (transcript deleted from disk). For non-AI tabs the close path is
-- already destructive so the flag is a no-op semantically — the
-- distinction is preserved here so 'executeSlashCommand' (WU9) can
-- still echo what the user asked for.
data ForceMode
  = ForceNo
  | ForceYes
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | The @/tab@ command family (introduced by WU2 of Tabbed Chat #51).
--
-- Tab indices are stored as plain 'Int' rather than as
-- 'PureClaw.Handles.Tab.TabIndex' to avoid an import cycle. The parser
-- ('PureClaw.Routing.Parse.parseInput') validates the index against
-- @_rc_maxTabs@ via @mkTabIndex@ before constructing these values, so
-- callers may treat the contained 'Int' as well-formed for the
-- configured cap; downstream handlers (WU9) are still expected to
-- re-wrap via @mkTabIndex@ when crossing into 'TabIndex'-typed APIs.
--
-- @TabResumeCmd@ carries the validated 'SessionId' produced by
-- @mkSessionId@ (WU2 smart constructor).
--
-- /tmux-style packing update:/ @TabNewCmd@ no longer carries an
-- explicit target index — new tabs are always allocated at the lowest
-- free slot. The constructor's payload is therefore just the optional
-- kind keyword and the optional argument-text remainder.
data TabSlashCommand
  = TabNewCmd !(Maybe TabKindArg) !(Maybe Text)
    -- ^ @\/tab new [\<kind\> [\<arg-text\>]]@. Index is allocated at
    --   the lowest free slot by the handler (tmux-style packing). The
    --   second field is the remainder of the line after the kind,
    --   captured as a single 'Text' for the handler to split further.
  | TabListCmd
    -- ^ @\/tab list@ (and the @\/tabs@ alias).
  | TabCloseCmd !Int !ForceMode
    -- ^ @\/tab close \<N\> [--force]@. Remaining tabs are renumbered
    --   down by one starting at @N+1@ so the registry is always packed
    --   in the lowest slots (tmux @renumber-windows on@ model).
  | TabFocusCmd !Int
    -- ^ @\/tab focus \<N\>@ (functional alias of @\/N@).
  | TabResumeCmd !SessionId
    -- ^ @\/tab resume \<session-id\>@. Validation lives in
    --   @mkSessionId@; rejection surfaces as
    --   @ParseErrorInvalidSessionId@.
  | TabRenameCmd !Int !Text
    -- ^ @\/tab rename \<N\> \<name\>@. Parser captures the requested
    --   name verbatim; @sanitizeTabName@ runs at handler time per
    --   S10 so the user sees the rejection reason when applicable.
  deriving stock (Show, Eq)
