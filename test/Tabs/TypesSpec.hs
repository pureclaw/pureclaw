-- |
-- Module      : Tabs.TypesSpec
-- Description : WU1 — core tab registry types & pure operations.
--
-- Covers the WU1 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79):
--
--   1. I1 contiguity — after any 'appendTab'\/'removeSlot' sequence,
--      slots are exactly @[0 .. n-1]@.
--   2. I2 uniqueness\/dedup — appending an already-bound 'TabRef' returns
--      @Left ('AlreadyBound' i)@; no two tabs share a ref.
--   3. 36-cap — appending a 37th distinct ref returns @Left 'SlotsFull'@.
--   4. Compaction — 'removeSlot' shifts higher slots down by one.
--   5. 'ConversationId' compiles + is exported from "PureClaw.Core.Types".
--   6. 'TabRegistry' IO handle wrappers reflect appends.
module Tabs.TypesSpec (spec) where

import Data.List qualified as List
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import PureClaw.Core.Types (ConversationId (..), SessionId (..))
import PureClaw.Handles.Tab (TabIndex, mkTabIndex, unTabIndex)
import PureClaw.Harness.Registry (parseHarnessId)

import PureClaw.Tabs
  ( newTabRegistry
  , readTabs
  , registryAppend
  , registryLookupRef
  , registryLookupSlot
  , registryRemove
  , registrySetStatus
  )
import PureClaw.Tabs.Types
  ( Tab (..)
  , TabList
  , TabRef (..)
  , TabStatus (..)
  , TabsError (..)
  , appendTab
  , emptyTabs
  , lookupRef
  , lookupSlot
  , rebindSlot
  , removeSlot
  , setStatus
  , toList
  )

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A distinct 'TabRef' for index @n@ (alternating session\/harness so both
-- constructors are exercised). HarnessIds are minted from a fixed-format
-- UUID string derived from @n@.
refN :: Int -> TabRef
refN n
  | even n    = BoundSession (SessionId ("s" <> tshow n))
  | otherwise = case parseHarnessId (uuidFor n) of
      Just hid -> BoundHarness hid
      Nothing  -> BoundSession (SessionId ("h" <> tshow n))
  where
    tshow = T.pack . show

-- | Deterministic UUID string for a small @n@ (0..99 is plenty for tests).
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

-- ---------------------------------------------------------------------------
-- Operation sequences for the contiguity property (I1)
-- ---------------------------------------------------------------------------

-- | A registry operation, parameterised over a small distinct-ref index.
data Op
  = OpAppend !Int   -- ^ append refN of this index (deduped if already present)
  | OpRemove !Int   -- ^ remove the slot at this position (mod length)
  deriving (Show)

instance Arbitrary Op where
  arbitrary = oneof
    [ OpAppend <$> choose (0, 40)
    , OpRemove <$> choose (0, 40)
    ]

