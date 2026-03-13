module CLI.ConfigSpec (spec) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.CLI.Config

-- | Helper: update vault config and read it back
updateAndRead :: FilePath -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> IO FileConfig
updateAndRead path vp vr vi vu = do
  updateVaultConfig path vp vr vi vu
  loadFileConfig path

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

    it "parses all fields together" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "api_key          = \"sk-test\"\n"
          , "model            = \"claude-haiku-4-5-20251001\"\n"
          , "provider         = \"anthropic\"\n"
          , "system           = \"Be helpful.\"\n"
          , "memory           = \"markdown\"\n"
          , "allow            = [\"git\", \"curl\"]\n"
          , "vault_recipient  = \"age1xyz\"\n"
          , "vault_identity   = \"~/.age/key.txt\"\n"
          , "vault_path       = \".pureclaw/vault.age\"\n"
          , "vault_unlock     = \"on_demand\"\n"
          ]
        cfg <- loadFileConfig path
        _fc_apiKey          cfg `shouldBe` Just "sk-test"
        _fc_model           cfg `shouldBe` Just "claude-haiku-4-5-20251001"
        _fc_provider        cfg `shouldBe` Just "anthropic"
        _fc_system          cfg `shouldBe` Just "Be helpful."
        _fc_memory          cfg `shouldBe` Just "markdown"
        _fc_allow           cfg `shouldBe` Just ["git", "curl"]
        _fc_vault_recipient cfg `shouldBe` Just "age1xyz"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/key.txt"
        _fc_vault_path      cfg `shouldBe` Just ".pureclaw/vault.age"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"

    it "ignores missing optional fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "api_key = \"sk-x\"\n"
        cfg <- loadFileConfig path
        _fc_model           cfg `shouldBe` Nothing
        _fc_provider        cfg `shouldBe` Nothing
        _fc_system          cfg `shouldBe` Nothing
        _fc_memory          cfg `shouldBe` Nothing
        _fc_allow           cfg `shouldBe` Nothing
        _fc_vault_recipient cfg `shouldBe` Nothing
        _fc_vault_identity  cfg `shouldBe` Nothing
        _fc_vault_path      cfg `shouldBe` Nothing
        _fc_vault_unlock    cfg `shouldBe` Nothing

    it "returns emptyFileConfig for invalid TOML" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "this is not = valid toml !!!\n"
        cfg <- loadFileConfig path
        cfg `shouldBe` emptyFileConfig

  describe "getPureclawDir" $ do
    it "returns a path ending in .pureclaw under the home directory" $ do
      dir <- getPureclawDir
      home <- getHomeDirectory
      dir `shouldBe` (home </> ".pureclaw")

  describe "emptyFileConfig" $ do
    it "has all Nothing fields" $ do
      _fc_apiKey          emptyFileConfig `shouldBe` Nothing
      _fc_model           emptyFileConfig `shouldBe` Nothing
      _fc_provider        emptyFileConfig `shouldBe` Nothing
      _fc_system          emptyFileConfig `shouldBe` Nothing
      _fc_memory          emptyFileConfig `shouldBe` Nothing
      _fc_allow           emptyFileConfig `shouldBe` Nothing
      _fc_vault_recipient emptyFileConfig `shouldBe` Nothing
      _fc_vault_identity  emptyFileConfig `shouldBe` Nothing
      _fc_vault_path      emptyFileConfig `shouldBe` Nothing
      _fc_vault_unlock    emptyFileConfig `shouldBe` Nothing

  describe "updateVaultConfig" $ do
    it "round-trips vault fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        cfg <- updateAndRead path
          (Just "/my/vault.age")
          (Just "age1recipient")
          (Just "~/.age/key.txt")
          (Just "startup")
        _fc_vault_path      cfg `shouldBe` Just "/my/vault.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1recipient"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/key.txt"
        _fc_vault_unlock    cfg `shouldBe` Just "startup"

    it "preserves non-vault fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Write a config with model and system set
        TIO.writeFile path $ mconcat
          [ "model  = \"claude-opus-4-20250514\"\n"
          , "system = \"Be concise.\"\n"
          ]
        -- Update vault fields only
        updateVaultConfig path
          (Just "/v.age") (Just "age1x") Nothing Nothing
        cfg <- loadFileConfig path
        -- Non-vault fields must be preserved
        _fc_model           cfg `shouldBe` Just "claude-opus-4-20250514"
        _fc_system          cfg `shouldBe` Just "Be concise."
        -- Vault fields should be set
        _fc_vault_path      cfg `shouldBe` Just "/v.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1x"

    it "creates file from scratch on non-existent path" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- File does not exist yet — updateVaultConfig should create it
        cfg <- updateAndRead path
          (Just "/new/vault.age") (Just "age1new") Nothing Nothing
        _fc_vault_path      cfg `shouldBe` Just "/new/vault.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1new"
        _fc_vault_identity  cfg `shouldBe` Nothing
        _fc_vault_unlock    cfg `shouldBe` Nothing

    it "leaves fields unchanged when given Nothing" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Set all vault fields
        updateVaultConfig path
          (Just "/v.age") (Just "age1r") (Just "~/.age/k") (Just "startup")
        -- Update with all Nothing — should be a no-op
        updateVaultConfig path Nothing Nothing Nothing Nothing
        cfg <- loadFileConfig path
        _fc_vault_path      cfg `shouldBe` Just "/v.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1r"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/k"
        _fc_vault_unlock    cfg `shouldBe` Just "startup"

    it "updates existing vault fields with new values" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Set initial values
        updateVaultConfig path
          (Just "/old.age") (Just "age1old") (Just "~/.age/old") (Just "startup")
        -- Update with new values
        updateVaultConfig path
          (Just "/new.age") (Just "age1new") (Just "~/.age/new") (Just "on_demand")
        cfg <- loadFileConfig path
        _fc_vault_path      cfg `shouldBe` Just "/new.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1new"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/new"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"
