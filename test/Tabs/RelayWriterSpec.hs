-- |
-- Module      : Tabs.RelayWriterSpec
-- Description : Output-side relay writer + sink registry (Tabs-as-View, #79, 8b.3a).
--
-- Covers the stage 8b.3a Definition-of-Done items. 'processOutput' fans one
-- tab's 'ChannelEvent' out, per conversation, via 'PureClaw.Tabs.Relay.relayEvent'
-- and delivers the resulting per-conversation events to each conversation's
-- registered 'ChannelHandle' (the 'emitToChannel' mapping). It replaces the
-- old global-focus @ChannelOut@ writer.
--
--   1. Focused conversation: a streamed burst (StreamStart, ChunkOf x2,
--      StreamEnd) reaches a focused conversation's sink as the right channel
--      calls (no-op, sendChunk ChunkText x2, sendChunk ChunkDone).
--   2. ActivityDigest background: exactly ONE BannerLine ping (-> _ch_send)
--      across the whole stream burst.
--   3. FocusedOnly background: no channel calls.
--   4. Firehose background: full stream delivered to its sink.
--   5. Missing sink: a conversation with a cursor but no registered sink is a
--      safe drop; other conversations are still served.
--   6. Burst dedup persists across 'processOutput' calls; refocus clears, so a
--      new background burst pings again.
--   7. 'emitToChannel' maps each 'ChannelEvent' constructor to the right
--      'ChannelHandle' call.
--   8. SinkRegistry register/lookup/unregister round-trip.
module Tabs.RelayWriterSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), SessionId (..))
import PureClaw.Handles.Channel
  ( ChannelHandle (..)
  , OutgoingMessage (..)
  , StreamChunk (..)
  , mkNoOpChannelHandle
  )
import PureClaw.Handles.Tab (TabIndex, mkTabIndex)
import PureClaw.Routing.Types (ChannelEvent (..), StreamId, mkStreamId)

import PureClaw.Tabs.RelayWriter
  ( RelayWriterDeps (..)
  , emitToChannel
  , lookupSink
  , newRelayWriter
  , newSinkRegistry
  , processOutput
  , registerSink
  , unregisterSink
  )
import PureClaw.Tabs.Types
  ( ConversationKey
  , RelayMode (..)
  , TabList
  , TabRef (..)
  , appendTab
  , emptyCursors
  , emptyTabs
  , setCursor
  )

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A distinct session-backed 'TabRef' for index @n@.
refN :: Int -> TabRef
refN n = BoundSession (SessionId ("s" <> T.pack (show n)))

-- | A distinct 'ConversationKey' for index @n@ (all on CLI; ids differ).
keyN :: Int -> ConversationKey
keyN n = (CkCli, ConversationId ("c" <> T.pack (show n)))

-- | A 'StreamId' for index @n@.
sidN :: Int -> StreamId
sidN n = mkStreamId (fromIntegral n)

-- | A valid 'TabIndex' from a small literal (panics on the impossible-here
-- out-of-range case).
idx :: Int -> TabIndex
idx n = case mkTabIndex n of
  Just i  -> i
  Nothing -> error ("idx: out of range " <> show n)

-- | An arbitrary 'TabIndex' to tag stream\/full events; the writer ignores it.
anyIdx :: TabIndex
anyIdx = idx 0