-- | Apply one op to a 'TabList'.
applyOp :: Op -> TabList -> TabList
applyOp (OpAppend n) tl =
  case appendTab (refN n) ("t" <> T.pack (show n)) tl of
    Right (_, tl') -> tl'
    Left _         -> tl
applyOp (OpRemove n) tl =
  case toList tl of
    [] -> tl
    xs -> let i = n `mod` length xs
          in removeSlot (_tab_slot (xs !! i)) tl

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "ConversationId (DoD 5)" $
    it "is exported from Core.Types and round-trips its Text" $
      ConversationId "cli" `shouldBe` ConversationId "cli"

  describe "I1 contiguity (DoD 1)" $
    it "slots are exactly [0..n-1] after any append/remove sequence" $
      property $ \ops ->
        let tl = List.foldl' (flip applyOp) emptyTabs (ops :: [Op])
            slots = map (unTabIndex . _tab_slot) (toList tl)
        in slots === [0 .. length (toList tl) - 1]

  describe "I2 uniqueness / dedup (DoD 2)" $ do
    it "appending an already-bound ref returns Left (AlreadyBound i)" $ do
      let tl = buildList 3
      appendTab (refN 1) "again" tl `shouldBe` Left (AlreadyBound (idx 1))

    it "AlreadyBound reports the ref's CURRENT slot after compaction" $ do
      -- Build [0,1,2]; remove slot 0 -> old ref 1 now at slot 0, ref 2 at 1.
      let tl  = buildList 3
          tl' = removeSlot (idx 0) tl
      appendTab (refN 1) "x" tl' `shouldBe` Left (AlreadyBound (idx 0))

    it "never produces two tabs with the same ref" $
      property $ \ops ->
        let tl = List.foldl' (flip applyOp) emptyTabs (ops :: [Op])
            refs = map _tab_ref (toList tl)
        in List.nub refs === refs

  describe "36-cap (DoD 3)" $ do
    it "appending a 37th distinct ref returns Left SlotsFull" $ do
      let tl36 = buildList 36
      length (toList tl36) `shouldBe` 36
      appendTab (refN 36) "overflow" tl36 `shouldBe` Left SlotsFull

    it "the 36th distinct ref still succeeds (boundary)" $ do
      let tl35 = buildList 35
      case appendTab (refN 35) "last" tl35 of
        Right (i, tl') -> do
          unTabIndex i `shouldBe` 35
          length (toList tl') `shouldBe` 36
        Left e -> expectationFailure ("expected Right, got " <> show e)

  describe "compaction (DoD 4)" $
    it "removing slot 1 of a 3-tab list shifts old slot-2 ref to slot 1" $ do
      let tl  = buildList 3
          tl' = removeSlot (idx 1) tl
      -- old ref at slot 2 is now found at slot 1
      lookupRef (refN 2) tl' `shouldBe` Just (idx 1)
      -- slot 1 now holds ref 2
      fmap _tab_ref (lookupSlot (idx 1) tl') `shouldBe` Just (refN 2)
      -- slot 0 (ref 0) is untouched
      lookupRef (refN 0) tl' `shouldBe` Just (idx 0)
      -- only two tabs remain
      length (toList tl') `shouldBe` 2

  describe "derived instances (Eq/Ord/Show)" $ do
    it "TabRef Ord orders BoundSession before BoundHarness and within constructors" $ do
      -- both constructors built; Ord exercised via compare (DoD: cover Ord alt)
      let s0 = BoundSession (SessionId "a")
          s1 = BoundSession (SessionId "b")
      compare s0 s1 `shouldBe` LT
      compare s1 s0 `shouldBe` GT
      compare s0 s0 `shouldBe` EQ
      case refN 1 of                      -- a BoundHarness
        h@(BoundHarness _) -> compare s0 h `shouldBe` LT
        _                  -> expectationFailure "refN 1 should be a BoundHarness"

    it "TabRef/TabStatus/Tab/TabsError/TabList Show round-trips meaningfully" $ do
      show (BoundSession (SessionId "x")) `shouldSatisfy` (\s -> "BoundSession" `List.isInfixOf` s)
      show Live `shouldBe` "Live"
      show Dead `shouldBe` "Dead"
      show SlotsFull `shouldBe` "SlotsFull"
      show (AlreadyBound (idx 3)) `shouldSatisfy` (\s -> "AlreadyBound" `List.isInfixOf` s)
      -- Tab Show mentions the name field; TabList Show wraps the tabs
      let tl = buildList 1
      case toList tl of
        (t : _) -> do
          show t `shouldSatisfy` (\s -> "Tab" `List.isInfixOf` s)
          -- exercise the _tab_name accessor with a real assertion
          _tab_name t `shouldBe` "tab0"
        []      -> expectationFailure "buildList 1 should have one tab"
      show tl `shouldSatisfy` (\s -> "TabList" `List.isInfixOf` s)

    it "TabStatus Eq distinguishes Live from Dead" $ do
      (Live == Live) `shouldBe` True
      (Live == Dead) `shouldBe` False

  describe "lookups & status" $ do
    it "lookupSlot returns Nothing for an out-of-range slot" $
      lookupSlot (idx 5) (buildList 2) `shouldBe` Nothing

    it "lookupRef returns Nothing for an absent ref" $
      lookupRef (refN 9) (buildList 2) `shouldBe` Nothing

    it "setStatus flips a present ref's status to Dead" $ do
      let tl  = buildList 2
          tl' = setStatus (refN 0) Dead tl
      fmap _tab_status (lookupSlot (idx 0) tl') `shouldBe` Just Dead
      -- the other tab is unaffected
      fmap _tab_status (lookupSlot (idx 1) tl') `shouldBe` Just Live

    it "setStatus on an absent ref is a no-op" $ do
      let tl = buildList 1
      toList (setStatus (refN 9) Dead tl) `shouldBe` toList tl

  describe "TabRegistry handle (DoD 6)" $ do
    it "newTabRegistry + registryAppend reflected by readTabs" $ do
      reg <- newTabRegistry
      tl0 <- readTabs reg
      toList tl0 `shouldBe` []
      r1 <- registryAppend reg (refN 0) "a"
      r1 `shouldBe` Right (idx 0)
      r2 <- registryAppend reg (refN 1) "b"
      r2 `shouldBe` Right (idx 1)
      tl <- readTabs reg
      map (unTabIndex . _tab_slot) (toList tl) `shouldBe` [0, 1]
      map _tab_ref (toList tl) `shouldBe` [refN 0, refN 1]
      -- dedup is enforced through the handle too
      registryAppend reg (refN 0) "dup" `shouldReturn` Left (AlreadyBound (idx 0))

    it "registryRemove drops the tab at a slot and compacts (via readTabs)" $ do
      reg <- newTabRegistry
      _ <- registryAppend reg (refN 0) "a"
      _ <- registryAppend reg (refN 1) "b"
      _ <- registryAppend reg (refN 2) "c"
      registryRemove reg (idx 1)            -- remove the middle tab
      tl <- readTabs reg
      -- slots stay contiguous, old ref 2 shifted down to slot 1
      map (unTabIndex . _tab_slot) (toList tl) `shouldBe` [0, 1]
      map _tab_ref (toList tl) `shouldBe` [refN 0, refN 2]

    it "registryRemove of an absent slot is a no-op" $ do
      reg <- newTabRegistry
      _ <- registryAppend reg (refN 0) "a"
      registryRemove reg (idx 5)            -- nothing at slot 5
      tl <- readTabs reg
      map _tab_ref (toList tl) `shouldBe` [refN 0]

    it "registryLookupSlot finds a present slot and misses an absent one" $ do
      reg <- newTabRegistry
      _ <- registryAppend reg (refN 0) "a"
      _ <- registryAppend reg (refN 1) "b"
      hit  <- registryLookupSlot reg (idx 1)
      fmap _tab_ref hit `shouldBe` Just (refN 1)
      miss <- registryLookupSlot reg (idx 9)
      miss `shouldBe` Nothing

    it "registryLookupRef finds a present ref's slot and misses an absent one" $ do
      reg <- newTabRegistry
      _ <- registryAppend reg (refN 0) "a"
      _ <- registryAppend reg (refN 1) "b"
      hit  <- registryLookupRef reg (refN 1)
      hit `shouldBe` Just (idx 1)
      miss <- registryLookupRef reg (refN 9)
      miss `shouldBe` Nothing

    it "registrySetStatus flips a present ref to Dead and no-ops an absent ref" $ do
      reg <- newTabRegistry
      _ <- registryAppend reg (refN 0) "a"
      _ <- registryAppend reg (refN 1) "b"
      registrySetStatus reg (refN 0) Dead   -- present: flips
      registrySetStatus reg (refN 9) Dead   -- absent: no-op
      tl <- readTabs reg
      map _tab_status (toList tl) `shouldBe` [Dead, Live]

  describe "rebindSlot (8b.4 /new support)" $ do
    it "rebinds the ref + name at a slot in place, preserving the slot" $ do
      let tl  = buildList 3
          new = refN 99
      case rebindSlot (idx 1) new "renamed" tl of
        Left e   -> expectationFailure ("unexpected Left: " <> show e)
        Right tl' -> do
          -- slots stay contiguous and unchanged
          map (unTabIndex . _tab_slot) (toList tl') `shouldBe` [0, 1, 2]
          -- slot 1 now holds the new ref + name; neighbours untouched
          fmap _tab_ref  (lookupSlot (idx 1) tl') `shouldBe` Just new
          fmap _tab_name (lookupSlot (idx 1) tl') `shouldBe` Just "renamed"
          fmap _tab_ref  (lookupSlot (idx 0) tl') `shouldBe` Just (refN 0)
          fmap _tab_ref  (lookupSlot (idx 2) tl') `shouldBe` Just (refN 2)

    it "resets the rebound tab's status to Live" $ do
      let tl  = setStatus (refN 1) Dead (buildList 2)
      case rebindSlot (idx 1) (refN 88) "fresh" tl of
        Left e    -> expectationFailure ("unexpected Left: " <> show e)
        Right tl' -> fmap _tab_status (lookupSlot (idx 1) tl') `shouldBe` Just Live

    it "rejects rebinding to a ref already bound at a different slot" $ do
      let tl = buildList 3
      -- slot 1 -> ref already at slot 2
      rebindSlot (idx 1) (refN 2) "dup" tl `shouldBe` Left (AlreadyBound (idx 2))

    it "allows rebinding a slot to the ref it already holds (rename in place)" $ do
      let tl = buildList 2
      case rebindSlot (idx 0) (refN 0) "relabel" tl of
        Left e    -> expectationFailure ("unexpected Left: " <> show e)
        Right tl' -> do
          fmap _tab_ref  (lookupSlot (idx 0) tl') `shouldBe` Just (refN 0)
          fmap _tab_name (lookupSlot (idx 0) tl') `shouldBe` Just "relabel"

    it "is a no-op Right when the slot is absent" $ do
      let tl = buildList 1
      case rebindSlot (idx 5) (refN 77) "ghost" tl of
        Left e    -> expectationFailure ("unexpected Left: " <> show e)
        Right tl' -> toList tl' `shouldBe` toList tl

-- | Unsafe 'TabIndex' for tests (the int is always in range here).
idx :: Int -> TabIndex
idx n = case mkTabIndex n of
  Just i  -> i
  Nothing -> error ("idx: out of range " <> show n)
