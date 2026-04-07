module Agent.AgentDefSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files qualified as PF
import Test.Hspec

import PureClaw.Agent.AgentDef
import PureClaw.Handles.Log (mkNoOpLogHandle)

-- | Helper: resolve an 'AgentName' from raw text in a test (only used for
-- fixture names known to be valid).
mustName :: Text -> AgentName
mustName t = case mkAgentName t of
  Right n -> n
  Left e  -> error ("mustName: invalid fixture name " <> show t <> ": " <> show e)

-- | Helper: build an 'AgentDef' for an on-disk fixture directory, with
-- 'defaultAgentConfig'. Tests that exercise config parsing should construct
-- the record directly instead.
fixtureAgentDef :: Text -> FilePath -> AgentDef
fixtureAgentDef name dir = AgentDef
  { _ad_name   = mustName name
  , _ad_dir    = dir
  , _ad_config = defaultAgentConfig
  }

spec :: Spec
spec = do
  describe "mkAgentName" $ do
    it "rejects the empty string" $
      mkAgentName "" `shouldBe` Left AgentNameEmpty

    it "rejects path traversal (..)" $
      mkAgentName "../evil" `shouldBe` Left (AgentNameInvalidChars "../evil")

    it "rejects names containing a slash" $
      mkAgentName "foo/bar" `shouldBe` Left (AgentNameInvalidChars "foo/bar")

    it "rejects names containing a backslash" $
      mkAgentName "foo\\bar" `shouldBe` Left (AgentNameInvalidChars "foo\\bar")

    it "rejects names containing a null byte" $
      mkAgentName "a\0b" `shouldBe` Left (AgentNameInvalidChars "a\0b")

    it "rejects names with a leading dot" $
      mkAgentName ".hidden" `shouldBe` Left AgentNameLeadingDot

    it "rejects names longer than 64 characters" $
      mkAgentName (T.replicate 65 "a") `shouldBe` Left AgentNameTooLong

    it "accepts a valid name made of letters, digits, underscores, and hyphens" $
      fmap unAgentName (mkAgentName "valid-name_1") `shouldBe` Right "valid-name_1"

    it "accepts a name exactly 64 characters long" $
      fmap unAgentName (mkAgentName (T.replicate 64 "a")) `shouldBe` Right (T.replicate 64 "a")

  describe "AgentName FromJSON" $ do
    it "returns Nothing for an invalid name (prevents smart-constructor bypass)" $
      (Aeson.decode "\"../evil\"" :: Maybe AgentName) `shouldBe` Nothing

    it "returns Just for a valid name via JSON" $
      fmap unAgentName (Aeson.decode "\"zoe\"" :: Maybe AgentName) `shouldBe` Just "zoe"

  describe "extractFrontmatter" $ do
    it "extracts a TOML fence at the start of the input" $
      extractFrontmatter "---\nmodel = \"foo\"\n---\nbody"
        `shouldBe` (Just "model = \"foo\"", "body")

    it "returns Nothing and the full text when there is no fence" $
      extractFrontmatter "just body text"
        `shouldBe` (Nothing, "just body text")

    it "returns Nothing and the full text for a malformed fence (missing closer)" $
      extractFrontmatter "---\nmodel = \"foo\"\nbody with no closer"
        `shouldBe` (Nothing, "---\nmodel = \"foo\"\nbody with no closer")

  describe "parseAgentsMd" $ do
    it "parses a file with no frontmatter into defaultAgentConfig and full body" $
      parseAgentsMd "just body"
        `shouldBe` Right (defaultAgentConfig, "just body")

    it "parses an empty frontmatter block into defaultAgentConfig" $
      parseAgentsMd "---\n\n---\nbody"
        `shouldBe` Right (defaultAgentConfig, "body")

    it "parses all fields when present" $
      parseAgentsMd "---\nmodel = \"claude-opus\"\ntool_profile = \"full\"\nworkspace = \"~/ws\"\n---\nbody"
        `shouldBe` Right
          ( AgentConfig
              { _ac_model = Just "claude-opus"
              , _ac_toolProfile = Just "full"
              , _ac_workspace = Just "~/ws"
              }
          , "body"
          )

    it "ignores unknown fields in the frontmatter" $
      parseAgentsMd "---\nmodel = \"m\"\nunknown_field = \"x\"\n---\nbody"
        `shouldBe` Right
          ( defaultAgentConfig { _ac_model = Just "m" }
          , "body"
          )

    it "returns an error for a malformed TOML body in the frontmatter" $
      case parseAgentsMd "---\nmodel = = broken\n---\nbody" of
        Left (AgentsMdTomlError _) -> pure ()
        other -> expectationFailure $ "Expected AgentsMdTomlError, got: " ++ show other

  describe "composeAgentPrompt (basics)" $ do
    let log_ = mkNoOpLogHandle
        zoeDef = fixtureAgentDef "zoe" "test/fixtures/agents/zoe"
        limit8k = 8000

    it "concatenates SOUL, USER, AGENTS (body only) with section markers in injection order" $ do
      out <- composeAgentPrompt log_ zoeDef limit8k
      out `shouldBe` T.intercalate "\n\n"
        [ "--- SOUL ---\nYou are zoe."
        , "--- USER ---\nThe user is Doug."
        , "--- AGENTS ---\nAgent body text."
        ]

    it "emits only sections for files that exist (single-file case)" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "solo"
        createDirectory dir
        TIO.writeFile (dir </> "MEMORY.md") "remember this"
        out <- composeAgentPrompt log_ (fixtureAgentDef "solo" dir) limit8k
        out `shouldBe` "--- MEMORY ---\nremember this"

    it "skips files that are zero bytes" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") ""
        TIO.writeFile (dir </> "USER.md") "u"
        out <- composeAgentPrompt log_ (fixtureAgentDef "a" dir) limit8k
        out `shouldBe` "--- USER ---\nu"

    it "skips files that are whitespace only" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") "   \n\t \n"
        TIO.writeFile (dir </> "USER.md") "u"
        out <- composeAgentPrompt log_ (fixtureAgentDef "a" dir) limit8k
        out `shouldBe` "--- USER ---\nu"

    it "does not truncate a file exactly at the limit" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        let body = T.replicate 100 "x"
        TIO.writeFile (dir </> "MEMORY.md") body
        out <- composeAgentPrompt log_ (fixtureAgentDef "a" dir) 100
        out `shouldBe` "--- MEMORY ---\n" <> body

    it "truncates a file just over the limit with the exact marker" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        let body = T.replicate 101 "x"
        TIO.writeFile (dir </> "MEMORY.md") body
        out <- composeAgentPrompt log_ (fixtureAgentDef "a" dir) 100
        out `shouldBe` "--- MEMORY ---\n" <> T.replicate 100 "x"
              <> "\n[...truncated at 100 chars...]"

    it "truncates a 10000-char fixture at 8000 with the exact marker" $ do
      out <- composeAgentPrompt log_
        (fixtureAgentDef "needs-truncation" "test/fixtures/agents/needs-truncation")
        8000
      out `shouldBe` "--- AGENTS ---\n" <> T.replicate 8000 "x"
              <> "\n[...truncated at 8000 chars...]"

    it "rejects files larger than 1MB and skips them" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        let big = T.replicate (1024 * 1024 + 1) "x"
        TIO.writeFile (dir </> "MEMORY.md") big
        TIO.writeFile (dir </> "USER.md") "u"
        out <- composeAgentPrompt log_ (fixtureAgentDef "a" dir) limit8k
        out `shouldBe` "--- USER ---\nu"

    it "honors injection order SOUL,USER,AGENTS,MEMORY,IDENTITY,TOOLS,BOOTSTRAP" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "all"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") "s"
        TIO.writeFile (dir </> "USER.md") "u"
        TIO.writeFile (dir </> "AGENTS.md") "a"
        TIO.writeFile (dir </> "MEMORY.md") "m"
        TIO.writeFile (dir </> "IDENTITY.md") "i"
        TIO.writeFile (dir </> "TOOLS.md") "t"
        TIO.writeFile (dir </> "BOOTSTRAP.md") "b"
        out <- composeAgentPrompt log_ (fixtureAgentDef "all" dir) limit8k
        out `shouldBe` T.intercalate "\n\n"
          [ "--- SOUL ---\ns"
          , "--- USER ---\nu"
          , "--- AGENTS ---\na"
          , "--- MEMORY ---\nm"
          , "--- IDENTITY ---\ni"
          , "--- TOOLS ---\nt"
          , "--- BOOTSTRAP ---\nb"
          ]

  describe "composeAgentPromptWithBootstrap" $ do
    let log_ = mkNoOpLogHandle

    it "includes BOOTSTRAP.md when consumed=False" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") "s"
        TIO.writeFile (dir </> "BOOTSTRAP.md") "b"
        out <- composeAgentPromptWithBootstrap log_ (fixtureAgentDef "a" dir) 8000 False
        out `shouldBe` "--- SOUL ---\ns\n\n--- BOOTSTRAP ---\nb"

    it "skips BOOTSTRAP.md when consumed=True" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "a"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") "s"
        TIO.writeFile (dir </> "BOOTSTRAP.md") "b"
        out <- composeAgentPromptWithBootstrap log_ (fixtureAgentDef "a" dir) 8000 True
        out `shouldBe` "--- SOUL ---\ns"

  describe "composeAgentPrompt (empty dir)" $ do
    it "returns empty Text when the directory has no .md files (fixture)" $ do
      out <- composeAgentPrompt mkNoOpLogHandle
        (fixtureAgentDef "empty" "test/fixtures/agents/empty")
        8000
      out `shouldBe` ""

    it "returns empty Text when the directory is completely empty (temp)" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "nil"
        createDirectory dir
        out <- composeAgentPrompt mkNoOpLogHandle (fixtureAgentDef "nil" dir) 8000
        out `shouldBe` ""

  describe "discoverAgents" $ do
    let log_ = mkNoOpLogHandle

    it "returns an empty list when the parent directory is missing" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        agents <- discoverAgents log_ (tmp </> "does-not-exist")
        fmap _ad_name agents `shouldBe` []

    it "returns an empty list when the parent directory has no subdirs" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        agents <- discoverAgents log_ tmp
        fmap _ad_name agents `shouldBe` []

    it "discovers only directories with valid agent names, skipping invalid ones" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "zoe")
        createDirectoryIfMissing True (tmp </> "valid_1")
        createDirectoryIfMissing True (tmp </> "bad name")
        createDirectoryIfMissing True (tmp </> ".hidden")
        agents <- discoverAgents log_ tmp
        let names = T.unpack . unAgentName . _ad_name <$> agents
        names `shouldMatchList` ["zoe", "valid_1"]

  describe "loadAgent" $ do
    it "returns Nothing for a directory that does not exist" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        result <- loadAgent tmp (mustName "missing")
        result `shouldBe` Nothing

    it "returns Just AgentDef with defaultAgentConfig when AGENTS.md is absent" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "zoe"
        createDirectory dir
        TIO.writeFile (dir </> "SOUL.md") "s"
        result <- loadAgent tmp (mustName "zoe")
        case result of
          Just def -> do
            unAgentName (_ad_name def) `shouldBe` "zoe"
            _ad_dir def `shouldBe` dir
            _ad_config def `shouldBe` defaultAgentConfig
          Nothing -> expectationFailure "expected Just AgentDef"

    it "parses AGENTS.md frontmatter into AgentConfig when present" $
      withSystemTempDirectory "pureclaw-agent-" $ \tmp -> do
        let dir = tmp </> "haskell"
        createDirectory dir
        TIO.writeFile (dir </> "AGENTS.md")
          "---\nmodel = \"claude-sonnet\"\ntool_profile = \"full\"\n---\nbody"
        result <- loadAgent tmp (mustName "haskell")
        case result of
          Just def -> _ad_config def `shouldBe`
            defaultAgentConfig
              { _ac_model = Just "claude-sonnet"
              , _ac_toolProfile = Just "full"
              }
          Nothing -> expectationFailure "expected Just AgentDef"

  describe "validateWorkspace" $ do
    let checkDenied path = do
          exists <- doesDirectoryExist path
          if not exists
            then pendingWith ("denied path not present on this OS: " <> path)
            else
              withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
                result <- validateWorkspace home (T.pack path)
                case result of
                  Left (WorkspaceDenied _ _) -> pure ()
                  other -> expectationFailure $
                    "expected WorkspaceDenied for " <> path <> ", got: " <> show other

    it "accepts a valid existing temp directory" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home ->
        withSystemTempDirectory "pureclaw-ws-" $ \ws -> do
          result <- validateWorkspace home (T.pack ws)
          canonical <- canonicalizePath ws
          result `shouldBe` Right canonical

    it "rejects a relative path" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        result <- validateWorkspace home "relative/path"
        case result of
          Left (WorkspaceNotAbsolute _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceNotAbsolute, got: " <> show other

    it "rejects a nonexistent directory" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        result <- validateWorkspace home "/this/does/not/exist/pureclaw-xyz"
        case result of
          Left (WorkspaceDoesNotExist _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDoesNotExist, got: " <> show other

    it "tilde-expands a leading ~/ to the supplied home dir" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let sub = home </> "myws"
        createDirectory sub
        result <- validateWorkspace home "~/myws"
        canonical <- canonicalizePath sub
        result `shouldBe` Right canonical

    it "rejects /" $ checkDenied "/"
    it "rejects /etc" $ checkDenied "/etc"
    it "rejects /usr" $ checkDenied "/usr"
    it "rejects /bin" $ checkDenied "/bin"
    it "rejects /sbin" $ checkDenied "/sbin"
    it "rejects /var" $ checkDenied "/var"
    it "rejects /sys" $ checkDenied "/sys"
    it "rejects /proc" $ checkDenied "/proc"
    it "rejects /dev" $ checkDenied "/dev"

    it "rejects <home>/.ssh" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let d = home </> ".ssh"
        createDirectory d
        result <- validateWorkspace home (T.pack d)
        case result of
          Left (WorkspaceDenied _ _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

    it "rejects <home>/.gnupg" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let d = home </> ".gnupg"
        createDirectory d
        result <- validateWorkspace home (T.pack d)
        case result of
          Left (WorkspaceDenied _ _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

    it "rejects <home>/.aws" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let d = home </> ".aws"
        createDirectory d
        result <- validateWorkspace home (T.pack d)
        case result of
          Left (WorkspaceDenied _ _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

    it "rejects <home>/.config" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let d = home </> ".config"
        createDirectory d
        result <- validateWorkspace home (T.pack d)
        case result of
          Left (WorkspaceDenied _ _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

    it "rejects <home>/.pureclaw" $
      withSystemTempDirectory "pureclaw-ws-home-" $ \home -> do
        let d = home </> ".pureclaw"
        createDirectory d
        result <- validateWorkspace home (T.pack d)
        case result of
          Left (WorkspaceDenied _ _) -> pure ()
          other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

    it "rejects a symlink pointing to a denied directory (/etc)" $ do
      etcExists <- doesDirectoryExist "/etc"
      if not etcExists
        then pendingWith "/etc not present on this OS"
        else
          withSystemTempDirectory "pureclaw-ws-home-" $ \home ->
            withSystemTempDirectory "pureclaw-ws-link-" $ \tmp -> do
              let link = tmp </> "link-to-etc"
              PF.createSymbolicLink "/etc" link
              result <- validateWorkspace home (T.pack link)
              case result of
                Left (WorkspaceDenied _ _) -> pure ()
                other -> expectationFailure $ "expected WorkspaceDenied, got: " <> show other

  describe "ensureDefaultWorkspace" $ do
    it "creates <pureclawDir>/agents/<name>/workspace with mode 0o700" $
      withSystemTempDirectory "pureclaw-dir-" $ \pcDir -> do
        let name = mustName "zoe"
        ws <- ensureDefaultWorkspace pcDir name
        ws `shouldBe` pcDir </> "agents" </> "zoe" </> "workspace"
        exists <- doesDirectoryExist ws
        exists `shouldBe` True
        st <- PF.getFileStatus ws
        let mode = PF.fileMode st `PF.intersectFileModes` PF.accessModes
        mode `shouldBe` PF.ownerModes

    it "is idempotent (second call does not fail)" $
      withSystemTempDirectory "pureclaw-dir-" $ \pcDir -> do
        let name = mustName "zoe"
        _ <- ensureDefaultWorkspace pcDir name
        ws <- ensureDefaultWorkspace pcDir name
        exists <- doesDirectoryExist ws
        exists `shouldBe` True

  describe "resolveOverride" $ do
    it "returns the CLI value when present (highest priority)" $
      resolveOverride (Just "X") (Just "Y") (Just "Z") (Just "D")
        `shouldBe` Just ("X" :: Text)

    it "falls back to frontmatter when CLI is Nothing" $
      resolveOverride Nothing (Just "Y") (Just "Z") (Just "D")
        `shouldBe` Just ("Y" :: Text)

    it "falls back to config when CLI and frontmatter are Nothing" $
      resolveOverride Nothing Nothing (Just "Z") (Just "D")
        `shouldBe` Just ("Z" :: Text)

    it "falls back to default when all else is Nothing" $
      resolveOverride Nothing Nothing Nothing (Just "D")
        `shouldBe` Just ("D" :: Text)

    it "returns Nothing when all four are Nothing" $
      resolveOverride Nothing Nothing Nothing Nothing
        `shouldBe` (Nothing :: Maybe Text)
