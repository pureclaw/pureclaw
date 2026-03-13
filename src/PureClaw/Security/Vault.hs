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
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, removeFile, renameFile)
import System.Posix.Files (setFileMode)

import PureClaw.Security.Vault.Age

-- | When the vault is automatically unlocked.
data UnlockMode
  = UnlockStartup   -- ^ Must be explicitly unlocked; returns VaultLocked if locked.
  | UnlockOnDemand  -- ^ Unlocks automatically on first access if locked.
  | UnlockPerAccess -- ^ Decrypts from disk on every operation; TVar unused.
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
  , _vh_rekey  :: VaultEncryptor -> Text -> (Text -> IO Bool) -> IO (Either VaultError ())
    -- ^ Re-encrypt the vault with a new encryptor.
    -- Args: new encryptor, new key type label, confirmation callback.
  }

-- Internal state, not exported.
data VaultState = VaultState
  { _vst_config    :: VaultConfig
  , _vst_encryptor :: IORef VaultEncryptor
  , _vst_keyType   :: IORef Text
  , _vst_tvar      :: TVar (Maybe (Map Text ByteString))
  , _vst_writeLock :: MVar ()  -- ^ serialises init/put/delete
  }

-- | Construct a 'VaultHandle'. Does not unlock; caller decides when.
openVault :: VaultConfig -> VaultEncryptor -> IO VaultHandle
openVault cfg enc = do
  encRef <- newIORef enc
  ktRef  <- newIORef (_vc_keyType cfg)
  tvar   <- newTVarIO Nothing
  mvar   <- newMVar ()
  let st = VaultState cfg encRef ktRef tvar mvar
  pure VaultHandle
    { _vh_init   = vaultInit   st
    , _vh_get    = vaultGet    st
    , _vh_put    = vaultPut    st
    , _vh_delete = vaultDelete st
    , _vh_list   = vaultList   st
    , _vh_lock   = vaultLock   st
    , _vh_unlock = vaultUnlock st
    , _vh_status = vaultStatus st
    , _vh_rekey  = vaultRekey  st
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
      enc <- readIORef (_vst_encryptor st)
      let emptyMap = Map.empty :: Map Text ByteString
          jsonBs   = BS.toStrict (Aeson.encode (encodedMap emptyMap))
      encrypted <- _ve_encrypt enc jsonBs
      case encrypted of
        Left err  -> pure (Left err)
        Right ciphertext -> do
          atomicWrite (_vc_path (_vst_config st)) ciphertext
          pure (Right ())

vaultUnlock :: VaultState -> IO (Either VaultError ())
vaultUnlock st = do
  enc <- readIORef (_vst_encryptor st)
  fileResult <- try @IOException (BS.readFile (_vc_path (_vst_config st)))
  case fileResult of
    Left  _      -> pure (Left VaultNotFound)
    Right fileBs -> do
      plainResult <- _ve_decrypt enc fileBs
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
    UnlockStartup -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> pure (lookupKey key m)
    UnlockOnDemand -> do
      ensureUnlocked st
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
    UnlockOnDemand -> do
      -- Unlock outside the write lock to avoid deadlock
      ensureUnlocked st
      withMVar (_vst_writeLock st) $ \_ -> do
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
    UnlockStartup -> withMVar (_vst_writeLock st) $ \_ -> do
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
    UnlockOnDemand -> do
      ensureUnlocked st
      withMVar (_vst_writeLock st) $ \_ -> do
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
    UnlockStartup -> withMVar (_vst_writeLock st) $ \_ -> do
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
    UnlockStartup -> do
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> pure (Right (Map.keys m))
    UnlockOnDemand -> do
      ensureUnlocked st
      current <- readTVarIO (_vst_tvar st)
      case current of
        Nothing -> pure (Left VaultLocked)
        Just m  -> pure (Right (Map.keys m))

vaultStatus :: VaultState -> IO VaultStatus
vaultStatus st = do
  current <- readTVarIO (_vst_tvar st)
  keyType <- readIORef (_vst_keyType st)
  let locked = case current of
                 Nothing -> True
                 Just _  -> False
      count  = maybe 0 Map.size current
  pure VaultStatus
    { _vs_locked      = locked
    , _vs_secretCount = count
    , _vs_keyType     = keyType
    }

-- | Re-encrypt the vault with a new encryptor.
-- Safe rekey: write to .new, verify, then atomically replace.
vaultRekey :: VaultState -> VaultEncryptor -> Text -> (Text -> IO Bool) -> IO (Either VaultError ())
vaultRekey st newEnc newKeyType confirm = withMVar (_vst_writeLock st) $ \_ -> do
  let path    = _vc_path (_vst_config st)
      newPath = path <> ".new"
  -- Step 1: Decrypt all secrets with current encryptor
  mapResult <- readAndDecryptMap st
  case mapResult of
    Left err -> pure (Left err)
    Right plainMap -> do
      -- Step 2: Re-encrypt with NEW encryptor, write to .new
      let jsonBs = BS.toStrict (Aeson.encode (encodedMap plainMap))
      encrypted <- _ve_encrypt newEnc jsonBs
      case encrypted of
        Left err -> pure (Left err)
        Right ciphertext -> do
          atomicWrite newPath ciphertext
          -- Step 3: Verify: read .new, decrypt with new encryptor, compare
          verifyResult <- try @IOException (BS.readFile newPath)
          case verifyResult of
            Left _ -> do
              cleanupNewFile newPath
              pure (Left (VaultCorrupted "rekey verification failed"))
            Right verifyBs -> do
              decResult <- _ve_decrypt newEnc verifyBs
              case decResult of
                Left _ -> do
                  cleanupNewFile newPath
                  pure (Left (VaultCorrupted "rekey verification failed"))
                Right decrypted -> do
                  -- Compare decoded map byte-for-byte with original
                  case Aeson.decodeStrict decrypted of
                    Nothing -> do
                      cleanupNewFile newPath
                      pure (Left (VaultCorrupted "rekey verification failed"))
                    Just encoded ->
                      case decodeMap encoded of
                        Nothing -> do
                          cleanupNewFile newPath
                          pure (Left (VaultCorrupted "rekey verification failed"))
                        Just verifiedMap
                          | verifiedMap /= plainMap -> do
                              cleanupNewFile newPath
                              pure (Left (VaultCorrupted "rekey verification failed"))
                          | otherwise -> do
                              -- Step 4: Ask for confirmation
                              oldKeyType <- readIORef (_vst_keyType st)
                              let secretCount = Map.size plainMap
                                  msg = "Replace vault? Old: " <> oldKeyType
                                     <> ", New: " <> newKeyType
                                     <> ", " <> T.pack (show secretCount)
                                     <> " secrets verified identical"
                              confirmed <- confirm msg
                              if confirmed
                                then do
                                  -- Step 5: Atomic replace
                                  renameFile newPath path
                                  writeIORef (_vst_encryptor st) newEnc
                                  writeIORef (_vst_keyType st) newKeyType
                                  atomically (writeTVar (_vst_tvar st) (Just plainMap))
                                  pure (Right ())
                                else do
                                  cleanupNewFile newPath
                                  pure (Left (VaultCorrupted "rekey cancelled by user"))

-- | Remove the .new file, ignoring errors if it doesn't exist.
cleanupNewFile :: FilePath -> IO ()
cleanupNewFile path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | Read vault file and decrypt to a map.
readAndDecryptMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
readAndDecryptMap st = do
  enc <- readIORef (_vst_encryptor st)
  fileResult <- try @IOException (BS.readFile (_vc_path (_vst_config st)))
  case fileResult of
    Left  _      -> pure (Left VaultNotFound)
    Right fileBs -> do
      plainResult <- _ve_decrypt enc fileBs
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
  enc <- readIORef (_vst_encryptor st)
  let jsonBs = BS.toStrict (Aeson.encode (encodedMap m))
  encrypted <- _ve_encrypt enc jsonBs
  case encrypted of
    Left err  -> pure (Left err)
    Right ciphertext -> do
      atomicWrite (_vc_path (_vst_config st)) ciphertext
      pure (Right ())

-- | For UnlockOnDemand: unlock the vault if the TVar is empty.
-- Guarded by write lock to prevent double-init from concurrent calls.
ensureUnlocked :: VaultState -> IO ()
ensureUnlocked st =
  withMVar (_vst_writeLock st) $ \_ -> do
    current <- readTVarIO (_vst_tvar st)
    case current of
      Just _  -> pure ()   -- already unlocked by a concurrent call
      Nothing -> do
        result <- vaultUnlock st
        case result of
          Right () -> pure ()
          Left _   -> pure ()  -- best-effort; callers check TVar afterward

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

