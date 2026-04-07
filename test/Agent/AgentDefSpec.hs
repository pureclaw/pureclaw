module Agent.AgentDefSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
