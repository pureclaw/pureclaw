module PureClaw.CLI.Config
  ( -- * File config
    FileConfig (..)
  , emptyFileConfig
    -- * Loading
  , loadFileConfig
  , loadConfig
    -- * Diagnostic loading
  , ConfigLoadResult (..)
  , loadFileConfigDiag
  , loadConfigDiag
  , configFileConfig
    -- * Writing
  , updateVaultConfig
    -- * Directory helpers
  , getPureclawDir
  ) where

import Control.Applicative ((<|>))
import Control.Exception
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import Toml (TomlCodec, (.=))
import Toml qualified

-- | Configuration that can be read from a TOML file.
-- All fields are optional — missing fields default to Nothing.
data FileConfig = FileConfig
  { _fc_apiKey         :: Maybe Text
  , _fc_model          :: Maybe Text
  , _fc_provider       :: Maybe Text
  , _fc_system         :: Maybe Text
  , _fc_memory         :: Maybe Text
  , _fc_allow          :: Maybe [Text]
  , _fc_vault_path      :: Maybe Text  -- ^ vault file path (default: ~/.pureclaw/vault.age)
  , _fc_vault_recipient :: Maybe Text  -- ^ age recipient string (required to enable vault)
  , _fc_vault_identity  :: Maybe Text  -- ^ age identity path or plugin string
  , _fc_vault_unlock    :: Maybe Text  -- ^ "startup", "on_demand", or "per_access"
  } deriving stock (Show, Eq)

emptyFileConfig :: FileConfig
emptyFileConfig =
  FileConfig Nothing Nothing Nothing Nothing Nothing Nothing
             Nothing Nothing Nothing Nothing

fileConfigCodec :: TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "api_key")                   .= _fc_apiKey
  <*> Toml.dioptional (Toml.text "model")                     .= _fc_model
  <*> Toml.dioptional (Toml.text "provider")                  .= _fc_provider
  <*> Toml.dioptional (Toml.text "system")                    .= _fc_system
  <*> Toml.dioptional (Toml.text "memory")                    .= _fc_memory
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow")       .= _fc_allow
  <*> Toml.dioptional (Toml.text "vault_path")                .= _fc_vault_path
  <*> Toml.dioptional (Toml.text "vault_recipient")           .= _fc_vault_recipient
  <*> Toml.dioptional (Toml.text "vault_identity")            .= _fc_vault_identity
  <*> Toml.dioptional (Toml.text "vault_unlock")              .= _fc_vault_unlock

-- | Load config from a single file path.
-- Returns 'emptyFileConfig' if the file does not exist or cannot be parsed.
loadFileConfig :: FilePath -> IO FileConfig
loadFileConfig path = do
  text <- try @IOError (TIO.readFile path)
  pure $ case text of
    Left  _    -> emptyFileConfig
    Right toml -> case Toml.decode fileConfigCodec toml of
      Left  _ -> emptyFileConfig
      Right c -> c

-- | The PureClaw home directory: @~\/.pureclaw@.
-- This is where config, memory, and vault files are stored by default.
getPureclawDir :: IO FilePath
getPureclawDir = do
  home <- getHomeDirectory
  pure (home </> ".pureclaw")

-- | Load config from the default locations, trying each in order:
--
-- 1. @~\/.pureclaw\/config.toml@ (user home)
-- 2. @~\/.config\/pureclaw\/config.toml@ (XDG fallback)
--
-- Returns the first config found, or 'emptyFileConfig' if none exists.
loadConfig :: IO FileConfig
loadConfig = configFileConfig <$> loadConfigDiag

-- | Result of attempting to load a config file.
data ConfigLoadResult
  = ConfigLoaded FilePath FileConfig     -- ^ File found and parsed successfully
  | ConfigParseError FilePath Text       -- ^ File exists but contains invalid TOML
  | ConfigFileNotFound FilePath          -- ^ Specific file was not found
  | ConfigNotFound [FilePath]            -- ^ No config found at any default location
  deriving stock (Show, Eq)

-- | Extract the 'FileConfig' from a result, defaulting to 'emptyFileConfig' on error.
configFileConfig :: ConfigLoadResult -> FileConfig
configFileConfig (ConfigLoaded _ fc)    = fc
configFileConfig (ConfigParseError _ _) = emptyFileConfig
configFileConfig (ConfigFileNotFound _) = emptyFileConfig
configFileConfig (ConfigNotFound _)     = emptyFileConfig

-- | Load config from a single file, returning diagnostic information.
-- Unlike 'loadFileConfig', parse errors are not silently discarded.
loadFileConfigDiag :: FilePath -> IO ConfigLoadResult
loadFileConfigDiag path = do
  text <- try @IOError (TIO.readFile path)
  pure $ case text of
    Left  _ -> ConfigFileNotFound path
    Right toml -> case Toml.decode fileConfigCodec toml of
      Left errs -> ConfigParseError path (Toml.prettyTomlDecodeErrors errs)
      Right c   -> ConfigLoaded path c

-- | Load config from default locations with diagnostics.
-- Stops at the first file that exists (even if it has errors).
loadConfigDiag :: IO ConfigLoadResult
loadConfigDiag = do
  home <- try @IOError getHomeDirectory
  case home of
    Left _ -> pure (ConfigNotFound [])
    Right h -> do
      let homePath = h </> ".pureclaw" </> "config.toml"
          xdgPath  = h </> ".config" </> "pureclaw" </> "config.toml"
      homeResult <- loadFileConfigDiag homePath
      case homeResult of
        ConfigFileNotFound _ -> do
          xdgResult <- loadFileConfigDiag xdgPath
          case xdgResult of
            ConfigFileNotFound _ -> pure (ConfigNotFound [homePath, xdgPath])
            _                    -> pure xdgResult
        _ -> pure homeResult

-- | Update vault-related fields in a config file, preserving all other settings.
-- 'Nothing' means "leave this field unchanged". If all four arguments are
-- 'Nothing', this is a no-op (no file write occurs).
updateVaultConfig
  :: FilePath    -- ^ Config file path
  -> Maybe Text  -- ^ vault_path
  -> Maybe Text  -- ^ vault_recipient
  -> Maybe Text  -- ^ vault_identity
  -> Maybe Text  -- ^ vault_unlock
  -> IO ()
updateVaultConfig _ Nothing Nothing Nothing Nothing = pure ()
updateVaultConfig path vaultPath vaultRecipient vaultIdentity vaultUnlock = do
  existing <- loadFileConfig path
  let updated = existing
        { _fc_vault_path      = vaultPath      <|> _fc_vault_path existing
        , _fc_vault_recipient = vaultRecipient  -- Direct: Nothing clears stale age creds
        , _fc_vault_identity  = vaultIdentity   -- Direct: Nothing clears stale age creds
        , _fc_vault_unlock    = vaultUnlock     <|> _fc_vault_unlock existing
        }
  TIO.writeFile path (Toml.encode fileConfigCodec updated)
