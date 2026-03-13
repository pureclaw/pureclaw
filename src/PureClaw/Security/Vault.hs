module PureClaw.Security.Vault
  ( -- * Config and status
    VaultConfig (..)
  , UnlockMode (..)
  , VaultStatus (..)
    -- * Handle
  , VaultHandle (..)
    -- * Constructor
  , openVault
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, renameFile)
import System.Posix.Files (setFileMode)

import PureClaw.Security.Vault.Age

-- | When the vault is automatically unlocked.
data UnlockMode
  = UnlockCached    -- ^ Decrypt once at startup; cache in memory. Returns VaultLocked if not unlocked.
  | UnlockPerAccess -- ^ Decrypt from disk on every operation; ideal for hardware keys (e.g. YubiKey).
  deriving stock (Show, Eq)

-- | Configuration for a vault.
data VaultConfig = VaultConfig
  { _vc_path    :: FilePath
  , _vc_keyType :: Text    -- ^ human-readable key type for /vault status
  , _vc_unlock  :: UnlockMode
  }
  deriving stock (Show, Eq)

-- | Runtime status of the vault.
data VaultStatus = VaultStatus
  { _vs_locked      :: Bool
  , _vs_secretCount :: Int
  , _vs_keyType     :: Text  -- ^ derived from recipient prefix
  }
  deriving stock (Show, Eq)

-- | Capability handle for vault operations.
data VaultHandle = VaultHandle
  { _vh_init   :: IO (Either VaultError ())
  , _vh_get    :: Text -> IO (Either VaultError ByteString)
  , _vh_put    :: Text -> ByteString -> IO (Either VaultError ())
  , _vh_delete :: Text -> IO (Either VaultError ())
  , _vh_list   :: IO (Either VaultError [Text])
  , _vh_lock   :: IO ()
  , _vh_unlock :: IO (Either VaultError ())
  , _vh_status :: IO VaultStatus
  }

-- Internal state, not exported.
data VaultState = VaultState
  { _vst_config    :: VaultConfig
  , _vst_encryptor :: VaultEncryptor
  , _vst_tvar      :: TVar (Maybe (Map Text ByteString))
  , _vst_writeLock :: MVar ()  -- ^ serialises init/put/delete
  }

-- | Construct a 'VaultHandle'. Does not unlock; caller decides when.
openVault :: VaultConfig -> VaultEncryptor -> IO VaultHandle
openVault cfg enc = do
  tvar  <- newTVarIO Nothing
  mvar  <- newMVar ()
  let st = VaultState cfg enc tvar mvar
  pure VaultHandle
    { _vh_init   = vaultInit   st
    , _vh_get    = vaultGet    st
    , _vh_put    = vaultPut    st
    , _vh_delete = vaultDelete st
    , _vh_list   = vaultList   st
    , _vh_lock   = vaultLock   st
    , _vh_unlock = vaultUnlock st
    , _vh_status = vaultStatus st
    }

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

vaultInit :: VaultState -> IO (Either VaultError ())
vaultInit st = withMVar (_vst_writeLock st) $ \_ -> do
  exists <- doesFileExist (_vc_path (_vst_config st))
  if exists
    then pure (Left VaultAlreadyExists)
    else do
      let emptyMap = Map.empty :: Map Text ByteString
          jsonBs   = BS.toStrict (Aeson.encode (encodedMap emptyMap))
      encrypted <- _ve_encrypt (_vst_encryptor st) jsonBs
      case encrypted of
        Left err  -> pure (Left err)
        Right ciphertext -> do
          atomicWrite (_vc_path (_vst_config st)) ciphertext
          pure (Right ())

vaultUnlock :: VaultState -> IO (Either VaultError ())
vaultUnlock st = do
  fileResult <- try @IOException (BS.readFile (_vc_path (_vst_config st)))
  case fileResult of
    Left  _      -> pure (Left VaultNotFound)
    Right fileBs -> do
      plainResult <- _ve_decrypt (_vst_encryptor st) fileBs
      case plainResult of
        Left err -> pure (Left err)
        Right plain ->
          case Aeson.decodeStrict plain of
            Nothing  -> pure (Left (VaultCorrupted "invalid JSON"))
            Just encoded ->
              case decodeMap encoded of
                Nothing  -> pure (Left (VaultCorrupted "invalid base64 in vault"))
                Just m   -> do
                  atomically (writeTVar (_vst_tvar st) (Just m))
                  pure (Right ())

vaultLock :: VaultState -> IO ()
vaultLock st = atomically (writeTVar (_vst_tvar st) Nothing)

vaultGet :: VaultState -> Text -> IO (Either VaultError ByteString)
vaultGet st key =
  case _vc_unlock (_vst_config st) of
    UnlockPerAccess -> do
      mapResult <- readAndDecryptMap st
      case mapResult of
        Left err -> pure (Left err)
        Right m  -> pure (lookupKey key m)
    UnlockCached -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> pure (lookupKey key m)

