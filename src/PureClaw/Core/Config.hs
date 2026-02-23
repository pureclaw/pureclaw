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
  ( AllowList
  , AutonomyLevel
  , CommandName
  , ModelId
  , Port
  , ProviderId
  , UserId
  )
import PureClaw.Security.Secrets (ApiKey, SecretKey)

-- | Serializable configuration — safe to write to disk.
-- Contains no secrets. All fields are safe to show, compare, and serialize.
data Config = Config
  { cfgProvider     :: ProviderId
  , cfgModel        :: ModelId
  , cfgGatewayPort  :: Port
  , cfgWorkspace    :: FilePath
  , cfgAutonomy     :: AutonomyLevel
  , cfgAllowedCmds  :: AllowList CommandName
  , cfgAllowedUsers :: AllowList UserId
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
  { _rtConfig    :: Config
  , _rtApiKey    :: ApiKey
  , _rtSecretKey :: SecretKey
  }

instance Show RuntimeConfig where
  show rc = "RuntimeConfig { config = " ++ show (_rtConfig rc)
         ++ ", apiKey = " ++ show (_rtApiKey rc)
         ++ ", secretKey = " ++ show (_rtSecretKey rc)
         ++ " }"

-- | Construct a 'RuntimeConfig' from a 'Config' and secrets.
mkRuntimeConfig :: Config -> ApiKey -> SecretKey -> RuntimeConfig
mkRuntimeConfig = RuntimeConfig

-- | Access the serializable config portion.
rtConfig :: RuntimeConfig -> Config
rtConfig = _rtConfig

-- | Access the API key.
rtApiKey :: RuntimeConfig -> ApiKey
rtApiKey = _rtApiKey

-- | Access the secret key.
rtSecretKey :: RuntimeConfig -> SecretKey
rtSecretKey = _rtSecretKey
