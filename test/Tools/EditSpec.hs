module Tools.EditSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Tools.Edit
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "editTool" $ do
    it "has the correct tool name" $ do
      let root = WorkspaceRoot "/tmp"
          (def', _) = editTool root mkNoOpFileHandle
      _td_name def' `shouldBe` "edit"

    it "replaces a unique string in a file" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello world"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("hello" :: String)
              , "new_string" .= ("goodbye" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "test.txt"
        contents <- readFile (dir </> "test.txt")
        contents `shouldBe` "goodbye world"

    it "rejects when old_string is not found" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello world"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("nonexistent" :: String)
              , "new_string" .= ("replacement" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` True
        T.unpack output `shouldContain` "not found"

    it "rejects when old_string has multiple matches" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "aaa bbb aaa"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("aaa" :: String)
              , "new_string" .= ("ccc" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` True
        T.unpack output `shouldContain` "not unique"

    it "rejects paths that escape the workspace" $ do
      withTestWorkspace $ \root _dir -> do
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("../../../etc/passwd" :: String)
              , "old_string" .= ("root" :: String)
              , "new_string" .= ("hacked" :: String)
              ]
        (_, isErr) <- runTool handler input
        isErr `shouldBe` True

    it "rejects blocked paths" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> ".env") "SECRET=x"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= (".env" :: String)
              , "old_string" .= ("SECRET" :: String)
              , "new_string" .= ("PUBLIC" :: String)
              ]
        (_, isErr) <- runTool handler input
        isErr `shouldBe` True

    it "handles multi-line replacements" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "line1\nline2\nline3\n"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("line2\nline3" :: String)
              , "new_string" .= ("replaced2\nreplaced3" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "test.txt"
        contents <- readFile (dir </> "test.txt")
        contents `shouldBe` "line1\nreplaced2\nreplaced3\n"

    it "rejects invalid JSON input" $ do
      let root = WorkspaceRoot "/tmp"
          (_, handler) = editTool root mkNoOpFileHandle
          input = object ["wrong_field" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

-- | Helper to create a temporary workspace for testing.
withTestWorkspace :: (WorkspaceRoot -> FilePath -> IO a) -> IO a
withTestWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-edit-test"
  createDirectoryIfMissing True dir
  let root = WorkspaceRoot dir
  action root dir
