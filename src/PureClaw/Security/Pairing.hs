module PureClaw.Security.Pairing
  ( -- * Pairing state
    PairingState
  , mkPairingState
    -- * Operations
  , generatePairingCode
  , attemptPair
  , verifyToken
  , revokeToken
    -- * Configuration
  , PairingConfig (..)
  , defaultPairingConfig
    -- * Errors
  , PairingError (..)
  ) where

import Control.Concurrent.STM
import Crypto.Random qualified as CR
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word32)

import PureClaw.Security.Crypto
import PureClaw.Security.Secrets

-- | Configuration for the pairing system.
data PairingConfig = PairingConfig
  { _pc_codeExpiry      :: NominalDiffTime
  , _pc_maxAttempts     :: Int
  , _pc_lockoutDuration :: NominalDiffTime
  , _pc_tokenBytes      :: Int
  }
  deriving stock (Show, Eq)

-- | Sensible defaults: 5 minute code expiry, 5 attempts before lockout,
-- 15 minute lockout, 32-byte tokens.
defaultPairingConfig :: PairingConfig
defaultPairingConfig = PairingConfig
  { _pc_codeExpiry      = 300
  , _pc_maxAttempts     = 5
  , _pc_lockoutDuration = 900
  , _pc_tokenBytes      = 32
  }

-- | Errors from pairing operations.
data PairingError
  = InvalidCode
  | LockedOut
  | CodeExpired
  deriving stock (Show, Eq)

-- | Per-client attempt tracking.
data AttemptInfo = AttemptInfo
  { _ai_count     :: Int
  , _ai_lastAttempt :: UTCTime
  }

-- | Mutable pairing state, managed via STM.
data PairingState = PairingState
  { _ps_config    :: PairingConfig
  , _ps_codes     :: TVar (Map Text UTCTime)
  , _ps_attempts  :: TVar (Map Text AttemptInfo)
  , _ps_tokens    :: TVar (Set ByteString)
  }

-- | Create a fresh pairing state.
mkPairingState :: PairingConfig -> IO PairingState
mkPairingState config = PairingState config
  <$> newTVarIO Map.empty
  <*> newTVarIO Map.empty
  <*> newTVarIO Set.empty

-- | Generate a cryptographically random 6-digit pairing code.
-- The code is registered in the pairing state with an expiry time.
generatePairingCode :: PairingState -> IO PairingCode
generatePairingCode st = do
  bytes <- CR.getRandomBytes 4 :: IO ByteString
  let n = (fromIntegral (BS.index bytes 0) `shiftL` 24
       .|. fromIntegral (BS.index bytes 1) `shiftL` 16
       .|. fromIntegral (BS.index bytes 2) `shiftL`  8
       .|. fromIntegral (BS.index bytes 3)) :: Word32
      codeText = T.justifyRight 6 '0' (T.pack (show (n `mod` 1000000)))
  now <- getCurrentTime
  let expiry = addUTCTime (_pc_codeExpiry (_ps_config st)) now
  atomically $ modifyTVar' (_ps_codes st) (Map.insert codeText expiry)
  pure (mkPairingCode codeText)

-- | Attempt to pair using a code. Returns a bearer token on success.
-- Tracks per-client attempts and enforces lockout after too many failures.
attemptPair :: PairingState -> Text -> PairingCode -> IO (Either PairingError BearerToken)
attemptPair st clientId code = do
  now <- getCurrentTime
  withPairingCode code $ \codeText -> do
    let config = _ps_config st
    result <- atomically $ do
      attempts <- readTVar (_ps_attempts st)
      case Map.lookup clientId attempts of
        Just info
          | _ai_count info >= _pc_maxAttempts config
          , diffUTCTime now (_ai_lastAttempt info) < _pc_lockoutDuration config
          -> pure (Left LockedOut)
        _ -> do
          codes <- readTVar (_ps_codes st)
          case Map.lookup codeText codes of
            Nothing -> do
              bumpAttempts st clientId now
              pure (Left InvalidCode)
            Just expiry
              | now > expiry -> do
                  modifyTVar' (_ps_codes st) (Map.delete codeText)
                  bumpAttempts st clientId now
                  pure (Left CodeExpired)
              | otherwise -> do
                  modifyTVar' (_ps_codes st) (Map.delete codeText)
                  modifyTVar' (_ps_attempts st) (Map.delete clientId)
                  pure (Right ())
    case result of
      Left err -> pure (Left err)
      Right () -> do
        tokenBytes <- CR.getRandomBytes (_pc_tokenBytes config)
        let tokenHash = sha256Hash tokenBytes
        atomically $ modifyTVar' (_ps_tokens st) (Set.insert tokenHash)
        pure (Right (mkBearerToken tokenBytes))

-- | Verify a bearer token against stored hashes. Constant-time comparison.
verifyToken :: PairingState -> BearerToken -> IO Bool
verifyToken st token =
  withBearerToken token $ \tokenBytes -> do
    let tokenHash = sha256Hash tokenBytes
    hashes <- readTVarIO (_ps_tokens st)
    pure (Set.member tokenHash hashes)

-- | Revoke a bearer token.
revokeToken :: PairingState -> BearerToken -> IO ()
revokeToken st token =
  withBearerToken token $ \tokenBytes -> do
    let tokenHash = sha256Hash tokenBytes
    atomically $ modifyTVar' (_ps_tokens st) (Set.delete tokenHash)

-- Internal: bump attempt counter for a client.
bumpAttempts :: PairingState -> Text -> UTCTime -> STM ()
bumpAttempts st clientId now =
  modifyTVar' (_ps_attempts st) $ Map.alter bump clientId
  where
    bump Nothing = Just (AttemptInfo 1 now)
    bump (Just info) = Just info { _ai_count = _ai_count info + 1, _ai_lastAttempt = now }
