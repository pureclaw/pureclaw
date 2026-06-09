-- |
-- Module      : Tabs.RelaySpec
-- Description : WU7 — per-conversation output relay engine.
--
-- Covers the WU7 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79). 'relayOutput' fans one tab's output out to every conversation
-- according to that conversation's effective 'RelayMode':
--
--   1. FocusedOnly — full text reaches ONLY conversations focused on the
--      source tab; a conversation focused elsewhere (or nowhere) gets nothing.
--   2. Firehose — full text reaches the conversation regardless of cursor.
--   3. ActivityDigest — focused conversation gets full text; a background
--      conversation gets exactly ONE name-first activity ping per burst (the
--      returned pinged-set suppresses a second ping); refocusing onto the
--      source tab clears that conversation's pinged membership.
--   4. Ordering — deliveries land in sorted conversation-key order (single
--      writer determinism).
--   5. Mixed modes — per-conversation overrides are each honoured in one call.
--   6. Ping naming — the ping names the tab and its CURRENT display slot, so a
--      compaction that moves the tab is reflected in the ping text.
module Tabs.RelaySpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), SessionId (..))
import PureClaw.Handles.Tab (TabIndex, mkTabIndex)

import PureClaw.Tabs.Relay (RelayDeps (..), relayOutput)
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , RelayMode (..)
  , TabList
  , TabRef (..)
  , TabStatus (..)
  , appendTab
  , emptyCursors
  , emptyTabs
  , removeSlot
  , setCursor
  , setStatus
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

