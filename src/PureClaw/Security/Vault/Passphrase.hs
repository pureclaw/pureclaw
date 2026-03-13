module PureClaw.Security.Vault.Passphrase
  ( mkPassphraseVaultEncryptor
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

-- | scrypt work factor (N = 2^22), matching the age CLI default.
ageWorkFactor :: WorkFactor
ageWorkFactor = fromJust (mkWorkFactor 22)

-- | Convert a passphrase 'ByteString' to an age 'Passphrase'.
toAgePass :: ByteString -> Passphrase
toAgePass bs = Passphrase (convert bs)

-- | Create a passphrase-based vault encryptor using the age encryption format.
-- The resulting ciphertext is a standard age binary file, compatible with
-- @age -d --passphrase@.
-- The IO action is called at most once to obtain the passphrase, then cached.
mkPassphraseVaultEncryptor :: IO ByteString -> IO VaultEncryptor
mkPassphraseVaultEncryptor getPass = do
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
                  , srWorkFactor  = ageWorkFactor
                  }
            result <- runExceptT (encrypt (RecipientsScrypt recipient) plaintext)
            case result of
              Left  err -> pure (Left (VaultCorrupted ("age encrypt: " <> T.pack (show err))))
              Right ct  -> pure (Right ct)
    , _ve_decrypt = \ciphertext -> do
        passphrase <- getOrPrompt
        let identity   = ScryptIdentity
              { siPassphrase    = toAgePass passphrase
              , siMaxWorkFactor = ageWorkFactor
              }
            identities = IdentityScrypt identity :| []
        case decrypt identities ciphertext of
          Left  _  -> pure (Left (VaultCorrupted "wrong passphrase"))
          Right pt -> pure (Right pt)
    }
