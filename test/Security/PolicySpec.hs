module Security.PolicySpec (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Set qualified as Set
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
      _sp_autonomy defaultPolicy `shouldBe` Deny

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
      _sp_autonomy policy `shouldBe` Full

    it "can override previous autonomy" $ do
      let policy = withAutonomy Supervised $ withAutonomy Full defaultPolicy
      _sp_autonomy policy `shouldBe` Supervised

  describe "AllowAll commands" $ do
    it "allows everything when policy uses AllowAll" $ do
      let policy = defaultPolicy { _sp_allowedCommands = AllowAll }
      property $ \(cmdText :: String) ->
        isCommandAllowed policy (CommandName (T.pack cmdText)) `shouldBe` True

  describe "_sp_allowedRemoteCommands" $ do
    it "defaultPolicy denies all remote commands" $
      property $ \(cmdText :: String) ->
        isRemoteCommandAllowed defaultPolicy (CommandName (T.pack cmdText))
          `shouldBe` False

    it "allowRemoteCommand grants the named remote command" $ do
      let policy = allowRemoteCommand (CommandName "ssh") defaultPolicy
      isRemoteCommandAllowed policy (CommandName "ssh")  `shouldBe` True
      isRemoteCommandAllowed policy (CommandName "bash") `shouldBe` False

    it "denyRemoteCommand is the inverse of allowRemoteCommand" $ do
      let policy = denyRemoteCommand (CommandName "ssh")
                 $ allowRemoteCommand (CommandName "ssh") defaultPolicy
      policy `shouldBe` defaultPolicy

    it "denyRemoteCommand is a no-op for commands not in the set" $ do
      let policy = denyRemoteCommand (CommandName "ssh") defaultPolicy
      isRemoteCommandAllowed policy (CommandName "ssh") `shouldBe` False

    it "local and remote allowlists are independent" $ do
      let policy = allowRemoteCommand (CommandName "tmux") defaultPolicy
      -- The local allowlist is untouched: still deny-all.
      _sp_allowedCommands policy `shouldBe` _sp_allowedCommands defaultPolicy
      isCommandAllowed       policy (CommandName "tmux") `shouldBe` False
      isRemoteCommandAllowed policy (CommandName "tmux") `shouldBe` True

    it "allowing a local command does not affect the remote allowlist" $ do
      let policy = allowCommand (CommandName "git") defaultPolicy
      _sp_allowedRemoteCommands policy
        `shouldBe` _sp_allowedRemoteCommands defaultPolicy
      isRemoteCommandAllowed policy (CommandName "git") `shouldBe` False

    it "allowRemoteCommand flips AllowList Set.empty to a singleton set" $ do
      -- defaultPolicy uses AllowList Set.empty for the remote field — verify
      -- that adding "ssh" yields exactly AllowList (Set.singleton "ssh"), not
      -- AllowAll.
      let policy = allowRemoteCommand (CommandName "ssh") defaultPolicy
      _sp_allowedRemoteCommands policy
        `shouldBe` AllowList (Set.singleton (CommandName "ssh"))

    it "AllowAll remote policy allows every remote command" $ do
      let policy = defaultPolicy { _sp_allowedRemoteCommands = AllowAll }
      property $ \(cmdText :: String) ->
        isRemoteCommandAllowed policy (CommandName (T.pack cmdText))
          `shouldBe` True

    it "allowRemoteCommand is a no-op on an AllowAll remote policy" $ do
      let policy = defaultPolicy { _sp_allowedRemoteCommands = AllowAll }
          policy' = allowRemoteCommand (CommandName "ssh") policy
      _sp_allowedRemoteCommands policy' `shouldBe` AllowAll

    it "denyRemoteCommand is a no-op on an AllowAll remote policy" $ do
      let policy = defaultPolicy { _sp_allowedRemoteCommands = AllowAll }
          policy' = denyRemoteCommand (CommandName "ssh") policy
      _sp_allowedRemoteCommands policy' `shouldBe` AllowAll
