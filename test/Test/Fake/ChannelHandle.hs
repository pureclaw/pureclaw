-- |
-- Module      : Test.Fake.ChannelHandle
-- Description : T2 — recording 'ChannelHandle' test seam used by tabbed-chat specs.
--
-- A 'ChannelHandle' implementation that records every outbound emission
-- ('_ch_send', '_ch_sendError', '_ch_sendChunk', '_ch_prompt') into a
-- timestamped 'TVar' log and reads inbound messages from an injectable
-- 'TQueue'. Used by D1, D3, D4, D5, B-series, and any spec that needs to
-- observe what reached the channel under varying focus state.
--
-- See @docs/tabbed-chat.md@ §"Test seams (T-series)" T2.
module Test.Fake.ChannelHandle
  ( -- * Recorded events
    FakeChannelEvent (..)
    -- * Fake channel
  , FakeChannel
  , newFakeChannel
  , fakeChannelHandle
    -- * Inputs (injectable)
  , feedIncoming
  , feedIncomingFromUser
    -- * Outputs (inspection)
  , drainEvents
  , peekEvents
  , clearEvents
  ) where

import Control.Concurrent.STM
  ( STM
  , TQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTQueueIO
  , newTVarIO
  , readTQueue
  , readTVar
  , readTVarIO
  , writeTQueue
  , writeTVar
  )
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel

-- | A recorded outbound channel event, paired with the UTC time it was
-- emitted. Mirrors the variants tab loops and the dispatcher write through
-- 'ChannelHandle'.
data FakeChannelEvent
  = FceSend !OutgoingMessage
  | FceSendError !PublicError
  | FceSendChunk !StreamChunk
  | FcePrompt !Text
  | FcePromptSecret !Text
  deriving (Show, Eq)

-- | Fake channel state — recorded outbound events plus the injectable
-- incoming queue.
data FakeChannel = FakeChannel
  { _fch_incoming :: !(TQueue IncomingMessage)
  , _fch_events   :: !(TVar [(UTCTime, FakeChannelEvent)])
  , _fch_secret   :: !(TVar Text)
  }

-- | Create a fresh fake channel with an empty incoming queue and event log.
newFakeChannel :: IO FakeChannel
newFakeChannel = FakeChannel
  <$> newTQueueIO
  <*> newTVarIO []
  <*> newTVarIO ""

-- | Project a 'FakeChannel' into a 'ChannelHandle' suitable for handing to
-- the dispatcher under test.
fakeChannelHandle :: FakeChannel -> ChannelHandle
fakeChannelHandle fch = ChannelHandle
  { _ch_receive      = atomically (readTQueue (_fch_incoming fch))
  , _ch_send         = recordEvent fch . FceSend
  , _ch_sendError    = recordEvent fch . FceSendError
  , _ch_sendChunk    = recordEvent fch . FceSendChunk
  , _ch_streaming    = True
  , _ch_readSecret   = readTVarIO (_fch_secret fch)
  , _ch_prompt       = \p -> do
      recordEvent fch (FcePrompt p)
      _im_content <$> atomically (readTQueue (_fch_incoming fch))
  , _ch_promptSecret = \p -> do
      recordEvent fch (FcePromptSecret p)
      readTVarIO (_fch_secret fch)
  }

-- | Inject one 'IncomingMessage' into the channel.
feedIncoming :: FakeChannel -> IncomingMessage -> IO ()
feedIncoming fch im = atomically (writeTQueue (_fch_incoming fch) im)

-- | Convenience: inject an incoming message from a given user with the
-- supplied text.
feedIncomingFromUser :: FakeChannel -> UserId -> Text -> IO ()
feedIncomingFromUser fch uid t =
  feedIncoming fch
    (IncomingMessage (mkMessageSource (CkOther "test") (ConversationId "test") (Just uid) mempty) t)

-- | Atomically drain all recorded events (oldest-first) and clear the log.
drainEvents :: FakeChannel -> IO [(UTCTime, FakeChannelEvent)]
drainEvents fch = atomically $ do
  es <- recordedEventsSTM fch
  writeTVar (_fch_events fch) []
  pure (reverse es)

-- | Peek at recorded events without clearing.
peekEvents :: FakeChannel -> IO [(UTCTime, FakeChannelEvent)]
peekEvents fch = reverse <$> readTVarIO (_fch_events fch)

-- | Clear the recorded event log without inspecting.
clearEvents :: FakeChannel -> IO ()
clearEvents fch = atomically (writeTVar (_fch_events fch) [])

-- Internal helpers

recordEvent :: FakeChannel -> FakeChannelEvent -> IO ()
recordEvent fch ev = do
  t <- getCurrentTime
  atomically (modifyTVar' (_fch_events fch) ((t, ev) :))

recordedEventsSTM :: FakeChannel -> STM [(UTCTime, FakeChannelEvent)]
recordedEventsSTM fch = readTVar (_fch_events fch)
