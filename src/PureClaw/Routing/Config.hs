-- |
-- Module      : PureClaw.Routing.Config
-- Description : TOML loader for 'RoutingConfig' (Tabbed Chat WU3).
--
-- Reads the @[routing]@ section of @~\/.pureclaw\/config.toml@ and
-- projects it onto a 'RoutingConfig'. Missing keys fall back to the
-- field values in 'defaultRoutingConfig'.
--
-- == Scope of WU3
--
--   * 'defaultRoutingConfig' — the source-of-truth defaults; re-used by
--     tests so the field values are not duplicated.
--   * 'loadRoutingConfig' — best-effort TOML loader. Mirrors the
--     forgiving semantics of 'PureClaw.CLI.Config.loadFileConfig':
--     unreadable file or unparseable TOML silently falls back to
--     'defaultRoutingConfig' rather than crashing process start.
--   * 'loadRoutingConfigFromFile' — same as 'loadRoutingConfig' but
--     takes an explicit path (so tests can point at a fixture file
--     without depending on @\$HOME@).
--   * 'routingConfigCodec' — exported for tests of round-tripping
--     behaviour and for a future diagnostic loader.
--
-- See @docs\/tabbed-chat.md@ §\"RoutingConfig\" for the per-field
-- semantics.
module PureClaw.Routing.Config
  ( -- * Defaults
    defaultRoutingConfig
    -- * Loaders
  , loadRoutingConfig
  , loadRoutingConfigFromFile
    -- * Codec
  , routingConfigCodec
  ) where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.FilePath ((</>))
import Toml (TomlCodec, (.=))
import Toml qualified

import PureClaw.Core.Types
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Routing.Types


-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

-- | Default 'AiDefaults' applied when @[routing.default_ai]@ is absent.
--
-- The provider \/ model pair is intentionally generic — the live
-- ProviderId\/ModelId for production deployments comes from
-- 'PureClaw.CLI.Config.FileConfig' and is layered over this baseline
-- when an AI tab spawns (the layering lands in WU6).
defaultAiDefaults :: AiDefaults
defaultAiDefaults = AiDefaults
  { _aid_providerId = ProviderId "anthropic"
  , _aid_modelId    = ModelId "claude-sonnet-4-5"
  }

-- | Default 'ShellDefaults' applied when @[routing.default_shell]@ is
-- absent.
defaultShellDefaults :: ShellDefaults
defaultShellDefaults = ShellDefaults
  { _sd_command = "bash"
  }

-- | The default 'RoutingConfig' used when no on-disk config is found
-- (or when on-disk fields are missing). Field values match the
-- per-field documentation in 'RoutingConfig' and the design doc's
-- RoutingConfig section.
defaultRoutingConfig :: RoutingConfig
defaultRoutingConfig = RoutingConfig
  { _rc_defaultKind         = Tab.KindAi
  , _rc_defaultAi           = defaultAiDefaults
  , _rc_defaultShell        = defaultShellDefaults
  , _rc_switchRecap         = 3
  , _rc_maxTabs             = 36
  , _rc_inputQueueBound     = 64
  , _rc_channelOutQBound    = 1024
  , _rc_spawnRateLimit      = 10
  , _rc_maxConcurrentActive = 4
  , _rc_maxNameLen          = 32
  , _rc_sshIdentityKey      = "default-ssh-key"
  }


-- ---------------------------------------------------------------------------
-- Partial-config + overlay (the missing-keys-fall-back-to-default trick)
-- ---------------------------------------------------------------------------

-- | A partial 'RoutingConfig' with every field optional. The TOML
-- codec produces this; 'overlayRoutingConfig' folds it onto
-- 'defaultRoutingConfig' so missing keys simply fall through.
data PartialRoutingConfig = PartialRoutingConfig
  { _prc_defaultKind         :: !(Maybe Tab.TabKind)
  , _prc_defaultAi           :: !(Maybe AiDefaults)
  , _prc_defaultShell        :: !(Maybe ShellDefaults)
  , _prc_switchRecap         :: !(Maybe Int)
  , _prc_maxTabs             :: !(Maybe Int)
  , _prc_inputQueueBound     :: !(Maybe Int)
  , _prc_channelOutQBound    :: !(Maybe Int)
  , _prc_spawnRateLimit      :: !(Maybe Int)
  , _prc_maxConcurrentActive :: !(Maybe Int)
  , _prc_maxNameLen          :: !(Maybe Int)
  , _prc_sshIdentityKey      :: !(Maybe Text)
  }

