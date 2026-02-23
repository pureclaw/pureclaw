module PureClaw.Core.Config
  ( -- * Serializable config (safe to write to disk)
    Config (..)
    -- * Runtime config (constructor NOT exported — contains secrets)
  , RuntimeConfig
  , mkRuntimeConfig
    -- * RuntimeConfig field accessors
  , rtConfig
  , rtApiKey
  , rtSecretKey
  ) where

import PureClaw.Core.Types
import PureClaw.Security.Secrets

-- | Serializable configuration — safe to write to disk.
-- Contains no secrets. All fields are safe to show, compare, and serialize.
data Config = Config
  { _cfg_provider     :: ProviderId
  , _cfg_model        :: ModelId
  , _cfg_gatewayPort  :: Port
  , _cfg_workspace    :: FilePath
  , _cfg_autonomy     :: AutonomyLevel
  , _cfg_allowedCmds  :: AllowList CommandName
  , _cfg_allowedUsers :: AllowList UserId
  }
  deriving stock (Show, Eq)

-- | Runtime configuration — NOT serializable.
-- Contains secrets that must never be written to disk.
-- Constructor is intentionally NOT exported — use 'mkRuntimeConfig'.
--
-- No 'ToJSON', 'FromJSON', or 'ToTOML' instances exist. Attempting to
-- derive them would be a compile error because 'ApiKey' and 'SecretKey'
-- have no serialization instances.
data RuntimeConfig = RuntimeConfig
  { _rc_config    :: Config
  , _rc_apiKey    :: ApiKey
  , _rc_secretKey :: SecretKey
  }

instance Show RuntimeConfig where
  show rc = "RuntimeConfig { config = " ++ show (_rc_config rc)
         ++ ", apiKey = " ++ show (_rc_apiKey rc)
         ++ ", secretKey = " ++ show (_rc_secretKey rc)
         ++ " }"

-- | Construct a 'RuntimeConfig' from a 'Config' and secrets.
mkRuntimeConfig :: Config -> ApiKey -> SecretKey -> RuntimeConfig
mkRuntimeConfig = RuntimeConfig

-- | Access the serializable config portion.
rtConfig :: RuntimeConfig -> Config
rtConfig = _rc_config

-- | Access the API key.
rtApiKey :: RuntimeConfig -> ApiKey
rtApiKey = _rc_apiKey

-- | Access the secret key.
rtSecretKey :: RuntimeConfig -> SecretKey
rtSecretKey = _rc_secretKey
