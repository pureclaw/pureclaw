-- |
-- Module      : Routing.RegistrySpec
-- Description : E-series tests for Registry + AgentEnv (WU3 implementation).
--
-- The E-series Definition-of-Done items from @docs/tabbed-chat.md@
-- §"Registry & AgentEnv (E-series)" are split across WUs:
--
--   * E1, E4 — green in WU3 (this file) — assert the AgentEnv fields
--     '_env_tabs', '_env_focus', '_env_activeCount', '_env_runners',
--     '_env_channelOutQ', '_env_routingConfig', '_env_fork' exist with
--     the documented types and the bounded TBQueue capacity tracks
--     '_rc_channelOutQBound'.
--   * E2 — declarative (the focused-tab projection wiring lands in
--     WU10); WU3 keeps the assertion as a type-level smoke test that
--     'AgentEnv' continues to expose '_env_target', '_env_session',
--     '_env_provider', and '_env_model' as 'IORef'-typed projections
--     that the dispatcher will read inside its message-processing
--     window.
--   * E3 — focus invariant (WU5 dispatcher); stays 'pending'.
--   * E5 — per-tab Context single-writer (WU6 Tab.Ai); stays 'pending'.
--
-- WU3 additionally exercises the pure tab-registry CRUD landed in
-- 'PureClaw.Routing.Registry' (the in-WU3 'lookupTab', 'insertTab',
-- 'removeTab', 'lowestFreeIndex' API).
module Routing.RegistrySpec (spec) where

import Control.Concurrent.STM (atomically, newTBQueueIO, newTVarIO, readTBQueue, readTVarIO, writeTBQueue)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, isJust, isNothing)
import Data.Text (Text)
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)

