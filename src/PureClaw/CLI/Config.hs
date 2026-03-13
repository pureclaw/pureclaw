module PureClaw.CLI.Config
  ( -- * Model providers
    ModelProvider (..)
  , AnthropicProviderConfig (..)
  , AnthropicAuth (..)
  , OpenAIProviderConfig (..)
  , OpenRouterProviderConfig (..)
  , OllamaProviderConfig (..)
  , ProviderType (..)
  , providerType
    -- * File config
  , FileConfig (..)
  , emptyFileConfig
    -- * Loading
  , loadFileConfig
  , loadConfig
    -- * Directory helpers
  , getPureclawDir
  ) where

import Control.Exception
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import Toml (TomlCodec, (.=))
import Toml qualified

-- ---------------------------------------------------------------------------
-- Provider types
-- ---------------------------------------------------------------------------

-- | Supported LLM provider types.
data ProviderType
  = PTAnthropic
  | PTOpenAI
  | PTOpenRouter
  | PTOllama
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | A configured model provider. The constructor determines the provider type;
-- each variant carries only the config relevant to that provider.
-- Sensitive credentials (API keys, tokens) are NEVER stored here — they live
-- in the vault.
data ModelProvider
  = AnthropicProvider AnthropicProviderConfig
  | OpenAIProvider OpenAIProviderConfig
  | OpenRouterProvider OpenRouterProviderConfig
  | OllamaProvider OllamaProviderConfig
  deriving stock (Show, Eq)

-- | Extract the provider type tag from a 'ModelProvider'.
providerType :: ModelProvider -> ProviderType
providerType (AnthropicProvider _)  = PTAnthropic
providerType (OpenAIProvider _)     = PTOpenAI
providerType (OpenRouterProvider _) = PTOpenRouter
providerType (OllamaProvider _)     = PTOllama

-- | Anthropic-specific configuration.
data AnthropicProviderConfig = AnthropicProviderConfig
  { _apc_auth :: AnthropicAuth
  } deriving stock (Show, Eq)

-- | How to authenticate with Anthropic.
data AnthropicAuth
  = AuthApiKey   -- ^ API key stored in the vault (default)
  | AuthOAuth    -- ^ OAuth 2.0 PKCE flow; tokens cached in vault
  deriving stock (Show, Eq)

-- | OpenAI-specific configuration.
data OpenAIProviderConfig = OpenAIProviderConfig
  { _oaipc_baseUrl :: Maybe Text  -- ^ Custom API endpoint (e.g. Azure OpenAI)
  } deriving stock (Show, Eq)

-- | OpenRouter-specific configuration.
data OpenRouterProviderConfig = OpenRouterProviderConfig
  deriving stock (Show, Eq)