-- | Append a named tab, panicking on the impossible-here error.
append1 :: TabRef -> Text -> TabList -> TabList
append1 ref name tl = case appendTab ref name tl of
  Right (_, tl') -> tl'
  Left e         -> error ("append1: " <> show e)

-- | A single tab list with one named tab at slot 0.
oneTab :: TabRef -> TabList
oneTab ref = append1 ref "alpha" emptyTabs

-- | One recorded call against a fake 'ChannelHandle'.
data Call
  = Sent OutgoingMessage
  | SentChunk StreamChunk
  deriving (Eq, Show)

-- | A fake 'ChannelHandle' that records '_ch_send' / '_ch_sendChunk' calls (in
-- order) into a fresh 'IORef', based on the no-op handle (all other fields
-- inherited).
newRecordingHandle :: IO (IORef [Call], ChannelHandle)
newRecordingHandle = do
  ref <- newIORef []
  let ch = mkNoOpChannelHandle
        { _ch_send      = \m -> modifyIORef' ref (++ [Sent m])
        , _ch_sendChunk = \c -> modifyIORef' ref (++ [SentChunk c])
        }
  pure (ref, ch)

-- | The streamed burst used by several tests: StreamStart, ChunkOf x2,
-- StreamEnd, all on stream @sidN 1@.
streamBurst :: [ChannelEvent]
streamBurst =
  [ StreamStart (sidN 1) anyIdx
  , ChunkOf (sidN 1) "he"
  , ChunkOf (sidN 1) "llo"
  , StreamEnd (sidN 1)
  ]

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "SinkRegistry" $ do
    it "register / lookup / unregister round-trips (DoD 8)" $ do
      reg <- newSinkRegistry
      (_, ch) <- newRecordingHandle
      pre <- lookupSink reg (keyN 0)
      isNothingHandle pre `shouldBe` True
      registerSink reg (keyN 0) ch
      post <- lookupSink reg (keyN 0)
      isNothingHandle post `shouldBe` False
      unregisterSink reg (keyN 0)
      gone <- lookupSink reg (keyN 0)
      isNothingHandle gone `shouldBe` True

  describe "emitToChannel mapping (DoD 7)" $ do
    it "StreamStart is a no-op" $ do
      (calls, ch) <- newRecordingHandle
      emitToChannel ch (StreamStart (sidN 1) anyIdx)
      readIORef calls `shouldReturn` []
    it "ChunkOf -> sendChunk (ChunkText)" $ do
      (calls, ch) <- newRecordingHandle
      emitToChannel ch (ChunkOf (sidN 1) "hi")
      readIORef calls `shouldReturn` [SentChunk (ChunkText "hi")]
    it "StreamEnd -> sendChunk ChunkDone" $ do
      (calls, ch) <- newRecordingHandle
      emitToChannel ch (StreamEnd (sidN 1))
      readIORef calls `shouldReturn` [SentChunk ChunkDone]
    it "FullMsg -> send OutgoingMessage" $ do
      (calls, ch) <- newRecordingHandle
      emitToChannel ch (FullMsg anyIdx "full")
      readIORef calls `shouldReturn` [Sent (OutgoingMessage "full")]
    it "BannerLine -> send OutgoingMessage" $ do
      (calls, ch) <- newRecordingHandle
      emitToChannel ch (BannerLine "banner")
      readIORef calls `shouldReturn` [Sent (OutgoingMessage "banner")]

  describe "processOutput" $ do
    it "delivers a focused stream burst verbatim (DoD 1)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      registerSink reg (keyN 0) ch
      let cs   = setCursor (keyN 0) (refN 0) emptyCursors
          tabs = oneTab (refN 0)
          deps = RelayWriterDeps reg (pure cs) (pure tabs) FocusedOnly
      w <- newRelayWriter
      mapM_ (processOutput deps w (refN 0)) streamBurst
      readIORef calls `shouldReturn`
        [ SentChunk (ChunkText "he")
        , SentChunk (ChunkText "llo")
        , SentChunk ChunkDone
        ]

    it "ActivityDigest background pings exactly once over a burst (DoD 2)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      registerSink reg (keyN 1) ch
      -- keyN 1 is NOT focused on the source ref; default ActivityDigest.
      let cs   = setCursor (keyN 1) (refN 9) emptyCursors
          tabs = oneTab (refN 0)
          deps = RelayWriterDeps reg (pure cs) (pure tabs) ActivityDigest
      w <- newRelayWriter
      mapM_ (processOutput deps w (refN 0)) streamBurst
      recorded <- readIORef calls
      length recorded `shouldBe` 1
      recorded `shouldBe` [Sent (OutgoingMessage "alpha (/0) has new output")]

    it "FocusedOnly background gets no channel calls (DoD 3)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      registerSink reg (keyN 1) ch
      let cs   = setCursor (keyN 1) (refN 9) emptyCursors
          tabs = oneTab (refN 0)
          deps = RelayWriterDeps reg (pure cs) (pure tabs) FocusedOnly
      w <- newRelayWriter
      mapM_ (processOutput deps w (refN 0)) streamBurst
      readIORef calls `shouldReturn` []

    it "Firehose background gets the full stream (DoD 4)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      registerSink reg (keyN 1) ch
      let cs   = setCursor (keyN 1) (refN 9) emptyCursors
          tabs = oneTab (refN 0)
          deps = RelayWriterDeps reg (pure cs) (pure tabs) Firehose
      w <- newRelayWriter
      mapM_ (processOutput deps w (refN 0)) streamBurst
      readIORef calls `shouldReturn`
        [ SentChunk (ChunkText "he")
        , SentChunk (ChunkText "llo")
        , SentChunk ChunkDone
        ]

    it "missing sink is a safe drop; other conversations still served (DoD 5)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      -- keyN 0 is focused but has NO registered sink; keyN 1 is focused and HAS one.
      registerSink reg (keyN 1) ch
      let cs   = setCursor (keyN 0) (refN 0)
                   (setCursor (keyN 1) (refN 0) emptyCursors)
          tabs = oneTab (refN 0)
          deps = RelayWriterDeps reg (pure cs) (pure tabs) FocusedOnly
      w <- newRelayWriter
      mapM_ (processOutput deps w (refN 0)) streamBurst
      readIORef calls `shouldReturn`
        [ SentChunk (ChunkText "he")
        , SentChunk (ChunkText "llo")
        , SentChunk ChunkDone
        ]

    it "burst dedup persists across calls; refocus clears (DoD 6)" $ do
      reg <- newSinkRegistry
      (calls, ch) <- newRecordingHandle
      registerSink reg (keyN 1) ch
      let tabs = oneTab (refN 0)
          -- Phase A: keyN 1 background (focused elsewhere), ActivityDigest.
          csBg = setCursor (keyN 1) (refN 9) emptyCursors
          depsBg = RelayWriterDeps reg (pure csBg) (pure tabs) ActivityDigest
      w <- newRelayWriter
      -- First burst (sid 1): exactly one ping.
      mapM_ (processOutput depsBg w (refN 0)) streamBurst
      afterFirst <- readIORef calls
      length afterFirst `shouldBe` 1
      -- A SECOND event of the SAME burst (sid 1) does NOT re-ping (dedup state
      -- carried across processOutput calls by the RelayWriter IORef).
      processOutput depsBg w (refN 0) (ChunkOf (sidN 1) "more")
      afterSame <- readIORef calls
      length afterSame `shouldBe` 1
      -- Refocus keyN 1 onto the source ref and deliver one event: clears its
      -- burst membership (and forwards the event verbatim).
      let csFocus = setCursor (keyN 1) (refN 0) emptyCursors
          depsFocus = RelayWriterDeps reg (pure csFocus) (pure tabs) ActivityDigest
      processOutput depsFocus w (refN 0) (FullMsg anyIdx "focused")
      -- Back to background with a NEW burst (sid 1 again) -> pings again,
      -- because refocus cleared the (key, _) membership.
      processOutput depsBg w (refN 0) (StreamStart (sidN 1) anyIdx)
      final <- readIORef calls
      -- ping(1) + focused FullMsg(1) + ping-again(1) = the focused FullMsg plus
      -- two pings.
      final `shouldBe`
        [ Sent (OutgoingMessage "alpha (/0) has new output")
        , Sent (OutgoingMessage "focused")
        , Sent (OutgoingMessage "alpha (/0) has new output")
        ]

-- | Whether a 'lookupSink' result is empty, without needing 'Eq' on
-- 'ChannelHandle'.
isNothingHandle :: Maybe ChannelHandle -> Bool
isNothingHandle Nothing  = True
isNothingHandle (Just _) = False
