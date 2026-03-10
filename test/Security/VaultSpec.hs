module Security.VaultSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (MVar)
import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.List (sort)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age

-- | Open a vault in a temp directory using the mock encryptor.
withMockVault :: UnlockMode -> (VaultHandle -> FilePath -> IO ()) -> IO ()
withMockVault mode action =
  withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
    let cfg = VaultConfig
              { _vc_path      = dir <> "/test.vault"
              , _vc_recipient = "age1examplerecipient"
              , _vc_identity  = "/path/to/identity"
              , _vc_unlock    = mode
              }
    vh <- openVault cfg mkMockAgeEncryptor
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

    it "reports X25519 key type for age1 recipient prefix" $ do
      withMockVault UnlockStartup $ \vh _ -> do
        _ <- _vh_init vh
        st <- _vh_status vh
        _vs_keyType st `shouldBe` "X25519"

    it "reports YubiKey PIV key type for age-plugin-yubikey prefix" $ do
      withSystemTempDirectory "pureclaw-vault-test" $ \dir -> do
        let cfg = VaultConfig
                  { _vc_path      = dir <> "/test2.vault"
                  , _vc_recipient = "age-plugin-yubikey-1abc"
                  , _vc_identity  = "/path/to/identity"
                  , _vc_unlock    = UnlockStartup
                  }
        vh <- openVault cfg mkMockAgeEncryptor
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
      let cfg = VaultConfig "/tmp/test.vault" "age1abc" "/id" UnlockStartup
      show cfg `shouldContain` "VaultConfig"
      cfg `shouldBe` cfg

  describe "UnlockMode" $ do
    it "has Show and Eq instances" $ do
      show UnlockStartup   `shouldBe` "UnlockStartup"
      show UnlockOnDemand  `shouldBe` "UnlockOnDemand"
      show UnlockPerAccess `shouldBe` "UnlockPerAccess"
      UnlockStartup `shouldNotBe` UnlockOnDemand
