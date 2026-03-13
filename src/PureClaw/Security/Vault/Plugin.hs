module PureClaw.Security.Vault.Plugin
  ( -- * Plugin type
    AgePlugin (..)
    -- * Plugin handle
  , PluginHandle (..)
  , mkPluginHandle
  , mkMockPluginHandle
    -- * Helpers
  , pluginLabel
  , pluginFromBinary
  ) where

import Data.ByteString.Lazy qualified as BL
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory qualified as Dir
import System.FilePath qualified as FP
import System.Process.Typed

import PureClaw.Security.Vault.Age (AgeRecipient (..), VaultError (..))

-- | An age plugin discovered on PATH.
data AgePlugin = AgePlugin
  { _ap_name   :: !Text      -- ^ Plugin name, e.g. "yubikey"
  , _ap_binary :: !FilePath   -- ^ Binary name, e.g. "age-plugin-yubikey"
  , _ap_label  :: !Text      -- ^ Human-readable label, e.g. "YubiKey PIV"
  } deriving stock (Show, Eq)

-- | Handle for age plugin detection and identity generation.
data PluginHandle = PluginHandle
  { _ph_detect   :: IO [AgePlugin]
  , _ph_generate :: AgePlugin -> FilePath -> IO (Either VaultError (AgeRecipient, FilePath))
  }

-- | Known age plugins with human-readable labels.
knownPluginLabels :: Map.Map Text Text
knownPluginLabels = Map.fromList
  [ ("yubikey",    "YubiKey PIV")
  , ("tpm",        "TPM 2.0")
  , ("se",         "Secure Enclave")
  , ("fido2-hmac", "FIDO2 HMAC")
  ]

-- | Look up a human-readable label for a plugin name.
-- Falls back to the plugin name itself if not in the known registry.
pluginLabel :: Text -> Text
pluginLabel name = Map.findWithDefault name name knownPluginLabels

-- | Construct an 'AgePlugin' from a binary name like @"age-plugin-yubikey"@.
-- Strips the @"age-plugin-"@ prefix and looks up the label.
pluginFromBinary :: FilePath -> AgePlugin
pluginFromBinary binary =
  let name = T.pack (drop (length ("age-plugin-" :: String)) binary)
  in AgePlugin
    { _ap_name   = name
    , _ap_binary = binary
    , _ap_label  = pluginLabel name
    }

-- | Construct a real 'PluginHandle' that scans PATH for age plugins.
mkPluginHandle :: PluginHandle
mkPluginHandle = PluginHandle
  { _ph_detect = detectPlugins
  , _ph_generate = generateIdentity
  }

-- | Scan PATH for executables matching @age-plugin-*@.
detectPlugins :: IO [AgePlugin]
detectPlugins = do
  pathVar <- FP.getSearchPath
  binaries <- concat <$> mapM listAgePlugins pathVar
  pure (map pluginFromBinary (L.nub binaries))

-- | List age-plugin-* executables in a single directory.
listAgePlugins :: FilePath -> IO [FilePath]
listAgePlugins dir = do
  exists <- Dir.doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- Dir.listDirectory dir
      let candidates = filter ("age-plugin-" `L.isPrefixOf`) entries
      filterIO (\e -> do
        let path = dir FP.</> e
        isFile <- Dir.doesFileExist path
        if isFile
          then Dir.executable <$> Dir.getPermissions path
          else pure False) candidates

-- | Filter a list with an IO predicate.
filterIO :: (a -> IO Bool) -> [a] -> IO [a]
filterIO _ [] = pure []
filterIO p (x:xs) = do
  keep <- p x
  rest <- filterIO p xs
  pure (if keep then x : rest else rest)

-- | Run @age-plugin-\<name\> --generate@ and parse the output.
--
-- The plugin process inherits the terminal (stdin, stderr) so it can
-- prompt the user for PIN entry and touch confirmation. Only stdout
-- is captured — that's where the plugin writes the identity and
-- recipient.
generateIdentity :: AgePlugin -> FilePath -> IO (Either VaultError (AgeRecipient, FilePath))
generateIdentity plugin dir = do
  let cfg = setStdin inherit
          $ setStderr inherit
          $ proc (_ap_binary plugin) ["--generate"]
  (exitCode, out, _ignored) <- readProcess cfg
  case exitCode of
    ExitFailure code ->
      pure (Left (AgeError ("plugin exited with code " <> T.pack (show code))))
    ExitSuccess -> do
      let outText = TE.decodeUtf8 (BL.toStrict out)
          outputLines = T.lines outText
          recipientLine = L.find (T.isPrefixOf "# public key: ") outputLines
          identityLines = filter (\l -> not (T.null l) && not (T.isPrefixOf "#" l)) outputLines
      case recipientLine of
        Nothing ->
          pure (Left (AgeError "no public key found in plugin output"))
        Just rLine -> do
          let recipient = T.drop (T.length "# public key: ") rLine
              identityPath = dir FP.</> T.unpack (_ap_name plugin) <> "-identity.txt"
          TIO.writeFile identityPath (T.unlines identityLines)
          pure (Right (AgeRecipient recipient, identityPath))

-- | Construct a mock 'PluginHandle' for testing.
mkMockPluginHandle
  :: [AgePlugin]
  -> (AgePlugin -> Either VaultError (AgeRecipient, FilePath))
  -> PluginHandle
mkMockPluginHandle plugins genFn = PluginHandle
  { _ph_detect   = pure plugins
  , _ph_generate = \p _dir -> pure (genFn p)
  }
