module PureClaw.Security.Vault.Passphrase
  ( mkPassphraseVaultEncryptor
  ) where

import Control.Concurrent.STM
import Crypto.KDF.PBKDF2 (Parameters (..), fastPBKDF2_SHA256)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

import PureClaw.Security.Crypto (decrypt, encrypt)
import PureClaw.Security.Secrets (mkSecretKey)
import PureClaw.Security.Vault.Age (VaultEncryptor (..), VaultError (..))

-- Magic header identifying passphrase-encrypted vault files.
magicHeader :: ByteString
magicHeader = "PCLAWPW1"

-- Magic prefix prepended to plaintext before encryption for passphrase verification.
checkMagic :: ByteString
checkMagic = "PCLAWCHK"

saltLen :: Int
saltLen = 32

pbkdf2Params :: Parameters
pbkdf2Params = Parameters { iterCounts = 100_000, outputLength = 32 }

-- | Derive a 32-byte encryption key from a passphrase and salt using PBKDF2-SHA256.
deriveKey :: ByteString -> ByteString -> ByteString
deriveKey = fastPBKDF2_SHA256 pbkdf2Params

-- | Create a passphrase-based vault encryptor.
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
        salt <- getRandomBytes saltLen
        let key = deriveKey passphrase salt
        result <- encrypt (mkSecretKey key) (checkMagic <> plaintext)
        case result of
          Left  _          -> pure (Left (VaultCorrupted "encryption failed"))
          Right ciphertext -> pure (Right (magicHeader <> salt <> ciphertext))
    , _ve_decrypt = \ciphertext -> do
        passphrase <- getOrPrompt
        let (hdr, rest) = BS.splitAt (BS.length magicHeader) ciphertext
        if hdr /= magicHeader
          then pure (Left (VaultCorrupted "not a passphrase-encrypted vault"))
          else do
            let (salt, encrypted) = BS.splitAt saltLen rest
            if BS.length salt < saltLen
              then pure (Left (VaultCorrupted "truncated vault file"))
              else do
                let key = deriveKey passphrase salt
                case decrypt (mkSecretKey key) encrypted of
                  Left  _ -> pure (Left (VaultCorrupted "decryption failed"))
                  Right plain ->
                    if checkMagic `BS.isPrefixOf` plain
                      then pure (Right (BS.drop (BS.length checkMagic) plain))
                      else pure (Left (VaultCorrupted "wrong passphrase"))
    }
