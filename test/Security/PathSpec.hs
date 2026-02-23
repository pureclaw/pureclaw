module Security.PathSpec (spec) where

import Test.Hspec
import System.Directory
import System.FilePath

import PureClaw.Core.Types
import PureClaw.Security.Path

spec :: Spec
spec = do
  -- Set up a temporary workspace for all path tests
  let withWorkspace action = do
        tmp <- getTemporaryDirectory
        let wsDir = tmp </> "pureclaw-test-workspace"
        createDirectoryIfMissing True (wsDir </> "subdir")
        -- Create a test file
        writeFile (wsDir </> "hello.txt") "hello"
        writeFile (wsDir </> "subdir" </> "nested.txt") "nested"
        -- Create blocked path files
        createDirectoryIfMissing True (wsDir </> ".ssh")
        writeFile (wsDir </> ".env") "SECRET=oops"
        wsRoot <- canonicalizePath wsDir
        action (WorkspaceRoot wsRoot) wsRoot
          `finally_` removeDirectoryRecursive wsDir

  describe "mkSafePath" $ do
    it "allows paths within the workspace" $ withWorkspace $ \root wsDir -> do
      result <- mkSafePath root "hello.txt"
      case result of
        Right sp -> getSafePath sp `shouldBe` (wsDir </> "hello.txt")
        Left e   -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "allows nested paths within the workspace" $ withWorkspace $ \root wsDir -> do
      result <- mkSafePath root ("subdir" </> "nested.txt")
      case result of
        Right sp -> getSafePath sp `shouldBe` (wsDir </> "subdir" </> "nested.txt")
        Left e   -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "rejects paths that escape the workspace via .." $ withWorkspace $ \root _ -> do
      result <- mkSafePath root ("../" </> "etc" </> "passwd")
      case result of
        Left (PathEscapesWorkspace _ _) -> pure ()
        Left e   -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
        Right _  -> expectationFailure "Expected Left, got Right"

    it "rejects absolute paths outside workspace" $ withWorkspace $ \root _ -> do
      result <- mkSafePath root "/etc/passwd"
      case result of
        Left (PathEscapesWorkspace _ _) -> pure ()
        Left e   -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
        Right _  -> expectationFailure "Expected Left, got Right"

    it "rejects blocked paths (.env)" $ withWorkspace $ \root _ -> do
      result <- mkSafePath root ".env"
      case result of
        Left (PathIsBlocked _ _) -> pure ()
        Left e   -> expectationFailure $ "Expected PathIsBlocked, got: " ++ show e
        Right _  -> expectationFailure "Expected Left, got Right"

    it "rejects blocked paths (.ssh)" $ withWorkspace $ \root _ -> do
      result <- mkSafePath root ".ssh"
      case result of
        Left (PathIsBlocked _ _) -> pure ()
        Left e   -> expectationFailure $ "Expected PathIsBlocked, got: " ++ show e
        Right _  -> expectationFailure "Expected Left, got Right"

    it "returns PathDoesNotExist for missing files" $ withWorkspace $ \root _ -> do
      result <- mkSafePath root "nonexistent.txt"
      case result of
        Left (PathDoesNotExist _) -> pure ()
        Left e   -> expectationFailure $ "Expected PathDoesNotExist, got: " ++ show e
        Right _  -> expectationFailure "Expected Left, got Right"

  describe "PathError" $ do
    it "has Show instance" $ do
      let e = PathEscapesWorkspace "../secret" "/etc/secret"
      show e `shouldSatisfy` (not . null)

    it "has Eq instance" $ do
      PathDoesNotExist "a" `shouldBe` PathDoesNotExist "a"
      PathDoesNotExist "a" `shouldNotBe` PathDoesNotExist "b"

-- Helper: bracket-like but simpler for our needs
finally_ :: IO a -> IO b -> IO a
finally_ action cleanup = do
  result <- action
  _ <- cleanup
  pure result
