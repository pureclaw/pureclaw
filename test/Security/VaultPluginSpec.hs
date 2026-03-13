module Security.VaultPluginSpec (spec) where

import Test.Hspec

import PureClaw.Security.Vault.Age (AgeRecipient (..), VaultError (..))
import PureClaw.Security.Vault.Plugin

spec :: Spec
spec = do
  describe "mkMockPluginHandle" $ do
    it "detect returns configured plugins" $ do
      let yubi = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
          tpm = AgePlugin
            { _ap_name   = "tpm"
            , _ap_binary = "age-plugin-tpm"
            , _ap_label  = "TPM 2.0"
            }
          ph = mkMockPluginHandle [yubi, tpm] (\_ -> Right (AgeRecipient "age1abc", "/tmp/id.txt"))
      plugins <- _ph_detect ph
      plugins `shouldBe` [yubi, tpm]

    it "detect returns empty list when no plugins" $ do
      let ph = mkMockPluginHandle [] (\_ -> Right (AgeRecipient "r", "/tmp/id"))
      plugins <- _ph_detect ph
      plugins `shouldBe` []

    it "generate returns recipient and identity file path" $ do
      let plugin = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
          expectedRecipient = AgeRecipient "age1yubikey1abc123"
          expectedPath = "/home/user/.config/pureclaw/yubikey-identity.txt"
          ph = mkMockPluginHandle [plugin] (\_ -> Right (expectedRecipient, expectedPath))
      result <- _ph_generate ph plugin "/home/user/.config/pureclaw"
      result `shouldBe` Right (expectedRecipient, expectedPath)

    it "generate returns AgeError when plugin generation fails" $ do
      let plugin = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
          ph = mkMockPluginHandle [plugin] (\_ -> Left (AgeError "plugin crashed"))
      result <- _ph_generate ph plugin "/tmp"
      result `shouldBe` Left (AgeError "plugin crashed")

    it "generate returns AgeError for unknown plugin" $ do
      let unknown = AgePlugin
            { _ap_name   = "unknown"
            , _ap_binary = "age-plugin-unknown"
            , _ap_label  = "unknown"
            }
          ph = mkMockPluginHandle [] (\_ -> Left (AgeError "plugin not found"))
      result <- _ph_generate ph unknown "/tmp"
      result `shouldBe` Left (AgeError "plugin not found")

  describe "knownPluginLabels" $ do
    it "returns human-readable label for yubikey" $ do
      pluginLabel "yubikey" `shouldBe` "YubiKey PIV"

    it "returns human-readable label for tpm" $ do
      pluginLabel "tpm" `shouldBe` "TPM 2.0"

    it "returns human-readable label for se" $ do
      pluginLabel "se" `shouldBe` "Secure Enclave"

    it "returns human-readable label for fido2-hmac" $ do
      pluginLabel "fido2-hmac" `shouldBe` "FIDO2 HMAC"

    it "falls back to plugin name for unknown plugins" $ do
      pluginLabel "somecustomplugin" `shouldBe` "somecustomplugin"

  describe "AgePlugin" $ do
    it "has Show instance" $ do
      let p = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
      show p `shouldContain` "yubikey"

    it "has Eq instance" $ do
      let p1 = AgePlugin "yubikey" "age-plugin-yubikey" "YubiKey PIV"
          p2 = AgePlugin "yubikey" "age-plugin-yubikey" "YubiKey PIV"
          p3 = AgePlugin "tpm" "age-plugin-tpm" "TPM 2.0"
      p1 `shouldBe` p2
      p1 `shouldNotBe` p3

  describe "pluginFromBinary" $ do
    it "extracts plugin name from binary path" $ do
      pluginFromBinary "age-plugin-yubikey" `shouldBe` AgePlugin "yubikey" "age-plugin-yubikey" "YubiKey PIV"

    it "uses plugin name as label for unknown plugins" $ do
      let p = pluginFromBinary "age-plugin-custom"
      _ap_name p `shouldBe` "custom"
      _ap_label p `shouldBe` "custom"
      _ap_binary p `shouldBe` "age-plugin-custom"

    it "handles plugin with hyphens in name" $ do
      let p = pluginFromBinary "age-plugin-fido2-hmac"
      _ap_name p `shouldBe` "fido2-hmac"
      _ap_label p `shouldBe` "FIDO2 HMAC"

    it "handles bare binary name without path" $ do
      let p = pluginFromBinary "age-plugin-se"
      _ap_name p `shouldBe` "se"
      _ap_label p `shouldBe` "Secure Enclave"
