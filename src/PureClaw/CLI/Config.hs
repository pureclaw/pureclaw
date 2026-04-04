module PureClaw.CLI.Config
  ( -- * File config
    FileConfig (..)
  , FileSignalConfig (..)
  , FileTelegramConfig (..)
  , emptyFileConfig
  , emptyFileSignalConfig
  , emptyFileTelegramConfig
    -- * Loading
  , loadFileConfig
  , loadConfig
    -- * Diagnostic loading
  , ConfigLoadResult (..)
  , loadFileConfigDiag
  , loadConfigDiag
  , configFileConfig
    -- * Writing
  , writeFileConfig
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
  , _fc_autonomy       :: Maybe Text  -- ^ "full", "supervised", or "deny"
  , _fc_defaultChannel :: Maybe Text  -- ^ "cli", "signal", or "telegram"
  , _fc_signal         :: Maybe FileSignalConfig    -- ^ [signal] TOML table
  , _fc_telegram       :: Maybe FileTelegramConfig  -- ^ [telegram] TOML table
  , _fc_reasoningEffort :: Maybe Text  -- ^ "high", "medium", or "low"
  , _fc_maxTurns       :: Maybe Int    -- ^ Maximum tool-call iterations per turn
  , _fc_timezone       :: Maybe Text   -- ^ IANA timezone (e.g. "America/New_York")
  , _fc_baseUrl          :: Maybe Text  -- ^ Provider base URL override (e.g. Ollama endpoint)
  , _fc_vault_path      :: Maybe Text  -- ^ vault file path (default: ~/.pureclaw/vault.age)
  , _fc_vault_recipient :: Maybe Text  -- ^ age recipient string (required to enable vault)
  , _fc_vault_identity  :: Maybe Text  -- ^ age identity path or plugin string
  , _fc_vault_unlock    :: Maybe Text  -- ^ "startup", "on_demand", or "per_access"
  } deriving stock (Show, Eq)

-- | Signal channel configuration from the @[signal]@ TOML table.
data FileSignalConfig = FileSignalConfig
  { _fsc_account        :: Maybe Text    -- ^ E.164 phone number
  , _fsc_dmPolicy       :: Maybe Text    -- ^ "pairing", "allowlist", "open", "disabled"
  , _fsc_allowFrom      :: Maybe [Text]  -- ^ E.164 numbers or UUIDs
  , _fsc_textChunkLimit :: Maybe Int     -- ^ Max chars per message (default: 6000)
  } deriving stock (Show, Eq)

emptyFileConfig :: FileConfig
emptyFileConfig =
  FileConfig Nothing Nothing Nothing Nothing Nothing Nothing
             Nothing Nothing Nothing Nothing Nothing Nothing Nothing
             Nothing Nothing Nothing Nothing Nothing

emptyFileSignalConfig :: FileSignalConfig
emptyFileSignalConfig = FileSignalConfig Nothing Nothing Nothing Nothing

-- | Telegram channel configuration from the @[telegram]@ TOML table.
data FileTelegramConfig = FileTelegramConfig
  { _ftc_botToken  :: Maybe Text    -- ^ Bot API token
  , _ftc_dmPolicy  :: Maybe Text    -- ^ "pairing", "allowlist", "open", "disabled"
  , _ftc_allowFrom :: Maybe [Text]  -- ^ Allowed usernames or IDs
  } deriving stock (Show, Eq)

emptyFileTelegramConfig :: FileTelegramConfig
emptyFileTelegramConfig = FileTelegramConfig Nothing Nothing Nothing

fileConfigCodec :: TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "api_key")                   .= _fc_apiKey
  <*> Toml.dioptional (Toml.text "model")                     .= _fc_model
  <*> Toml.dioptional (Toml.text "provider")                  .= _fc_provider
  <*> Toml.dioptional (Toml.text "system")                    .= _fc_system
  <*> Toml.dioptional (Toml.text "memory")                    .= _fc_memory
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow")       .= _fc_allow
  <*> Toml.dioptional (Toml.text "autonomy")                  .= _fc_autonomy
  <*> Toml.dioptional (Toml.text "default_channel")           .= _fc_defaultChannel
  <*> Toml.dioptional (Toml.table fileSignalConfigCodec "signal") .= _fc_signal
  <*> Toml.dioptional (Toml.table fileTelegramConfigCodec "telegram") .= _fc_telegram
  <*> Toml.dioptional (Toml.text "reasoning_effort")           .= _fc_reasoningEffort
  <*> Toml.dioptional (Toml.int "max_turns")                   .= _fc_maxTurns
  <*> Toml.dioptional (Toml.text "timezone")                   .= _fc_timezone
  <*> Toml.dioptional (Toml.text "base_url")                  .= _fc_baseUrl
  <*> Toml.dioptional (Toml.text "vault_path")                .= _fc_vault_path
  <*> Toml.dioptional (Toml.text "vault_recipient")           .= _fc_vault_recipient
  <*> Toml.dioptional (Toml.text "vault_identity")            .= _fc_vault_identity
  <*> Toml.dioptional (Toml.text "vault_unlock")              .= _fc_vault_unlock

fileSignalConfigCodec :: TomlCodec FileSignalConfig
fileSignalConfigCodec = FileSignalConfig
  <$> Toml.dioptional (Toml.text "account")                   .= _fsc_account
  <*> Toml.dioptional (Toml.text "dm_policy")                 .= _fsc_dmPolicy
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow_from")  .= _fsc_allowFrom
  <*> Toml.dioptional (Toml.int "text_chunk_limit")           .= _fsc_textChunkLimit

fileTelegramConfigCodec :: TomlCodec FileTelegramConfig
fileTelegramConfigCodec = FileTelegramConfig
  <$> Toml.dioptional (Toml.text "bot_token")                 .= _ftc_botToken
  <*> Toml.dioptional (Toml.text "dm_policy")                 .= _ftc_dmPolicy
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow_from")  .= _ftc_allowFrom

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

-- | Write a complete 'FileConfig' to a TOML file.
-- Overwrites the file entirely. Creates the file if it does not exist.
writeFileConfig :: FilePath -> FileConfig -> IO ()
writeFileConfig path cfg = TIO.writeFile path (Toml.encode fileConfigCodec cfg)

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
