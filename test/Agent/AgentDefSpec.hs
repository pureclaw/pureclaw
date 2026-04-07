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
