module Tools.PatchSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Tools.Patch
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "patchTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = patchTool (WorkspaceRoot "/tmp") mkNoOpFileHandle
      _td_name def' `shouldBe` "patch"

    it "applies a simple single-file patch" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.hs") "module Main where\n\nmain :: IO ()\nmain = putStrLn \"hello\"\n"
        let fh = mkFileHandle root
            (_, handler) = patchTool root fh
            input = object ["patch" .= T.unlines
              [ "--- a/test.hs"
              , "+++ b/test.hs"
              , "@@ -3,2 +3,2 @@"
              , "-main :: IO ()"
              , "-main = putStrLn \"hello\""
              , "+main :: IO ()"
              , "+main = putStrLn \"goodbye\""
              ]]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "Patched"
        contents <- readFile (dir </> "test.hs")
        contents `shouldContain` "goodbye"

    it "applies a multi-file patch" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "a.txt") "line1\nline2\nline3\n"
        writeFile (dir </> "b.txt") "alpha\nbeta\ngamma\n"
        let fh = mkFileHandle root
            (_, handler) = patchTool root fh
            input = object ["patch" .= T.unlines
              [ "--- a/a.txt"
              , "+++ b/a.txt"
              , "@@ -1,3 +1,3 @@"
              , "-line2"
              , "+LINE2"
              , "--- a/b.txt"
              , "+++ b/b.txt"
              , "@@ -1,3 +1,3 @@"
              , "-beta"
              , "+BETA"
              ]]
        (_output, isErr) <- runTool handler input
        isErr `shouldBe` False
        aContents <- readFile (dir </> "a.txt")
        bContents <- readFile (dir </> "b.txt")
        aContents `shouldContain` "LINE2"
        bContents `shouldContain` "BETA"

    it "reports error for non-matching hunks" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello world\n"
        let fh = mkFileHandle root
            (_, handler) = patchTool root fh
            input = object ["patch" .= T.unlines
              [ "--- a/test.txt"
              , "+++ b/test.txt"
              , "@@ -1,1 +1,1 @@"
              , "-nonexistent line"
              , "+replacement"
              ]]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` True
        T.unpack output `shouldContain` "could not find"

    it "rejects empty patches" $ do
      let (_, handler) = patchTool (WorkspaceRoot "/tmp") mkNoOpFileHandle
          input = object ["patch" .= ("" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Empty patch"

    it "rejects invalid JSON input" $ do
      let (_, handler) = patchTool (WorkspaceRoot "/tmp") mkNoOpFileHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

  describe "parsePatch" $ do
    it "parses a single-file patch" $ do
      let result = parsePatch $ T.unlines
            [ "--- a/foo.hs"
            , "+++ b/foo.hs"
            , "@@ -1,2 +1,2 @@"
            , "-old"
            , "+new"
            ]
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right files -> case files of
          [f] -> do
            _pf_path f `shouldBe` "foo.hs"
            length (_pf_hunks f) `shouldBe` 1
          _ -> expectationFailure $ "Expected 1 file, got " <> show (length files)

    it "parses a multi-file patch" $ do
      let result = parsePatch $ T.unlines
            [ "--- a/one.txt"
            , "+++ b/one.txt"
            , "@@ -1 +1 @@"
            , "-a"
            , "+b"
            , "--- a/two.txt"
            , "+++ b/two.txt"
            , "@@ -1 +1 @@"
            , "-c"
            , "+d"
            ]
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right files -> length files `shouldBe` 2

    it "parses context lines" $ do
      let result = parsePatch $ T.unlines
            [ "--- a/ctx.txt"
            , "+++ b/ctx.txt"
            , "@@ -1,4 +1,4 @@"
            , " context1"
            , " context2"
            , "-old"
            , "+new"
            ]
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right [f] -> case _pf_hunks f of
          [hunk] -> do
            length (_ph_context hunk) `shouldBe` 2
            _ph_removals hunk `shouldBe` ["old"]
            _ph_additions hunk `shouldBe` ["new"]
          hs -> expectationFailure $ "Expected 1 hunk, got " <> show (length hs)
        Right fs -> expectationFailure $ "Expected 1 file, got " <> show (length fs)

withTestWorkspace :: (WorkspaceRoot -> FilePath -> IO a) -> IO a
withTestWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-patch-test"
  createDirectoryIfMissing True dir
  contents <- listDirectory dir
  mapM_ (\f -> removePathForcibly (dir </> f)) contents
  let root = WorkspaceRoot dir
  action root dir
