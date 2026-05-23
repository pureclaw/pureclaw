module Tools.DelegateSpec (spec) where

import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Data.Aeson
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.Text qualified as T
import Test.Hspec

import Data.Map.Strict qualified as Map

import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle
import PureClaw.Tools.Delegate
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "delegateTaskTool" $ do
    it "has the correct tool name" $ do
      env <- mkTestEnv Nothing
      let (def', _) = delegateTaskTool env
      _td_name def' `shouldBe` "delegate_task"

    it "returns error when no provider configured" $ do
      env <- mkTestEnv Nothing
      let (_, handler) = delegateTaskTool env
          input = object ["goal" .= ("do something" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "no provider"

    it "runs sub-agent with mock provider and returns result" $ do
      let mockProvider = MkProvider MockProvider
      env <- mkTestEnv (Just mockProvider)
      let (_, handler) = delegateTaskTool env
          input = object ["goal" .= ("say hello" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      -- MockProvider returns "Mock response" for every request
      T.unpack output `shouldContain` "Mock response"

    it "rejects invalid JSON input" $ do
      env <- mkTestEnv Nothing
      let (_, handler) = delegateTaskTool env
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

-- | Minimal mock provider that returns a text response with no tool calls.
data MockProvider = MockProvider

instance Provider MockProvider where
  complete _ _req = pure CompletionResponse
    { _crsp_content = [TextBlock "Mock response"]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

-- | Build a minimal test AgentEnv for delegate_task testing.
mkTestEnv :: Maybe SomeProvider -> IO AgentEnv
mkTestEnv mProvider = do
  providerRef <- newIORef mProvider
  modelRef    <- newIORef (Just (ModelId "mock-model"))
  vaultRef    <- newIORef Nothing
  harnessRef  <- newIORef Map.empty
  targetRef   <- newIORef TargetProvider
  windowIdxRef <- newIORef 0
  noOpSession <- mkNoOpSessionHandle
  sessionRef  <- newIORef noOpSession
  onFirstRef  <- newIORef Nothing
  mcpRef      <- newIORef Map.empty
  -- WU3 (Tabbed Chat #51) defaults
  tabsRef       <- newIORef IntMap.empty
  focusRef      <- newIORef Nothing
  activeCountTv <- newTVarIO 0
  runnersRef    <- newIORef IntMap.empty
  let routing = defaultRoutingConfig
  channelOutQ   <- newTBQueueIO (fromIntegral (_rc_channelOutQBound routing))
  pure AgentEnv
    { _env_provider         = providerRef
    , _env_model            = modelRef
    , _env_channel          = mkNoOpChannelHandle
    , _env_logger           = mkNoOpLogHandle
    , _env_systemPrompt     = Nothing
    , _env_registry         = emptyRegistry
    , _env_vault            = vaultRef
    , _env_pluginHandle     = mkPluginHandle
    , _env_policy           = defaultPolicy
    , _env_harnesses        = harnessRef
    , _env_target           = targetRef
    , _env_nextWindowIdx    = windowIdxRef
    , _env_agentDef         = Nothing
    , _env_session          = sessionRef
    , _env_onFirstStreamDone = onFirstRef
    , _env_mcpServers       = mcpRef
    , _env_tabs             = tabsRef
    , _env_focus            = focusRef
    , _env_activeCount      = activeCountTv
    , _env_runners          = runnersRef
    , _env_channelOutQ      = channelOutQ
    , _env_routingConfig    = routing
    , _env_fork             = defaultEnvFork
    , _env_broker             = Nothing
    }
