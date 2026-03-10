module PureClaw.Security.Vault.Age
  ( -- * Error type
    VaultError (..)
    -- * Age encryptor handle
  , AgeEncryptor (..)
  , AgeRecipient (..)
  , AgeIdentity (..)
  , mkAgeEncryptor
  , mkMockAgeEncryptor
  , mkFailingAgeEncryptor
    -- * Simplified vault encryptor (credentials captured in closure)
  , VaultEncryptor (..)
  , ageVaultEncryptor
  , mkMockVaultEncryptor
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Process.Typed

-- | Errors that can arise from vault operations.
data VaultError
  = VaultLocked
  | VaultNotFound
  | VaultCorrupted Text
  | AgeError Text          -- ^ stderr from age subprocess
  | VaultAlreadyExists
  | AgeNotInstalled Text   -- ^ message with install hint
  deriving stock (Show, Eq)

-- | An age public-key recipient (e.g. "age1..." or "age-plugin-yubikey-...").
newtype AgeRecipient = AgeRecipient Text
  deriving stock (Show, Eq)

-- | An age identity: a file path or plugin string.
newtype AgeIdentity = AgeIdentity Text
  deriving stock (Show, Eq)

-- | Handle for age encrypt/decrypt operations.
-- Use 'mkAgeEncryptor' for the real subprocess implementation,
-- or 'mkMockAgeEncryptor' in tests.
data AgeEncryptor = AgeEncryptor
  { _ae_encrypt :: AgeRecipient -> ByteString -> IO (Either VaultError ByteString)
  , _ae_decrypt :: AgeIdentity  -> ByteString -> IO (Either VaultError ByteString)
  }

-- | Construct a real 'AgeEncryptor' that shells out to the @age@ binary.
-- Performs a preflight @age --version@ check; returns
-- @Left (AgeNotInstalled hint)@ if the binary is not on PATH.
mkAgeEncryptor :: IO (Either VaultError AgeEncryptor)
mkAgeEncryptor = do
  versionResult <- runProcess (proc "age" ["--version"])
  case versionResult of
    ExitFailure _ ->
      pure (Left (AgeNotInstalled "Install age from https://age-encryption.org"))
    ExitSuccess   ->
      pure (Right enc)
  where
    enc :: AgeEncryptor
    enc = AgeEncryptor
      { _ae_encrypt = \(AgeRecipient recipient) plaintext -> do
          let cfg = setStdin (byteStringInput (BS.fromStrict plaintext))
                  $ proc "age" ["--encrypt", "--recipient", textToStr recipient]
          (exitCode, out, err) <- readProcess cfg
          case exitCode of
            ExitSuccess   -> pure (Right (BS.toStrict out))
            ExitFailure _ -> pure (Left (AgeError (TE.decodeUtf8 (BS.toStrict err))))
      , _ae_decrypt = \(AgeIdentity identity) ciphertext -> do
          let cfg = setStdin (byteStringInput (BS.fromStrict ciphertext))
                  $ proc "age" ["--decrypt", "--identity", textToStr identity]
          (exitCode, out, err) <- readProcess cfg
          case exitCode of
            ExitSuccess   -> pure (Right (BS.toStrict out))
            ExitFailure _ -> pure (Left (AgeError (TE.decodeUtf8 (BS.toStrict err))))
      }

    textToStr :: Text -> String
    textToStr = T.unpack

-- | A mock 'AgeEncryptor' that XORs each byte with @0xAB@.
-- No real @age@ binary required — suitable for unit tests.
mkMockAgeEncryptor :: AgeEncryptor
mkMockAgeEncryptor = AgeEncryptor
  { _ae_encrypt = \_recipient plaintext -> pure (Right (mockXor plaintext))
  , _ae_decrypt = \_identity  ciphertext -> pure (Right (mockXor ciphertext))
  }
  where
    mockXor :: ByteString -> ByteString
    mockXor = BS.map (`xor` 0xAB)

-- | A mock 'AgeEncryptor' that always returns the given error.
-- Useful for testing error-path handling in vault operations.
mkFailingAgeEncryptor :: VaultError -> AgeEncryptor
mkFailingAgeEncryptor err = AgeEncryptor
  { _ae_encrypt = \_ _ -> pure (Left err)
  , _ae_decrypt = \_ _ -> pure (Left err)
  }

-- | Simplified encryptor: credentials are captured in the closure.
-- Replaces the explicit AgeRecipient/AgeIdentity arguments at call sites.
data VaultEncryptor = VaultEncryptor
  { _ve_encrypt :: ByteString -> IO (Either VaultError ByteString)
  , _ve_decrypt :: ByteString -> IO (Either VaultError ByteString)
  }

-- | Create a 'VaultEncryptor' from an 'AgeEncryptor' with specific recipient/identity.
ageVaultEncryptor :: AgeEncryptor -> Text -> Text -> VaultEncryptor
ageVaultEncryptor enc recipient identity = VaultEncryptor
  { _ve_encrypt = _ae_encrypt enc (AgeRecipient recipient)
  , _ve_decrypt = _ae_decrypt enc (AgeIdentity identity)
  }

-- | A mock 'VaultEncryptor' for unit tests (XOR like 'mkMockAgeEncryptor').
mkMockVaultEncryptor :: VaultEncryptor
mkMockVaultEncryptor = VaultEncryptor
  { _ve_encrypt = pure . Right . mockXor
  , _ve_decrypt = pure . Right . mockXor
  }
  where
    mockXor :: ByteString -> ByteString
    mockXor = BS.map (`xor` 0xAB)
