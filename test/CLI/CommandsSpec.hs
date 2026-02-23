module CLI.CommandsSpec (spec) where

import Options.Applicative
import Test.Hspec

import PureClaw.CLI.Commands

-- Helper to parse CLI args.
parseArgs :: [String] -> Maybe ChatOptions
parseArgs args = case execParserPure defaultPrefs (info chatOptionsParser mempty) args of
  Success opts -> Just opts
  _            -> Nothing

spec :: Spec
spec = do
  describe "chatOptionsParser" $ do
    it "parses with default model" $ do
      case parseArgs [] of
        Just opts -> _co_model opts `shouldBe` "claude-sonnet-4-20250514"
        Nothing -> expectationFailure "parse failed"

    it "parses --model flag" $ do
      case parseArgs ["--model", "claude-opus-4-20250514"] of
        Just opts -> _co_model opts `shouldBe` "claude-opus-4-20250514"
        Nothing -> expectationFailure "parse failed"

    it "parses -m short flag" $ do
      case parseArgs ["-m", "test-model"] of
        Just opts -> _co_model opts `shouldBe` "test-model"
        Nothing -> expectationFailure "parse failed"

    it "parses --api-key flag" $ do
      case parseArgs ["--api-key", "sk-test"] of
        Just opts -> _co_apiKey opts `shouldBe` Just "sk-test"
        Nothing -> expectationFailure "parse failed"

    it "api-key defaults to Nothing" $ do
      case parseArgs [] of
        Just opts -> _co_apiKey opts `shouldBe` Nothing
        Nothing -> expectationFailure "parse failed"

    it "parses --system flag" $ do
      case parseArgs ["--system", "Be brief"] of
        Just opts -> _co_system opts `shouldBe` Just "Be brief"
        Nothing -> expectationFailure "parse failed"

    it "parses -s short flag for system" $ do
      case parseArgs ["-s", "Be helpful"] of
        Just opts -> _co_system opts `shouldBe` Just "Be helpful"
        Nothing -> expectationFailure "parse failed"

    it "parses --provider flag" $ do
      case parseArgs ["--provider", "openai"] of
        Just opts -> _co_provider opts `shouldBe` "openai"
        Nothing -> expectationFailure "parse failed"

    it "provider defaults to anthropic" $ do
      case parseArgs [] of
        Just opts -> _co_provider opts `shouldBe` "anthropic"
        Nothing -> expectationFailure "parse failed"

    it "parses -p short flag for provider" $ do
      case parseArgs ["-p", "ollama"] of
        Just opts -> _co_provider opts `shouldBe` "ollama"
        Nothing -> expectationFailure "parse failed"

    it "parses --allow flags" $ do
      case parseArgs ["--allow", "git", "--allow", "ls"] of
        Just opts -> _co_allowCommands opts `shouldBe` ["git", "ls"]
        Nothing -> expectationFailure "parse failed"

    it "allow defaults to empty" $ do
      case parseArgs [] of
        Just opts -> _co_allowCommands opts `shouldBe` []
        Nothing -> expectationFailure "parse failed"

    it "parses -a short flag for allow" $ do
      case parseArgs ["-a", "cat"] of
        Just opts -> _co_allowCommands opts `shouldBe` ["cat"]
        Nothing -> expectationFailure "parse failed"

    it "parses --memory flag" $ do
      case parseArgs ["--memory", "sqlite"] of
        Just opts -> _co_memory opts `shouldBe` "sqlite"
        Nothing -> expectationFailure "parse failed"

    it "memory defaults to none" $ do
      case parseArgs [] of
        Just opts -> _co_memory opts `shouldBe` "none"
        Nothing -> expectationFailure "parse failed"

    it "parses --soul flag" $ do
      case parseArgs ["--soul", "my-soul.md"] of
        Just opts -> _co_soul opts `shouldBe` Just "my-soul.md"
        Nothing -> expectationFailure "parse failed"

    it "soul defaults to Nothing" $ do
      case parseArgs [] of
        Just opts -> _co_soul opts `shouldBe` Nothing
        Nothing -> expectationFailure "parse failed"

    it "parses all flags together" $ do
      case parseArgs ["-p", "openai", "-m", "gpt-4", "--api-key", "sk-x", "--allow", "git", "--memory", "sqlite", "--soul", "SOUL.md", "-s", "Be brief"] of
        Just opts -> do
          _co_provider opts `shouldBe` "openai"
          _co_model opts `shouldBe` "gpt-4"
          _co_apiKey opts `shouldBe` Just "sk-x"
          _co_allowCommands opts `shouldBe` ["git"]
          _co_memory opts `shouldBe` "sqlite"
          _co_soul opts `shouldBe` Just "SOUL.md"
          _co_system opts `shouldBe` Just "Be brief"
        Nothing -> expectationFailure "parse failed"