-- | Ollama-specific configuration.
data OllamaProviderConfig = OllamaProviderConfig
  { _olpc_baseUrl :: Maybe Text  -- ^ Custom endpoint (default: http://localhost:11434)
  } deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Raw provider entry (internal — for TOML parsing)
-- ---------------------------------------------------------------------------

-- | Flat representation of a @[[providers]]@ entry for TOML codec.
-- Converted to 'ModelProvider' after decoding.
data RawProviderEntry = RawProviderEntry
  { _rpe_provider :: Text
  , _rpe_auth     :: Maybe Text
  , _rpe_baseUrl  :: Maybe Text
  } deriving stock (Show, Eq)

rawProviderCodec :: TomlCodec RawProviderEntry
rawProviderCodec = RawProviderEntry
  <$> Toml.text "provider"                      .= _rpe_provider
  <*> Toml.dioptional (Toml.text "auth")         .= _rpe_auth
  <*> Toml.dioptional (Toml.text "base_url")     .= _rpe_baseUrl

-- | Convert a raw TOML entry to a typed 'ModelProvider'.
-- Returns 'Nothing' for unrecognised provider names.
rawToProvider :: RawProviderEntry -> Maybe ModelProvider
rawToProvider raw = case T.toLower (_rpe_provider raw) of
  "anthropic" -> Just $ AnthropicProvider $ AnthropicProviderConfig auth
    where auth = case _rpe_auth raw of
            Just "oauth" -> AuthOAuth
            _            -> AuthApiKey
  "openai" -> Just $ OpenAIProvider $ OpenAIProviderConfig
    { _oaipc_baseUrl = _rpe_baseUrl raw }
  "openrouter" -> Just $ OpenRouterProvider OpenRouterProviderConfig
  "ollama" -> Just $ OllamaProvider $ OllamaProviderConfig
    { _olpc_baseUrl = _rpe_baseUrl raw }
  _ -> Nothing

-- | Convert a typed 'ModelProvider' back to a raw entry (for TOML encoding).
providerToRaw :: ModelProvider -> RawProviderEntry
providerToRaw (AnthropicProvider cfg) = RawProviderEntry
  { _rpe_provider = "anthropic"
  , _rpe_auth     = case _apc_auth cfg of
      AuthApiKey -> Nothing
      AuthOAuth  -> Just "oauth"
  , _rpe_baseUrl  = Nothing
  }
providerToRaw (OpenAIProvider cfg) = RawProviderEntry
  { _rpe_provider = "openai"
  , _rpe_auth     = Nothing
  , _rpe_baseUrl  = _oaipc_baseUrl cfg
  }
providerToRaw (OpenRouterProvider _) = RawProviderEntry
  { _rpe_provider = "openrouter"
  , _rpe_auth     = Nothing
  , _rpe_baseUrl  = Nothing
  }
providerToRaw (OllamaProvider cfg) = RawProviderEntry
  { _rpe_provider = "ollama"
  , _rpe_auth     = Nothing
  , _rpe_baseUrl  = _olpc_baseUrl cfg
  }

-- ---------------------------------------------------------------------------
-- File config
-- ---------------------------------------------------------------------------

-- | Configuration that can be read from a TOML file.
-- All fields are optional — missing fields use sensible defaults.
-- Sensitive credentials (API keys) are NEVER stored here; use the vault.
--
-- Providers are declared in a @[[providers]]@ array of tables:
--
-- > [[providers]]
-- > provider = "anthropic"
-- > auth = "oauth"
-- >
-- > [[providers]]
-- > provider = "ollama"
-- > base_url = "http://gpu-server:11434"
data FileConfig = FileConfig
  { _fc_model           :: Maybe Text    -- ^ default model (supports "provider:model" syntax)
  , _fc_system          :: Maybe Text
  , _fc_memory          :: Maybe Text
  , _fc_allow           :: Maybe [Text]
  , _fc_vault_path      :: Maybe Text    -- ^ vault file path (default: ~/.pureclaw/vault.age)
  , _fc_vault_recipient :: Maybe Text    -- ^ age recipient string
  , _fc_vault_identity  :: Maybe Text    -- ^ age identity path or plugin string
  , _fc_vault_unlock    :: Maybe Text    -- ^ "startup", "on_demand", or "per_access"
  , _fc_providers       :: [ModelProvider]
  } deriving stock (Show, Eq)

emptyFileConfig :: FileConfig
emptyFileConfig =
  FileConfig Nothing Nothing Nothing Nothing
             Nothing Nothing Nothing Nothing
             []

fileConfigCodec :: TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "model")                     .= _fc_model
  <*> Toml.dioptional (Toml.text "system")                    .= _fc_system
  <*> Toml.dioptional (Toml.text "memory")                    .= _fc_memory
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow")       .= _fc_allow
  <*> Toml.dioptional (Toml.text "vault_path")                .= _fc_vault_path
  <*> Toml.dioptional (Toml.text "vault_recipient")           .= _fc_vault_recipient
  <*> Toml.dioptional (Toml.text "vault_identity")            .= _fc_vault_identity
  <*> Toml.dioptional (Toml.text "vault_unlock")              .= _fc_vault_unlock
  <*> Toml.dimap (map providerToRaw) (mapMaybe rawToProvider)
        (Toml.list rawProviderCodec "providers")               .= _fc_providers

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
