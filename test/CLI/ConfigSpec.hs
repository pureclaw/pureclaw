module CLI.ConfigSpec (spec) where

import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Data.Text.IO qualified as TIO
import Test.Hspec

import PureClaw.CLI.Config

spec :: Spec
spec = do
  describe "loadFileConfig" $ do
    it "returns emptyFileConfig for a nonexistent file" $ do
      cfg <- loadFileConfig "/nonexistent/path/config.toml"
      cfg `shouldBe` emptyFileConfig

    it "returns emptyFileConfig for an empty file" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path ""
        cfg <- loadFileConfig path
        cfg `shouldBe` emptyFileConfig

    it "parses model" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "model = \"claude-opus-4-20250514\"\n"
        cfg <- loadFileConfig path
        _fc_model cfg `shouldBe` Just "claude-opus-4-20250514"

    it "parses system" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "system = \"Be concise.\"\n"
        cfg <- loadFileConfig path
        _fc_system cfg `shouldBe` Just "Be concise."

    it "parses memory" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "memory = \"sqlite\"\n"
        cfg <- loadFileConfig path
        _fc_memory cfg `shouldBe` Just "sqlite"

    it "parses allow array" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "allow = [\"git\", \"ls\"]\n"
        cfg <- loadFileConfig path
        _fc_allow cfg `shouldBe` Just ["git", "ls"]

    it "parses vault_recipient" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_recipient = \"age1abc\"\n"
        cfg <- loadFileConfig path
        _fc_vault_recipient cfg `shouldBe` Just "age1abc"

    it "parses vault_identity" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_identity = \"~/.age/key.txt\"\n"
        cfg <- loadFileConfig path
        _fc_vault_identity cfg `shouldBe` Just "~/.age/key.txt"

    it "parses vault_path" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = \"/custom/vault.age\"\n"
        cfg <- loadFileConfig path
        _fc_vault_path cfg `shouldBe` Just "/custom/vault.age"

    it "parses vault_unlock" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_unlock = \"startup\"\n"
        cfg <- loadFileConfig path
        _fc_vault_unlock cfg `shouldBe` Just "startup"

    it "parses [[providers]] with anthropic api-key (default)" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "[[providers]]\nprovider = \"anthropic\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [AnthropicProvider (AnthropicProviderConfig AuthApiKey)]

    it "parses [[providers]] with anthropic oauth" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "[[providers]]\nprovider = \"anthropic\"\nauth = \"oauth\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [AnthropicProvider (AnthropicProviderConfig AuthOAuth)]

    it "parses [[providers]] with ollama and base_url" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "[[providers]]\nprovider = \"ollama\"\nbase_url = \"http://gpu:11434\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [OllamaProvider (OllamaProviderConfig (Just "http://gpu:11434"))]

    it "parses [[providers]] with openai" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "[[providers]]\nprovider = \"openai\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [OpenAIProvider (OpenAIProviderConfig Nothing)]

    it "parses [[providers]] with openrouter" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "[[providers]]\nprovider = \"openrouter\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [OpenRouterProvider OpenRouterProviderConfig]

    it "parses multiple providers" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "model = \"anthropic:claude-opus-4-5\"\n\n"
          , "[[providers]]\n"
          , "provider = \"anthropic\"\n"
          , "auth = \"oauth\"\n\n"
          , "[[providers]]\n"
          , "provider = \"ollama\"\n"
          , "base_url = \"http://localhost:11434\"\n"
          ]
        cfg <- loadFileConfig path
        _fc_model cfg `shouldBe` Just "anthropic:claude-opus-4-5"
        _fc_providers cfg `shouldBe`
          [ AnthropicProvider (AnthropicProviderConfig AuthOAuth)
          , OllamaProvider (OllamaProviderConfig (Just "http://localhost:11434"))
          ]

    it "defaults to empty providers list when no [[providers]] section" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "model = \"claude-opus-4-20250514\"\n"
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe` []

    it "ignores unknown provider names" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "[[providers]]\n"
          , "provider = \"unknown-provider\"\n\n"
          , "[[providers]]\n"
          , "provider = \"anthropic\"\n"
          ]
        cfg <- loadFileConfig path
        _fc_providers cfg `shouldBe`
          [AnthropicProvider (AnthropicProviderConfig AuthApiKey)]

    it "parses all fields together" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "model            = \"claude-haiku-4-5-20251001\"\n"
          , "system           = \"Be helpful.\"\n"
          , "memory           = \"markdown\"\n"
          , "allow            = [\"git\", \"curl\"]\n"
          , "vault_recipient  = \"age1xyz\"\n"
          , "vault_identity   = \"~/.age/key.txt\"\n"
          , "vault_path       = \".pureclaw/vault.age\"\n"
          , "vault_unlock     = \"cached\"\n\n"
          , "[[providers]]\n"
          , "provider = \"anthropic\"\n\n"
          , "[[providers]]\n"
          , "provider = \"openai\"\n"
          ]
        cfg <- loadFileConfig path
        _fc_model           cfg `shouldBe` Just "claude-haiku-4-5-20251001"
        _fc_system          cfg `shouldBe` Just "Be helpful."
        _fc_memory          cfg `shouldBe` Just "markdown"
        _fc_allow           cfg `shouldBe` Just ["git", "curl"]
        _fc_vault_recipient cfg `shouldBe` Just "age1xyz"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/key.txt"
        _fc_vault_path      cfg `shouldBe` Just ".pureclaw/vault.age"
        _fc_vault_unlock    cfg `shouldBe` Just "cached"
        _fc_providers       cfg `shouldBe`
          [ AnthropicProvider (AnthropicProviderConfig AuthApiKey)
          , OpenAIProvider (OpenAIProviderConfig Nothing)
          ]

    it "ignores missing optional fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "model = \"claude-haiku-4-5-20251001\"\n"
        cfg <- loadFileConfig path
        _fc_system          cfg `shouldBe` Nothing
        _fc_memory          cfg `shouldBe` Nothing
        _fc_allow           cfg `shouldBe` Nothing
        _fc_vault_recipient cfg `shouldBe` Nothing
        _fc_vault_identity  cfg `shouldBe` Nothing
        _fc_vault_path      cfg `shouldBe` Nothing
        _fc_vault_unlock    cfg `shouldBe` Nothing
        _fc_providers       cfg `shouldBe` []

    it "returns emptyFileConfig for invalid TOML" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "this is not = valid toml !!!\n"
        cfg <- loadFileConfig path
        cfg `shouldBe` emptyFileConfig

  describe "providerType" $ do
    it "returns PTAnthropic for AnthropicProvider" $
      providerType (AnthropicProvider (AnthropicProviderConfig AuthApiKey))
        `shouldBe` PTAnthropic

    it "returns PTOllama for OllamaProvider" $
      providerType (OllamaProvider (OllamaProviderConfig Nothing))
        `shouldBe` PTOllama

    it "returns PTOpenAI for OpenAIProvider" $
      providerType (OpenAIProvider (OpenAIProviderConfig Nothing))
        `shouldBe` PTOpenAI

    it "returns PTOpenRouter for OpenRouterProvider" $
      providerType (OpenRouterProvider OpenRouterProviderConfig)
        `shouldBe` PTOpenRouter

  describe "getPureclawDir" $ do
    it "returns a path ending in .pureclaw under the home directory" $ do
      dir <- getPureclawDir
      home <- getHomeDirectory
      dir `shouldBe` (home </> ".pureclaw")

  describe "emptyFileConfig" $ do
    it "has all Nothing/empty fields" $ do
      _fc_model           emptyFileConfig `shouldBe` Nothing
      _fc_system          emptyFileConfig `shouldBe` Nothing
      _fc_memory          emptyFileConfig `shouldBe` Nothing
      _fc_allow           emptyFileConfig `shouldBe` Nothing
      _fc_vault_recipient emptyFileConfig `shouldBe` Nothing
      _fc_vault_identity  emptyFileConfig `shouldBe` Nothing
      _fc_vault_path      emptyFileConfig `shouldBe` Nothing
      _fc_vault_unlock    emptyFileConfig `shouldBe` Nothing
      _fc_providers       emptyFileConfig `shouldBe` []
