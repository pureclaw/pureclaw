module CLI.ConfigSpec (spec) where

import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
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

    it "parses api_key" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "api_key = \"sk-ant-test\"\n"
        cfg <- loadFileConfig path
        _fc_apiKey cfg `shouldBe` Just "sk-ant-test"

    it "parses model" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "model = \"claude-opus-4-20250514\"\n"
        cfg <- loadFileConfig path
        _fc_model cfg `shouldBe` Just "claude-opus-4-20250514"

    it "parses provider" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "provider = \"openai\"\n"
        cfg <- loadFileConfig path
        _fc_provider cfg `shouldBe` Just "openai"

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

    it "parses all fields together" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "api_key  = \"sk-test\"\n"
          , "model    = \"claude-haiku-4-5-20251001\"\n"
          , "provider = \"anthropic\"\n"
          , "system   = \"Be helpful.\"\n"
          , "memory   = \"markdown\"\n"
          , "allow    = [\"git\", \"curl\"]\n"
          ]
        cfg <- loadFileConfig path
        _fc_apiKey   cfg `shouldBe` Just "sk-test"
        _fc_model    cfg `shouldBe` Just "claude-haiku-4-5-20251001"
        _fc_provider cfg `shouldBe` Just "anthropic"
        _fc_system   cfg `shouldBe` Just "Be helpful."
        _fc_memory   cfg `shouldBe` Just "markdown"
        _fc_allow    cfg `shouldBe` Just ["git", "curl"]

    it "ignores missing optional fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "api_key = \"sk-x\"\n"
        cfg <- loadFileConfig path
        _fc_model    cfg `shouldBe` Nothing
        _fc_provider cfg `shouldBe` Nothing
        _fc_system   cfg `shouldBe` Nothing
        _fc_memory   cfg `shouldBe` Nothing
        _fc_allow    cfg `shouldBe` Nothing

    it "returns emptyFileConfig for invalid TOML" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "this is not = valid toml !!!\n"
        cfg <- loadFileConfig path
        cfg `shouldBe` emptyFileConfig

  describe "emptyFileConfig" $ do
    it "has all Nothing fields" $ do
      _fc_apiKey   emptyFileConfig `shouldBe` Nothing
      _fc_model    emptyFileConfig `shouldBe` Nothing
      _fc_provider emptyFileConfig `shouldBe` Nothing
      _fc_system   emptyFileConfig `shouldBe` Nothing
      _fc_memory   emptyFileConfig `shouldBe` Nothing
      _fc_allow    emptyFileConfig `shouldBe` Nothing
