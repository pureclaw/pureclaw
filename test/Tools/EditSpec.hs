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

    it "suggests replace_all in multi-match error" $ do
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
        T.unpack output `shouldContain` "replace_all"

  describe "replace_all mode" $ do
    it "replaces all occurrences when replace_all is true" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "foo bar foo baz foo"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("foo" :: String)
              , "new_string" .= ("qux" :: String)
              , "replace_all" .= True
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "3"
        contents <- readFile (dir </> "test.txt")
        contents `shouldBe` "qux bar qux baz qux"

    it "reports not-found when replace_all finds nothing" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello world"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("nonexistent" :: String)
              , "new_string" .= ("replacement" :: String)
              , "replace_all" .= True
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` True
        T.unpack output `shouldContain` "not found"

  describe "fuzzy matching" $ do
    it "matches with normalized whitespace when exact fails" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello   world"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("hello world" :: String)
              , "new_string" .= ("goodbye" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        T.unpack output `shouldContain` "whitespace"
        contents <- readFile (dir </> "test.txt")
        contents `shouldBe` "goodbye"

    it "matches with normalized line endings (CRLF)" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "line1\r\nline2\r\n"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("line1\nline2\n" :: String)
              , "new_string" .= ("replaced\n" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` False
        -- CRLF is caught by whitespace-normalized (tried first) since
        -- \r\n → \n changes whitespace composition
        T.unpack output `shouldContain` "matched via"

    it "reports not-found when fuzzy also fails" $ do
      withTestWorkspace $ \root dir -> do
        writeFile (dir </> "test.txt") "hello world"
        let fh = mkFileHandle root
            (_, handler) = editTool root fh
            input = object
              [ "path" .= ("test.txt" :: String)
              , "old_string" .= ("completely different" :: String)
              , "new_string" .= ("replacement" :: String)
              ]
        (output, isErr) <- runTool handler input
        isErr `shouldBe` True
        T.unpack output `shouldContain` "not found"

  describe "pure helpers" $ do
    it "countOccurrences counts correctly" $ do
      countOccurrences "aa" "aaaaaa" `shouldBe` 3
      countOccurrences "x" "hello" `shouldBe` 0
      countOccurrences "" "hello" `shouldBe` 0
      countOccurrences "hello" "hello" `shouldBe` 1

    it "replaceFirst replaces first occurrence only" $ do
      replaceFirst "a" "b" "axa" `shouldBe` "bxa"

    it "replaceAll replaces all occurrences" $ do
      replaceAll "a" "b" "axa" `shouldBe` "bxb"
      replaceAll "" "b" "hello" `shouldBe` "hello"

    it "fuzzyFind matches whitespace-normalized" $ do
      fuzzyFind "hello world" "hello   world" `shouldSatisfy` isUniqueFuzzy
      fuzzyFind "completely different" "hello world" `shouldBe` NoFuzzyMatch

-- | Helper to create a temporary workspace for testing.
withTestWorkspace :: (WorkspaceRoot -> FilePath -> IO a) -> IO a
withTestWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-edit-test"
  createDirectoryIfMissing True dir
  let root = WorkspaceRoot dir
  action root dir

isUniqueFuzzy :: FuzzyMatch -> Bool
isUniqueFuzzy (UniqueFuzzy _ _) = True
isUniqueFuzzy _ = False
