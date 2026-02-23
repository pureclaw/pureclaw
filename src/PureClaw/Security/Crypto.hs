module PureClaw.Security.Crypto
  ( -- * Encryption / decryption (AES-256-CTR via crypton)
    encrypt
  , decrypt
    -- * Cryptographic randomness
  , getRandomBytes
  , generateToken
    -- * Constant-time comparison
  , constantTimeEq
    -- * Hashing
  , sha256Hash
    -- * Errors
  , CryptoError (..)
  ) where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (cipherInit, ctrCombine, makeIV)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random qualified as CR
import Data.ByteArray (constEq, convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import PureClaw.Security.Secrets

-- | Errors that can occur during cryptographic operations.
data CryptoError
  = InvalidKeyLength
  | InvalidIV
  | CipherInitFailed
  deriving stock (Show, Eq)

-- | Encrypt plaintext using AES-256-CTR.
-- The IV is prepended to the ciphertext so it can be recovered for decryption.
-- Requires a 32-byte SecretKey and returns Left on invalid key/IV.
encrypt :: SecretKey -> ByteString -> IO (Either CryptoError ByteString)
encrypt key plaintext = withSecretKey key $ \rawKey -> do
  if BS.length rawKey /= 32
    then pure (Left InvalidKeyLength)
    else do
      iv <- CR.getRandomBytes 16
      case initCipher rawKey of
        Left err -> pure (Left err)
        Right cipher ->
          case makeIV (iv :: ByteString) of
            Nothing -> pure (Left InvalidIV)
            Just aesIV -> do
              let ciphertext = ctrCombine cipher aesIV plaintext
              pure (Right (iv <> ciphertext))

-- | Decrypt ciphertext produced by 'encrypt'.
-- Expects the IV prepended to the ciphertext (first 16 bytes).
decrypt :: SecretKey -> ByteString -> Either CryptoError ByteString
decrypt key ciphertextWithIV = withSecretKey key $ \rawKey ->
  if BS.length rawKey /= 32
    then Left InvalidKeyLength
    else if BS.length ciphertextWithIV < 16
      then Left InvalidIV
      else
        let (iv, ciphertext) = BS.splitAt 16 ciphertextWithIV
        in case initCipher rawKey of
          Left err -> Left err
          Right cipher ->
            case makeIV (iv :: ByteString) of
              Nothing -> Left InvalidIV
              Just aesIV -> Right (ctrCombine cipher aesIV ciphertext)

-- | Generate cryptographically secure random bytes.
getRandomBytes :: Int -> IO ByteString
getRandomBytes = CR.getRandomBytes

-- | Generate a hex-encoded random token of the given byte length.
-- The output text will be 2x the byte length (hex encoding).
generateToken :: Int -> IO Text
generateToken n = do
  bytes <- CR.getRandomBytes n
  pure (TE.decodeUtf8 (B16.encode bytes))

-- | Constant-time equality comparison for ByteStrings.
-- Prevents timing attacks when comparing secrets.
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq = constEq

-- | SHA-256 hash, returned as hex-encoded ByteString.
sha256Hash :: ByteString -> ByteString
sha256Hash bs = B16.encode (convert digest)
  where
    digest = hash bs :: Digest SHA256

-- Internal: initialize an AES256 cipher from raw key bytes.
initCipher :: ByteString -> Either CryptoError AES256
initCipher rawKey =
  case cipherInit rawKey of
    CryptoPassed c  -> Right c
    CryptoFailed _  -> Left CipherInitFailed
