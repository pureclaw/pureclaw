-- |
-- Module      : Tabs.CursorSpec
-- Description : WU2 — per-conversation cursors, ConversationKey, RelayMode.
--
-- Covers the WU2 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79):
--
--   1. I3 — a cursor keys by 'TabRef', so it survives slot compaction:
--      'resolveCursorSlot' returns the bound tab's /current/ slot, including
--      after a 'removeSlot' that shifts the ref to a new slot.
--   2. 'pruneDangling' — clears cursors whose ref is no longer in the
--      'TabList', keeping the valid ones.
--   3. 'conversationsOn' — returns exactly the keys focused on a given ref;
--      'clearCursor' removes a key.
--   4. 'relayModeFor' — per-conversation override if set, else the supplied
--      global default.
--   5. 'resolveCursorSlot' — 'Nothing' for an unset key or a dangling ref.
module Tabs.CursorSpec (spec) where

import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), SessionId (..))
import PureClaw.Handles.Tab (TabIndex, mkTabIndex)
import PureClaw.Harness.Registry (parseHarnessId)

import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , RelayMode (..)
  , Tab (..)
  , TabList
  , TabRef (..)
  , appendTab
  , clearCursor
  , conversationsOn
  , emptyCursors
  , emptyTabs
  , pruneDangling
  , relayModeFor
  , removeSlot
  , resolveCursorSlot
  , setCursor
  , toList
  )

-- ---------------------------------------------------------------------------
-- Helpers (mirror Tabs.TypesSpec so both ref constructors are exercised)
-- ---------------------------------------------------------------------------

-- | A distinct 'TabRef' for index @n@ (alternating session\/harness).
refN :: Int -> TabRef
refN n
  | even n    = BoundSession (SessionId ("s" <> tshow n))
  | otherwise = case parseHarnessId (uuidFor n) of
      Just hid -> BoundHarness hid
      Nothing  -> BoundSession (SessionId ("h" <> tshow n))
  where
    tshow = T.pack . show

-- | Deterministic UUID string for a small @n@.
uuidFor :: Int -> T.Text
uuidFor n =
  let d2 = T.pack (pad2 n)
  in "00000000-0000-0000-0000-0000000000" <> d2
  where
    pad2 k = let s = show (k `mod` 100) in replicate (2 - length s) '0' <> s

