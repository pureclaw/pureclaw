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
    it "parses with default model (Nothing — resolved at runtime)" $ do
      case parseArgs [] of
        Just opts -> _co_model opts `shouldBe` Nothing
        Nothing -> expectationFailure "parse failed"

    it "parses --model flag" $ do
      case parseArgs ["--model", "claude-opus-4-20250514"] of
        Just opts -> _co_model opts `shouldBe` Just "claude-opus-4-20250514"
        Nothing -> expectationFailure "parse failed"

    it "parses -m short flag" $ do
      case parseArgs ["-m", "test-model"] of
        Just opts -> _co_model opts `shouldBe` Just "test-model"
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
        Just opts -> _co_provider opts `shouldBe` Just OpenAI
        Nothing -> expectationFailure "parse failed"

    it "provider defaults to Nothing (resolved at runtime)" $ do
      case parseArgs [] of
        Just opts -> _co_provider opts `shouldBe` Nothing
        Nothing -> expectationFailure "parse failed"

    it "parses -p short flag for provider" $ do
      case parseArgs ["-p", "ollama"] of
        Just opts -> _co_provider opts `shouldBe` Just Ollama
        Nothing -> expectationFailure "parse failed"

    it "parses openrouter provider" $ do
      case parseArgs ["-p", "openrouter"] of
        Just opts -> _co_provider opts `shouldBe` Just OpenRouter
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
        Just opts -> _co_memory opts `shouldBe` Just SQLiteMemory
        Nothing -> expectationFailure "parse failed"

    it "parses markdown memory" $ do
      case parseArgs ["--memory", "markdown"] of
        Just opts -> _co_memory opts `shouldBe` Just MarkdownMemory
        Nothing -> expectationFailure "parse failed"

    it "memory defaults to Nothing (resolved at runtime)" $ do
      case parseArgs [] of
        Just opts -> _co_memory opts `shouldBe` Nothing
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

    it "parses --config flag" $ do
      case parseArgs ["--config", "/path/to/config.toml"] of
        Just opts -> _co_config opts `shouldBe` Just "/path/to/config.toml"
        Nothing -> expectationFailure "parse failed"

    it "parses -c short flag for config" $ do
      case parseArgs ["-c", "myconfig.toml"] of
        Just opts -> _co_config opts `shouldBe` Just "myconfig.toml"
        Nothing -> expectationFailure "parse failed"

    it "config defaults to Nothing" $ do
      case parseArgs [] of
        Just opts -> _co_config opts `shouldBe` Nothing
        Nothing -> expectationFailure "parse failed"

    it "parses --no-vault flag" $ do
      case parseArgs ["--no-vault"] of
        Just opts -> _co_noVault opts `shouldBe` True
        Nothing -> expectationFailure "parse failed"

    it "no-vault defaults to False" $ do
      case parseArgs [] of
        Just opts -> _co_noVault opts `shouldBe` False
        Nothing -> expectationFailure "parse failed"

    it "parses --oauth flag" $ do
      case parseArgs ["--oauth"] of
        Just opts -> _co_oauth opts `shouldBe` True
        Nothing -> expectationFailure "parse failed"

    it "oauth defaults to False" $ do
      case parseArgs [] of
        Just opts -> _co_oauth opts `shouldBe` False
        Nothing -> expectationFailure "parse failed"

    it "parses all flags together" $ do
      case parseArgs ["-p", "openai", "-m", "gpt-4", "--api-key", "sk-x", "--allow", "git", "--memory", "sqlite", "--soul", "SOUL.md", "-s", "Be brief", "-c", "my.toml", "--no-vault"] of
        Just opts -> do
          _co_provider opts `shouldBe` Just OpenAI
          _co_model opts `shouldBe` Just "gpt-4"
          _co_apiKey opts `shouldBe` Just "sk-x"
          _co_allowCommands opts `shouldBe` ["git"]
          _co_memory opts `shouldBe` Just SQLiteMemory
          _co_soul opts `shouldBe` Just "SOUL.md"
          _co_system opts `shouldBe` Just "Be brief"
          _co_config opts `shouldBe` Just "my.toml"
          _co_noVault opts `shouldBe` True
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
