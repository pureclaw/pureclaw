module PureClaw.Security.Vault.Passphrase
  ( mkPassphraseVaultEncryptor
  , mkPassphraseVaultEncryptorWith
  , ageWorkFactor
  , WorkFactor
  , mkWorkFactor
  ) where

import Control.Concurrent.STM
import Control.Monad.Trans.Except (runExceptT)
import Crypto.Age (decrypt, encrypt)
import Crypto.Age.Identity (Identity (..), ScryptIdentity (..))
import Crypto.Age.Recipient (Recipients (..), ScryptRecipient (..))
import Crypto.Age.Scrypt (Passphrase (..), WorkFactor, bytesToSalt, mkWorkFactor)
import Crypto.Random (getRandomBytes)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromJust)
import Data.Text qualified as T

import PureClaw.Security.Vault.Age (VaultEncryptor (..), VaultError (..))

-- | scrypt work factor for production vaults (N = 2^22): a deliberately high,
-- fixed cost for brute-force resistance. The work factor only affects KDF
-- cost, not correctness, so tests inject a small factor via
-- 'mkPassphraseVaultEncryptorWith' to stay fast.
ageWorkFactor :: WorkFactor
ageWorkFactor = fromJust (mkWorkFactor 22)

-- | Convert a passphrase 'ByteString' to an age 'Passphrase'.
toAgePass :: ByteString -> Passphrase
toAgePass bs = Passphrase (convert bs)

-- | Create a passphrase-based vault encryptor using the age encryption format.
-- The resulting ciphertext is a standard age binary file, compatible with
-- @age -d --passphrase@.
-- The IO action is called at most once to obtain the passphrase, then cached.
--
-- Uses the production 'ageWorkFactor'. For a configurable work factor (e.g.
-- a cheap one in tests), use 'mkPassphraseVaultEncryptorWith'.
mkPassphraseVaultEncryptor :: IO ByteString -> IO VaultEncryptor
mkPassphraseVaultEncryptor = mkPassphraseVaultEncryptorWith ageWorkFactor

-- | Like 'mkPassphraseVaultEncryptor', but with an explicit scrypt work factor.
-- Production callers should use 'mkPassphraseVaultEncryptor' (which supplies
-- 'ageWorkFactor'); a low work factor makes the scrypt KDF cheap and is
-- intended for tests, where the high production cost would dominate CI time.
mkPassphraseVaultEncryptorWith :: WorkFactor -> IO ByteString -> IO VaultEncryptor
mkPassphraseVaultEncryptorWith workFactor getPass = do
  cache <- newTVarIO Nothing
  let getOrPrompt = do
        c <- readTVarIO cache
        case c of
          Just p  -> pure p
          Nothing -> do
            p <- getPass
            atomically (writeTVar cache (Just p))
            pure p
  pure VaultEncryptor
    { _ve_encrypt = \plaintext -> do
        passphrase <- getOrPrompt
        saltBytes  <- getRandomBytes 16
        case bytesToSalt saltBytes of
          Nothing   -> pure (Left (VaultCorrupted "salt generation failed"))
          Just salt -> do
            let recipient = ScryptRecipient
                  { srPassphrase  = toAgePass passphrase
                  , srSalt        = salt
                  , srWorkFactor  = workFactor
                  }
            result <- runExceptT (encrypt (RecipientsScrypt recipient) plaintext)
            case result of
              Left  err -> pure (Left (VaultCorrupted ("age encrypt: " <> T.pack (show err))))
              Right ct  -> pure (Right ct)
    , _ve_decrypt = \ciphertext -> do
        passphrase <- getOrPrompt
        let identity   = ScryptIdentity
              { siPassphrase    = toAgePass passphrase
              , siMaxWorkFactor = workFactor
              }
            identities = IdentityScrypt identity :| []
        case decrypt identities ciphertext of
          Left  _  -> pure (Left (VaultCorrupted "wrong passphrase"))
          Right pt -> pure (Right pt)
    }
