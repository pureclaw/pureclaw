-- |
-- Module      : PureClaw.Tabs.Relay
-- Description : Per-conversation output relay engine (Tabs-as-View, GitHub #79).
--
-- When a tab (named by its 'TabRef') emits output, 'relayOutput' fans that
-- output out to every conversation according to /that conversation's/
-- effective 'RelayMode' (its per-conversation override, else the global
-- default). This replaces the single-focus @ChannelOut@ gate
-- (@shouldEmit@): a tab can be foreground for conversation A and background
-- for B at the same time, so the decision is taken per conversation rather
-- than once for the whole output (design §9.3).
--
-- The engine is a __single writer__: the dispatcher invokes it from one
-- thread, and it iterates conversations in a deterministic (sorted-key) order,
-- calling the injected sink in turn. There is no concurrency inside the
-- engine — ordering across the per-conversation sinks is preserved exactly as
-- @ChannelOut@ guaranteed.
--
-- == Per-conversation decision (effective mode @m@ for key @k@)
--
-- Let @focused@ mean the conversation's cursor names the source tab.
--
--   * __FocusedOnly__ — deliver the full text iff @focused@; otherwise nothing.
--   * __Firehose__ — always deliver the full text, regardless of cursor.
--   * __ActivityDigest__ — if @focused@, deliver the full text; otherwise, if
--     @k@ has not already been pinged for this tab since it last focused it,
--     deliver a name-first activity ping and remember @k@. A repeat background
--     burst is suppressed (one ping per burst). The ping names the tab by its
--     friendly name first and its /current/ display slot second
--     (@\"\<name\> (\/N) has new output\"@), because slots renumber under
--     compaction (§8). A 'Dead' tombstone source still pings (§8) — only a
--     source ref /absent/ from the list yields no ping (no name\/slot to show).
--
-- Delivering the full text to a focused conversation (cursor == source) clears
-- that conversation's pinged membership: it is now looking at the tab, so a
-- future background burst should ping it again.
--
-- The set of conversations considered is every key present in the
-- 'CursorState' — the union of the cursor-map keys and the relay-override-map
-- keys — so a conversation that has only set a 'RelayMode' (no cursor yet) is
-- still routed.
module PureClaw.Tabs.Relay
  ( RelayDeps (..)
  , relayOutput
  ) where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Tab (unTabIndex)
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , RelayMode (..)
  , Tab (..)
  , TabList
  , TabRef
  , lookupRef
  , lookupSlot
  , relayModeFor
  )

-- | The relay engine's only side-effect seam: a conversation-addressed output
-- sink. @'_rl_sink' k t@ delivers text @t@ to conversation @k@. Injected so
-- the engine can be unit-tested against a recording sink.
newtype RelayDeps = RelayDeps
  { _rl_sink :: ConversationKey -> Text -> IO ()
  }

-- | Fan one tab's output out to every conversation per its effective
-- 'RelayMode'. See the module header for the full per-conversation decision.
--
-- @globalDefault@ is the fallback 'RelayMode' for conversations with no
-- override. @pinged@ is the set of conversations already activity-pinged for
-- /this/ source tab since they last focused it (burst de-dup for
-- 'ActivityDigest'); the updated set is returned.
relayOutput
  :: RelayDeps
  -> CursorState
  -> RelayMode
  -> TabList
  -> Set ConversationKey
  -> TabRef
  -> Text
  -> IO (Set ConversationKey)
relayOutput deps cs globalDefault tl pinged src text =
    go pinged conversationKeys
  where
    -- Every conversation the dispatcher knows about: keys with a cursor or a
    -- relay override. Sorted so the single-writer emission order is testable.
    conversationKeys :: [ConversationKey]
    conversationKeys =
      Set.toAscList
        (Set.fromList (Map.keys (_cs_cursors cs))
           `Set.union` Set.fromList (Map.keys (_cs_relay cs)))

    -- The source tab's current display slot (0-based), if it is in the list.
    srcSlot :: Maybe Int
    srcSlot = unTabIndex <$> lookupRef src tl

    -- The source tab's friendly name, if it is in the list.
    srcName :: Maybe Text
    srcName = do
      i <- lookupRef src tl
      _tab_name <$> lookupSlot i tl

    -- A name-first activity ping for the source tab at its current slot.
    -- 'Nothing' when the source ref is absent (no name/slot to render).
    activityPing :: Maybe Text
    activityPing = do
      name <- srcName
      slot <- srcSlot
      pure (name <> " (/" <> T.pack (show slot) <> ") has new output")

    deliver :: ConversationKey -> Text -> IO ()
    deliver = _rl_sink deps

    go :: Set ConversationKey -> [ConversationKey] -> IO (Set ConversationKey)
    go acc []       = pure acc
    go acc (k : ks) = do
      acc' <-
        if Map.lookup k (_cs_cursors cs) == Just src
          -- Focused on the source tab: deliver the full text in every mode,
          -- and clear this conversation's pinged membership (it is now looking
          -- at the tab, so a future background burst should ping it again).
          then deliver k text >> pure (Set.delete k acc)
          -- Background: behaviour depends on the conversation's effective mode.
          else case relayModeFor k globalDefault cs of
            FocusedOnly    -> pure acc
            Firehose       -> deliver k text >> pure acc
            ActivityDigest -> backgroundDigest acc k
      go acc' ks

    -- ActivityDigest for a background conversation: one name-first ping per
    -- burst. Suppressed when @k@ was already pinged for this tab, or when the
    -- source ref is absent from the list (no name\/slot to render).
    backgroundDigest
      :: Set ConversationKey -> ConversationKey -> IO (Set ConversationKey)
    backgroundDigest acc k
      | k `Set.member` acc = pure acc
      | otherwise          = case activityPing of
          Just p  -> deliver k p >> pure (Set.insert k acc)
          Nothing -> pure acc
