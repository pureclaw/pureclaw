module Security.PathSpec (spec) where

import Test.Hspec
import Data.List qualified as L
import System.Directory
import System.FilePath
import System.IO.Temp
import System.Posix.Files qualified as PF
import System.Posix.User qualified as PU

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

    it "rejects blocked paths (.pureclaw)" $ withWorkspace $ \root wsDir -> do
      createDirectoryIfMissing True (wsDir </> ".pureclaw")
      writeFile (wsDir </> ".pureclaw" </> "vault.age") "encrypted"
      result <- mkSafePath root ".pureclaw/vault.age"
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

  describe "mkSafeKeyPath" $ do
    it "accepts a relative path under the keys root" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        let kr = KeysRoot canon
            kf = canon </> "id_ed25519"
        writeFile kf ""
        PF.setFileMode kf 0o400
        result <- mkSafeKeyPath kr "id_ed25519"
        case result of
          Right p  -> getSafeKeyPath p `shouldBe` kf
          Left  e  -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "rejects .. traversal in the requested path" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        let kr = KeysRoot canon
        result <- mkSafeKeyPath kr ("../" </> "escape")
        case result of
          Left (PathEscapesWorkspace _ _) -> pure ()
          Left e -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
          Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects a symlink that resolves outside the root" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir ->
      withSystemTempDirectory "pureclaw-outside" $ \outsideDir -> do
        canonKeys <- canonicalizePath keysDir
        canonOut  <- canonicalizePath outsideDir
        let target  = canonOut </> "secret"
            symlink = canonKeys </> "evil"
        writeFile target ""
        PF.setFileMode target 0o400
        PF.createSymbolicLink target symlink
        result <- mkSafeKeyPath (KeysRoot canonKeys) "evil"
        case result of
          Left (PathEscapesWorkspace _ _) -> pure ()
          Left e -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
          Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects a non-existent root" $ do
      result <- mkSafeKeyPath (KeysRoot "/no/such/dir/anywhere") "x"
      case result of
        Left (PathDoesNotExist _) -> pure ()
        Left e -> expectationFailure $ "Expected PathDoesNotExist, got: " ++ show e
        Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects a file whose mode is 0644" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        let kf = canon </> "loose"
        writeFile kf ""
        PF.setFileMode kf 0o644
        result <- mkSafeKeyPath (KeysRoot canon) "loose"
        case result of
          Left PathInsecureMode{} -> pure ()
          Left e -> expectationFailure $ "Expected PathInsecureMode, got: " ++ show e
          Right _ -> expectationFailure "Expected Left, got Right"

    it "accepts a file with mode 0400 owned by geteuid" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        let kf = canon </> "good"
        writeFile kf ""
        PF.setFileMode kf 0o400
        uid <- PU.getEffectiveUserID
        st  <- PF.getFileStatus kf
        PF.fileOwner st `shouldBe` uid
        result <- mkSafeKeyPath (KeysRoot canon) "good"
        case result of
          Right p -> getSafeKeyPath p `shouldBe` kf
          Left  e -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "accepts a non-existent file under the root (key will be written later)" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        result <- mkSafeKeyPath (KeysRoot canon) "future-key"
        case result of
          Right p -> getSafeKeyPath p `shouldBe` (canon </> "future-key")
          Left  e -> expectationFailure $ "Expected Right, got Left: " ++ show e

  describe "mkSafeRuntimePath" $ do
    it "accepts a relative path under the runtime root" $
      withSystemTempDirectory "pureclaw-run" $ \runDir -> do
        canon <- canonicalizePath runDir
        let rr = RuntimeRoot canon
        result <- mkSafeRuntimePath rr "ctrl.sock"
        case result of
          Right p -> getSafeRuntimePath p `shouldBe` (canon </> "ctrl.sock")
          Left  e -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "rejects .. traversal in the requested path" $
      withSystemTempDirectory "pureclaw-run" $ \runDir -> do
        canon <- canonicalizePath runDir
        result <- mkSafeRuntimePath (RuntimeRoot canon) ("../" </> "escape")
        case result of
          Left (PathEscapesWorkspace _ _) -> pure ()
          Left e -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
          Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects a symlink that resolves outside the root" $
      withSystemTempDirectory "pureclaw-run" $ \runDir ->
      withSystemTempDirectory "pureclaw-out" $ \outDir -> do
        canonRun <- canonicalizePath runDir
        canonOut <- canonicalizePath outDir
        let target  = canonOut </> "outside.sock"
            symlink = canonRun </> "evil.sock"
        writeFile target ""
        PF.createSymbolicLink target symlink
        result <- mkSafeRuntimePath (RuntimeRoot canonRun) "evil.sock"
        case result of
          Left (PathEscapesWorkspace _ _) -> pure ()
          Left e -> expectationFailure $ "Expected PathEscapesWorkspace, got: " ++ show e
          Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects a non-existent root" $ do
      result <- mkSafeRuntimePath (RuntimeRoot "/no/such/dir/anywhere") "x"
      case result of
        Left (PathDoesNotExist _) -> pure ()
        Left e -> expectationFailure $ "Expected PathDoesNotExist, got: " ++ show e
        Right _ -> expectationFailure "Expected Left, got Right"

  describe "Show redaction" $ do
    it "Show SafeKeyPath does not include the underlying path string" $
      withSystemTempDirectory "pureclaw-keys" $ \keysDir -> do
        canon <- canonicalizePath keysDir
        let kf = canon </> "secret-key"
        writeFile kf ""
        PF.setFileMode kf 0o400
        result <- mkSafeKeyPath (KeysRoot canon) "secret-key"
        case result of
          Right p -> do
            let s = show p
            s `shouldNotSatisfy` ("secret-key" `L.isInfixOf`)
            s `shouldNotSatisfy` (canon `L.isInfixOf`)
            s `shouldSatisfy` ("redacted" `L.isInfixOf`)
          Left e -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "Show SafeRuntimePath does not include the underlying path string" $
      withSystemTempDirectory "pureclaw-run" $ \runDir -> do
        canon <- canonicalizePath runDir
        result <- mkSafeRuntimePath (RuntimeRoot canon) "ctrl-marker.sock"
        case result of
          Right p -> do
            let s = show p
            s `shouldNotSatisfy` ("ctrl-marker.sock" `L.isInfixOf`)
            s `shouldNotSatisfy` (canon `L.isInfixOf`)
            s `shouldSatisfy` ("redacted" `L.isInfixOf`)
          Left e -> expectationFailure $ "Expected Right, got Left: " ++ show e

  describe "ensureKeysRoot" $ do
    it "creates the directory if missing with mode 0700" $
      withSystemTempDirectory "pureclaw-parent" $ \parent -> do
        let dir = parent </> "keys"
        kr <- ensureKeysRoot dir
        case kr of
          KeysRoot p -> p `shouldBe` dir
        exists <- doesDirectoryExist dir
        exists `shouldBe` True
        st <- PF.getFileStatus dir
        (PF.fileMode st `PF.intersectFileModes` 0o777) `shouldBe` 0o700

    it "is idempotent (does not fail if the directory already exists)" $
      withSystemTempDirectory "pureclaw-parent" $ \parent -> do
        let dir = parent </> "keys"
        _ <- ensureKeysRoot dir
        kr <- ensureKeysRoot dir
        case kr of
          KeysRoot p -> p `shouldBe` dir
        st <- PF.getFileStatus dir
        (PF.fileMode st `PF.intersectFileModes` 0o777) `shouldBe` 0o700

  describe "ensureRuntimeRoot" $ do
    it "creates the directory if missing with mode 0700" $
      withSystemTempDirectory "pureclaw-parent" $ \parent -> do
        let dir = parent </> "run"
        rr <- ensureRuntimeRoot dir
        case rr of
          RuntimeRoot p -> p `shouldBe` dir
        exists <- doesDirectoryExist dir
        exists `shouldBe` True
        st <- PF.getFileStatus dir
        (PF.fileMode st `PF.intersectFileModes` 0o777) `shouldBe` 0o700

    it "is idempotent (does not fail if the directory already exists)" $
      withSystemTempDirectory "pureclaw-parent" $ \parent -> do
        let dir = parent </> "run"
        _ <- ensureRuntimeRoot dir
        rr <- ensureRuntimeRoot dir
        case rr of
          RuntimeRoot p -> p `shouldBe` dir
        st <- PF.getFileStatus dir
        (PF.fileMode st `PF.intersectFileModes` 0o777) `shouldBe` 0o700

-- Helper: bracket-like but simpler for our needs
finally_ :: IO a -> IO b -> IO a
finally_ action cleanup = do
  result <- action
  _ <- cleanup
  pure result
