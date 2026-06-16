-- |
-- Module      : Tabs.RelaySpec
-- Description : Streaming-aware per-conversation output relay (Tabs-as-View, #79).
--
-- Covers the stage 8b.1 Definition-of-Done items for the Tabs-as-View
-- refactor (GitHub #79). 'relayEvent' fans one tab's 'ChannelEvent' out to
-- every conversation according to that conversation's effective 'RelayMode':
--
--   1. FocusedOnly — every event of a stream reaches a focused conversation
--      verbatim; a background FocusedOnly conversation receives nothing.
--   2. Firehose — every event reaches a background conversation verbatim.
--   3. ActivityDigest streaming burst — a background conversation gets exactly
--      ONE 'BannerLine' ping across a whole StreamStart+ChunkOf*+StreamEnd
--      sequence (the returned pinged-set suppresses repeats); a focused
--      conversation gets every event.
--   4. ActivityDigest FullMsg — one ping per 'BurstFull'; a second FullMsg
--      before refocus does NOT re-ping; refocus then a new FullMsg pings again.
--   5. Refocus clears — delivering to a focused conversation clears its
--      @(k, _)@ burst membership.
--   6. Mixed modes — per-conversation overrides are each honoured in one call.
--   7. Ping naming — the ping names the tab and its CURRENT display slot, so a
--      compaction that moves the tab is reflected in the ping text.
--   8. BannerLine source — a 'BannerLine' event never pings and never forwards
--      to a background conversation (returns the set unchanged).
--
-- Focused __speaker prefix__ (pureclaw): when more than one tab exists, a
-- focused burst-start does NOT get a standalone @\/N@ banner anymore — instead
-- a @\/N \<model\>: @ prefix is MERGED into the burst content: prepended to a
-- 'FullMsg', or injected as the first 'ChunkOf' right after 'StreamStart' so a
-- streamed reply renders the speaker inline (and a non-streaming channel buffers
-- it into the one flushed message). The model is omitted when unknown (a harness
-- tab). A single-tab session is never prefixed.
module Tabs.RelaySpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), SessionId (..))
import PureClaw.Handles.Tab (TabIndex, mkTabIndex)
import PureClaw.Routing.Types (ChannelEvent (..), StreamId, mkStreamId)

import PureClaw.Tabs.Relay (BurstKey (..), RelayDeps (..), relayEvent)
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

-- | A 'StreamId' for index @n@.
sidN :: Int -> StreamId
sidN n = mkStreamId (fromIntegral n)

-- | An arbitrary 'TabIndex' to tag stream\/full events; the relay ignores it.
anyIdx :: TabIndex
anyIdx = idx 0