-- | Fold a partial config onto the defaults.
overlayRoutingConfig :: PartialRoutingConfig -> RoutingConfig
overlayRoutingConfig p = RoutingConfig
  { _rc_defaultKind         = pick _rc_defaultKind         _prc_defaultKind
  , _rc_defaultAi           = pick _rc_defaultAi           _prc_defaultAi
  , _rc_defaultShell        = pick _rc_defaultShell        _prc_defaultShell
  , _rc_switchRecap         = pick _rc_switchRecap         _prc_switchRecap
  , _rc_maxTabs             = pick _rc_maxTabs             _prc_maxTabs
  , _rc_inputQueueBound     = pick _rc_inputQueueBound     _prc_inputQueueBound
  , _rc_channelOutQBound    = pick _rc_channelOutQBound    _prc_channelOutQBound
  , _rc_spawnRateLimit      = pick _rc_spawnRateLimit      _prc_spawnRateLimit
  , _rc_maxConcurrentActive = pick _rc_maxConcurrentActive _prc_maxConcurrentActive
  , _rc_maxNameLen          = pick _rc_maxNameLen          _prc_maxNameLen
  , _rc_sshIdentityKey      = pick _rc_sshIdentityKey      _prc_sshIdentityKey
  }
  where
    pick :: (RoutingConfig -> a) -> (PartialRoutingConfig -> Maybe a) -> a
    pick getDef getMb = case getMb p of
      Just v  -> v
      Nothing -> getDef defaultRoutingConfig


-- ---------------------------------------------------------------------------
-- Codecs
-- ---------------------------------------------------------------------------

-- | TOML codec for a 'TabKind' encoded as a snake_case string. Used
-- for the @default_kind@ field.
tabKindCodec :: Toml.Key -> TomlCodec Tab.TabKind
tabKindCodec = Toml.textBy showKind parseKind
  where
    showKind :: Tab.TabKind -> Text
    showKind k = case k of
      Tab.KindAi      -> "ai"
      Tab.KindHarness -> "harness"
      Tab.KindShell   -> "shell"
      Tab.KindSsh     -> "ssh"
      Tab.KindTmux    -> "tmux"

    parseKind :: Text -> Either Text Tab.TabKind
    parseKind t = case t of
      "ai"      -> Right Tab.KindAi
      "harness" -> Right Tab.KindHarness
      "shell"   -> Right Tab.KindShell
      "ssh"     -> Right Tab.KindSsh
      "tmux"    -> Right Tab.KindTmux
      _         -> Left ("Unknown tab kind: " <> t)

-- | TOML codec for 'AiDefaults' (the @[default_ai]@ sub-table inside
-- the @[routing]@ section).
aiDefaultsCodec :: TomlCodec AiDefaults
aiDefaultsCodec = AiDefaults
  <$> Toml.diwrap (Toml.text "provider") .= _aid_providerId
  <*> Toml.diwrap (Toml.text "model")    .= _aid_modelId

-- | TOML codec for 'ShellDefaults' (the @[default_shell]@ sub-table).
shellDefaultsCodec :: TomlCodec ShellDefaults
shellDefaultsCodec = ShellDefaults
  <$> Toml.text "command" .= _sd_command

