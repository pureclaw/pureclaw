module Tools.FileWriteSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Tools.FileWrite
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "fileWriteTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = fileWriteTool (WorkspaceRoot "/tmp") mkNoOpFileHandle
      _td_name def' `shouldBe` "file_write"

    it "writes a new file" $ do
      withTestWorkspace $ \root dir -> do
        let fh = mkFileHandle root
            (_, handler) = fileWriteTool root fh
            input = object
              [ "path" .= ("new-file.txt" :: String)
              , "content" .= ("hello world" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "new-file.txt"
        exists <- doesFileExist (dir </> "new-file.txt")
        exists `shouldBe` True
        contents <- readFile (dir </> "new-file.txt")
        contents `shouldBe` "hello world"

    it "overwrites an existing file" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "existing.txt") "old content"
        let fh = mkFileHandle root
            (_, handler) = fileWriteTool root fh
            input = object
              [ "path" .= ("existing.txt" :: String)
              , "content" .= ("new content" :: String)
              ]
        (_output, isErr) <- runTool handler input
        isErr `shouldBe` False
        contents <- readFile (dir </> "existing.txt")
        contents `shouldBe` "new content"

    it "creates parent directories for new files" $ do
      withTestWorkspace $ \root dir -> do
        let fh = mkFileHandle root
            (_, handler) = fileWriteTool root fh
            input = object
              [ "path" .= ("subdir/nested/new-file.txt" :: String)
              , "content" .= ("deep content" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "new-file.txt"
        exists <- doesFileExist (dir </> "subdir" </> "nested" </> "new-file.txt")
        exists `shouldBe` True
        contents <- readFile (dir </> "subdir" </> "nested" </> "new-file.txt")
        contents `shouldBe` "deep content"

    it "rejects paths that escape the workspace" $ do
      withTestWorkspace $ \root _dir -> do
        let fh = mkFileHandle root
            (_, handler) = fileWriteTool root fh
            input = object
              [ "path" .= ("../../../etc/evil" :: String)
              , "content" .= ("hacked" :: String)
              ]
        (_, isErr) <- runTool handler input
        isErr `shouldBe` True

    it "rejects blocked paths" $ do
      withTestWorkspace $ \root _dir -> do
        let fh = mkFileHandle root
            (_, handler) = fileWriteTool root fh
            input = object
              [ "path" .= (".env" :: String)
              , "content" .= ("SECRET=x" :: String)
              ]
        (_, isErr) <- runTool handler input
        isErr `shouldBe` True

    it "rejects invalid JSON input" $ do
      let (_, handler) = fileWriteTool (WorkspaceRoot "/tmp") mkNoOpFileHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

withTestWorkspace :: (WorkspaceRoot -> FilePath -> IO a) -> IO a
withTestWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-filewrite-test"
  createDirectoryIfMissing True dir
  contents <- listDirectory dir
  mapM_ (\f -> removePathForcibly (dir </> f)) contents
  let root = WorkspaceRoot dir
  action root dir
