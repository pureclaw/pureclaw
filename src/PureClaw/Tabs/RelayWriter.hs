-- |
-- Module      : PureClaw.Tabs.RelayWriter
-- Description : Output-side relay writer + sink registry (Tabs-as-View, #79).
--
-- This is the __output side__ of the Tabs-as-View model (design spike §4\/§5).
-- It replaces the old global-focus @ChannelOut@ writer: instead of one focus
-- gate deciding whether a whole message reaches /the/ channel, each tab-output
-- 'ChannelEvent' is fanned out __per conversation__ via
-- 'PureClaw.Tabs.Relay.relayEvent', and the resulting per-conversation events
-- are delivered to each conversation's own 'ChannelHandle'.
--
-- Two pieces:
--
--   * __Sink registry__ ('SinkRegistry') — a @'ConversationKey' ->
--     'ChannelHandle'@ map, registered by each channel as a conversation
--     becomes active. The relay sends a conversation's output to its
--     registered sink; a /missing/ sink is a safe drop (§5).
--   * __Relay writer__ ('RelayWriter' + 'processOutput') — drives
--     'relayEvent' for one @('TabRef', 'ChannelEvent')@ at a time. It reads a
--     snapshot of the 'CursorState' and 'TabList' (the dispatcher owns those
--     IORefs), carries the burst-dedup pinged-set across events in its own
--     IORef, and routes each per-conversation event the relay produces into the
--     sink registry via 'emitToChannel'.
--
-- The 'emitToChannel' mapping is a direct port of @ChannelOut.emitEvent@
-- (which is deleted in 8c): @StreamStart@ has no on-channel representation;
-- @ChunkOf@\/@StreamEnd@ become '_ch_sendChunk' calls; @FullMsg@\/@BannerLine@
-- become '_ch_send' calls.
--
-- This module is __additive__ in 8b: it is wired into the live loop in 8c.
-- Every seam is injected, so it is fully unit-testable with fake
-- 'ChannelHandle's.
module PureClaw.Tabs.RelayWriter
  ( -- * Sink registry
    SinkRegistry
  , newSinkRegistry
  , registerSink
  , unregisterSink
  , lookupSink
    -- * Relay writer
  , RelayWriterDeps (..)
  , RelayWriter
  , newRelayWriter
  , processOutput
    -- * Event -> channel mapping
  , emitToChannel
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Channel
  ( ChannelHandle (..)
  , OutgoingMessage (..)
  , StreamChunk (..)
  )
import PureClaw.Routing.Types (ChannelEvent (..), StreamId)
import PureClaw.Tabs.Relay (BurstKey, RelayDeps (..), relayEvent)
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState
  , RelayMode
  , TabList
  , TabRef
  )

-- ---------------------------------------------------------------------------
-- Sink registry
-- ---------------------------------------------------------------------------

-- | Where each conversation's output goes: a @'ConversationKey' ->
-- 'ChannelHandle'@ map, registered by each channel as a conversation becomes
-- active. A conversation with no entry is a safe drop in 'processOutput'.
newtype SinkRegistry = SinkRegistry (IORef (Map ConversationKey ChannelHandle))

-- | A fresh, empty sink registry.
newSinkRegistry :: IO SinkRegistry
newSinkRegistry = SinkRegistry <$> newIORef Map.empty

-- | Register (or replace) the 'ChannelHandle' a conversation's output is sent
-- to.
registerSink :: SinkRegistry -> ConversationKey -> ChannelHandle -> IO ()
registerSink (SinkRegistry ref) k ch =
  atomicModifyIORef' ref (\m -> (Map.insert k ch m, ()))

-- | Drop a conversation's sink (a no-op if it had none).
unregisterSink :: SinkRegistry -> ConversationKey -> IO ()
unregisterSink (SinkRegistry ref) k =
  atomicModifyIORef' ref (\m -> (Map.delete k m, ()))

-- | Look up a conversation's registered sink.
lookupSink :: SinkRegistry -> ConversationKey -> IO (Maybe ChannelHandle)
lookupSink (SinkRegistry ref) k = Map.lookup k <$> readIORef ref

-- ---------------------------------------------------------------------------
-- Relay writer
-- ---------------------------------------------------------------------------

-- | Everything 'processOutput' needs to fan one tab-output event out.
--
-- The cursor and tab snapshots are read fresh on every 'processOutput' call —
-- the dispatcher owns those IORefs; the writer only reads them — so focus and
-- slot changes between events take effect immediately.
data RelayWriterDeps = RelayWriterDeps
  { _rw_sinks   :: !SinkRegistry
    -- ^ The conversation -> 'ChannelHandle' registry.
  , _rw_cursors :: !(IO CursorState)
    -- ^ Snapshot the current 'CursorState' (dispatcher-owned).
  , _rw_tabs    :: !(IO TabList)
    -- ^ Snapshot the current 'TabList' (tab registry).
  , _rw_default :: !RelayMode
    -- ^ The global default 'RelayMode' for conversations with no override.
  , _rw_modelOf :: !(TabRef -> IO (Maybe Text))
    -- ^ Resolve a tab's model name for the focused speaker prefix
    --   (@\/N \<model\>: @). 'Nothing' when unknown (e.g. a harness tab), so the
    --   prefix renders slot-only. Read fresh per output event for the source
    --   ref only (the only tab whose prefix is rendered).
  }

-- | The mutable state carried across 'processOutput' calls.
--
-- '_rw_pinged' is the burst-dedup set: the @('ConversationKey', 'BurstKey')@
-- pairs already activity-pinged. The relay's 'ActivityDigest' decision keys on
-- this so a multi-chunk stream pings once, and refocus clears a conversation's
-- entries (so a later background burst pings again).
--
-- '_rw_buffer' is the per-stream accumulation buffer for __non-streaming__
-- channels (Signal\/Telegram, @'_ch_streaming' = False@). Those channels
-- discard '_ch_sendChunk', so a streamed provider reply would be lost entirely.
-- Instead the writer accumulates each stream's 'ChunkOf' text keyed by
-- @('ConversationKey', 'StreamId')@ and flushes it as ONE '_ch_send' on
-- 'StreamEnd' — restoring the legacy full-send. Streaming channels never touch
-- this buffer.
data RelayWriter = RelayWriter
  { _rw_pinged :: !(IORef (Set (ConversationKey, BurstKey)))
  , _rw_buffer :: !(IORef (Map (ConversationKey, StreamId) Text))
  }

-- | A fresh relay writer with an empty pinged-set and an empty stream buffer.
newRelayWriter :: IO RelayWriter
newRelayWriter =
  RelayWriter <$> newIORef Set.empty <*> newIORef Map.empty

-- | Process ONE tab-output event: fan it out per conversation via
-- 'relayEvent', delivering each resulting per-conversation event to that
-- conversation's registered sink (via 'emitToChannel'). A conversation with no
-- registered sink is a safe drop.
--
-- Reads the cursor + tab snapshots and the writer's carried pinged-set, runs
-- the relay decision, then writes the updated pinged-set back so burst dedup
-- persists across calls.
processOutput :: RelayWriterDeps -> RelayWriter -> TabRef -> ChannelEvent -> IO ()
processOutput deps rw src event = do
  cursors  <- _rw_cursors deps
  tabs     <- _rw_tabs deps
  srcModel <- _rw_modelOf deps src
  pinged   <- readIORef (_rw_pinged rw)
  let sink = RelayDeps $ \convKey ev ->
        lookupSink (_rw_sinks deps) convKey
          >>= maybe (pure ()) (\ch -> emitToConversation (_rw_buffer rw) convKey ch ev)
  pinged' <- relayEvent sink cursors (_rw_default deps) tabs srcModel pinged src event
  writeIORef (_rw_pinged rw) pinged'

-- | Deliver one per-conversation 'ChannelEvent' to its sink, honoring the
-- channel's '_ch_streaming' capability.
--
--   * __Streaming channel__ (@'_ch_streaming' = True@, e.g. CLI): unchanged —
--     defer to 'emitToChannel', which streams 'ChunkOf'\/'StreamEnd' via
--     '_ch_sendChunk'.
--   * __Non-streaming channel__ (@'_ch_streaming' = False@, e.g.
--     Signal\/Telegram): '_ch_sendChunk' is a no-op on the real channel, so
--     buffer each stream's 'ChunkOf' text keyed by @('ConversationKey',
--     'StreamId')@ and flush it as ONE '_ch_send' on 'StreamEnd' (dropping an
--     empty stream). 'StreamStart' just primes an empty buffer entry;
--     'FullMsg'\/'BannerLine' send a full message directly.
--
-- Note: in a multi-tab session the relay injects the focused speaker prefix
-- (@\/N \<model\>: @) as the first 'ChunkOf' after 'StreamStart' (see
-- "PureClaw.Tabs.Relay"), so a stream that carries NO content chunks still
-- buffers the prefix and flushes a content-free @\/N \<model\>: @ message
-- rather than being dropped. This only affects the degenerate text-less stream;
-- a single-tab session injects no prefix and still drops an empty stream.
emitToConversation
  :: IORef (Map (ConversationKey, StreamId) Text)
  -> ConversationKey
  -> ChannelHandle
  -> ChannelEvent
  -> IO ()
