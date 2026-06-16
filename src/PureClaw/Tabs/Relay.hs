-- |
-- Module      : PureClaw.Tabs.Relay
-- Description : Streaming-aware per-conversation output relay (Tabs-as-View, #79).
--
-- When a tab (named by its 'TabRef') emits a 'ChannelEvent', 'relayEvent' fans
-- that event out to every conversation according to /that conversation's/
-- effective 'RelayMode' (its per-conversation override, else the global
-- default). This replaces the single-focus @ChannelOut@ gate (@shouldEmit@): a
-- tab can be foreground for conversation A and background for B at the same
-- time, so the decision is taken per conversation rather than once for the
-- whole output (design §9.3).
--
-- Unlike the earlier whole-@Text@ relay, this engine is __streaming-aware__:
-- it sinks a 'ChannelEvent', so a focused conversation receives every
-- @StreamStart@\/@ChunkOf@\/@StreamEnd@ verbatim (full provider streaming),
-- while a background 'ActivityDigest' conversation gets __at most one__
-- breadcrumb ping per /burst/ — one logical message. The burst is identified
-- by a 'BurstKey': all framing events of one stream share @'BurstStream' sid@,
-- and a one-shot @FullMsg@ is its own @'BurstFull'@ burst. The pinged-set is
-- keyed on @('ConversationKey', 'BurstKey')@ so a 100-chunk stream pings once,
-- not 100 times (§4).
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
--   * __Focused__ (any mode) — forward the event, MERGING a one-shot
--     @\"\/N \<model\>: \"@ speaker prefix into the burst-start when more than
--     one tab exists (prepended to a @FullMsg@, injected as the first @ChunkOf@
--     after a @StreamStart@; mid-burst\/banner events pass verbatim). Also clear
--     /every/ @(k, _)@ entry from the pinged-set: the conversation is looking at
--     the tab, so a future background burst should ping it again.
--   * __FocusedOnly__ background — nothing.
--   * __Firehose__ background — forward the event verbatim.
--   * __ActivityDigest__ background — emit at most one ping per burst. A
--     'BannerLine' source event is skipped entirely (banners are
--     dispatcher-class, never relayed here): no ping, set untouched. For a
--     stream\/full event, if @(k, burstKey)@ is not already pinged AND the
--     source ref resolves in the 'TabList', deliver a 'BannerLine' ping
--     (@\"\<name\> (\/N) has new output\"@, where @\<name\>@ is the source
--     tab's friendly name and @N@ its /current/ display slot) and remember
--     @(k, burstKey)@. A 'Dead' tombstone source still pings (§8) — only a
--     source ref /absent/ from the list yields no ping (no name\/slot).
--
-- The set of conversations considered is every key present in the
-- 'CursorState' — the union of the cursor-map keys and the relay-override-map
-- keys — so a conversation that has only set a 'RelayMode' (no cursor yet) is
-- still routed.
module PureClaw.Tabs.Relay
  ( BurstKey (..)
  , RelayDeps (..)
  , relayEvent
  ) where

import Control.Monad (guard)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Tab (unTabIndex)
import PureClaw.Routing.Types (ChannelEvent (..), StreamId)
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , RelayMode (..)
  , TabList
  , TabRef
  , lookupRef
  , relayModeFor
  , toList
  )

-- | The /burst/ a 'ChannelEvent' belongs to — one logical message. All framing
-- events of a single provider stream (@StreamStart@\/@ChunkOf@\/@StreamEnd@)
-- share the same @'BurstStream' sid@; a one-shot @FullMsg@ is its own
-- @'BurstFull'@ burst. 'ActivityDigest' de-dups its background ping on
-- @('ConversationKey', 'BurstKey')@, so a multi-chunk stream pings once.
data BurstKey
  = BurstStream !StreamId
  | BurstFull
  deriving stock (Eq, Ord, Show)

-- | The relay engine's only side-effect seam: a conversation-addressed output
-- sink. @'_rl_sink' k e@ delivers event @e@ to conversation @k@. Injected so
-- the engine can be unit-tested against a recording sink.
newtype RelayDeps = RelayDeps
  { _rl_sink :: ConversationKey -> ChannelEvent -> IO ()
  }

-- | The burst a 'ChannelEvent' belongs to, or 'Nothing' for a 'BannerLine'
-- (banners are dispatcher-class and never relayed to background conversations).
burstKeyOf :: ChannelEvent -> Maybe BurstKey
burstKeyOf = \case
  StreamStart sid _ -> Just (BurstStream sid)
  ChunkOf sid _     -> Just (BurstStream sid)
  StreamEnd sid     -> Just (BurstStream sid)
  FullMsg _ _       -> Just BurstFull
  BannerLine _      -> Nothing

-- | Fan one tab's 'ChannelEvent' out to every conversation per its effective
-- 'RelayMode'. See the module header for the full per-conversation decision.
--
-- @globalDefault@ is the fallback 'RelayMode' for conversations with no
-- override. @pinged@ is the set of @('ConversationKey', 'BurstKey')@ pairs
-- already activity-pinged (burst de-dup for 'ActivityDigest'); the updated set
-- is returned.
relayEvent
  :: RelayDeps
  -> CursorState
  -> RelayMode
  -> TabList
  -> Maybe Text
     -- ^ The source tab's model name, used to render the focused speaker prefix
     --   (@\/N \<model\>: @). 'Nothing' when unknown (e.g. a harness tab), in
     --   which case the prefix is slot-only (@\/N: @).
  -> Set (ConversationKey, BurstKey)
  -> TabRef
  -> ChannelEvent
  -> IO (Set (ConversationKey, BurstKey))
relayEvent deps cs globalDefault tl srcModel pinged src event =
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

    -- A slot-keyed activity ping for the source tab, as a 'BannerLine'.
    -- 'Nothing' when the source ref is absent (no slot). Tabs carry no label of
    -- their own anymore, so the source is named by its current slot.
    activityPing :: Maybe ChannelEvent
    activityPing = do
      slot <- srcSlot
      pure (BannerLine ("/" <> T.pack (show slot) <> " has new output"))

    -- How many tabs exist right now. A single-tab CLI stays unlabelled; a
    -- multi-tab session labels focused bursts so the speaker is identifiable.
    tabCount :: Int
    tabCount = length (toList tl)

    -- The speaker prefix to MERGE into a focused burst-start, or 'Nothing' when
    -- only one tab exists or the source ref has no slot. Rendered as
    -- @\/N \<model\>: @: the slot the source tab currently occupies, then the
    -- source model when known (omitted for a harness tab / unresolved model),
    -- then a @": "@ separator before the content. Tabs carry no label of their
    -- own, so the source is named by its current slot.
    speakerPrefix :: Maybe Text
    speakerPrefix = do
      slot <- srcSlot
      guard (tabCount > 1)
      pure ("/" <> T.pack (show slot) <> maybe "" (" " <>) srcModel <> ": ")

    deliver :: ConversationKey -> ChannelEvent -> IO ()
    deliver = _rl_sink deps

    -- Forward the event to a focused conversation, MERGING a one-shot speaker
    -- prefix into the START of a burst when more than one tab exists. The prefix
    -- is prepended to a 'FullMsg' and injected as the first 'ChunkOf' right
    -- after a 'StreamStart' — so a streamed reply renders the speaker inline,
    -- and a non-streaming channel buffers it into the one flushed message.
    -- Mid-burst 'ChunkOf'\/'StreamEnd' and 'BannerLine' events forward verbatim,
    -- so a multi-chunk reply is prefixed exactly once. A single-tab session is
    -- never prefixed (clean CLI, the gb7 decision).
    deliverFocused :: ConversationKey -> IO ()
    deliverFocused k = mapM_ (deliver k) (focusedEvents event)

    -- The event(s) to deliver to a focused conversation for @ev@: the
    -- burst-start carrying the merged speaker prefix when 'speakerPrefix' is
    -- 'Just', else the event verbatim. A 'StreamStart' becomes the start plus an
    -- injected prefix chunk; a 'FullMsg' has the prefix prepended to its text.
    -- 'ChunkOf'\/'StreamEnd'\/'BannerLine' are always forwarded verbatim.
    focusedEvents :: ChannelEvent -> [ChannelEvent]
    focusedEvents ev = case ev of
      StreamStart sid tix -> case speakerPrefix of
        Just pfx -> [StreamStart sid tix, ChunkOf sid pfx]
        Nothing  -> [ev]
      FullMsg tix t -> case speakerPrefix of
        Just pfx -> [FullMsg tix (pfx <> t)]
        Nothing  -> [ev]
      ChunkOf {}    -> [ev]
      StreamEnd {}  -> [ev]
      BannerLine {} -> [ev]

    go
      :: Set (ConversationKey, BurstKey)
      -> [ConversationKey]
      -> IO (Set (ConversationKey, BurstKey))
    go acc []       = pure acc
    go acc (k : ks) = do
      acc' <-
        if Map.lookup k (_cs_cursors cs) == Just src
          -- Focused on the source tab: forward the event verbatim in every
          -- mode, and clear ALL of this conversation's burst entries (it is
          -- now looking at the tab, so a future background burst should ping).
          then deliverFocused k >> pure (clearKey k acc)
          -- Background: behaviour depends on the conversation's effective mode.
          else case relayModeFor k globalDefault cs of
            FocusedOnly    -> pure acc
            Firehose       -> deliver k event >> pure acc
            ActivityDigest -> backgroundDigest acc k
      go acc' ks

    -- Drop every @(k, _)@ burst entry for conversation @k@.
    clearKey
      :: ConversationKey
      -> Set (ConversationKey, BurstKey)
      -> Set (ConversationKey, BurstKey)
    clearKey k = Set.filter ((/= k) . fst)

    -- ActivityDigest for a background conversation: one name-first ping per
    -- burst. A 'BannerLine' source is skipped (no burst, set untouched).
    -- Otherwise suppressed when @(k, burstKey)@ was already pinged, or when the
    -- source ref is absent from the list (no name/slot to render).
    backgroundDigest
      :: Set (ConversationKey, BurstKey)
      -> ConversationKey
      -> IO (Set (ConversationKey, BurstKey))
    backgroundDigest acc k = case burstKeyOf event of
      Nothing -> pure acc
      Just bk
        | (k, bk) `Set.member` acc -> pure acc
        | otherwise -> case activityPing of
            Just p  -> deliver k p >> pure (Set.insert (k, bk) acc)
            Nothing -> pure acc
