module Security.VaultSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (MVar)
import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.List (sort)
import Data.Word (Word8)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age

-- | Open a vault in a temp directory using the mock encryptor.
withMockVault :: UnlockMode -> (VaultHandle -> FilePath -> IO ()) -> IO ()
withMockVault mode action =
  withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
    let cfg = VaultConfig
              { _vc_path    = dir <> "/test.vault"
              , _vc_keyType = "Mock"
              , _vc_unlock  = mode
              }
    vh <- openVault cfg mkMockVaultEncryptor
    action vh (dir <> "/test.vault")

spec :: Spec
spec = do
  describe "_vh_init" $ do
    it "creates the vault file on disk" $ do
      withMockVault UnlockStartup $ \vh path -> do
        result <- _vh_init vh
        result `shouldBe` Right ()
        contents <- BS.readFile path
        BS.length contents `shouldSatisfy` (> 0)

    it "returns VaultAlreadyExists if called twice" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        result <- _vh_init vh
        result `shouldBe` Left VaultAlreadyExists

  describe "_vh_put and _vh_get (UnlockStartup)" $ do
    it "roundtrip: put then get returns the stored value" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        putResult <- _vh_put vh "mykey" "myvalue"
        putResult `shouldBe` Right ()
        getResult <- _vh_get vh "mykey"
        getResult `shouldBe` Right "myvalue"

    it "get on missing key returns VaultCorrupted" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        result <- _vh_get vh "nonexistent"
        result `shouldBe` Left (VaultCorrupted "no such key")

  describe "_vh_list" $ do
    it "returns all stored key names" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "alpha" "1"
        _ <- _vh_put vh "beta"  "2"
        _ <- _vh_put vh "gamma" "3"
        result <- _vh_list vh
        case result of
          Left err  -> expectationFailure $ "list failed: " ++ show err
          Right keys -> sort keys `shouldBe` ["alpha", "beta", "gamma"]

    it "returns empty list on fresh vault" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        result <- _vh_list vh
        result `shouldBe` Right []

  describe "_vh_delete" $ do
    it "removes a key so get returns error" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "key1" "val1"
        delResult <- _vh_delete vh "key1"
        delResult `shouldBe` Right ()
        getResult <- _vh_get vh "key1"
        getResult `shouldBe` Left (VaultCorrupted "no such key")

    it "delete on missing key returns error" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        result <- _vh_delete vh "missing"
        result `shouldBe` Left (VaultCorrupted "key not found")

  describe "_vh_lock and _vh_unlock" $ do
    it "lock then unlock cycle preserves data" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "secret" "secretvalue"
        _vh_lock vh
        _ <- _vh_unlock vh
        result <- _vh_get vh "secret"
        result `shouldBe` Right "secretvalue"

  describe "UnlockStartup: get on locked vault" $ do
    it "returns VaultLocked when TVar is empty" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        -- Do NOT unlock — vault stays locked
        result <- _vh_get vh "anykey"
        result `shouldBe` Left VaultLocked

  describe "UnlockOnDemand: get auto-unlocks" $ do
    it "get on locked vault triggers unlock and returns value" $ do
      withMockVault UnlockOnDemand $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "k" "v"
        _vh_lock vh
        -- Auto-unlock on demand
        result <- _vh_get vh "k"
        result `shouldBe` Right "v"

  describe "UnlockPerAccess" $ do
    it "put and get roundtrip without explicit unlock" $ do
      withMockVault UnlockPerAccess $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_put vh "k2" "v2"
        result <- _vh_get vh "k2"
        result `shouldBe` Right "v2"

    it "list works without explicit unlock" $ do
      withMockVault UnlockPerAccess $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_put vh "pa" "1"
        _ <- _vh_put vh "pb" "2"
        result <- _vh_list vh
        case result of
          Left err  -> expectationFailure $ "list failed: " ++ show err
          Right keys -> sort keys `shouldBe` ["pa", "pb"]

  describe "_vh_status" $ do
    it "reports locked=True before unlock" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        st <- _vh_status vh
        _vs_locked st `shouldBe` True

    it "reports locked=False after unlock" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        st <- _vh_status vh
        _vs_locked st `shouldBe` False

    it "reports correct secret count after puts" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "a" "1"
        _ <- _vh_put vh "b" "2"
        st <- _vh_status vh
        _vs_secretCount st `shouldBe` 2

    it "reports X25519 key type when configured" $ do
      withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
        let cfg = VaultConfig
                  { _vc_path    = dir <> "/test2.vault"
                  , _vc_keyType = "X25519"
                  , _vc_unlock  = UnlockStartup
                  }
        vh <- openVault cfg mkMockVaultEncryptor
        _ <- _vh_init vh
        st <- _vh_status vh
        _vs_keyType st `shouldBe` "X25519"

    it "reports YubiKey PIV key type for age-plugin-yubikey prefix" $ do
      withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
        let cfg = VaultConfig
                  { _vc_path    = dir <> "/test3.vault"
                  , _vc_keyType = "YubiKey PIV"
                  , _vc_unlock  = UnlockStartup
                  }
        vh <- openVault cfg mkMockVaultEncryptor
        _ <- _vh_init vh
        st <- _vh_status vh
        _vs_keyType st `shouldBe` "YubiKey PIV"

  describe "concurrent puts" $ do
    it "two concurrent puts both persist" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        done1 <- newEmptyMVar :: IO (MVar ())
        done2 <- newEmptyMVar :: IO (MVar ())
        _ <- forkIO $ do
          _ <- _vh_put vh "concurrent1" "val1"
          putMVar done1 ()
        _ <- forkIO $ do
          _ <- _vh_put vh "concurrent2" "val2"
          putMVar done2 ()
        takeMVar done1
        takeMVar done2
        r1 <- _vh_get vh "concurrent1"
        r2 <- _vh_get vh "concurrent2"
        r1 `shouldSatisfy` isRight
        r2 `shouldSatisfy` isRight

  describe "VaultConfig" $ do
    it "has Show and Eq instances" $ do
      let cfg = VaultConfig "/tmp/test.vault" "Mock" UnlockStartup
      show cfg `shouldContain` "VaultConfig"
      cfg `shouldBe` cfg

  describe "UnlockMode" $ do
    it "has Show and Eq instances" $ do
      show UnlockStartup   `shouldBe` "UnlockStartup"
      show UnlockOnDemand  `shouldBe` "UnlockOnDemand"
      show UnlockPerAccess `shouldBe` "UnlockPerAccess"
      UnlockStartup `shouldNotBe` UnlockOnDemand

  describe "_vh_unlock" $ do
    it "returns VaultNotFound when vault file does not exist" $ do
      withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
        let cfg = VaultConfig
                  { _vc_path    = dir <> "/nonexistent.vault"
                  , _vc_keyType = "Mock"
                  , _vc_unlock  = UnlockStartup
                  }
        vh <- openVault cfg mkMockVaultEncryptor
        result <- _vh_unlock vh
        result `shouldBe` Left VaultNotFound

  describe "_vh_rekey" $ do
    it "rekey preserves all secrets" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "secret1" "value1"
        _ <- _vh_put vh "secret2" "value2"
        _ <- _vh_put vh "secret3" "value3"
        -- Rekey to a different mock encryptor (XOR with 0xCD instead of 0xAB)
        let newEnc = mkMockVaultEncryptorAlt 0xCD
        result <- _vh_rekey vh newEnc "Alt-Mock" (\_ -> pure True)
        result `shouldBe` Right ()
        -- All secrets should be retrievable after rekey
        r1 <- _vh_get vh "secret1"
        r1 `shouldBe` Right "value1"
        r2 <- _vh_get vh "secret2"
        r2 `shouldBe` Right "value2"
        r3 <- _vh_get vh "secret3"
        r3 `shouldBe` Right "value3"

    it "rekey updates key type in status" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "k" "v"
        let newEnc = mkMockVaultEncryptorAlt 0xCD
        _ <- _vh_rekey vh newEnc "NewKeyType" (\_ -> pure True)
        st <- _vh_status vh
        _vs_keyType st `shouldBe` "NewKeyType"

    it "rekey verification catches mismatch" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "k" "v"
        -- Use an encryptor whose decrypt returns corrupted data,
        -- so verification (encrypt then decrypt) produces a mismatch.
        let badEnc = VaultEncryptor
              { _ve_encrypt = pure . Right . BS.map (`xor` 0xCD)
              , _ve_decrypt = \_ -> pure (Right "garbage that is not valid JSON")
              }
        result <- _vh_rekey vh badEnc "Bad" (\_ -> pure True)
        result `shouldSatisfy` isLeft
        case result of
          Left (VaultCorrupted msg) -> msg `shouldBe` "rekey verification failed"
          other -> expectationFailure $ "Expected VaultCorrupted, got: " ++ show other

    it "rekey cancelled leaves vault intact" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        _ <- _vh_unlock vh
        _ <- _vh_put vh "mykey" "myval"
        let newEnc = mkMockVaultEncryptorAlt 0xCD
        result <- _vh_rekey vh newEnc "NewType" (\_ -> pure False)
        result `shouldSatisfy` isLeft
        case result of
          Left (VaultCorrupted msg) -> msg `shouldBe` "rekey cancelled by user"
          other -> expectationFailure $ "Expected cancellation error, got: " ++ show other
        -- Original vault should still work
        r <- _vh_get vh "mykey"
        r `shouldBe` Right "myval"
        -- Key type should be unchanged
        st <- _vh_status vh
        _vs_keyType st `shouldBe` "Mock"

-- | A mock 'VaultEncryptor' that XORs each byte with the given mask.
-- Allows creating distinct encryptors for rekey tests.
mkMockVaultEncryptorAlt :: Word8 -> VaultEncryptor
mkMockVaultEncryptorAlt mask = VaultEncryptor
  { _ve_encrypt = pure . Right . BS.map (`xor` mask)
  , _ve_decrypt = pure . Right . BS.map (`xor` mask)
  }
