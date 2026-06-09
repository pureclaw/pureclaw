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

import PureClaw.Handles.Channel
  ( ChannelHandle (..)
  , OutgoingMessage (..)
  , StreamChunk (..)
  )
import PureClaw.Routing.Types (ChannelEvent (..))
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
  }

-- | The burst-dedup state carried across 'processOutput' calls: the set of
-- @('ConversationKey', 'BurstKey')@ pairs already activity-pinged. The relay's
-- 'ActivityDigest' decision keys on this so a multi-chunk stream pings once,
-- and refocus clears a conversation's entries (so a later background burst
-- pings again).
newtype RelayWriter = RelayWriter (IORef (Set (ConversationKey, BurstKey)))

-- | A fresh relay writer with an empty pinged-set.
newRelayWriter :: IO RelayWriter
newRelayWriter = RelayWriter <$> newIORef Set.empty

-- | Process ONE tab-output event: fan it out per conversation via
-- 'relayEvent', delivering each resulting per-conversation event to that
-- conversation's registered sink (via 'emitToChannel'). A conversation with no
-- registered sink is a safe drop.
--
-- Reads the cursor + tab snapshots and the writer's carried pinged-set, runs
-- the relay decision, then writes the updated pinged-set back so burst dedup
-- persists across calls.
processOutput :: RelayWriterDeps -> RelayWriter -> TabRef -> ChannelEvent -> IO ()
processOutput deps (RelayWriter pingedRef) src event = do
  cursors <- _rw_cursors deps
  tabs    <- _rw_tabs deps
  pinged  <- readIORef pingedRef
  let sink = RelayDeps $ \convKey ev ->
        lookupSink (_rw_sinks deps) convKey
          >>= maybe (pure ()) (`emitToChannel` ev)
  pinged' <- relayEvent sink cursors (_rw_default deps) tabs pinged src event
  writeIORef pingedRef pinged'

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