emitToConversation bufRef convKey ch ev
  | _ch_streaming ch = emitToChannel ch ev
  | otherwise = case ev of
      StreamStart sid _ ->
        atomicModifyIORef' bufRef
          (\m -> (Map.insertWith (\_ old -> old) (convKey, sid) "" m, ()))
      ChunkOf sid t ->
        -- 'flip (<>)' so the existing buffered text precedes the new chunk:
        -- Map.insertWith f applies @f new old@, so @flip (<>) new old = old <> new@.
        atomicModifyIORef' bufRef
          (\m -> (Map.insertWith (flip (<>)) (convKey, sid) t m, ()))
      StreamEnd sid -> do
        buffered <- atomicModifyIORef' bufRef
          (\m -> (Map.delete (convKey, sid) m, Map.lookup (convKey, sid) m))
        case buffered of
          Just full | not (T.null full) -> _ch_send ch (OutgoingMessage full)
          _                                      -> pure ()
      FullMsg _ t  -> _ch_send ch (OutgoingMessage t)
      BannerLine t -> _ch_send ch (OutgoingMessage t)

-- ---------------------------------------------------------------------------
-- Event -> channel mapping
-- ---------------------------------------------------------------------------

-- | Translate a 'ChannelEvent' into the underlying 'ChannelHandle' calls. A
-- direct port of @ChannelOut.emitEvent@ (deleted in 8c): 'StreamStart' is
-- writer-state metadata with no on-channel representation; 'ChunkOf' and
-- 'StreamEnd' stream via '_ch_sendChunk'; 'FullMsg' and 'BannerLine' send a
-- full message via '_ch_send'.
emitToChannel :: ChannelHandle -> ChannelEvent -> IO ()
emitToChannel ch ev = case ev of
  StreamStart{} -> pure ()
  ChunkOf _ t   -> _ch_sendChunk ch (ChunkText t)
  StreamEnd _   -> _ch_sendChunk ch ChunkDone
  FullMsg _ t   -> _ch_send ch (OutgoingMessage t)
  BannerLine t  -> _ch_send ch (OutgoingMessage t)
