module Tools.SearchFilesSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Tools.Registry
import PureClaw.Tools.SearchFiles

spec :: Spec
spec = do
  describe "searchFilesTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = searchFilesTool (WorkspaceRoot "/tmp")
      _td_name def' `shouldBe` "search_files"

    it "finds content matches with line numbers" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "hello.txt") "hello world\ngoodbye world\nhello again\n"
        let (_, handler) = searchFilesTool root
            input = object ["pattern" .= ("hello" :: String)]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "hello"
        T.unpack output `shouldContain` "hello.txt"

    it "returns no-match message for missing pattern" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "hello.txt") "hello world\n"
        let (_, handler) = searchFilesTool root
            input = object ["pattern" .= ("nonexistent_xyz" :: String)]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "No matches"

    it "supports files_only output mode" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "a.txt") "target\n"
        writeFile (dir </> "b.txt") "nothing\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("target" :: String)
              , "output_mode" .= ("files_only" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "a.txt"
        T.unpack output `shouldSatisfy` (not . ("b.txt" `elem`) . words)

    it "supports count output mode" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "multi.txt") "foo\nbar\nfoo\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("foo" :: String)
              , "output_mode" .= ("count" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "2"

    it "respects file_glob filter" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "code.hs") "findme\n"
        writeFile (dir </> "readme.md") "findme\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("findme" :: String)
              , "file_glob" .= ("*.hs" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "code.hs"
        T.unpack output `shouldSatisfy` (not . ("readme.md" `elem`) . words)

    it "supports case-insensitive search" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "Hello World\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("hello" :: String)
              , "case_insensitive" .= True
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "Hello"

    it "supports context lines" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "ctx.txt") "line1\nline2\ntarget\nline4\nline5\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("target" :: String)
              , "context" .= (1 :: Int)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "line2"
        T.unpack output `shouldContain` "line4"

    it "respects search path" $ do
      withTestWorkspace $ \root dir -> do
        createDirectoryIfMissing True (dir </> "sub")
        writeFile (dir </> "sub" </> "deep.txt") "deep_match\n"
        writeFile (dir </> "top.txt") "deep_match\n"
        let (_, handler) = searchFilesTool root
            input = object
              [ "pattern" .= ("deep_match" :: String)
              , "path" .= ("sub" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "deep.txt"

    it "rejects invalid JSON input" $ do
      let (_, handler) = searchFilesTool (WorkspaceRoot "/tmp")
          input = object ["wrong_field" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

withTestWorkspace :: (WorkspaceRoot -> FilePath -> IO a) -> IO a
withTestWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-search-test"
  createDirectoryIfMissing True dir
  -- Clean any leftover files
  contents <- listDirectory dir
  mapM_ (\f -> removePathForcibly (dir </> f)) contents
  let root = WorkspaceRoot dir
  action root dir
