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
        Just opts -> _co_provider opts `shouldBe` OpenAI
        Nothing -> expectationFailure "parse failed"

    it "provider defaults to Anthropic" $ do
      case parseArgs [] of
        Just opts -> _co_provider opts `shouldBe` Anthropic
        Nothing -> expectationFailure "parse failed"

    it "parses -p short flag for provider" $ do
      case parseArgs ["-p", "ollama"] of
        Just opts -> _co_provider opts `shouldBe` Ollama
        Nothing -> expectationFailure "parse failed"

    it "parses openrouter provider" $ do
      case parseArgs ["-p", "openrouter"] of
        Just opts -> _co_provider opts `shouldBe` OpenRouter
        Nothing -> expectationFailure "parse failed"

    it "rejects invalid provider" $
      parseArgs ["-p", "invalid"] `shouldBe` Nothing

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
        Just opts -> _co_memory opts `shouldBe` SQLiteMemory
        Nothing -> expectationFailure "parse failed"

    it "parses markdown memory" $ do
      case parseArgs ["--memory", "markdown"] of
        Just opts -> _co_memory opts `shouldBe` MarkdownMemory
        Nothing -> expectationFailure "parse failed"

    it "memory defaults to NoMemory" $ do
      case parseArgs [] of
        Just opts -> _co_memory opts `shouldBe` NoMemory
        Nothing -> expectationFailure "parse failed"

    it "rejects invalid memory backend" $
      parseArgs ["--memory", "invalid"] `shouldBe` Nothing

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
          _co_provider opts `shouldBe` OpenAI
          _co_model opts `shouldBe` "gpt-4"
          _co_apiKey opts `shouldBe` Just "sk-x"
          _co_allowCommands opts `shouldBe` ["git"]
          _co_memory opts `shouldBe` SQLiteMemory
          _co_soul opts `shouldBe` Just "SOUL.md"
          _co_system opts `shouldBe` Just "Be brief"
        Nothing -> expectationFailure "parse failed"

  describe "ProviderType" $ do
    it "has Show and Eq instances" $ do
      show Anthropic `shouldBe` "Anthropic"
      Anthropic `shouldNotBe` OpenAI

    it "has all four variants" $ do
      let allVariants = [Anthropic, OpenAI, OpenRouter, Ollama]
      length allVariants `shouldBe` 4

  describe "MemoryBackend" $ do
    it "has Show and Eq instances" $ do
      show NoMemory `shouldBe` "NoMemory"
      NoMemory `shouldNotBe` SQLiteMemory

    it "has all three variants" $ do
      let allVariants = [NoMemory, SQLiteMemory, MarkdownMemory]
      length allVariants `shouldBe` 3