-- | Build a 'TabList' by appending refs @0..k-1@ with placeholder names.
buildList :: Int -> TabList
buildList k = go 0 emptyTabs
  where
    go i tl
      | i >= k = tl
      | otherwise = case appendTab (refN i) ("tab" <> T.pack (show i)) tl of
          Right (_, tl') -> go (i + 1) tl'
          Left _         -> tl

-- | A distinct 'ConversationKey' for index @n@ (varies channel + id).
keyN :: Int -> ConversationKey
keyN n = (chan, ConversationId ("c" <> T.pack (show n)))
  where
    chan = case n `mod` 3 of
      0 -> CkCli
      1 -> CkTelegram
      _ -> CkOther "x"

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
  describe "I3 — cursors key by TabRef and survive compaction (DoD 1)" $ do
    it "resolveCursorSlot returns the bound tab's current slot" $ do
      let tl = buildList 3
          cs = setCursor (keyN 0) (refN 1) emptyCursors
      resolveCursorSlot (keyN 0) cs tl `shouldBe` Just (idx 1)

    it "tracks the ref to its NEW slot after removeSlot compacts the list" $ do
      -- [0,1,2]; cursor on ref 2 (slot 2). Remove slot 0 -> ref 2 now at slot 1.
      let tl  = buildList 3
          cs  = setCursor (keyN 0) (refN 2) emptyCursors
          tl' = removeSlotAt 0 tl
      resolveCursorSlot (keyN 0) cs tl' `shouldBe` Just (idx 1)

    it "property: resolution always equals the slot the bound ref sits at" $
      property $ \(NonEmptyTabs n) (Removals rs) ->
        let tl0 = buildList n
            tl  = List.foldl' (flip removeSlotMod) tl0 rs
        in case toList tl of
             [] -> property True   -- list emptied; covered by the misses below
             (t0 : _) ->
               -- bind the cursor to the ref currently at slot 0, then assert
               -- resolution returns slot 0 regardless of how compaction ran.
               let cs = setCursor (keyN 0) (_tab_ref t0) emptyCursors
               in resolveCursorSlot (keyN 0) cs tl === Just (_tab_slot t0)

  describe "pruneDangling (DoD 2)" $ do
    it "clears cursors whose ref is no longer in the TabList" $ do
      let tl  = buildList 2                       -- refs 0,1 present
          cs  = setCursor (keyN 0) (refN 5)       -- ref 5 absent -> dangling
              $ setCursor (keyN 1) (refN 1)       -- ref 1 present -> kept
                emptyCursors
          cs' = pruneDangling tl cs
      Map.lookup (keyN 0) (_cs_cursors cs') `shouldBe` Nothing
      Map.lookup (keyN 1) (_cs_cursors cs') `shouldBe` Just (refN 1)

    it "is a no-op when every cursor's ref is present" $ do
      let tl  = buildList 3
          cs  = setCursor (keyN 0) (refN 0)
              $ setCursor (keyN 1) (refN 2) emptyCursors
      _cs_cursors (pruneDangling tl cs) `shouldBe` _cs_cursors cs

    it "leaves the relay map untouched" $ do
      let tl  = buildList 1
          cs  = (setCursor (keyN 0) (refN 9) emptyCursors)
                  { _cs_relay = Map.fromList [(keyN 0, Firehose)] }
          cs' = pruneDangling tl cs
      _cs_cursors cs' `shouldBe` Map.empty           -- ref 9 dangling -> dropped
      _cs_relay cs'   `shouldBe` Map.fromList [(keyN 0, Firehose)]

  describe "conversationsOn / clearCursor (DoD 3)" $ do
    it "returns exactly the keys whose cursor == the given ref" $ do
      let cs = setCursor (keyN 0) (refN 1)
             $ setCursor (keyN 1) (refN 1)
             $ setCursor (keyN 2) (refN 2) emptyCursors
      List.sort (conversationsOn (refN 1) cs)
        `shouldBe` List.sort [keyN 0, keyN 1]
      conversationsOn (refN 2) cs `shouldBe` [keyN 2]

    it "returns [] for a ref no conversation is focused on" $
      conversationsOn (refN 7) (setCursor (keyN 0) (refN 1) emptyCursors)
        `shouldBe` []

    it "clearCursor removes a key (and only that key)" $ do
      let cs  = setCursor (keyN 0) (refN 1)
              $ setCursor (keyN 1) (refN 1) emptyCursors
          cs' = clearCursor (keyN 0) cs
      conversationsOn (refN 1) cs' `shouldBe` [keyN 1]
      Map.lookup (keyN 0) (_cs_cursors cs') `shouldBe` Nothing

    it "clearCursor on an absent key is a no-op" $ do
      let cs = setCursor (keyN 0) (refN 1) emptyCursors
      _cs_cursors (clearCursor (keyN 9) cs) `shouldBe` _cs_cursors cs

    it "setCursor overwrites a prior cursor for the same key" $ do
      let cs = setCursor (keyN 0) (refN 2)
             $ setCursor (keyN 0) (refN 1) emptyCursors
      Map.lookup (keyN 0) (_cs_cursors cs) `shouldBe` Just (refN 2)
      conversationsOn (refN 1) cs `shouldBe` []

  describe "relayModeFor (DoD 4)" $ do
    it "returns the per-conversation override when set" $ do
      let cs = emptyCursors { _cs_relay = Map.fromList [(keyN 0, Firehose)] }
      relayModeFor (keyN 0) FocusedOnly cs `shouldBe` Firehose

    it "returns the supplied global default when no override is set" $
      relayModeFor (keyN 0) ActivityDigest emptyCursors `shouldBe` ActivityDigest

    it "an override on one key does not leak to another" $ do
      let cs = emptyCursors { _cs_relay = Map.fromList [(keyN 0, Firehose)] }
      relayModeFor (keyN 1) FocusedOnly cs `shouldBe` FocusedOnly

  describe "resolveCursorSlot misses (DoD 5)" $ do
    it "Nothing for an unset key" $
      resolveCursorSlot (keyN 0) emptyCursors (buildList 2) `shouldBe` Nothing

    it "Nothing for a dangling ref (cursor set but ref absent in list)" $ do
      let cs = setCursor (keyN 0) (refN 9) emptyCursors
      resolveCursorSlot (keyN 0) cs (buildList 2) `shouldBe` Nothing

  describe "derived instances (Eq/Show) on the new types" $ do
    it "RelayMode Eq distinguishes all three modes" $ do
      (FocusedOnly == FocusedOnly) `shouldBe` True
      (FocusedOnly == ActivityDigest) `shouldBe` False
      (ActivityDigest == Firehose) `shouldBe` False

    it "RelayMode Show round-trips the constructor names" $ do
      show FocusedOnly `shouldBe` "FocusedOnly"
      show ActivityDigest `shouldBe` "ActivityDigest"
      show Firehose `shouldBe` "Firehose"

    it "CursorState Eq / Show reflect contents" $ do
      let cs = setCursor (keyN 0) (refN 1) emptyCursors
      cs `shouldBe` cs
      (cs == emptyCursors) `shouldBe` False
      show cs `shouldSatisfy` (\s -> "CursorState" `List.isInfixOf` s)
      show emptyCursors `shouldSatisfy` (\s -> "CursorState" `List.isInfixOf` s)

-- ---------------------------------------------------------------------------
-- removeSlot wrappers
-- ---------------------------------------------------------------------------

-- | 'removeSlot' taking a raw Int slot.
removeSlotAt :: Int -> TabList -> TabList
removeSlotAt n = removeSlot (idx n)

-- | Remove the tab at position @n mod length@ (by its slot), no-op if empty.
removeSlotMod :: Int -> TabList -> TabList
removeSlotMod n tl =
  case toList tl of
    [] -> tl
    xs -> let i = n `mod` length xs
          in removeSlot (_tab_slot (xs !! i)) tl

-- ---------------------------------------------------------------------------
-- QuickCheck newtypes
-- ---------------------------------------------------------------------------

newtype NonEmptyTabs = NonEmptyTabs Int deriving (Show)

instance Arbitrary NonEmptyTabs where
  arbitrary = NonEmptyTabs <$> choose (1, 8)

newtype Removals = Removals [Int] deriving (Show)

instance Arbitrary Removals where
  arbitrary = Removals <$> listOf (choose (0, 20))
