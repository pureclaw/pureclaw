module Security.PolicySpec (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Text qualified as T

import PureClaw.Core.Types
import PureClaw.Security.Policy

spec :: Spec
spec = do
  describe "defaultPolicy" $ do
    it "denies all commands" $
      property $ \(cmdText :: String) ->
        isCommandAllowed defaultPolicy (CommandName (T.pack cmdText)) `shouldBe` False

    it "has Deny autonomy" $
      policyAutonomy defaultPolicy `shouldBe` Deny

  describe "allowCommand" $ do
    it "adds a command to the allowed set" $ do
      let policy = allowCommand (CommandName "git") defaultPolicy
      isCommandAllowed policy (CommandName "git") `shouldBe` True

    it "does not affect other commands" $ do
      let policy = allowCommand (CommandName "git") defaultPolicy
      isCommandAllowed policy (CommandName "rm") `shouldBe` False

    it "can add multiple commands" $ do
      let policy = allowCommand (CommandName "ls")
                 $ allowCommand (CommandName "git") defaultPolicy
      isCommandAllowed policy (CommandName "git") `shouldBe` True
      isCommandAllowed policy (CommandName "ls") `shouldBe` True

  describe "denyCommand" $ do
    it "removes a command from the allowed set" $ do
      let policy = denyCommand (CommandName "git")
                 $ allowCommand (CommandName "git") defaultPolicy
      isCommandAllowed policy (CommandName "git") `shouldBe` False

    it "is a no-op for commands not in the set" $ do
      let policy = denyCommand (CommandName "rm") defaultPolicy
      isCommandAllowed policy (CommandName "rm") `shouldBe` False

  describe "withAutonomy" $ do
    it "sets the autonomy level" $ do
      let policy = withAutonomy Full defaultPolicy
      policyAutonomy policy `shouldBe` Full

    it "can override previous autonomy" $ do
      let policy = withAutonomy Supervised $ withAutonomy Full defaultPolicy
      policyAutonomy policy `shouldBe` Supervised

  describe "AllowAll commands" $ do
    it "allows everything when policy uses AllowAll" $ do
      let policy = defaultPolicy { policyAllowedCommands = AllowAll }
      property $ \(cmdText :: String) ->
        isCommandAllowed policy (CommandName (T.pack cmdText)) `shouldBe` True