-- | Append a named tab, panicking on the impossible-here error.
append1 :: TabRef -> Text -> TabList -> TabList
append1 ref name tl = case appendTab ref name tl of
  Right (_, tl') -> tl'
  Left e         -> error ("append1: " <> show e)

-- | A recording sink: every @(key, text)@ delivery in order.
newSink :: IO (IORef [(ConversationKey, Text)], RelayDeps)
newSink = do
  ref <- newIORef []
  let deps = RelayDeps (\k t -> modifyIORef' ref (++ [(k, t)]))
  pure (ref, deps)

-- | Set several conversation cursors at once.
withCursors :: [(ConversationKey, TabRef)] -> CursorState
withCursors = foldr (\(k, r) cs -> setCursor k r cs) emptyCursors

-- | Add a per-conversation 'RelayMode' override.
withRelay :: ConversationKey -> RelayMode -> CursorState -> CursorState
withRelay k m cs = cs { _cs_relay = Map.insert k m (_cs_relay cs) }

-- | The activity-ping text the engine is contracted to produce.
ping :: Text -> Int -> Text
ping name slot = name <> " (/" <> T.pack (show slot) <> ") has new output"

-- | Unsafe 'TabIndex' for tests (the int is always in range here).
idx :: Int -> TabIndex
idx n = case mkTabIndex n of
  Just i  -> i
  Nothing -> error ("idx: out of range " <> show n)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  -- DoD 1 — FocusedOnly
  describe "FocusedOnly" $ do
    it "delivers full text only to conversations focused on the source tab" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          -- c0 focused on src; c1 focused elsewhere; c2 focused nowhere.
          cs = withCursors [(keyN 0, src), (keyN 1, other)]
      (sink, deps) <- newSink
      _ <- relayOutput deps cs FocusedOnly tl Set.empty src "hello"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, "hello")]

  -- DoD 2 — Firehose
  describe "Firehose" $ do
    it "delivers full text even when focused on a different tab" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      _ <- relayOutput deps cs Firehose tl Set.empty src "world"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, "world")]

    it "delivers full text and clears pinged membership when focused on source" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      pinged' <- relayOutput deps cs Firehose tl (Set.fromList [keyN 0]) src "f"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, "f")]
      pinged' `shouldBe` Set.empty

  -- DoD 3 — ActivityDigest
  describe "ActivityDigest" $ do
    it "delivers full text to a focused conversation" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      pinged' <- relayOutput deps cs ActivityDigest tl Set.empty src "full"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, "full")]
      pinged' `shouldBe` Set.empty

    it "pings a background conversation exactly once per burst" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      -- First emission: background conversation gets ONE ping; src is slot 0.
      pinged1 <- relayOutput deps cs ActivityDigest tl Set.empty src "burst-1"
      out1 <- readIORef sink
      out1 `shouldBe` [(keyN 0, ping "alpha" 0)]
      pinged1 `shouldBe` Set.fromList [keyN 0]
      -- Second emission with the returned set: no second ping.
      pinged2 <- relayOutput deps cs ActivityDigest tl pinged1 src "burst-2"
      out2 <- readIORef sink
      out2 `shouldBe` [(keyN 0, ping "alpha" 0)] -- unchanged
      pinged2 `shouldBe` Set.fromList [keyN 0]

    it "clears pinged membership when the conversation refocuses on the source" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          -- Conversation now focused ON src; it was previously pinged.
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      pinged' <- relayOutput deps cs ActivityDigest tl (Set.fromList [keyN 0]) src "full"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, "full")]
      pinged' `shouldBe` Set.empty

  -- DoD 4 — ordering
  describe "ordering" $ do
    it "records deliveries in sorted conversation-key order" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          -- Insert cursors out of order; all focused on src.
          cs = withCursors [(keyN 2, src), (keyN 0, src), (keyN 1, src)]
      (sink, deps) <- newSink
      _ <- relayOutput deps cs FocusedOnly tl Set.empty src "x"
      out <- readIORef sink
      map fst out `shouldBe` [keyN 0, keyN 1, keyN 2]

  -- DoD 5 — mixed modes in one call
  describe "mixed per-conversation modes" $ do
    it "honours each conversation's own RelayMode in a single call" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          -- c0: FocusedOnly on other (gets nothing).
          -- c1: Firehose on other (gets full).
          -- c2: ActivityDigest on other (gets ping).
          -- c3: FocusedOnly on src (gets full).
          base = withCursors
            [ (keyN 0, other), (keyN 1, other), (keyN 2, other), (keyN 3, src) ]
          cs = withRelay (keyN 1) Firehose
             . withRelay (keyN 2) ActivityDigest
             $ base
      (sink, deps) <- newSink
      pinged' <- relayOutput deps cs FocusedOnly tl Set.empty src "msg"
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 1, "msg")          -- Firehose
        , (keyN 2, ping "alpha" 0) -- ActivityDigest background ping
        , (keyN 3, "msg")          -- FocusedOnly on src
        ]
      pinged' `shouldBe` Set.fromList [keyN 2]

  -- DoD 6 — ping naming uses CURRENT slot
  describe "ping naming reflects current slot" $ do
    it "shows the tab's new slot after a compaction moves it" $ do
      let a = refN 0
          src = refN 1
          other = refN 2
          -- alpha@0, src@1, gamma@2.
          tl0 = append1 other "gamma"
              $ append1 src "src" (append1 a "alpha" emptyTabs)
          -- Remove slot 0 → src compacts from slot 1 to slot 0.
          tl1 = removeSlot (idx 0) tl0
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      _ <- relayOutput deps cs ActivityDigest tl1 Set.empty src "out"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, ping "src" 0)]

  -- Coverage: empty conversation set is a no-op returning the input set.
  describe "empty conversation set" $ do
    it "delivers nothing and returns the input pinged-set unchanged" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
      (sink, deps) <- newSink
      pinged' <- relayOutput deps emptyCursors FocusedOnly tl Set.empty src "x"
      out <- readIORef sink
      out `shouldBe` []
      pinged' `shouldBe` Set.empty

  -- Coverage: relay-override keys with no cursor are still considered.
  describe "relay-override-only conversations" $ do
    it "considers a key present only in the relay-override map" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          -- keyN 5 has a Firehose override but no cursor anywhere.
          cs = withRelay (keyN 5) Firehose emptyCursors
      (sink, deps) <- newSink
      _ <- relayOutput deps cs FocusedOnly tl Set.empty src "f"
      out <- readIORef sink
      out `shouldBe` [(keyN 5, "f")]

  -- Coverage: a Dead source tab still pings under ActivityDigest (§8).
  describe "Dead source tab" $ do
    it "still pings a background conversation under ActivityDigest" $ do
      let src = refN 0
          other = refN 1
          tl0 = append1 other "beta" (append1 src "alpha" emptyTabs)
          tl = setStatus src Dead tl0
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      _ <- relayOutput deps cs ActivityDigest tl Set.empty src "x"
      out <- readIORef sink
      out `shouldBe` [(keyN 0, ping "alpha" 0)]

  -- Coverage: a background conversation whose source tab is missing from the
  -- TabList gets no ping (the lookup fails, so there is no name/slot).
  describe "source tab absent from the list" $ do
    it "does not ping when the source ref is not present" $ do
      let src = refN 0
          other = refN 1
          -- Only `other` is in the list; `src` was removed.
          tl = append1 other "beta" emptyTabs
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      pinged' <- relayOutput deps cs ActivityDigest tl Set.empty src "x"
      out <- readIORef sink
      out `shouldBe` []
      pinged' `shouldBe` Set.empty
