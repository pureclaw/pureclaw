module Handles.MemorySpec (spec) where

import Data.Map qualified as Map
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Memory

spec :: Spec
spec = do
  describe "mkNoOpMemoryHandle" $ do
    it "search returns empty list" $ do
      results <- _mh_search mkNoOpMemoryHandle "query" defaultSearchConfig
      results `shouldBe` []

    it "save returns Nothing" $ do
      let source = MemorySource "content" Map.empty
      result <- _mh_save mkNoOpMemoryHandle source
      result `shouldBe` Nothing

    it "recall returns Nothing" $ do
      result <- _mh_recall mkNoOpMemoryHandle (MemoryId "some-id")
      result `shouldBe` Nothing

  describe "defaultSearchConfig" $ do
    it "has maxResults of 10" $ do
      _sc_maxResults defaultSearchConfig `shouldBe` 10

    it "has minScore of 0.0" $ do
      _sc_minScore defaultSearchConfig `shouldBe` 0.0

  describe "MemorySource" $ do
    it "has Show and Eq instances" $ do
      let src = MemorySource "hello" (Map.fromList [("key", "val")])
      show src `shouldContain` "hello"
      src `shouldBe` src

  describe "SearchResult" $ do
    it "has Show and Eq instances" $ do
      let sr = SearchResult (MemoryId "1") "content" 0.95
      show sr `shouldContain` "content"
      sr `shouldBe` sr
