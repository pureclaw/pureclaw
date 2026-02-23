module Agent.IdentitySpec (spec) where

import Data.Text qualified as T
import System.FilePath
import System.IO.Temp
import Test.Hspec

import PureClaw.Agent.Identity

spec :: Spec
spec = do
  describe "defaultIdentity" $ do
    it "has a name" $
      _ai_name defaultIdentity `shouldBe` "PureClaw"

    it "has a description" $
      _ai_description defaultIdentity `shouldSatisfy` (not . T.null)

    it "has empty instructions" $
      _ai_instructions defaultIdentity `shouldBe` ""

    it "has no constraints" $
      _ai_constraints defaultIdentity `shouldBe` []

    it "has Show and Eq instances" $ do
      show defaultIdentity `shouldContain` "AgentIdentity"
      defaultIdentity `shouldBe` defaultIdentity

  describe "loadIdentityFromText" $ do
    it "parses a full SOUL.md" $ do
      let soul = T.unlines
            [ "# Name"
            , "TestBot"
            , ""
            , "# Description"
            , "A test bot for unit tests."
            , ""
            , "# Instructions"
            , "Be helpful and concise."
            , ""
            , "# Constraints"
            , "- Do not share secrets"
            , "- Always be polite"
            ]
          ident = loadIdentityFromText soul
      _ai_name ident `shouldBe` "TestBot"
      _ai_description ident `shouldBe` "A test bot for unit tests."
      _ai_instructions ident `shouldBe` "Be helpful and concise."
      _ai_constraints ident `shouldBe` ["Do not share secrets", "Always be polite"]

    it "handles missing sections gracefully" $ do
      let soul = T.unlines
            [ "# Name"
            , "MinimalBot"
            ]
          ident = loadIdentityFromText soul
      _ai_name ident `shouldBe` "MinimalBot"
      _ai_description ident `shouldBe` ""
      _ai_instructions ident `shouldBe` ""
      _ai_constraints ident `shouldBe` []

    it "handles empty content" $ do
      let ident = loadIdentityFromText ""
      _ai_name ident `shouldBe` ""
      _ai_description ident `shouldBe` ""

    it "ignores content before first heading" $ do
      let soul = T.unlines
            [ "This is preamble text"
            , "that should be ignored."
            , ""
            , "# Name"
            , "MyBot"
            ]
          ident = loadIdentityFromText soul
      _ai_name ident `shouldBe` "MyBot"

  describe "loadIdentity" $ do
    it "loads from a file" $ do
      withSystemTempDirectory "pureclaw-test" $ \dir -> do
        let path = dir </> "SOUL.md"
        writeFile path "# Name\nFileBot\n\n# Description\nLoaded from disk."
        ident <- loadIdentity path
        _ai_name ident `shouldBe` "FileBot"
        _ai_description ident `shouldBe` "Loaded from disk."

    it "returns defaultIdentity for missing file" $ do
      ident <- loadIdentity "/nonexistent/SOUL.md"
      ident `shouldBe` defaultIdentity

  describe "identitySystemPrompt" $ do
    it "generates a system prompt from identity" $ do
      let ident = AgentIdentity "Bot" "A helpful bot." "Be concise." ["No secrets"]
          prompt = identitySystemPrompt ident
      prompt `shouldSatisfy` T.isInfixOf "You are Bot."
      prompt `shouldSatisfy` T.isInfixOf "A helpful bot."
      prompt `shouldSatisfy` T.isInfixOf "Be concise."
      prompt `shouldSatisfy` T.isInfixOf "No secrets"

    it "omits empty sections" $ do
      let ident = AgentIdentity "Bot" "" "" []
          prompt = identitySystemPrompt ident
      prompt `shouldBe` "You are Bot."

    it "includes constraints header" $ do
      let ident = AgentIdentity "" "" "" ["Rule 1", "Rule 2"]
          prompt = identitySystemPrompt ident
      prompt `shouldSatisfy` T.isInfixOf "Constraints:"
      prompt `shouldSatisfy` T.isInfixOf "- Rule 1"
      prompt `shouldSatisfy` T.isInfixOf "- Rule 2"
