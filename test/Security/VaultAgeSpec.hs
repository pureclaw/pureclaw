module Security.VaultAgeSpec (spec) where

import Data.ByteString qualified as BS
import Test.Hspec

import PureClaw.Security.Vault.Age

spec :: Spec
spec = do
  describe "mkMockAgeEncryptor" $ do
    it "roundtrip: encrypt then decrypt returns original plaintext" $ do
      let enc = mkMockAgeEncryptor
          recipient = AgeRecipient "age1examplerecipient"
          identity  = AgeIdentity  "/path/to/identity"
          plaintext = "hello, secrets vault!"
      Right ciphertext <- _ae_encrypt enc recipient plaintext
      Right recovered  <- _ae_decrypt enc identity ciphertext
      recovered `shouldBe` plaintext

    it "encrypted bytes differ from plaintext" $ do
      let enc = mkMockAgeEncryptor
          plaintext = "sensitive data"
      Right ciphertext <- _ae_encrypt enc (AgeRecipient "r") plaintext
      ciphertext `shouldNotBe` plaintext

    it "XOR is its own inverse: double-encrypt returns original" $ do
      let enc = mkMockAgeEncryptor
          plaintext = "double xor test"
      Right once  <- _ae_encrypt enc (AgeRecipient "r") plaintext
      Right twice <- _ae_encrypt enc (AgeRecipient "r") once
      twice `shouldBe` plaintext

    it "encrypts empty bytestring" $ do
      let enc = mkMockAgeEncryptor
      Right ciphertext <- _ae_encrypt enc (AgeRecipient "r") BS.empty
      ciphertext `shouldBe` BS.empty

  describe "mkFailingAgeEncryptor" $ do
    it "encrypt returns the configured error" $ do
      let enc = mkFailingAgeEncryptor VaultLocked
      result <- _ae_encrypt enc (AgeRecipient "r") "anything"
      result `shouldBe` Left VaultLocked

    it "decrypt returns the configured error" $ do
      let enc = mkFailingAgeEncryptor (VaultCorrupted "bad data")
      result <- _ae_decrypt enc (AgeIdentity "i") "anything"
      result `shouldBe` Left (VaultCorrupted "bad data")

    it "AgeNotInstalled error roundtrips through Show/Eq" $ do
      let err = AgeNotInstalled "Install age from https://age-encryption.org"
      show err `shouldContain` "AgeNotInstalled"
      err `shouldBe` AgeNotInstalled "Install age from https://age-encryption.org"

  describe "VaultError" $ do
    it "has Show and Eq instances" $ do
      show VaultLocked       `shouldBe` "VaultLocked"
      show VaultNotFound     `shouldBe` "VaultNotFound"
      show VaultAlreadyExists `shouldBe` "VaultAlreadyExists"
      show (VaultCorrupted "msg") `shouldContain` "VaultCorrupted"
      show (AgeError "stderr")    `shouldContain` "AgeError"
      VaultLocked `shouldNotBe` VaultNotFound
      VaultLocked `shouldBe` VaultLocked
