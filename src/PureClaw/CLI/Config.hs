module PureClaw.CLI.Config
  ( -- * File config
    FileConfig (..)
  , emptyFileConfig
    -- * Loading
  , loadFileConfig
  , loadConfig
  ) where

import Control.Exception
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (getHomeDirectory)
import Toml (TomlCodec, (.=))
import Toml qualified

-- | Configuration that can be read from a TOML file.
-- All fields are optional — missing fields default to Nothing.
data FileConfig = FileConfig
  { _fc_apiKey   :: Maybe Text
  , _fc_model    :: Maybe Text
  , _fc_provider :: Maybe Text
  , _fc_system   :: Maybe Text
  , _fc_memory   :: Maybe Text
  , _fc_allow    :: Maybe [Text]
  } deriving stock (Show, Eq)

emptyFileConfig :: FileConfig
emptyFileConfig = FileConfig Nothing Nothing Nothing Nothing Nothing Nothing

fileConfigCodec :: TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "api_key")                   .= _fc_apiKey
  <*> Toml.dioptional (Toml.text "model")                     .= _fc_model
  <*> Toml.dioptional (Toml.text "provider")                  .= _fc_provider
  <*> Toml.dioptional (Toml.text "system")                    .= _fc_system
  <*> Toml.dioptional (Toml.text "memory")                    .= _fc_memory
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "allow")       .= _fc_allow

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

-- | Load config from the default locations, trying each in order:
--
-- 1. @.pureclaw\/config.toml@ (project-local)
-- 2. @~\/.config\/pureclaw\/config.toml@ (user-global XDG)
--
-- Returns the first config found, or 'emptyFileConfig' if none exists.
loadConfig :: IO FileConfig
loadConfig = do
  projectCfg <- loadFileConfig ".pureclaw/config.toml"
  if projectCfg /= emptyFileConfig
    then pure projectCfg
    else do
      home <- try @IOError getHomeDirectory
      case home of
        Left  _    -> pure emptyFileConfig
        Right h    -> loadFileConfig (h ++ "/.config/pureclaw/config.toml")
