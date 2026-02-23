module Memory.MarkdownSpec (spec) where

import Data.Map.Strict qualified as Map
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Memory
import PureClaw.Memory.Markdown

spec :: Spec
spec = do
  describe "mkMarkdownMemoryHandle" $ do
    it "saves and recalls a memory" $ do
      dir <- mkTempDir "pureclaw-md-test"
      mh <- mkMarkdownMemoryHandle dir
      let source = MemorySource "Remember this important thing" Map.empty
      result <- _mh_save mh source
      case result of
        Nothing -> expectationFailure "expected Just from save"
        Just mid -> do
          recalled <- _mh_recall mh mid
          case recalled of
            Nothing -> expectationFailure "expected Just from recall"
            Just entry ->
              _me_content entry `shouldBe` "Remember this important thing"

    it "searches by substring match" $ do
      dir <- mkTempDir "pureclaw-md-search"
      mh <- mkMarkdownMemoryHandle dir
      let source1 = MemorySource "The cat sat on the mat" Map.empty
          source2 = MemorySource "The dog ran in the park" Map.empty
      _ <- _mh_save mh source1
      _ <- _mh_save mh source2
      results <- _mh_search mh "cat" defaultSearchConfig
      case results of
        [r] -> _sr_content r `shouldBe` "The cat sat on the mat"
        _   -> expectationFailure $ "expected 1 result, got " ++ show (length results)

    it "returns empty for no matches" $ do
      dir <- mkTempDir "pureclaw-md-nomatch"
      mh <- mkMarkdownMemoryHandle dir
      let source = MemorySource "hello world" Map.empty
      _ <- _mh_save mh source
      results <- _mh_search mh "zebra" defaultSearchConfig
      results `shouldBe` []

    it "stores and retrieves metadata" $ do
      dir <- mkTempDir "pureclaw-md-meta"
      mh <- mkMarkdownMemoryHandle dir
      let meta = Map.fromList [("tags", "test,important")]
          source = MemorySource "content with tags" meta
      result <- _mh_save mh source
      case result of
        Nothing -> expectationFailure "expected Just from save"
        Just mid -> do
          recalled <- _mh_recall mh mid
          case recalled of
            Nothing -> expectationFailure "expected Just from recall"
            Just entry ->
              Map.lookup "tags" (_me_metadata entry) `shouldBe` Just "test,important"

    it "recall returns Nothing for unknown id" $ do
      dir <- mkTempDir "pureclaw-md-unknown"
      mh <- mkMarkdownMemoryHandle dir
      result <- _mh_recall mh (MemoryId "nonexistent")
      result `shouldBe` Nothing

    it "creates the directory if it does not exist" $ do
      tmpDir <- getTemporaryDirectory
      let dir = tmpDir </> "pureclaw-md-newdir"
      removePathForcibly dir
      mh <- mkMarkdownMemoryHandle dir
      _ <- _mh_save mh (MemorySource "test" Map.empty)
      doesDirectoryExist dir `shouldReturn` True

mkTempDir :: String -> IO FilePath
mkTempDir name = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> name
  removePathForcibly dir
  createDirectoryIfMissing True dir
  pure dir
