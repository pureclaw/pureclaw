module Core.TypesSpec (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Set qualified as Set
import Data.Text qualified as T
import PureClaw.Core.Types

spec :: Spec
spec = do
  describe "AllowList" $ do
    -- Test with String (has Arbitrary instance) to verify AllowList logic
    it "AllowAll allows any element" $
      property $ \(x :: String) ->
        isAllowed AllowAll (CommandName (T.pack x)) `shouldBe` True

    it "AllowList allows elements in the set" $ do
      let al = AllowList (Set.fromList ["git" :: String, "ls"])
      isAllowed al "git" `shouldBe` True
      isAllowed al "ls" `shouldBe` True

    it "AllowList rejects elements not in the set" $ do
      let al = AllowList (Set.fromList ["git" :: String, "ls"])
      isAllowed al "rm" `shouldBe` False
      isAllowed al "curl" `shouldBe` False

    it "empty AllowList rejects everything" $
      property $ \(x :: String) ->
        isAllowed (AllowList Set.empty) (CommandName (T.pack x)) `shouldBe` False

    -- Also verify it works with CommandName specifically
    it "works with CommandName" $ do
      let al = AllowList (Set.fromList [CommandName "git"])
      isAllowed al (CommandName "git") `shouldBe` True
      isAllowed al (CommandName "rm") `shouldBe` False

  describe "AutonomyLevel" $ do
    it "has Show instances" $ do
      show Full `shouldBe` "Full"
      show Supervised `shouldBe` "Supervised"
      show Deny `shouldBe` "Deny"

    it "has Eq instance" $ do
      Full `shouldBe` Full
      Supervised `shouldNotBe` Deny

  describe "newtypes" $ do
    it "ProviderId wraps Text" $ do
      let p = ProviderId "anthropic"
      show p `shouldSatisfy` (not . null)

    it "ModelId wraps Text" $ do
      let m = ModelId "claude-3"
      show m `shouldSatisfy` (not . null)

    it "Port wraps Int" $ do
      let p = Port 8080
      show p `shouldSatisfy` (not . null)

    it "WorkspaceRoot wraps FilePath" $ do
      let w = WorkspaceRoot "/home/user/workspace"
      show w `shouldSatisfy` (not . null)

    it "CommandName has Ord for Set usage" $ do
      let s = Set.fromList [CommandName "a", CommandName "b", CommandName "a"]
      Set.size s `shouldBe` 2
