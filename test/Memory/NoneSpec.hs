module Memory.NoneSpec (spec) where

import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Memory
import PureClaw.Memory.None

spec :: Spec
spec = do
  describe "mkNoneMemoryHandle" $ do
    it "search returns empty list" $ do
      let mh = mkNoneMemoryHandle
      results <- _mh_search mh "anything" defaultSearchConfig
      results `shouldBe` []

    it "save returns Nothing" $ do
      let mh = mkNoneMemoryHandle
          source = MemorySource "test" mempty
      result <- _mh_save mh source
      result `shouldBe` Nothing

    it "recall returns Nothing" $ do
      let mh = mkNoneMemoryHandle
      result <- _mh_recall mh (MemoryId "1")
      result `shouldBe` Nothing