-- | TOML codec for a 'PartialRoutingConfig'. Used internally by
-- 'loadRoutingConfigFromFile'.
partialRoutingCodec :: TomlCodec PartialRoutingConfig
partialRoutingCodec = PartialRoutingConfig
  <$> Toml.dioptional (tabKindCodec "default_kind")                   .= _prc_defaultKind
  <*> Toml.dioptional (Toml.table aiDefaultsCodec "default_ai")       .= _prc_defaultAi
  <*> Toml.dioptional (Toml.table shellDefaultsCodec "default_shell") .= _prc_defaultShell
  <*> Toml.dioptional (Toml.int  "switch_recap")                      .= _prc_switchRecap
  <*> Toml.dioptional (Toml.int  "max_tabs")                          .= _prc_maxTabs
  <*> Toml.dioptional (Toml.int  "input_queue_bound")                 .= _prc_inputQueueBound
  <*> Toml.dioptional (Toml.int  "channel_out_q_bound")               .= _prc_channelOutQBound
  <*> Toml.dioptional (Toml.int  "spawn_rate_limit")                  .= _prc_spawnRateLimit
  <*> Toml.dioptional (Toml.int  "max_concurrent_active")             .= _prc_maxConcurrentActive
  <*> Toml.dioptional (Toml.int  "max_name_len")                      .= _prc_maxNameLen
  <*> Toml.dioptional (Toml.text "ssh_identity_key")                  .= _prc_sshIdentityKey

-- | Bidirectional TOML codec for the full 'RoutingConfig'.
--
-- The wrapping 'Toml.table' (@[routing]@) is added by the loader, not
-- here, so this codec works both as a top-level codec (for fixtures
-- that omit the @[routing]@ wrapper) and inside 'Toml.table' (for
-- production @config.toml@ files).
--
-- Implemented as a 'Toml.dimap' over 'partialRoutingCodec': decoding
-- folds onto the defaults via 'overlayRoutingConfig'; encoding lifts
-- every concrete field to 'Just' (round-tripping the full snapshot).
routingConfigCodec :: TomlCodec RoutingConfig
routingConfigCodec = Toml.dimap toPartial overlayRoutingConfig partialRoutingCodec
  where
    toPartial :: RoutingConfig -> PartialRoutingConfig
    toPartial rc = PartialRoutingConfig
      { _prc_defaultKind         = Just (_rc_defaultKind rc)
      , _prc_defaultAi           = Just (_rc_defaultAi rc)
      , _prc_defaultShell        = Just (_rc_defaultShell rc)
      , _prc_switchRecap         = Just (_rc_switchRecap rc)
      , _prc_maxTabs             = Just (_rc_maxTabs rc)
      , _prc_inputQueueBound     = Just (_rc_inputQueueBound rc)
      , _prc_channelOutQBound    = Just (_rc_channelOutQBound rc)
      , _prc_spawnRateLimit      = Just (_rc_spawnRateLimit rc)
      , _prc_maxConcurrentActive = Just (_rc_maxConcurrentActive rc)
      , _prc_maxNameLen          = Just (_rc_maxNameLen rc)
      , _prc_sshIdentityKey      = Just (_rc_sshIdentityKey rc)
      }


-- ---------------------------------------------------------------------------
-- Loaders
-- ---------------------------------------------------------------------------

-- | Load a 'RoutingConfig' from a single TOML file.
--
-- Best-effort: the file may not exist (in which case
-- 'defaultRoutingConfig' is returned), or it may exist but fail to
-- parse (same fallback). The expected layout is a @[routing]@ table at
-- the top of the file, but a @[routing]@-less document (keys at top
-- level) is also accepted to keep fixture files small.
loadRoutingConfigFromFile :: FilePath -> IO RoutingConfig
loadRoutingConfigFromFile path = do
  text <- try @IOError (TIO.readFile path)
  pure $ case text of
    Left  _    -> defaultRoutingConfig
    Right toml ->
      case Toml.decode (Toml.table partialRoutingCodec "routing") toml of
        Right p -> overlayRoutingConfig p
        Left _  ->
          -- Fall back to a top-level @routing@-less document.
          case Toml.decode partialRoutingCodec toml of
            Right p -> overlayRoutingConfig p
            Left _  -> defaultRoutingConfig

-- | Load a 'RoutingConfig' from the standard PureClaw config location
-- (@\<pureclawDir\>\/config.toml@). Returns 'defaultRoutingConfig' if
-- the file is missing or unparseable.
loadRoutingConfig :: FilePath -> IO RoutingConfig
loadRoutingConfig pureclawDir =
  loadRoutingConfigFromFile (pureclawDir </> "config.toml")