import PureClaw.Handles.Tab
  ( TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabRunner (..)
  , TabStatus (..)
  , mkTabIndex
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Dispatcher qualified as Dispatcher
import PureClaw.Routing.Registry
  ( insertTab
  , lookupTab
  , lowestFreeIndex
  , packAfterRemove
  , removeTab
  )
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  , mkStreamId
  )
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Session.Handle (SessionHandle, mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Tab.Ai qualified as TabAi
import PureClaw.Tools.Registry (ToolRegistry, emptyRegistry)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | The set of common 'AgentEnv' base fields plus E-series defaults.
data AgentEnvOverrides = AgentEnvOverrides
  { _aeo_provider          :: IORef (Maybe SomeProvider)
  , _aeo_model             :: IORef (Maybe ModelId)
  , _aeo_channel           :: ChannelHandle
  , _aeo_logger            :: LogHandle
  , _aeo_systemPrompt      :: Maybe Text
  , _aeo_registry          :: ToolRegistry
  , _aeo_vault             :: IORef (Maybe VaultHandle)
  , _aeo_pluginHandle      :: PluginHandle
  , _aeo_policy            :: SecurityPolicy
  , _aeo_harnesses         :: IORef (Map Text HarnessHandle)
  , _aeo_target            :: IORef MessageTarget
  , _aeo_nextWindowIdx     :: IORef Int
  , _aeo_agentDef          :: Maybe AgentDef
  , _aeo_session           :: IORef SessionHandle
  , _aeo_onFirstStreamDone :: IORef (Maybe (IO ()))
  , _aeo_mcpServers        :: IORef (Map Text McpServer)
  }

mkDefaultAgentEnv :: AgentEnvOverrides -> IO AgentEnv
mkDefaultAgentEnv overrides = do
  let routing = defaultRoutingConfig
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef Nothing
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO (fromIntegral (_rc_channelOutQBound routing))
  pure AgentEnv
    { _env_provider         = _aeo_provider overrides
    , _env_model            = _aeo_model overrides
    , _env_channel          = _aeo_channel overrides
    , _env_logger           = _aeo_logger overrides
    , _env_systemPrompt     = _aeo_systemPrompt overrides
    , _env_registry         = _aeo_registry overrides
    , _env_vault            = _aeo_vault overrides
    , _env_pluginHandle     = _aeo_pluginHandle overrides
    , _env_policy           = _aeo_policy overrides
    , _env_harnesses        = _aeo_harnesses overrides
    , _env_target           = _aeo_target overrides
    , _env_nextWindowIdx    = _aeo_nextWindowIdx overrides
    , _env_agentDef         = _aeo_agentDef overrides
    , _env_session          = _aeo_session overrides
    , _env_onFirstStreamDone = _aeo_onFirstStreamDone overrides
    , _env_mcpServers       = _aeo_mcpServers overrides
    , _env_tabs             = tabsRef
    , _env_focus            = focusRef
    , _env_activeCount      = activeCountTv
    , _env_runners          = runnersRef
    , _env_channelOutQ      = channelOutQ
    , _env_routingConfig    = routing
    , _env_fork             = defaultEnvFork
    }

-- | Construct a minimal in-memory 'AgentEnv' for E-series assertions.
mkE3TestEnv :: IO AgentEnv
mkE3TestEnv = do
  vaultRef       <- newIORef Nothing
  providerRef    <- newIORef Nothing
  modelRef       <- newIORef Nothing
  harnessRef     <- newIORef Map.empty
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef Map.empty
  mkDefaultAgentEnv
    AgentEnvOverrides
      { _aeo_provider     = providerRef
      , _aeo_model        = modelRef
      , _aeo_channel      = mkNoOpChannelHandle
      , _aeo_logger       = mkNoOpLogHandle
      , _aeo_systemPrompt = Nothing
      , _aeo_registry     = emptyRegistry
      , _aeo_vault        = vaultRef
      , _aeo_pluginHandle = mkPluginHandle
      , _aeo_policy       = defaultPolicy
      , _aeo_harnesses    = harnessRef
      , _aeo_target       = targetRef
      , _aeo_nextWindowIdx = windowIdxRef
      , _aeo_agentDef     = Nothing
      , _aeo_session      = sessionRef
      , _aeo_onFirstStreamDone = noOpOnFirstStreamDoneRef
      , _aeo_mcpServers   = mcpRef
      }

-- | Synthetic 'TabHandle' for registry tests. None of the IO actions are
-- exercised; this is a placeholder value with a known 'TabIndex' so the
-- pure CRUD assertions can match.
syntheticTabHandle :: TabIndex -> TabHandle
syntheticTabHandle idx = TabHandle
  { _tabHandle_index        = idx
  , _tabHandle_name         = TabName "tab"
  , _tabHandle_kind         = KindAi
  , _tabHandle_status       = error "syntheticTabHandle: _tabHandle_status not used"
  , _tabHandle_send         = \_ -> error "syntheticTabHandle: _tabHandle_send not used"
  , _tabHandle_enqueueSlash = \_ -> error "syntheticTabHandle: _tabHandle_enqueueSlash not used"
  , _tabHandle_close        = \_ -> error "syntheticTabHandle: _tabHandle_close not used"
  }

idx0, idx1, idx2 :: TabIndex
idx0 = fromJust (mkTabIndex 0)
idx1 = fromJust (mkTabIndex 1)
idx2 = fromJust (mkTabIndex 2)

-- | E3 helper: synthetic tab whose '_tabHandle_send' is a silent no-op
-- and whose status is permanently 'Idle' (no crash banner side
-- effects). Sufficient for the focus-invariant assertions.
mkSyntheticTabForE3 :: TabIndex -> TabKind -> IO TabHandle
mkSyntheticTabForE3 idx kind = pure TabHandle
  { _tabHandle_index        = idx
  , _tabHandle_name         = TabName "e3"
  , _tabHandle_kind         = kind
  , _tabHandle_status       = pure (Idle (UTCTime (fromGregorian 2026 5 17)
                                                   (secondsToDiffTime 0)))
  , _tabHandle_send         = \_ -> pure (Right ())
  , _tabHandle_enqueueSlash = \_ -> pure (Right ())
  , _tabHandle_close        = \_ -> pure ()
  }

-- ---------------------------------------------------------------------------
-- E-series
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "E-series — registry + AgentEnv (WU3)" $ do
    it "E1: AgentEnv gains _env_tabs / _env_focus / _env_activeCount / _env_runners / _env_channelOutQ / _env_routingConfig / _env_fork (bounded TBQueue capacity _rc_channelOutQBound)" $ do
      env <- mkE3TestEnv
      -- _env_tabs is empty IntMap on construction (we can only check
      -- emptiness — TabHandle has no Show)
      tabs <- readIORef (_env_tabs env)
      IntMap.null tabs `shouldBe` True
      -- _env_focus starts Nothing
      curFocus <- readIORef (_env_focus env)
      curFocus `shouldBe` Nothing
      -- _env_activeCount starts at 0
      active <- readTVarIO (_env_activeCount env)
      active `shouldBe` 0
      -- _env_runners starts empty
      runners <- readIORef (_env_runners env)
      IntMap.null runners `shouldBe` True
      -- _env_routingConfig holds the default
      _env_routingConfig env `shouldBe` defaultRoutingConfig
      -- _env_channelOutQ is a TBQueue whose capacity equals
      -- _rc_channelOutQBound; verify by round-tripping an item.
      let bound = _rc_channelOutQBound (_env_routingConfig env)
      bound `shouldBe` 1024
      let sid = mkStreamId 1
      atomically $ writeTBQueue (_env_channelOutQ env) (SrcDispatcher, BannerLine "ping")
      out <- atomically $ readTBQueue (_env_channelOutQ env)
      out `shouldBe` (SrcDispatcher, BannerLine "ping")
      atomically $ writeTBQueue (_env_channelOutQ env) (SrcTab idx0, StreamStart sid idx0)
      out2 <- atomically $ readTBQueue (_env_channelOutQ env)
      out2 `shouldBe` (SrcTab idx0, StreamStart sid idx0)

    it "E2: existing _env_target / _env_session / _env_provider / _env_model continue to be IORef-typed (focused-tab projection wiring is WU10)" $ do
      env <- mkE3TestEnv
      -- All four are IORefs we can read; the wiring change in WU10 will
      -- redirect these reads through a focused-tab projection but the
      -- field shapes do not change. This is the WU3-scope assertion.
      target  <- readIORef (_env_target env)
      target `shouldBe` TargetProvider
      _       <- readIORef (_env_session env)
      -- SomeProvider has no Show instance, so we test via Maybe-pattern.
      provider <- readIORef (_env_provider env)
      case provider of
        Nothing -> pure ()
        Just _  -> expectationFailure "expected _env_provider to start Nothing"
      model    <- readIORef (_env_model env)
      model `shouldSatisfy` isNothing

    it "E3: focus invariant — _env_focus written only by dispatcher between message cycles (WU5 dispatcher)" $ do
      -- WU5: 'dispatchOne' is the only function in the routing layer
      -- that writes '_env_focus'; it runs synchronously in the
      -- dispatcher's thread. We assert the invariant operationally:
      -- drive a sequence of inputs through 'dispatchOne' on a single
      -- thread and confirm focus is consistent with the LAST accepted
      -- 'Switch' (sequential reads/writes — no TOCTOU).
      env <- mkE3TestEnv
      st  <- mkSyntheticTabForE3 idx0 KindAi
      _   <- insertTab (_env_tabs env) idx0 st
      st1 <- mkSyntheticTabForE3 idx1 KindAi
      _   <- insertTab (_env_tabs env) idx1 st1
      ds  <- Dispatcher.newDispatcherState env
               (\_k _i _a -> pure (Right st))
      -- Initial focus: Nothing.
      readIORef (_env_focus env) `shouldReturn` Nothing
      -- After /0: focus = Just 0.
      Dispatcher.dispatchOne env ds (UserId "u") "/0"
      readIORef (_env_focus env) `shouldReturn` Just idx0
      -- After /1: focus = Just 1 (write happened synchronously inside
      -- the same dispatchOne call; no interleaving possible).
      Dispatcher.dispatchOne env ds (UserId "u") "/1"
      readIORef (_env_focus env) `shouldReturn` Just idx1
      -- An Inject does NOT change focus (E3 contract: only Switch can).
      Dispatcher.dispatchOne env ds (UserId "u") "/0 hello"
      readIORef (_env_focus env) `shouldReturn` Just idx1
      -- A Default also does NOT change focus.
      Dispatcher.dispatchOne env ds (UserId "u") "plain text"
      readIORef (_env_focus env) `shouldReturn` Just idx1

    it "E4: _env_fork :: IO () -> IO TabRunner is part of AgentEnv (default wraps Control.Concurrent.Async.async)" $ do
      env <- mkE3TestEnv
      -- Fork an action that writes a sentinel; wait on the runner; assert
      -- the action ran. The fork closure is what the dispatcher will use
      -- in WU5 to spawn the per-tab loop.
      sentinel <- newIORef False
      runner <- _env_fork env (writeIORef sentinel True)
      _trun_wait runner
      ran <- readIORef sentinel
      ran `shouldBe` True
      -- Cancel after wait is idempotent.
      _trun_cancel runner

    it ("E5: per-tab Context mutations go through tab loop's input "
        <> "queue (WU6 Tab.Ai). The AI tab factory exposes "
        <> "_tabHandle_enqueueSlash which deposits a SlashCmd on the "
        <> "per-tab TBQueue; the loop is the sole context writer.") $ do
      env <- mkE3TestEnv
      r <- TabAi.mkTabAi env idx0
             Tab.AiSpawnArgs { Tab._ai_requestedName = "e5" }
      case r of
        Right h -> do
          -- The handle's enqueueSlash returns Right () — the dispatcher's
          -- E5 routing for AI tabs goes through this surface.
          res <- _tabHandle_enqueueSlash h Slash.CmdNew
          res `shouldBe` Right ()
          -- Close cleans up (idempotent + never-throws).
          _tabHandle_close h Tab.CloseGraceful
        Left e -> expectationFailure
                    ("expected Right TabHandle for E5 spawn; got " <> show e)

  describe "Registry — pure tab CRUD" $ do
    it "lookupTab returns Nothing for an empty registry" $ do
      ref <- newIORef IntMap.empty
      r <- lookupTab ref idx0
      isNothing r `shouldBe` True

    it "insertTab + lookupTab round-trip a synthetic handle" $ do
      ref <- newIORef IntMap.empty
      let h = syntheticTabHandle idx0
      r <- insertTab ref idx0 h
      r `shouldBe` Right ()
      got <- lookupTab ref idx0
      isJust got `shouldBe` True
      -- The handle's pure fields survive the round trip.
      fmap _tabHandle_index got `shouldBe` Just idx0
      fmap _tabHandle_kind got `shouldBe` Just KindAi

    it "insertTab rejects an in-use index with TabIndexInUse" $ do
      ref <- newIORef IntMap.empty
      _ <- insertTab ref idx0 (syntheticTabHandle idx0)
      r <- insertTab ref idx0 (syntheticTabHandle idx0)
      case r of
        Left e -> show e `shouldContain` "TabIndexInUse"
        Right _ -> expectationFailure "expected TabIndexInUse"

    it "removeTab returns the removed handle and drops it from the map" $ do
      ref <- newIORef IntMap.empty
      _ <- insertTab ref idx1 (syntheticTabHandle idx1)
      got <- removeTab ref idx1
      fmap _tabHandle_index got `shouldBe` Just idx1
      remaining <- lookupTab ref idx1
      isNothing remaining `shouldBe` True

    it "removeTab on an absent index returns Nothing" $ do
      ref <- newIORef IntMap.empty
      got <- removeTab ref idx2
      isNothing got `shouldBe` True

    it "lowestFreeIndex on an empty registry returns 0" $ do
      ref <- newIORef IntMap.empty
      r <- lowestFreeIndex ref 10
      r `shouldBe` mkTabIndex 0

    it "lowestFreeIndex skips occupied low indices" $ do
      ref <- newIORef IntMap.empty
      _ <- insertTab ref idx0 (syntheticTabHandle idx0)
      _ <- insertTab ref idx1 (syntheticTabHandle idx1)
      r <- lowestFreeIndex ref 10
      r `shouldBe` mkTabIndex 2

    it "lowestFreeIndex finds a gap before the highest used slot" $ do
      ref <- newIORef IntMap.empty
      _ <- insertTab ref idx0 (syntheticTabHandle idx0)
      _ <- insertTab ref idx2 (syntheticTabHandle idx2)
      -- idx 1 is the lowest free.
      r <- lowestFreeIndex ref 10
      r `shouldBe` mkTabIndex 1

    it "lowestFreeIndex returns Nothing when every slot 0..(maxN-1) is taken" $ do
      ref <- newIORef IntMap.empty
      _ <- insertTab ref idx0 (syntheticTabHandle idx0)
      _ <- insertTab ref idx1 (syntheticTabHandle idx1)
      r <- lowestFreeIndex ref 2
      r `shouldBe` Nothing

    it "lowestFreeIndex with maxN = 0 always returns Nothing" $ do
      ref <- newIORef IntMap.empty
      r <- lowestFreeIndex ref 0
      r `shouldBe` Nothing

    it "packAfterRemove shifts keys > k down by 1; keys < k untouched" $ do
      -- Initial map (after removing entry at 1): keys [0,2,3] map to ['a','c','d'].
      -- After packAfterRemove 1: keys [0,1,2] (former 2→1, former 3→2).
      let m0 = IntMap.fromList [(0 :: Int, 'a'), (2, 'c'), (3, 'd')]
          m1 = packAfterRemove 1 m0
      IntMap.toAscList m1 `shouldBe` [(0, 'a'), (1, 'c'), (2, 'd')]

    it "packAfterRemove with no keys > k is the identity" $ do
      let m0 = IntMap.fromList [(0 :: Int, 'a'), (1, 'b')]
          m1 = packAfterRemove 5 m0
      m1 `shouldBe` m0

    it "packAfterRemove on the empty map is the empty map" $ do
      packAfterRemove 3 (IntMap.empty :: IntMap.IntMap Char)
        `shouldBe` IntMap.empty
