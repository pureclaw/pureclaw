module PureClaw.CLI.Config
  ( -- * File config
    FileConfig (..)
  , emptyFileConfig
    -- * Loading
  , loadFileConfig
  , loadConfig
    -- * Writing
  , FieldUpdate (..)
  , updateVaultConfig
    -- * Directory helpers
  , getPureclawDir
  ) where

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
loadConfig = do
  home <- try @IOError getHomeDirectory
  case home of
    Left  _ -> pure emptyFileConfig
    Right h -> do
      homeCfg <- loadFileConfig (h </> ".pureclaw" </> "config.toml")
      if homeCfg /= emptyFileConfig
        then pure homeCfg
        else loadFileConfig (h </> ".config" </> "pureclaw" </> "config.toml")

-- | Three-valued update: set a new value, clear the field, or keep the existing value.
data FieldUpdate a
  = Set a    -- ^ Replace with this value
  | Clear    -- ^ Remove the field (set to Nothing)
  | Keep     -- ^ Leave the existing value unchanged
  deriving stock (Show, Eq)

-- | Apply a 'FieldUpdate' to an existing 'Maybe' value.
applyUpdate :: FieldUpdate a -> Maybe a -> Maybe a
applyUpdate (Set x) _ = Just x
applyUpdate Clear   _ = Nothing
applyUpdate Keep    v = v

-- | Update vault-related fields in a config file, preserving all other settings.
-- 'Keep' means "leave this field unchanged", 'Clear' means "remove the field",
-- 'Set' means "replace with this value".
-- If all four arguments are 'Keep', this is a no-op (no file write occurs).
updateVaultConfig
  :: FilePath             -- ^ Config file path
  -> FieldUpdate Text     -- ^ vault_path
  -> FieldUpdate Text     -- ^ vault_recipient
  -> FieldUpdate Text     -- ^ vault_identity
  -> FieldUpdate Text     -- ^ vault_unlock
  -> IO ()
updateVaultConfig _ Keep Keep Keep Keep = pure ()
updateVaultConfig path vaultPath vaultRecipient vaultIdentity vaultUnlock = do
  existing <- loadFileConfig path
  let updated = existing
        { _fc_vault_path      = applyUpdate vaultPath      (_fc_vault_path existing)
        , _fc_vault_recipient = applyUpdate vaultRecipient  (_fc_vault_recipient existing)
        , _fc_vault_identity  = applyUpdate vaultIdentity   (_fc_vault_identity existing)
        , _fc_vault_unlock    = applyUpdate vaultUnlock     (_fc_vault_unlock existing)
        }
  TIO.writeFile path (Toml.encode fileConfigCodec updated)
