module Support.AgentEnv
  ( mkTestAgentEnv
  ) where

import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map

import PureClaw.Agent.Env
import PureClaw.Handles.Channel (mkNoOpChannelHandle)
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy (defaultPolicy)
import PureClaw.Security.Vault.Plugin (mkPluginHandle)
import PureClaw.Session.Handle (mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Tools.Registry (emptyRegistry)

-- | Build a complete, usable test 'AgentEnv' with sane no-op defaults.
--
-- Every field is populated with a working value (no @error@ stubs), so any
-- test can do @env <- mkTestAgentEnv@ and override individual fields via
-- record update. Provider, model, and vault start as 'Nothing'; the channel
-- and logger are no-ops; registries\/maps are empty; the tab subsystem is a
-- freshly-allocated empty bundle from 'newTabSubsystem'; the harness registry
-- is a real (empty) 'Registry.HarnessRegistry'; the session is a no-op handle.
mkTestAgentEnv :: IO AgentEnv
mkTestAgentEnv = do
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  vaultRef     <- newIORef Nothing
  harnessRef   <- newIORef Map.empty
  harnessReg   <- Registry.newRegistry
  targetRef    <- newIORef TargetProvider
  windowIdxRef <- newIORef 0
  sessionRef   <- newIORef =<< mkNoOpSessionHandle
  mcpRef       <- newIORef Map.empty
  let routing = defaultRoutingConfig
  ts <- newTabSubsystem (_rc_channelOutQBound routing)
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = mkNoOpChannelHandle
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
    , _env_harnesses         = harnessRef
    , _env_harnessRegistry   = harnessReg
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_routingConfig     = routing
    , _env_fork              = defaultEnvFork
    , _env_broker            = Nothing
    , _env_tabRegistry       = _ts_tabRegistry ts
    , _env_cursors           = _ts_cursors ts
    , _env_exec              = _ts_exec ts
    , _env_relayWriter       = _ts_relayWriter ts
    , _env_sinks             = _ts_sinks ts
    , _env_wizard            = _ts_wizard ts
    , _env_tabOutQ           = _ts_tabOutQ ts
    , _env_onTabsChanged     = _ts_onTabsChanged ts
    , _env_startHarness      = noStartHarness
    , _env_runTabCommand     = noRunTabCommand
    }
