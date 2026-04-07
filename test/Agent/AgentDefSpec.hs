module Agent.AgentDefSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.AgentDef

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
