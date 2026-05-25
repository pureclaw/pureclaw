{-# LANGUAGE PatternSynonyms #-}
-- |
-- Module      : Routing.AutoSpawnSpec
-- Description : A-series + B-series DoDs (WU9).
--
-- Enumerates the A-series (auto-spawn truth table) and B-series
-- (dashboard) Definition-of-Done items from @docs/tabbed-chat.md@ and
-- flips them green by exercising the WU9 'PureClaw.Routing.AutoSpawn'
-- and 'PureClaw.Routing.Dashboard' handlers end-to-end through the
-- dispatcher's 'dispatchOne' seam.
--
-- Test seam: an in-test 'TabFactory' (the same shape the dispatcher
-- uses via 'spawnTabWith') returns synthetic 'TabHandle' records so
-- the assertions can observe registry mutations + channel-out
-- emissions without exercising the real WU6 \/ WU7 \/ WU8 factory
-- bodies.
module Routing.AutoSpawnSpec (spec) where

import Control.Concurrent.STM
  ( TBQueue
  , atomically
  , newTBQueueIO
  , newTVarIO
  , tryReadTBQueue
  )
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands qualified
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log
import PureClaw.Handles.Tab
  ( TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabStatus (..)
  , mkTabIndex
  , pattern KindAi
  , pattern KindHarness
  , pattern KindShell
  )
import PureClaw.Handles.Tab qualified
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Dashboard
  ( bulletThreshold
  , emptyDashboardText
  , renderDashboard
  )
import PureClaw.Routing.Dispatcher
  ( TabFactory
  , dispatchOne
  , newDispatcherState
  )
import PureClaw.Routing.Dispatcher qualified
import PureClaw.Routing.AutoSpawn qualified
import PureClaw.Routing.PromptRenderer
  ( PromptRenderer (..)
  , mkDefaultPromptRenderer
  , mkInlineKeyboardPromptRenderer
  , mkTextPromptRenderer
  , renderKindsAsText
  )
import PureClaw.Routing.Registry (insertTab)
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  )
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle (fakeChannelHandle, newFakeChannel)


-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 17) (secondsToDiffTime 0)

ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | A synthetic tab whose send + close calls are observable.
data SyntheticTab = SyntheticTab
  { _st_handle   :: !TabHandle
  , _st_sentRf   :: !(IORef [Text])
  , _st_closedRf :: !(IORef Int)
  , _st_statusRf :: !(IORef TabStatus)
  }

mkSyntheticTab :: TabIndex -> TabKind -> Text -> TabStatus -> IO SyntheticTab
mkSyntheticTab idx kind nm initSt = do
  statusRf <- newIORef initSt
  sentRf   <- newIORef []
  closedRf <- newIORef 0
  let handle = TabHandle
        { _tabHandle_index        = idx
        , _tabHandle_name         = TabName nm
        , _tabHandle_kind         = kind
        , _tabHandle_status       = readIORef statusRf
        , _tabHandle_send         = \t -> do
            atomicModifyIORef' sentRf (\xs -> (t : xs, ()))
            pure (Right ())
        , _tabHandle_enqueueSlash = \_ -> pure (Right ())
        , _tabHandle_close        = \_mode ->
            atomicModifyIORef' closedRf (\n -> (n + 1, ()))
        }
  pure SyntheticTab
    { _st_handle   = handle
    , _st_sentRf   = sentRf
    , _st_closedRf = closedRf
    , _st_statusRf = statusRf
    }

-- | A factory that returns successive synthetic tabs from a shared IORef.
-- The IORef holds a list (kind-keyed) of pending fixtures.
syntheticFactoryFromQueue :: IORef [SyntheticTab] -> TabFactory
syntheticFactoryFromQueue queue _kind _idx _args = do
  next <- atomicModifyIORef' queue popHead
  case next of
    Just st -> pure (Right (_st_handle st))
    Nothing -> pure (Left (TabLimitExceeded 0))
  where
    popHead :: [a] -> ([a], Maybe a)
    popHead []     = ([], Nothing)
    popHead (h:tl) = (tl, Just h)

-- | Build a minimal 'AgentEnv' for AutoSpawn tests.
mkAutoSpawnEnv :: IO AgentEnv
mkAutoSpawnEnv = do
  let routing = defaultRoutingConfig
  fch <- newFakeChannel
  mkAutoSpawnEnvWith (fakeChannelHandle fch) routing

