module Handles.FileSpec (spec) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Security.Path

spec :: Spec
spec = do
  describe "mkFileHandle" $ do
    around withTestWorkspace $ do
      it "reads a file through SafePath" $ \root -> do
        let fh = mkFileHandle root
        Right sp <- mkSafePath root "test.txt"
        contents <- _fh_readFile fh sp
        contents `shouldBe` "hello"

      it "writes and reads back a file" $ \root -> do
        let fh = mkFileHandle root
        Right sp <- mkSafePath root "new.txt"
        _fh_writeFile fh sp "written content"
        contents <- _fh_readFile fh sp
        contents `shouldBe` "written content"

      it "lists directory contents as SafePaths" $ \root -> do
        let fh = mkFileHandle root
        Right sp <- mkSafePath root "."
        entries <- _fh_listDir fh sp
        let names = map (takeFileName . getSafePath) entries
        names `shouldContain` ["test.txt"]
        names `shouldContain` ["subdir"]

      it "listDir filters out blocked paths" $ \root -> do
        let wsDir = unWorkspaceRoot root
        BS.writeFile (wsDir </> ".env") "SECRET=oops"
        let fh = mkFileHandle root
        Right sp <- mkSafePath root "."
        entries <- _fh_listDir fh sp
        let names = map (takeFileName . getSafePath) entries
        names `shouldNotContain` [".env"]
        removeFile (wsDir </> ".env")

  describe "mkNoOpFileHandle" $ do
    it "can be constructed" $ do
      let fh = mkNoOpFileHandle
      fh `seq` pure () :: IO ()

-- | Create a temporary workspace directory for testing.
withTestWorkspace :: (WorkspaceRoot -> IO ()) -> IO ()
withTestWorkspace = bracket setup teardown
  where
    setup = do
      tmp <- getTemporaryDirectory
      let wsDir = tmp </> "pureclaw-test-file-handle"
      createDirectoryIfMissing True wsDir
      createDirectoryIfMissing True (wsDir </> "subdir")
      BS.writeFile (wsDir </> "test.txt") "hello"
      BS.writeFile (wsDir </> "new.txt") ""
      pure (WorkspaceRoot wsDir)
    teardown root = removeDirectoryRecursive (unWorkspaceRoot root)