-- | Append a tab, panicking on the impossible-here error. Tabs no longer carry
-- a label of their own; the @_name@ argument is retained only so the call sites
-- read as documentation of the fixture (it is ignored).
append1 :: TabRef -> Text -> TabList -> TabList
append1 ref _name tl = case appendTab ref tl of
  Right (_, tl') -> tl'
  Left e         -> error ("append1: " <> show e)

-- | A recording sink: every @(key, event)@ delivery in order.
newSink :: IO (IORef [(ConversationKey, ChannelEvent)], RelayDeps)
newSink = do
  ref <- newIORef []
  let deps = RelayDeps (\k e -> modifyIORef' ref (++ [(k, e)]))
  pure (ref, deps)

-- | Set several conversation cursors at once.
withCursors :: [(ConversationKey, TabRef)] -> CursorState
withCursors = foldr (\(k, r) cs -> setCursor k r cs) emptyCursors

-- | Add a per-conversation 'RelayMode' override.
withRelay :: ConversationKey -> RelayMode -> CursorState -> CursorState
withRelay k m cs = cs { _cs_relay = Map.insert k m (_cs_relay cs) }

-- | The activity-ping event the engine is contracted to produce. Tabs no
-- longer carry a label of their own, so the source is named by its current
-- slot only; the @_name@ argument is retained for call-site readability.
ping :: Text -> Int -> ChannelEvent
ping _name slot = BannerLine ("/" <> T.pack (show slot) <> " has new output")

-- | The source tab's model fixture, passed to 'relayEvent' and rendered into
-- the focused speaker prefix (e.g. @\/0 opus: @).
srcModel :: Maybe Text
srcModel = Just "opus"

-- | The speaker prefix the engine MERGES into a focused burst-start when more
-- than one tab exists: @\/N \<model\>: @ (the model is omitted when 'Nothing',
-- e.g. a harness tab). Replicated here to keep the streaming-injection
-- assertions readable; the format itself is also pinned by literal-string
-- assertions below.
speakerPrefix :: Maybe Text -> Int -> Text
speakerPrefix model slot =
  "/" <> T.pack (show slot) <> maybe "" (" " <>) model <> ": "

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
  -- DoD 1 — FocusedOnly: focused gets every event verbatim; background nothing.
  describe "FocusedOnly" $ do
    it "delivers every event of a stream to a focused conversation (prefix injected at StreamStart), and nothing to a background FocusedOnly conversation" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          sid = sidN 1
          -- c0 focused on src; c1 focused elsewhere (background FocusedOnly).
          cs = withCursors [(keyN 0, src), (keyN 1, other)]
          events =
            [ StreamStart sid anyIdx
            , ChunkOf sid "a"
            , ChunkOf sid "b"
            , StreamEnd sid
            ]
      (sink, deps) <- newSink
      let drive acc = relayEvent deps cs FocusedOnly tl srcModel acc src
      _ <- foldEvents drive events
      out <- readIORef sink
      -- The focused conversation c0 saw all four events, with the speaker prefix
      -- injected as the first chunk (since 2 tabs exist); c1 saw none.
      out `shouldBe`
        [ (keyN 0, StreamStart sid anyIdx)
        , (keyN 0, ChunkOf sid (speakerPrefix srcModel 0))
        , (keyN 0, ChunkOf sid "a")
        , (keyN 0, ChunkOf sid "b")
        , (keyN 0, StreamEnd sid)
        ]

  -- gb7 — focused output is labelled ONLY when more than one tab exists.
  describe "focused multi-tab labelling (pureclaw-gb7)" $ do
    -- Test A: 2+ tabs, focused on src, a provider streaming burst → the
    -- speaker prefix is injected exactly once (the first chunk after
    -- StreamStart), before the forwarded chunks.
    it "injects the speaker prefix once at StreamStart when 2+ tabs exist" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          sid = sidN 4
          cs = withCursors [(keyN 0, src)]
          events =
            [ StreamStart sid anyIdx
            , ChunkOf sid "a"
            , ChunkOf sid "b"
            , StreamEnd sid
            ]
      (sink, deps) <- newSink
      let drive acc = relayEvent deps cs FocusedOnly tl srcModel acc src
      _ <- foldEvents drive events
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 0, StreamStart sid anyIdx)
        , (keyN 0, ChunkOf sid "/0 opus: ")
        , (keyN 0, ChunkOf sid "a")
        , (keyN 0, ChunkOf sid "b")
        , (keyN 0, StreamEnd sid)
        ]

    -- Test B: only ONE tab, focused on src, a provider burst → NO prefix
    -- (single-tab CLI stays clean).
    it "does NOT prefix focused output when only one tab exists" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          sid = sidN 5
          cs = withCursors [(keyN 0, src)]
          events =
            [ StreamStart sid anyIdx
            , ChunkOf sid "a"
            , StreamEnd sid
            ]
      (sink, deps) <- newSink
      let drive acc = relayEvent deps cs FocusedOnly tl srcModel acc src
      _ <- foldEvents drive events
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 0, StreamStart sid anyIdx)
        , (keyN 0, ChunkOf sid "a")
        , (keyN 0, StreamEnd sid)
        ]

    -- Test C: 2+ tabs, focused on src, a harness FullMsg → the prefix is
    -- prepended to the FullMsg text (one message, slot + model + separator).
    it "prefixes a focused FullMsg with '/N model: ' when 2+ tabs exist" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl srcModel Set.empty src (FullMsg anyIdx "cap")
      out <- readIORef sink
      -- Literal pin of the on-wire prefix format: "/<slot> <model>: <text>".
      out `shouldBe` [(keyN 0, FullMsg anyIdx "/0 opus: cap")]

    -- A focused FullMsg with an UNKNOWN model (e.g. a harness tab) → the prefix
    -- is slot-only ("/N: "), with no model token.
    it "prefixes a focused FullMsg with a slot-only '/N: ' when the model is unknown" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl Nothing Set.empty src (FullMsg anyIdx "h")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, FullMsg anyIdx "/0: h")]

    -- A focused 'BannerLine' is forwarded verbatim and carries NO speaker prefix
    -- even with 2+ tabs (only burst-start StreamStart/FullMsg are prefixed).
    it "does NOT prefix a focused BannerLine even with 2+ tabs" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl srcModel Set.empty src (BannerLine "raw")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, BannerLine "raw")]

    -- A focused source tab absent from the list yields no prefix (no slot) even
    -- with 2+ tabs in the list; the event still forwards verbatim.
    it "does NOT prefix when the focused source ref is absent from the list" $ do
      let src = refN 0
          a = refN 1
          b = refN 2
          tl = append1 b "gamma" (append1 a "beta" emptyTabs) -- src not present
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl srcModel Set.empty src (FullMsg anyIdx "x")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, FullMsg anyIdx "x")]

  -- DoD 2 — Firehose background: every event verbatim.
  describe "Firehose" $ do
    it "delivers every event of a stream verbatim to a background conversation" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          sid = sidN 2
          cs = withCursors [(keyN 0, other)] -- background under Firehose default
          events =
            [ StreamStart sid anyIdx
            , ChunkOf sid "x"
            , StreamEnd sid
            ]
      (sink, deps) <- newSink
      let drive acc = relayEvent deps cs Firehose tl Nothing acc src
      _ <- foldEvents drive events
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 0, StreamStart sid anyIdx)
        , (keyN 0, ChunkOf sid "x")
        , (keyN 0, StreamEnd sid)
        ]

  -- DoD 3 — ActivityDigest streaming burst.
  describe "ActivityDigest streaming burst" $ do
    it "pings a background conversation exactly once across a full stream, and forwards every event (prefixed) to a focused one" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          sid = sidN 3
          -- c0 focused on src; c1 background.
          cs = withCursors [(keyN 0, src), (keyN 1, other)]
          events =
            [ StreamStart sid anyIdx
            , ChunkOf sid "1"
            , ChunkOf sid "2"
            , ChunkOf sid "3"
            , StreamEnd sid
            ]
      (sink, deps) <- newSink
      let drive acc = relayEvent deps cs ActivityDigest tl srcModel acc src
      final <- foldEvents drive events
      out <- readIORef sink
      -- c1 gets exactly one ping; c0 gets all five events, prefix injected.
      filter ((== keyN 1) . fst) out `shouldBe` [(keyN 1, ping "alpha" 0)]
      filter ((== keyN 0) . fst) out `shouldBe`
        [ (keyN 0, StreamStart sid anyIdx)
        , (keyN 0, ChunkOf sid (speakerPrefix srcModel 0))
        , (keyN 0, ChunkOf sid "1")
        , (keyN 0, ChunkOf sid "2")
        , (keyN 0, ChunkOf sid "3")
        , (keyN 0, StreamEnd sid)
        ]
      final `shouldBe` Set.fromList [(keyN 1, BurstStream sid)]

  -- DoD 4 — ActivityDigest FullMsg dedup + refocus re-ping.
  describe "ActivityDigest FullMsg" $ do
    it "pings once per BurstFull; a 2nd FullMsg before refocus does not re-ping; refocus then a new FullMsg pings again" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          bg = withCursors [(keyN 0, other)]    -- background
          fg = withCursors [(keyN 0, src)]      -- focused on src
      (sink, deps) <- newSink
      -- First FullMsg (background): one ping.
      s1 <- relayEvent deps bg ActivityDigest tl srcModel Set.empty src (FullMsg anyIdx "m1")
      s1 `shouldBe` Set.fromList [(keyN 0, BurstFull)]
      -- Second FullMsg (still background, threading s1): no re-ping.
      s2 <- relayEvent deps bg ActivityDigest tl srcModel s1 src (FullMsg anyIdx "m2")
      s2 `shouldBe` Set.fromList [(keyN 0, BurstFull)]
      -- Refocus onto src and deliver: clears membership, forwards (prefixed).
      s3 <- relayEvent deps fg ActivityDigest tl srcModel s2 src (FullMsg anyIdx "m3")
      s3 `shouldBe` Set.empty
      -- New FullMsg while background again: pings again.
      s4 <- relayEvent deps bg ActivityDigest tl srcModel s3 src (FullMsg anyIdx "m4")
      s4 `shouldBe` Set.fromList [(keyN 0, BurstFull)]
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 0, ping "alpha" 0)                          -- m1 ping
        , (keyN 0, FullMsg anyIdx "/0 opus: m3")            -- m3 focused, prefixed
        , (keyN 0, ping "alpha" 0)                          -- m4 ping
        ]

  -- DoD 5 — Refocus clears ALL of a conversation's burst entries.
  describe "refocus clears burst entries" $ do
    it "removes every (k, _) burst entry when delivering to a focused conversation" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withCursors [(keyN 0, src)]
          -- Seed two distinct burst entries for keyN 0 plus an unrelated key.
          seeded = Set.fromList
            [ (keyN 0, BurstFull)
            , (keyN 0, BurstStream (sidN 7))
            , (keyN 1, BurstFull)
            ]
      (sink, deps) <- newSink
      final <- relayEvent deps cs ActivityDigest tl srcModel seeded src (FullMsg anyIdx "go")
      out <- readIORef sink
      -- Single tab → no prefix.
      out `shouldBe` [(keyN 0, FullMsg anyIdx "go")]
      -- All keyN 0 entries gone; the unrelated keyN 1 entry survives.
      final `shouldBe` Set.fromList [(keyN 1, BurstFull)]

  -- DoD 6 — mixed modes in one event.
  describe "mixed per-conversation modes" $ do
    it "honours each conversation's own RelayMode for the same event" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          -- c0: FocusedOnly on other (nothing). c1: Firehose (full).
          -- c2: ActivityDigest (ping). c3: FocusedOnly on src (full).
          base = withCursors
            [ (keyN 0, other), (keyN 1, other), (keyN 2, other), (keyN 3, src) ]
          cs = withRelay (keyN 1) Firehose
             . withRelay (keyN 2) ActivityDigest
             $ base
          ev = FullMsg anyIdx "msg"
      (sink, deps) <- newSink
      final <- relayEvent deps cs FocusedOnly tl srcModel Set.empty src ev
      out <- readIORef sink
      out `shouldBe`
        [ (keyN 1, ev)                              -- Firehose verbatim (background)
        , (keyN 2, ping "alpha" 0)                  -- ActivityDigest background ping
        , (keyN 3, FullMsg anyIdx "/0 opus: msg")   -- FocusedOnly on src, prefixed
        ]
      final `shouldBe` Set.fromList [(keyN 2, BurstFull)]

  -- DoD 7 — ping naming uses CURRENT slot.
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
      _ <- relayEvent deps cs ActivityDigest tl1 Nothing Set.empty src (FullMsg anyIdx "out")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, ping "src" 0)]

  -- DoD 8 — BannerLine source event under ActivityDigest: never pings and never
  -- forwards to a background conversation, returning the set unchanged.
  -- (Banners are dispatcher-class; the ActivityDigest digest path skips them.)
  describe "BannerLine source event" $ do
    it "never pings and never forwards to a background ActivityDigest conversation, returning the set unchanged" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" (append1 src "alpha" emptyTabs)
          -- Two background conversations, both ActivityDigest (default + override).
          cs = withRelay (keyN 1) ActivityDigest
             $ withCursors [(keyN 0, other), (keyN 1, other)]
          seeded = Set.fromList [(keyN 1, BurstFull)]
      (sink, deps) <- newSink
      final <- relayEvent deps cs ActivityDigest tl Nothing seeded src (BannerLine "ignored")
      out <- readIORef sink
      out `shouldBe` []
      final `shouldBe` seeded

  -- Coverage: a focused conversation receives a BannerLine verbatim (focused
  -- branch forwards every event, banners included).
  describe "BannerLine to a focused conversation" $ do
    it "forwards a BannerLine verbatim to a focused conversation" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withCursors [(keyN 0, src)]
      (sink, deps) <- newSink
      final <- relayEvent deps cs ActivityDigest tl srcModel Set.empty src (BannerLine "hi")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, BannerLine "hi")]
      final `shouldBe` Set.empty

  -- Coverage: empty conversation set is a no-op returning the input set.
  describe "empty conversation set" $ do
    it "delivers nothing and returns the input pinged-set unchanged" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
      (sink, deps) <- newSink
      final <- relayEvent deps emptyCursors FocusedOnly tl Nothing Set.empty src (FullMsg anyIdx "x")
      out <- readIORef sink
      out `shouldBe` []
      final `shouldBe` Set.empty

  -- Coverage: deliveries land in sorted conversation-key order (single writer).
  describe "ordering" $ do
    it "records deliveries in sorted conversation-key order" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withCursors [(keyN 2, src), (keyN 0, src), (keyN 1, src)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl srcModel Set.empty src (FullMsg anyIdx "x")
      out <- readIORef sink
      map fst out `shouldBe` [keyN 0, keyN 1, keyN 2]

  -- Coverage: relay-override keys with no cursor are still considered.
  describe "relay-override-only conversations" $ do
    it "considers a key present only in the relay-override map" $ do
      let src = refN 0
          tl = append1 src "alpha" emptyTabs
          cs = withRelay (keyN 5) Firehose emptyCursors
      (sink, deps) <- newSink
      _ <- relayEvent deps cs FocusedOnly tl Nothing Set.empty src (FullMsg anyIdx "f")
      out <- readIORef sink
      out `shouldBe` [(keyN 5, FullMsg anyIdx "f")]

  -- Coverage: a Dead source tab still pings under ActivityDigest (§8).
  describe "Dead source tab" $ do
    it "still pings a background conversation under ActivityDigest" $ do
      let src = refN 0
          other = refN 1
          tl0 = append1 other "beta" (append1 src "alpha" emptyTabs)
          tl = setStatus src Dead tl0
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      _ <- relayEvent deps cs ActivityDigest tl Nothing Set.empty src (FullMsg anyIdx "x")
      out <- readIORef sink
      out `shouldBe` [(keyN 0, ping "alpha" 0)]

  -- Coverage: a background ActivityDigest conversation whose source tab is
  -- missing from the TabList gets no ping (no name/slot).
  describe "source tab absent from the list" $ do
    it "does not ping when the source ref is not present" $ do
      let src = refN 0
          other = refN 1
          tl = append1 other "beta" emptyTabs -- src not in the list
          cs = withCursors [(keyN 0, other)]
      (sink, deps) <- newSink
      final <- relayEvent deps cs ActivityDigest tl Nothing Set.empty src (FullMsg anyIdx "x")
      out <- readIORef sink
      out `shouldBe` []
      final `shouldBe` Set.empty

-- | Drive a list of events through a relay action, threading the pinged-set
-- from 'Set.empty'. Returns the final set.
foldEvents
  :: Monad m
  => (Set.Set acc -> e -> m (Set.Set acc))
  -> [e]
  -> m (Set.Set acc)
foldEvents step = go Set.empty
  where
    go acc []       = pure acc
    go acc (e : es) = step acc e >>= \acc' -> go acc' es