vaultPut :: VaultState -> Text -> ByteString -> IO (Either VaultError ())
vaultPut st key value =
  case _vc_unlock (_vst_config st) of
    UnlockPerAccess -> withMVar (_vst_writeLock st) $ \_ -> do
      mapResult <- readAndDecryptMap st
      case mapResult of
        Left err -> pure (Left err)
        Right m  -> encryptAndWrite st (Map.insert key value m)
    UnlockCached -> withMVar (_vst_writeLock st) $ \_ -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> do
          let m' = Map.insert key value m
          result <- encryptAndWrite st m'
          case result of
            Left err -> pure (Left err)
            Right () -> do
              atomically (writeTVar (_vst_tvar st) (Just m'))
              pure (Right ())

vaultDelete :: VaultState -> Text -> IO (Either VaultError ())
vaultDelete st key =
  case _vc_unlock (_vst_config st) of
    UnlockPerAccess -> withMVar (_vst_writeLock st) $ \_ -> do
      mapResult <- readAndDecryptMap st
      case mapResult of
        Left err -> pure (Left err)
        Right m  ->
          if Map.member key m
            then encryptAndWrite st (Map.delete key m)
            else pure (Left (VaultCorrupted "key not found"))
    UnlockCached -> withMVar (_vst_writeLock st) $ \_ -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  ->
          if Map.member key m
            then do
              let m' = Map.delete key m
              result <- encryptAndWrite st m'
              case result of
                Left err -> pure (Left err)
                Right () -> do
                  atomically (writeTVar (_vst_tvar st) (Just m'))
                  pure (Right ())
            else pure (Left (VaultCorrupted "key not found"))

vaultList :: VaultState -> IO (Either VaultError [Text])
vaultList st =
  case _vc_unlock (_vst_config st) of
    UnlockPerAccess -> do
      mapResult <- readAndDecryptMap st
      case mapResult of
        Left err -> pure (Left err)
        Right m  -> pure (Right (Map.keys m))
    UnlockCached -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> pure (Right (Map.keys m))

vaultStatus :: VaultState -> IO VaultStatus
vaultStatus st = do
  current <- readTVarIO (_vst_tvar st)
  let locked = case current of
                 Nothing -> True
                 Just _  -> False
      count  = maybe 0 Map.size current
  pure VaultStatus
    { _vs_locked      = locked
    , _vs_secretCount = count
    , _vs_keyType     = _vc_keyType (_vst_config st)
    }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | Read vault file and decrypt to a map.
readAndDecryptMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
readAndDecryptMap st = do
  fileResult <- try @IOException (BS.readFile (_vc_path (_vst_config st)))
  case fileResult of
    Left  _      -> pure (Left VaultNotFound)
    Right fileBs -> do
      plainResult <- _ve_decrypt (_vst_encryptor st) fileBs
      case plainResult of
        Left err -> pure (Left err)
        Right plain ->
          case Aeson.decodeStrict plain of
            Nothing      -> pure (Left (VaultCorrupted "invalid JSON"))
            Just encoded ->
              case decodeMap encoded of
                Nothing -> pure (Left (VaultCorrupted "invalid base64 in vault"))
                Just m  -> pure (Right m)

-- | Serialise map to JSON, encrypt, and atomically write to disk.
encryptAndWrite :: VaultState -> Map Text ByteString -> IO (Either VaultError ())
encryptAndWrite st m = do
  let jsonBs = BS.toStrict (Aeson.encode (encodedMap m))
  encrypted <- _ve_encrypt (_vst_encryptor st) jsonBs
  case encrypted of
    Left err  -> pure (Left err)
    Right ciphertext -> do
      atomicWrite (_vc_path (_vst_config st)) ciphertext
      pure (Right ())

-- | Look up a key or return the appropriate error.
lookupKey :: Text -> Map Text ByteString -> Either VaultError ByteString
lookupKey key m =
  case Map.lookup key m of
    Nothing -> Left (VaultCorrupted "no such key")
    Just v  -> Right v

-- | Atomically write file: write to .tmp, chmod 0600, then rename.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bs = do
  let tmp = path <> ".tmp"
  BS.writeFile tmp bs
  setFileMode tmp 0o600
  renameFile tmp path

-- | Encode a map's values as base64 for JSON serialisation.
-- The vault format stores values as base64-encoded strings so that
-- binary secrets survive JSON round-trips intact.
encodedMap :: Map Text ByteString -> Map Text Text
encodedMap = Map.map (decodeUtf8Lenient . B64.encode)
  where
    -- B64.encode produces valid ASCII; decoding cannot fail.
    decodeUtf8Lenient :: ByteString -> Text
    decodeUtf8Lenient = T.pack . map (toEnum . fromIntegral) . BS.unpack

-- | Decode base64 values from the JSON representation back to ByteStrings.
decodeMap :: Map Text Text -> Maybe (Map Text ByteString)
decodeMap = traverse decodeValue
  where
    decodeValue :: Text -> Maybe ByteString
    decodeValue t =
      case B64.decode (encodeUtf8 t) of
        Left _  -> Nothing
        Right v -> Just v

    encodeUtf8 :: Text -> ByteString
    encodeUtf8 = BS.pack . map (fromIntegral . fromEnum) . T.unpack

