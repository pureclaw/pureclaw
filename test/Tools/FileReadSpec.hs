module Tools.FileReadSpec (spec) where

import Data.Aeson
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Tools.FileRead
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "fileReadTool" $ do
    it "has the correct tool name" $ do
      let root = WorkspaceRoot "/tmp"
          (def', _) = fileReadTool root mkNoOpFileHandle
      _td_name def' `shouldBe` "file_read"

    it "reads a file within the workspace" $ do
      tmpDir <- getTemporaryDirectory
      let dir = tmpDir </> "pureclaw-fileread-test"
      createDirectoryIfMissing True dir
      let root = WorkspaceRoot dir
          fh = mkFileHandle root
          (_, handler) = fileReadTool root fh
      writeFile (dir </> "test.txt") "hello from file"
      -- Use relative path — mkSafePath resolves relative to workspace root
      let input = object ["path" .= ("test.txt" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      output `shouldBe` "hello from file"

    it "rejects paths that escape the workspace" $ do
      tmpDir <- getTemporaryDirectory
      let dir = tmpDir </> "pureclaw-fileread-test2"
      createDirectoryIfMissing True dir
      let root = WorkspaceRoot dir
          fh = mkFileHandle root
          (_, handler) = fileReadTool root fh
          input = object ["path" .= ("../../../etc/passwd" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "rejects blocked paths" $ do
      tmpDir <- getTemporaryDirectory
      let dir = tmpDir </> "pureclaw-fileread-test3"
      createDirectoryIfMissing True dir
      let root = WorkspaceRoot dir
          fh = mkFileHandle root
          (_, handler) = fileReadTool root fh
      writeFile (dir </> ".env") "SECRET=x"
      let input = object ["path" .= (".env" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True
