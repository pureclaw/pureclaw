module Security.CommandSpec (spec) where

import Test.Hspec
import Test.QuickCheck
import PureClaw.Core.Types
import PureClaw.Security.Command
import PureClaw.Security.Policy

spec :: Spec
spec = do
  describe "authorize" $ do
    let gitPolicy = withAutonomy Full
                  $ allowCommand (CommandName "git") defaultPolicy

    it "authorizes an allowed command" $ do
      let result = authorize gitPolicy "git" ["status"]
      case result of
        Right cmd -> do
          getCommandProgram cmd `shouldBe` "git"
          getCommandArgs cmd `shouldBe` ["status"]
        Left e -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "rejects a denied command" $ do
      let result = authorize gitPolicy "rm" ["-rf", "/"]
      case result of
        Left (CommandNotAllowed _) -> pure ()
        Left e  -> expectationFailure $ "Expected CommandNotAllowed, got: " ++ show e
        Right _ -> expectationFailure "Expected Left, got Right"

    it "rejects all commands when autonomy is Deny" $ do
      let denyPolicy = withAutonomy Deny
                     $ allowCommand (CommandName "git") defaultPolicy
      let result = authorize denyPolicy "git" ["status"]
      case result of
        Left CommandInAutonomyDeny -> pure ()
        Left e  -> expectationFailure $ "Expected CommandInAutonomyDeny, got: " ++ show e
        Right _ -> expectationFailure "Expected Left, got Right"

    it "uses basename for command matching" $ do
      let result = authorize gitPolicy "/usr/bin/git" ["log"]
      case result of
        Right cmd -> getCommandProgram cmd `shouldBe` "/usr/bin/git"
        Left e    -> expectationFailure $ "Expected Right, got Left: " ++ show e

    it "AllowAll policy allows any command" $ do
      let allPolicy = SecurityPolicy AllowAll Full
      property $ \(cmdText :: String) ->
        case authorize allPolicy cmdText [] of
          Right _ -> True
          Left _  -> False

  describe "CommandError" $ do
    it "has Show instance" $ do
      show (CommandNotAllowed "rm") `shouldSatisfy` (not . null)
      show CommandInAutonomyDeny `shouldSatisfy` (not . null)

    it "has Eq instance" $ do
      CommandInAutonomyDeny `shouldBe` CommandInAutonomyDeny
      CommandNotAllowed "a" `shouldNotBe` CommandNotAllowed "b"
