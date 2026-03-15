module CLI.ConfigSpec (spec) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.CLI.Config

-- | Helper: update vault config and read it back
updateAndRead :: FilePath -> FieldUpdate Text -> FieldUpdate Text -> FieldUpdate Text -> FieldUpdate Text -> IO FileConfig
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

    it "parses autonomy" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "autonomy = \"full\"\n"
        cfg <- loadFileConfig path
        _fc_autonomy cfg `shouldBe` Just "full"

    it "parses autonomy supervised" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "autonomy = \"supervised\"\n"
        cfg <- loadFileConfig path
        _fc_autonomy cfg `shouldBe` Just "supervised"

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
          , "autonomy         = \"full\"\n"
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
        _fc_autonomy        cfg `shouldBe` Just "full"
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
        _fc_autonomy        cfg `shouldBe` Nothing
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
      _fc_autonomy        emptyFileConfig `shouldBe` Nothing
      _fc_vault_recipient emptyFileConfig `shouldBe` Nothing
      _fc_vault_identity  emptyFileConfig `shouldBe` Nothing
      _fc_vault_path      emptyFileConfig `shouldBe` Nothing
      _fc_vault_unlock    emptyFileConfig `shouldBe` Nothing

  describe "updateVaultConfig" $ do
    it "round-trips vault fields" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        cfg <- updateAndRead path
          (Set "/my/vault.age")
          (Set "age1recipient")
          (Set "~/.age/key.txt")
          (Set "startup")
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
          (Set "/v.age") (Set "age1x") Keep Keep
        cfg <- loadFileConfig path
        -- Non-vault fields must be preserved
        _fc_model           cfg `shouldBe` Just "claude-opus-4-20250514"
        _fc_system          cfg `shouldBe` Just "Be concise."
        -- Vault fields should be set
        _fc_vault_path      cfg `shouldBe` Just "/v.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1x"

    it "preserves api_key and provider during passphrase vault setup" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Simulate a typical user config before /vault setup
        TIO.writeFile path $ mconcat
          [ "api_key  = \"sk-ant-test123\"\n"
          , "provider = \"anthropic\"\n"
          , "model    = \"claude-sonnet-4-20250514\"\n"
          ]
        -- Simulate passphrase /vault setup: explicitly Clear recipient/identity
        updateVaultConfig path
          (Set "/home/user/.pureclaw/vault/vault.age")
          Clear Clear (Set "on_demand")
        cfg <- loadFileConfig path
        -- All original fields must survive the round-trip
        _fc_apiKey          cfg `shouldBe` Just "sk-ant-test123"
        _fc_provider        cfg `shouldBe` Just "anthropic"
        _fc_model           cfg `shouldBe` Just "claude-sonnet-4-20250514"
        -- Vault fields should be set
        _fc_vault_path      cfg `shouldBe` Just "/home/user/.pureclaw/vault/vault.age"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"
        -- Recipient and identity should be cleared
        _fc_vault_recipient cfg `shouldBe` Nothing
        _fc_vault_identity  cfg `shouldBe` Nothing

    it "preserves allow list during vault setup round-trip" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ mconcat
          [ "api_key  = \"sk-ant-test\"\n"
          , "provider = \"anthropic\"\n"
          , "allow    = [\"git\", \"ls\", \"curl\"]\n"
          ]
        updateVaultConfig path
          (Set "/v.age") Keep Keep (Set "on_demand")
        cfg <- loadFileConfig path
        _fc_apiKey   cfg `shouldBe` Just "sk-ant-test"
        _fc_provider cfg `shouldBe` Just "anthropic"
        _fc_allow    cfg `shouldBe` Just ["git", "ls", "curl"]

    it "preserves age credentials when only updating vault_path" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Simulate an existing age-based vault config
        TIO.writeFile path $ mconcat
          [ "api_key          = \"sk-ant-test\"\n"
          , "provider         = \"anthropic\"\n"
          , "vault_path       = \"/old/vault.age\"\n"
          , "vault_recipient  = \"age1yubikey-old\"\n"
          , "vault_identity   = \"/home/user/.pureclaw/vault/yubikey-identity.txt\"\n"
          , "vault_unlock     = \"startup\"\n"
          ]
        -- Update only vault_path — recipient and identity must survive
        updateVaultConfig path
          (Set "/new/vault.age") Keep Keep (Set "on_demand")
        cfg <- loadFileConfig path
        _fc_apiKey          cfg `shouldBe` Just "sk-ant-test"
        _fc_provider        cfg `shouldBe` Just "anthropic"
        _fc_vault_path      cfg `shouldBe` Just "/new/vault.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1yubikey-old"
        _fc_vault_identity  cfg `shouldBe` Just "/home/user/.pureclaw/vault/yubikey-identity.txt"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"

    it "clears stale age credentials when explicitly told to" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Simulate an existing age-based vault config
        TIO.writeFile path $ mconcat
          [ "api_key          = \"sk-ant-test\"\n"
          , "provider         = \"anthropic\"\n"
          , "vault_path       = \"/home/user/.pureclaw/vault/vault.age\"\n"
          , "vault_recipient  = \"age1yubikey-old\"\n"
          , "vault_identity   = \"/home/user/.pureclaw/vault/yubikey-identity.txt\"\n"
          , "vault_unlock     = \"startup\"\n"
          ]
        -- Simulate passphrase /vault setup: explicitly Clear recipient/identity
        updateVaultConfig path
          (Set "/home/user/.pureclaw/vault/vault.age")
          Clear Clear (Set "on_demand")
        cfg <- loadFileConfig path
        _fc_apiKey          cfg `shouldBe` Just "sk-ant-test"
        _fc_provider        cfg `shouldBe` Just "anthropic"
        _fc_vault_recipient cfg `shouldBe` Nothing
        _fc_vault_identity  cfg `shouldBe` Nothing
        _fc_vault_path      cfg `shouldBe` Just "/home/user/.pureclaw/vault/vault.age"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"

    it "creates file from scratch on non-existent path" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- File does not exist yet — updateVaultConfig should create it
        cfg <- updateAndRead path
          (Set "/new/vault.age") (Set "age1new") Keep Keep
        _fc_vault_path      cfg `shouldBe` Just "/new/vault.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1new"
        _fc_vault_identity  cfg `shouldBe` Nothing
        _fc_vault_unlock    cfg `shouldBe` Nothing

    it "leaves fields unchanged when given Keep" $
      withSystemTempDirectory "pureclaw-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        -- Set all vault fields
        updateVaultConfig path
          (Set "/v.age") (Set "age1r") (Set "~/.age/k") (Set "startup")
        -- Update with all Keep — should be a no-op
        updateVaultConfig path Keep Keep Keep Keep
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
          (Set "/old.age") (Set "age1old") (Set "~/.age/old") (Set "startup")
        -- Update with new values
        updateVaultConfig path
          (Set "/new.age") (Set "age1new") (Set "~/.age/new") (Set "on_demand")
        cfg <- loadFileConfig path
        _fc_vault_path      cfg `shouldBe` Just "/new.age"
        _fc_vault_recipient cfg `shouldBe` Just "age1new"
        _fc_vault_identity  cfg `shouldBe` Just "~/.age/new"
        _fc_vault_unlock    cfg `shouldBe` Just "on_demand"
