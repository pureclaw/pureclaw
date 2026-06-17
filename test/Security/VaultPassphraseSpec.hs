module Security.VaultPassphraseSpec (spec) where

import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromJust)
import Test.Hspec

import PureClaw.Security.Vault.Age (VaultEncryptor (..), VaultError (..))
import PureClaw.Security.Vault.Passphrase

spec :: Spec
spec = do
  describe "mkPassphraseVaultEncryptor" $ do
    -- A tiny scrypt work factor keeps these tests fast even on small CI
    -- hardware. Production uses 'ageWorkFactor' (N = 2^22); the work factor
    -- only affects KDF cost, not correctness, so a low value exercises the
    -- same code paths instantly.
    let testWorkFactor = fromJust (mkWorkFactor 8)
        mkEnc pass = mkPassphraseVaultEncryptorWith testWorkFactor (pure pass)

    it "roundtrip: encrypt then decrypt returns original plaintext" $ do
      enc <- mkEnc "correcthorsebatterystaple"
      Right ct <- _ve_encrypt enc "my secret"
      Right pt <- _ve_decrypt enc ct
      pt `shouldBe` "my secret"

    it "ciphertext differs from plaintext" $ do
      enc <- mkEnc "pass"
      Right ct <- _ve_encrypt enc "hello"
      ct `shouldNotBe` "hello"

    it "ciphertext has age format header" $ do
      enc <- mkEnc "pass"
      Right ct <- _ve_encrypt enc "data"
      ct `shouldSatisfy` BS.isPrefixOf "age-encryption.org/v1"

    it "wrong passphrase returns VaultCorrupted" $ do
      enc1 <- mkEnc "correctpass"
      enc2 <- mkEnc "wrongpass"
      Right ct <- _ve_encrypt enc1 "secret"
      result   <- _ve_decrypt enc2 ct
      result `shouldBe` Left (VaultCorrupted "wrong passphrase")

    it "returns VaultCorrupted for corrupt ciphertext" $ do
      enc <- mkEnc "pass"
      result <- _ve_decrypt enc "not valid age ciphertext"
      result `shouldSatisfy` isLeft

    it "each encrypt produces different ciphertext (fresh salt)" $ do
      enc <- mkEnc "pass"
      Right ct1 <- _ve_encrypt enc "same plaintext"
      Right ct2 <- _ve_encrypt enc "same plaintext"
      ct1 `shouldNotBe` ct2

    it "mkPassphraseVaultEncryptor (production default) decrypts a vault" $ do
      -- Exercises the production default, which delegates with 'ageWorkFactor'.
      -- We encrypt cheaply, then decrypt through the production default: decrypt
      -- forces the production max work factor (covering 'ageWorkFactor') for its
      -- cap check, while the KDF runs at the file's cheap factor, so it's fast.
      cheap    <- mkEnc "pass"
      Right ct <- _ve_encrypt cheap "secret"
      prod     <- mkPassphraseVaultEncryptor (pure "pass")
      Right pt <- _ve_decrypt prod ct
      pt `shouldBe` "secret"

    it "passphrase is prompted at most once (cached)" $ do
      callCount <- newIORef (0 :: Int)
      let getPass = modifyIORef' callCount (+1) >> pure "pass"
      enc <- mkPassphraseVaultEncryptorWith testWorkFactor getPass
      Right ct <- _ve_encrypt enc "secret"
      Right _  <- _ve_decrypt enc ct
      Right _  <- _ve_decrypt enc ct
      count <- readIORef callCount
      count `shouldBe` 1