mkAutoSpawnEnvWith :: ChannelHandle -> RoutingConfig -> IO AgentEnv
mkAutoSpawnEnvWith ch routing = do
  providerRef    <- newIORef (Nothing :: Maybe SomeProvider)
  modelRef       <- newIORef (Nothing :: Maybe ModelId)
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef (Map.empty :: Map Text McpServer)
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef (Nothing :: Maybe TabIndex)
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO 1024
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = ch
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
    , _env_harnesses         = harnessRef
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing :: Maybe AgentDef
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_tabs              = tabsRef
    , _env_focus             = focusRef
    , _env_activeCount       = activeCountTv
    , _env_runners           = runnersRef
    , _env_channelOutQ       = channelOutQ
    , _env_routingConfig     = routing
    , _env_fork              = defaultEnvFork
    , _env_broker              = Nothing
    }

drainQueue :: TBQueue a -> IO [a]
drainQueue q = go []
  where
    go acc = do
      mv <- atomically (tryReadTBQueue q)
      case mv of
        Nothing -> pure (reverse acc)
        Just v  -> go (v : acc)

banners :: [(OutputSource, ChannelEvent)] -> [Text]
banners xs = [t | (SrcDispatcher, BannerLine t) <- xs]


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "A-series — /N switch + /tab new + close (tmux packing)" $ do

    it ("A1: /3 when N exists — focus + recap banner; \"focused\" "
        <> "marker present") $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 3) KindAi "ai-3" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 3) (_st_handle st)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/3"
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 3)
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("/3: focused" `T.isInfixOf`)
      banners drained `shouldSatisfy`
        any ("recap" `T.isInfixOf`)

    it ("A2: /3 payload when N exists — enqueue payload to tab 3's "
        <> "input; focus unchanged") $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 3) KindAi "ai-3" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 3) (_st_handle st)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/3 hello world"
      f <- readIORef (_env_focus env)
      f `shouldBe` Nothing
      sent <- readIORef (_st_sentRf st)
      sent `shouldBe` ["hello world"]

    it ("A3 (tmux-packing): /3 when N missing — emits a 'no such tab' "
        <> "banner; NO auto-spawn; focus unchanged") $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 0) KindAi "shouldnt-spawn" (Idle t0)
      queue <- newIORef [st]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/3"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0
      f <- readIORef (_env_focus env)
      f `shouldBe` Nothing
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "/3" `T.isInfixOf` t && "no such tab" `T.isInfixOf` t)

    it ("A4 (tmux-packing): /tab new (no kind) — force-prompt at the "
        <> "next free slot (0); enumerates the kind keywords; NO spawn") $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 0) KindAi "shouldnt-spawn" (Idle t0)
      queue <- newIORef [st]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new"
      drained <- drainQueue (_env_channelOutQ env)
      -- Prompt renders for the lowest free slot (0).
      banners drained `shouldSatisfy`
        any (\t -> "/0" `T.isInfixOf` t
                && ("ai" `T.isInfixOf` t || "shell" `T.isInfixOf` t))
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0

    it ("A5 (tmux-packing): /3 payload when N missing — Inject path "
        <> "surfaces 'no such tab' PublicError; no spawn") $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 0) KindAi "shouldnt-spawn" (Idle t0)
      queue <- newIORef [st]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/3 hello"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "/3" `T.isInfixOf` t && "no such tab" `T.isInfixOf` t)

    it ("A6 (tmux-packing): /tab new force-prompt with a non-empty "
        <> "registry — prompt targets the NEXT free slot (not slot 0)") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "exists" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("/1" `T.isInfixOf`)

    it "A7: /tab new (no kind) — force-prompt mentions the kinds" $ do
      env <- mkAutoSpawnEnv
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "/0" `T.isInfixOf` t
                && ("ai" `T.isInfixOf` t || "shell" `T.isInfixOf` t))
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0

    it ("A8 (tmux-packing): /tab new always lands at the lowest free "
        <> "slot; user no longer picks the index. With one tab already "
        <> "at /0, /tab new ai spawns at /1.") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "tab-0" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      stNew <- mkSyntheticTab (ti 1) KindAi "new-tab" (Idle t0)
      queue <- newIORef [stNew]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new ai"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "/1" `T.isInfixOf` t && "spawned" `T.isInfixOf` t)

    it "A9: /tab new shell — spawn with KindShell, focus" $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 0) KindShell "sh-0" (Idle t0)
      queue <- newIORef [st]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new shell"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 0)
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("shell" `T.isInfixOf`)

    it ("A10 (tmux-packing): /tab new ai with /0 already existing "
        <> "spawns at /1 (no 'already exists' error any more — the user "
        <> "no longer names the slot)") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "tab-0" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      stNew <- mkSyntheticTab (ti 1) KindAi "new-tab" (Idle t0)
      queue <- newIORef [stNew]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab new ai"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 2
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy` any ("spawned" `T.isInfixOf`)

    it ("A11 \\/ S6: /tab new at full capacity — TabLimitExceeded "
        <> "surfaces as a redacted PublicError; no spawn") $ do
      env0 <- mkAutoSpawnEnv
      let envFull = env0
            { _env_routingConfig = (_env_routingConfig env0)
                { _rc_maxTabs = 2 }
            }
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      _   <- insertTab (_env_tabs envFull) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs envFull) (ti 1) (_st_handle st1)
      -- The factory's queue is empty so a successful spawn would also
      -- fail; the rate-limited dispatcher path returns TabLimitExceeded
      -- because lowestFreeIndex returns Nothing at cap.
      queue <- newIORef []
      ds  <- newDispatcherState envFull (syntheticFactoryFromQueue queue)
      dispatchOne envFull ds (UserId "u") "/tab new ai"
      drained <- drainQueue (_env_channelOutQ envFull)
      -- The dispatcher banner mentions the /tab new prefix and a
      -- redacted error.
      banners drained `shouldSatisfy`
        any (\t -> "/tab new" `T.isInfixOf` t && "tab:" `T.isInfixOf` t)
      tabs <- readIORef (_env_tabs envFull)
      IntMap.size tabs `shouldBe` 2

    it ("A12: after /tab close 0, the lowest free slot is 0 again; "
        <> "/tab new ai spawns at 0") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      stNew <- mkSyntheticTab (ti 0) KindAi "new-0" (Idle t0)
      queue <- newIORef [stNew]
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 0"
      tabs0 <- readIORef (_env_tabs env)
      IntMap.size tabs0 `shouldBe` 0
      dispatchOne env ds (UserId "u") "/tab new ai"
      tabs1 <- readIORef (_env_tabs env)
      IntMap.size tabs1 `shouldBe` 1
      IntMap.member 0 tabs1 `shouldBe` True

  describe "tmux renumber-on-close (always-packed slot model)" $ do

    it ("closing /1 with /0,/1,/2 open renumbers /2 to /1; registry "
        <> "is contiguous [0,1]") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      st2 <- mkSyntheticTab (ti 2) KindAi "t2" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      _   <- insertTab (_env_tabs env) (ti 2) (_st_handle st2)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 1"
      tabs <- readIORef (_env_tabs env)
      IntMap.keys tabs `shouldBe` [0, 1]
      -- The handle at the new /1 is what used to be st2 (its name is
      -- preserved through the registry move; _tabHandle_index is
      -- advisory and not rewritten).
      case IntMap.lookup 1 tabs of
        Just h  -> _tabHandle_name h `shouldBe` TabName "t2"
        Nothing -> expectationFailure "expected /1 to hold former t2"

    it "closing a focused tab clears focus (was N → Nothing)" $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      writeIORef (_env_focus env) (Just (ti 1))
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 1"
      f <- readIORef (_env_focus env)
      f `shouldBe` Nothing

    it ("closing a tab below the focus decrements focus by 1 "
        <> "(was at N+1; new focus N)") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      st2 <- mkSyntheticTab (ti 2) KindAi "t2" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      _   <- insertTab (_env_tabs env) (ti 2) (_st_handle st2)
      writeIORef (_env_focus env) (Just (ti 2))
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 0"
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 1)

    it "closing a tab above the focus leaves focus untouched" $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      writeIORef (_env_focus env) (Just (ti 0))
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 1"
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 0)

    it ("SpawnArgs side map is shifted to follow the renumber: closing "
        <> "tab 0 drops its args entry and shifts the rest down by 1") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindShell "t1" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      let saMap = PureClaw.Routing.Dispatcher._ds_spawnArgs ds
      PureClaw.Routing.AutoSpawn.rememberArgsForTest saMap (ti 0)
        KindAi    ["t0"]
      PureClaw.Routing.AutoSpawn.rememberArgsForTest saMap (ti 1)
        KindShell ["t1"]
      dispatchOne env ds (UserId "u") "/tab close 0"
      saAfter <- readIORef saMap
      Map.keys saAfter `shouldBe` [0]
      case Map.lookup 0 saAfter of
        Just sa -> PureClaw.Routing.AutoSpawn._sa_kind sa `shouldBe` KindShell
        Nothing -> expectationFailure "expected the former /1 args at /0"

    it ("pending-retry side map is shifted to follow the renumber: "
        <> "closing /0 drops its entry; an entry that pointed at /1 "
        <> "is renumbered to /0") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi "t1" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _   <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      let pendRef = PureClaw.Routing.Dispatcher._ds_pendingRetry ds
          sa = PureClaw.Routing.AutoSpawn.SpawnArgs
                 { PureClaw.Routing.AutoSpawn._sa_kind = KindAi
                 , PureClaw.Routing.AutoSpawn._sa_args = ["x"]
                 }
      atomicModifyIORef' pendRef
        (\m -> ( Map.insert (UserId "v") (ti 1, sa)
                  (Map.insert (UserId "u") (ti 0, sa) m), () ))
      dispatchOne env ds (UserId "u") "/tab close 0"
      pendAfter <- readIORef pendRef
      Map.lookup (UserId "u") pendAfter `shouldBe` Nothing
      case Map.lookup (UserId "v") pendAfter of
        Just (idx, _) -> idx `shouldBe` ti 0
        Nothing       -> expectationFailure "expected v's retry at /0 after renumber"

  describe "B-series — dashboard rendering (WU9)" $ do

    it ("B1: /tabs with empty registry emits 'No tabs open. Use /N "
        <> "or /tab new N <kind> to create one.'") $ do
      env <- mkAutoSpawnEnv
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tabs"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy` any (emptyDashboardText `T.isInfixOf`)

    it ("B2: /tabs with N=3 tabs emits one line per tab (index, "
        <> "kind, redacted name, status, focus marker)") $ do
      env <- mkAutoSpawnEnv
      st0 <- mkSyntheticTab (ti 0) KindAi "first"  (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindShell "sh"  (Idle t0)
      st2 <- mkSyntheticTab (ti 2) KindHarness "h" (Idle t0)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _ <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      _ <- insertTab (_env_tabs env) (ti 2) (_st_handle st2)
      writeIORef (_env_focus env) (Just (ti 1))
      out <- renderDashboard env
      let lined = T.lines out
      length lined `shouldBe` 3
      -- The focused tab carries an asterisk; the kind:detail keywords appear.
      out `shouldSatisfy` T.isInfixOf "provider:anthropic"
      out `shouldSatisfy` T.isInfixOf "shell:local"
      out `shouldSatisfy` T.isInfixOf "harness:claude-code"
      out `shouldSatisfy` T.isInfixOf "/1"
      out `shouldSatisfy` T.isInfixOf "*"

    -- WU-11 C5: /tab list shows kind info
    it "C5: dashboard includes kind detail (provider:anthropic, harness:claude-code, shell:local)" $ do
      env <- mkAutoSpawnEnv
      -- KindAi uses defaultProviderSpec with ProviderId "anthropic"
      st0 <- mkSyntheticTab (ti 0) KindAi "first" (Idle t0)
      -- KindShell = TkRawShell TbLocal
      st1 <- mkSyntheticTab (ti 1) KindShell "sh" (Idle t0)
      -- KindHarness uses defaultHarnessSpec with HClaudeCode
      st2 <- mkSyntheticTab (ti 2) KindHarness "h" (Idle t0)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      _ <- insertTab (_env_tabs env) (ti 1) (_st_handle st1)
      _ <- insertTab (_env_tabs env) (ti 2) (_st_handle st2)
      out <- renderDashboard env
      out `shouldSatisfy` T.isInfixOf "provider:anthropic"
      out `shouldSatisfy` T.isInfixOf "harness:claude-code"
      out `shouldSatisfy` T.isInfixOf "shell:local"

    it "B3: /tabs rendering for ≥ 8 tabs uses bullet rendering" $ do
      env <- mkAutoSpawnEnv
      let n = bulletThreshold
      mapM_ (\i -> do
               st <- mkSyntheticTab (ti i) KindAi ("t" <> T.pack (show i)) (Idle t0)
               _  <- insertTab (_env_tabs env) (ti i) (_st_handle st)
               pure ())
            [0 .. (n - 1)]
      out <- renderDashboard env
      out `shouldSatisfy` T.isInfixOf " - "

    it ("Dashboard renderStatus: Active + Crashed branches surface "
        <> "their respective labels") $ do
      env <- mkAutoSpawnEnv
      stA  <- mkSyntheticTab (ti 0) KindAi "a" Active
      stC  <- mkSyntheticTab (ti 1) KindAi "c"
                (Crashed (PureClaw.Handles.Tab.PublicTabError
                            "tab: ai loop crashed"))
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle stA)
      _ <- insertTab (_env_tabs env) (ti 1) (_st_handle stC)
      out <- renderDashboard env
      out `shouldSatisfy` T.isInfixOf "active"
      out `shouldSatisfy` T.isInfixOf "crashed"

    it "Dashboard tolerates a tab whose status raises" $ do
      env <- mkAutoSpawnEnv
      statusRf <- newIORef (Idle t0)
      closedRf <- newIORef (0 :: Int)
      let bad = TabHandle
            { _tabHandle_index        = ti 0
            , _tabHandle_name         = TabName "bad"
            , _tabHandle_kind         = KindAi
            , _tabHandle_status       = error "boom"
            , _tabHandle_send         = \_ -> pure (Right ())
            , _tabHandle_enqueueSlash = \_ -> pure (Right ())
            , _tabHandle_close        = \_ ->
                atomicModifyIORef' closedRf (\n -> (n + 1, ()))
            }
      _ <- insertTab (_env_tabs env) (ti 0) bad
      out <- renderDashboard env
      out `shouldSatisfy` T.isInfixOf "?"
      _ <- readIORef statusRf  -- silence unused
      pure ()

  describe "PromptRenderer — channel-dispatched spawn-prompt UX (WU9)" $ do

    it ("mkTextPromptRenderer surfaces the enumerated kind keywords "
        <> "and is selected when the channel reports streaming = True") $ do
      env <- mkAutoSpawnEnv
      let streamingCh = (_env_channel env) { _ch_streaming = True }
          rend = mkDefaultPromptRenderer streamingCh
      _pr_renderSpawnPrompt rend (ti 3) Nothing
        `shouldSatisfy` T.isInfixOf renderKindsAsText

    it ("mkInlineKeyboardPromptRenderer is selected when the channel "
        <> "reports streaming = False (Telegram\\/Signal default)") $ do
      env <- mkAutoSpawnEnv
      let noStreamCh = (_env_channel env) { _ch_streaming = False }
          rend = mkDefaultPromptRenderer noStreamCh
      _pr_renderSpawnPrompt rend (ti 5) Nothing
        `shouldSatisfy` T.isInfixOf "[ai]"

    it ("buffered payload is round-tripped via the prompt body "
        <> "(text + inline-keyboard variants)") $ do
      let textRend = mkTextPromptRenderer
          kbRend   = mkInlineKeyboardPromptRenderer
      _pr_renderSpawnPrompt textRend (ti 1) (Just "hello")
        `shouldSatisfy` T.isInfixOf "Buffered text: hello"
      _pr_renderSpawnPrompt kbRend (ti 2) (Just "world")
        `shouldSatisfy` T.isInfixOf "Buffered text: world"

  describe "AutoSpawn — error paths + tab-kind round-trip (WU9)" $ do

    it ("handleNew: factory returning Left propagates as a "
        <> "dispatcher PublicError (no per-index banner under tmux "
        <> "packing — the banner is keyed on /tab new since the user "
        <> "no longer named the slot)") $ do
      env <- mkAutoSpawnEnv
      let leftFactory _ _ _ = pure (Left (TabLimitExceeded 9))
      ds <- newDispatcherState env leftFactory
      dispatchOne env ds (UserId "u") "/tab new ai"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "/tab new" `T.isInfixOf` t
                && "tab:" `T.isInfixOf` t)

    it "handleClose: invalid index emits 'tab: invalid index'" $ do
      env <- mkAutoSpawnEnv
      queue <- newIORef []
      ds <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab close 9"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("not found" `T.isInfixOf`)

    it "handleFocus: /tab focus N — switches focus to existing N" $ do
      env <- mkAutoSpawnEnv
      st  <- mkSyntheticTab (ti 2) KindAi "t2" (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 2) (_st_handle st)
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab focus 2"
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 2)

    it ("handleRename: invalid (non-existent) index emits "
        <> "'tab: not found' banner") $ do
      env <- mkAutoSpawnEnv
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab rename 4 myname"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("not found" `T.isInfixOf`)

    it "recapText: returns empty when _rc_switchRecap <= 0" $ do
      env <- mkAutoSpawnEnv
      let rc = (_env_routingConfig env) { _rc_switchRecap = 0 }
          recap = PureClaw.Routing.AutoSpawn.recapText rc (ti 1)
      T.null recap `shouldBe` True

    it "kindKeyword + tabKindArgToKind cover every TabKindArg arm" $ do
      let ks =
            [ PureClaw.Agent.SlashCommands.TkaAi
            , PureClaw.Agent.SlashCommands.TkaProvider
            , PureClaw.Agent.SlashCommands.TkaHarness
            , PureClaw.Agent.SlashCommands.TkaShell
            , PureClaw.Agent.SlashCommands.TkaSsh
            , PureClaw.Agent.SlashCommands.TkaTmux
            ]
          kindMap = map PureClaw.Routing.AutoSpawn.tabKindArgToKind ks
          keywords = map PureClaw.Routing.AutoSpawn.kindKeyword kindMap
      -- TkaAi and TkaProvider both map to TkSession (SkProvider _) -> "ai"
      keywords `shouldBe` ["ai", "ai", "harness", "shell", "ssh", "tmux"]

    -- WU-11 S5: maxTabs enforcement on /tab new provider
    it "S5: /tab new provider at full capacity emits TabLimitExceeded" $ do
      env0 <- mkAutoSpawnEnv
      let envFull = env0
            { _env_routingConfig = (_env_routingConfig env0)
                { _rc_maxTabs = 1 }
            }
      st0 <- mkSyntheticTab (ti 0) KindAi "t0" (Idle t0)
      _   <- insertTab (_env_tabs envFull) (ti 0) (_st_handle st0)
      queue <- newIORef []
      ds  <- newDispatcherState envFull (syntheticFactoryFromQueue queue)
      dispatchOne envFull ds (UserId "u") "/tab new provider"
      drained <- drainQueue (_env_channelOutQ envFull)
      banners drained `shouldSatisfy`
        any (\t -> "/tab new" `T.isInfixOf` t && "tab:" `T.isInfixOf` t)
      tabs <- readIORef (_env_tabs envFull)
      IntMap.size tabs `shouldBe` 1

    it "splitArgs: Nothing yields []; Just splits on whitespace" $ do
      PureClaw.Routing.AutoSpawn.splitArgs Nothing `shouldBe` []
      PureClaw.Routing.AutoSpawn.splitArgs (Just "a b  c") `shouldBe` ["a","b","c"]

    it ("handleResume (now wired in WU10) — dispatcher walks the "
        <> "resolveSessionRef + resumeSession chain; a not-found "
        <> "session emits the redacted 'no such session' banner") $ do
      env <- mkAutoSpawnEnv
      queue <- newIORef []
      ds  <- newDispatcherState env (syntheticFactoryFromQueue queue)
      dispatchOne env ds (UserId "u") "/tab resume good-id"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any (\t -> "tab resume" `T.isInfixOf` t
                && "good-id" `T.isInfixOf` t)

    it "handleDefault: spawn failure (factory Left) emits PublicError" $ do
      env <- mkAutoSpawnEnv
      let leftFactory _ _ _ = pure (Left (TabLimitExceeded 9))
      ds <- newDispatcherState env leftFactory
      dispatchOne env ds (UserId "u") "hi default"
      drained <- drainQueue (_env_channelOutQ env)
      banners drained `shouldSatisfy`
        any ("/0:" `T.isInfixOf`)
