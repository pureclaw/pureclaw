module Memory.SQLiteSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Memory
import PureClaw.Memory.SQLite

spec :: Spec
spec = do
  describe "mkSQLiteMemoryHandle" $ do
    it "saves and recalls a memory" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-test"
      mh <- mkSQLiteMemoryHandle dbPath
      let source = MemorySource "Remember this" Map.empty
      result <- _mh_save mh source
      case result of
        Nothing -> expectationFailure "expected Just from save"
        Just mid -> do
          recalled <- _mh_recall mh mid
          case recalled of
            Nothing -> expectationFailure "expected Just from recall"
            Just entry ->
              _me_content entry `shouldBe` "Remember this"

    it "searches by substring" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-search"
      mh <- mkSQLiteMemoryHandle dbPath
      _ <- _mh_save mh (MemorySource "The cat sat on the mat" Map.empty)
      _ <- _mh_save mh (MemorySource "The dog ran in the park" Map.empty)
      results <- _mh_search mh "cat" defaultSearchConfig
      case results of
        [r] -> _sr_content r `shouldBe` "The cat sat on the mat"
        _   -> expectationFailure $ "expected 1 result, got " ++ show (length results)

    it "returns empty for no matches" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-nomatch"
      mh <- mkSQLiteMemoryHandle dbPath
      _ <- _mh_save mh (MemorySource "hello world" Map.empty)
      results <- _mh_search mh "zebra" defaultSearchConfig
      results `shouldBe` []

    it "recall returns Nothing for unknown id" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-unknown"
      mh <- mkSQLiteMemoryHandle dbPath
      result <- _mh_recall mh (MemoryId "nonexistent")
      result `shouldBe` Nothing

    it "preserves metadata" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-meta"
      mh <- mkSQLiteMemoryHandle dbPath
      let meta = Map.fromList [("tags", "test")]
      result <- _mh_save mh (MemorySource "content" meta)
      case result of
        Nothing -> expectationFailure "expected Just from save"
        Just mid -> do
          recalled <- _mh_recall mh mid
          case recalled of
            Nothing -> expectationFailure "expected Just from recall"
            Just entry ->
              Map.lookup "tags" (_me_metadata entry) `shouldBe` Just "test"

  describe "withSQLiteMemory" $ do
    it "runs an action with a memory handle" $ do
      dbPath <- mkTempDb "pureclaw-sqlite-with"
      result <- withSQLiteMemory dbPath $ \mh ->
        _mh_save mh (MemorySource "test" Map.empty)
      result `shouldSatisfy` isJust

mkTempDb :: String -> IO FilePath
mkTempDb name = do
  tmpDir <- getTemporaryDirectory
  let path = tmpDir </> name <> ".db"
  removePathForcibly path
  pure path
