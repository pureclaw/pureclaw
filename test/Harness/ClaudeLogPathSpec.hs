module Harness.ClaudeLogPathSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.List (isInfixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files qualified as PF
import System.Posix.Types (FileMode, UserID)
import Test.Hspec

import PureClaw.Harness.ClaudeLogPath
import PureClaw.Harness.ClaudeSession

-- | A known-good canonical UUID (lowercase hex, 8-4-4-4-12).
goodUuid :: Text
goodUuid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

-- | Promote the test uuid (panics in the test only if the constant is wrong).
mkUuid :: ClaudeSessionUuid
mkUuid = case mkClaudeSessionUuid goodUuid of
  Right u -> u
  Left e  -> error ("test uuid invalid: " <> show e)

-- | Build a realistic claude-style project tree under @base@ with a single
-- log file at @<base>/projects/<dirName>/<uuid>.jsonl@ (mode 0600). Returns
-- the absolute path to the created log file.
plantLog :: FilePath -> FilePath -> Text -> IO FilePath
plantLog base dirName uuid = do
  let projDir = base </> "projects" </> dirName
      logFile = projDir </> (textToStr uuid <> ".jsonl")
  createDirectoryIfMissing True projDir
  writeFile logFile "{}\n"
  PF.setFileMode logFile 0o600
  pure logFile

textToStr :: Text -> String
textToStr = T.unpack

spec :: Spec
spec = do
  describe "ownerModeOk (D2.4 pure predicate)" $ do
    let euid = 1000 :: UserID
    it "accepts owner == euid and mode 0600" $
      ownerModeOk euid (0o600 :: FileMode) euid `shouldBe` True

    it "accepts owner == euid and mode 0400" $
      ownerModeOk euid 0o400 euid `shouldBe` True

    it "rejects a foreign owner even with a safe mode" $
      ownerModeOk euid 0o600 (euid + 1) `shouldBe` False

    it "rejects a group-writable mode" $
      ownerModeOk euid 0o660 euid `shouldBe` False

    it "rejects an other-writable mode" $
      ownerModeOk euid 0o606 euid `shouldBe` False

  describe "mkSafeClaudeLogPath (D2.2 glob, happy path)" $ do
    let cases =
          [ ("plain", "-Users-zoe-proj")
          , ("nested", "-Users-zoe-proj-sub-dir")
          , ("space-sanitized", "-Users-zoe-proj-space")
          , ("dot-sanitized", "-Users-zoe-proj-dot")
          ]
    forM_ cases $ \(label, dirName) ->
      it ("locates the log by uuid-glob (" <> label <> ")") $
        withSystemTempDirectory "clp-happy" $ \base -> do
          logFile <- plantLog base dirName goodUuid
          res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
          case res of
            Right safe -> do
              -- accessor returns a canonicalized path ending in the uuid file
              let p = getSafeClaudeLogPath safe
              (".jsonl" `isInfixOf` p) `shouldBe` True
              (textToStr goodUuid `isInfixOf` p) `shouldBe` True
              -- and it points at the file we planted
              same <- sameFile p logFile
              same `shouldBe` True
            Left e -> expectationFailure ("expected Right, got " <> show e)

  describe "mkSafeClaudeLogPath (D2.2 zero/multiple hits)" $ do
    it "returns a typed not-found error when no log exists" $
      withSystemTempDirectory "clp-missing" $ \base -> do
        createDirectoryIfMissing True (base </> "projects")
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          -- bind + inspect the carried path (forces the error field)
          Left (ClaudeLogNotFound root) ->
            ("projects" `isSuffixOf` root) `shouldBe` True
          other -> expectationFailure ("expected ClaudeLogNotFound, got " <> show other)

    it "returns a typed not-found error when the projects root is absent" $
      withSystemTempDirectory "clp-noroot" $ \base -> do
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          Left (ClaudeLogNotFound root) ->
            ("projects" `isSuffixOf` root) `shouldBe` True
          other -> expectationFailure ("expected ClaudeLogNotFound, got " <> show other)

    it "returns a typed ambiguity error when the same uuid appears twice" $
      withSystemTempDirectory "clp-dup" $ \base -> do
        _ <- plantLog base "-Users-zoe-a" goodUuid
        _ <- plantLog base "-Users-zoe-b" goodUuid
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          Left (ClaudeLogAmbiguous ps) -> do
            length ps `shouldBe` 2
            all (".jsonl" `isSuffixOf`) ps `shouldBe` True
          other -> expectationFailure ("expected ClaudeLogAmbiguous, got " <> show other)

  describe "mkSafeClaudeLogPath (D2.3 symlink escape containment)" $
    it "rejects a log file that is a symlink to a target outside projects root" $
      withSystemTempDirectory "clp-symesc" $ \base -> do
        -- create the real target OUTSIDE the projects root
        let outsideDir = base </> "outside"
        createDirectoryIfMissing True outsideDir
        let target = outsideDir </> "secret.jsonl"
        writeFile target "{}\n"
        PF.setFileMode target 0o600
        -- create a project dir whose <uuid>.jsonl is a symlink to the outside target
        let projDir = base </> "projects" </> "-Users-zoe-proj"
        createDirectoryIfMissing True projDir
        let linkPath = projDir </> (textToStr goodUuid <> ".jsonl")
        PF.createSymbolicLink target linkPath
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          Left (ClaudeLogEscapesRoot root cand) -> do
            ("projects" `isInfixOf` root) `shouldBe` True
            ("secret.jsonl" `isSuffixOf` cand) `shouldBe` True
          other -> expectationFailure ("expected ClaudeLogEscapesRoot, got " <> show other)

  describe "mkSafeClaudeLogPath (D2.4 O_NOFOLLOW leaf symlink)" $
    it "rejects an IN-root leaf symlink (canonical containment passes, but O_NOFOLLOW open fails)" $
      withSystemTempDirectory "clp-leafsym" $ \base -> do
        -- Real target lives INSIDE the projects root, so canonicalizePath
        -- containment passes — only the O_NOFOLLOW open defeats the symlink.
        let projDir = base </> "projects" </> "-Users-zoe-proj"
        createDirectoryIfMissing True projDir
        let realLog = projDir </> "real.jsonl"
        writeFile realLog "{}\n"
        PF.setFileMode realLog 0o600
        let linkPath = projDir </> (textToStr goodUuid <> ".jsonl")
        PF.createSymbolicLink realLog linkPath
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          -- ELOOP arm reports a zeroed mode and owner
          Left (ClaudeLogInsecure p m o) -> do
            (".jsonl" `isSuffixOf` p) `shouldBe` True
            m `shouldBe` 0
            o `shouldBe` 0
          other -> expectationFailure ("expected ClaudeLogInsecure, got " <> show other)

  describe "mkSafeClaudeLogPath (D2.4 owner/mode rejection)" $
    it "rejects a group/world-writable log file" $
      withSystemTempDirectory "clp-mode" $ \base -> do
        let projDir = base </> "projects" </> "-Users-zoe-proj"
            logFile = projDir </> (textToStr goodUuid <> ".jsonl")
        createDirectoryIfMissing True projDir
        writeFile logFile "{}\n"
        PF.setFileMode logFile 0o666  -- world-writable
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          -- real fstat arm carries the actual (non-zero) mode and owner
          Left (ClaudeLogInsecure p m o) -> do
            (".jsonl" `isSuffixOf` p) `shouldBe` True
            -- world-writable bit is present in the reported mode
            (m `intersectsBit` 0o002) `shouldBe` True
            o `shouldSatisfy` (>= 0)
          other -> expectationFailure ("expected ClaudeLogInsecure, got " <> show other)

  describe "mkSafeClaudeLogPath (D2.3 symlinked project DIRECTORY escape)" $
    it "rejects when the containing project dir is a symlink pointing outside the root" $
      withSystemTempDirectory "clp-dirsym" $ \base -> do
        -- real dir holding the log, located outside the projects root
        let realDir = base </> "elsewhere"
        createDirectoryIfMissing True realDir
        let realLog = realDir </> (textToStr goodUuid <> ".jsonl")
        writeFile realLog "{}\n"
        PF.setFileMode realLog 0o600
        -- projects root contains a symlink dir entry that points at realDir
        createDirectoryIfMissing True (base </> "projects")
        let linkDir = base </> "projects" </> "-Users-zoe-proj"
        PF.createSymbolicLink realDir linkDir
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          Left (ClaudeLogEscapesRoot root cand) -> do
            ("projects" `isInfixOf` root) `shouldBe` True
            (".jsonl" `isSuffixOf` cand) `shouldBe` True
          other -> expectationFailure ("expected ClaudeLogEscapesRoot, got " <> show other)

  describe "chooseBase (pure base-dir choice — all branches)" $ do
    it "uses the env value when set and non-empty" $
      getClaudeBase (chooseBase (Just "/tmp/cfg") "/home/zoe")
        `shouldBe` "/tmp/cfg"

    it "falls back to <home>/.claude when env is an empty string" $
      getClaudeBase (chooseBase (Just "") "/home/zoe")
        `shouldBe` ("/home/zoe" </> ".claude")

    it "falls back to <home>/.claude when env is unset (Nothing)" $
      getClaudeBase (chooseBase Nothing "/home/zoe")
        `shouldBe` ("/home/zoe" </> ".claude")

  describe "resolveClaudeBase (IO wrapper over chooseBase)" $ do
    it "uses CLAUDE_CONFIG_DIR when it is set and non-empty" $
      withSavedClaudeEnv $ do
        setEnv "CLAUDE_CONFIG_DIR" "/tmp/my-claude-config"
        base <- resolveClaudeBase
        getClaudeBase base `shouldBe` "/tmp/my-claude-config"

    it "falls back to ~/.claude when CLAUDE_CONFIG_DIR is unset" $
      withSavedClaudeEnv $ do
        unsetEnv "CLAUDE_CONFIG_DIR"
        home <- getHomeDirectory
        base <- resolveClaudeBase
        let expected = home </> ".claude"
        (".claude" `isSuffixOf` getClaudeBase base) `shouldBe` True
        getClaudeBase base `shouldBe` expected

  describe "derived/declared instances (Eq/Ord/Show)" $ do
    it "ClaudeBase has a working Eq and Show" $ do
      mkClaudeBase "/a" `shouldBe` mkClaudeBase "/a"
      mkClaudeBase "/a" `shouldNotBe` mkClaudeBase "/b"
      show (mkClaudeBase "/a") `shouldSatisfy` ("/a" `isInfixOf`)

    it "ClaudeLogPathError has a working Eq and Show" $ do
      ClaudeLogNotFound "/x" `shouldBe` ClaudeLogNotFound "/x"
      ClaudeLogNotFound "/x" `shouldNotBe` ClaudeLogNotFound "/y"
      show (ClaudeLogAmbiguous ["/x", "/y"])
        `shouldSatisfy` ("Ambiguous" `isInfixOf`)

    it "SafeClaudeLogPath has a working Eq/Ord exercised via two values" $
      withSystemTempDirectory "clp-eq" $ \base -> do
        _ <- plantLog base "-Users-zoe-proj" goodUuid
        r1 <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        r2 <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case (r1, r2) of
          (Right a, Right b) -> do
            a `shouldBe` b          -- Eq
            compare a b `shouldBe` EQ -- Ord
          _ -> expectationFailure "expected both to validate"

  describe "redacted Show (D2.5)" $
    it "does NOT print the full path into the Show output" $
      withSystemTempDirectory "clp-show" $ \base -> do
        _ <- plantLog base "-Users-zoe-proj" goodUuid
        res <- mkSafeClaudeLogPath (mkClaudeBase base) mkUuid Nothing
        case res of
          Right safe -> do
            let shown = show safe
            (base `isInfixOf` shown) `shouldBe` False
            ("redacted" `isInfixOf` shown) `shouldBe` True
          Left e -> expectationFailure ("expected Right, got " <> show e)

-- | True iff @mode@ has any of the @mask@ bits set (used to assert the
-- reported insecure mode actually carries the world-writable bit).
intersectsBit :: FileMode -> FileMode -> Bool
intersectsBit mode mask = (mode `PF.intersectFileModes` mask) /= 0

-- | Run an action with @CLAUDE_CONFIG_DIR@ saved and restored afterwards, so
-- the env-resolution tests never leak global state into other specs.
withSavedClaudeEnv :: IO a -> IO a
withSavedClaudeEnv action =
  bracket
    (lookupEnv "CLAUDE_CONFIG_DIR")
    restore
    (const action)
  where
    restore saved = case saved of
      Just v  -> setEnv "CLAUDE_CONFIG_DIR" v
      Nothing -> unsetEnv "CLAUDE_CONFIG_DIR"

-- | True iff two paths refer to the same inode (device+inode equality),
-- which is robust to /private vs /var canonicalization on macOS.
sameFile :: FilePath -> FilePath -> IO Bool
sameFile a b = do
  sa <- PF.getFileStatus a
  sb <- PF.getFileStatus b
  pure (PF.deviceID sa == PF.deviceID sb && PF.fileID sa == PF.fileID sb)
