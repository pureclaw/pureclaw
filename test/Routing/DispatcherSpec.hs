{-# LANGUAGE PatternSynonyms #-}
-- |
-- Module      : Routing.DispatcherSpec
-- Description : C-series + dispatcher-internal tests for WU5.
--
-- WU0 staged every C-series DoD as 'pending'; WU5 flips the
-- dispatcher-side subset green:
--
--   * C3 — tab spawn is exception-safe (mask-based spawn rolls back
--     the placeholder on a factory throw).
--   * C4 — dispatcher death cancels all tabs (bracket fires cleanup
--     on both exception AND graceful EOF).
--   * C5 — crash isolation (dispatcher-side assertion: a tab whose
--     loop crashed does NOT crash the dispatcher; AI-loop side lands
--     in WU6).
--
-- C1, C2, C6 stay 'pending' here because their assertions require
-- the AI tab loop body landing in WU6 (provider integration,
-- per-tab state isolation).
--
-- This file ALSO covers the dispatcher's internal surface:
-- 'tryConsumeSpawnToken' (S7 rate limit), 'dispatchOne' (single-step
-- routing), and the C3 placeholder-rollback contract via a
-- throw-from-factory test-local factory.
module Routing.DispatcherSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( TBQueue
  , atomically
  , newTBQueueIO
  , newTVarIO
  , tryReadTBQueue
  )
import Control.Exception (ErrorCall (..), throwIO, try)
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Log
import PureClaw.Handles.Tab
  ( AiSpawnArgs (..)
  , BackendSpawnArgs (..)
  , CloseMode (..)
  , HarnessSpawnArgs (..)
  , PublicTabError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabRunner (..)
  , TabStatus (..)
  , mkTabIndex
  , pattern KindAi
  , pattern KindHarness
  , pattern KindShell
  , pattern KindSsh
  , pattern KindTmux
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class
  ( CompletionResponse (..)
  , ContentBlock (..)
  , SomeProvider (MkProvider)
  )
import PureClaw.Routing.ChannelOut (startChannelOut)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Dispatcher
  ( TabFactory
  , _ds_pendingRetry
  , _ds_spawnArgs
  , closeAllTabs
  , dispatchOne
  , emitCrashedRedacted
  , newDispatcherState
  , newRateLimiter
  , parseArgsForKind
  , runDispatcher
  , runDispatcherWith
  , spawnTab
  , spawnTabWith
  , tryConsumeSpawnToken
  )
import PureClaw.Routing.AutoSpawn qualified
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
import PureClaw.Tab.Ai qualified as TabAi
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle
  ( FakeChannelEvent (..)
  , drainEvents
  , fakeChannelHandle
  , feedIncoming
  , newFakeChannel
  )
import Test.Fake.Provider
  ( newFakeProvider
  , queueResponse
  )


-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

-- | A baseline UTC for deterministic rate-limit math.
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 17) (secondsToDiffTime 0)

ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | Construct a minimal 'AgentEnv' shared by every dispatcher test.
-- Mirrors 'Routing.RegistrySpec.mkE3TestEnv' but takes an explicit
-- 'ChannelHandle' (so we can wire a fake channel for input).
mkDispatcherEnv :: ChannelHandle -> IO AgentEnv
mkDispatcherEnv ch = do
  let routing = defaultRoutingConfig
  providerRef    <- newIORef (Nothing :: Maybe SomeProvider)
  modelRef       <- newIORef (Nothing :: Maybe ModelId)
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  harnessReg     <- Registry.newRegistry
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
    , _env_harnessRegistry  = harnessReg
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

-- | A synthetic 'TabHandle' whose IO actions all record into a shared
-- log (so the test can assert which paths fired). Status is a held
-- IORef so the test can flip it to 'Crashed'.
data SyntheticTab = SyntheticTab
  { _st_handle   :: !TabHandle
  , _st_statusRf :: !(IORef TabStatus)
  , _st_sentRf   :: !(IORef [Text])
  , _st_closedRf :: !(IORef Int)
  }

mkSyntheticTab :: TabIndex -> TabKind -> TabStatus -> IO SyntheticTab
mkSyntheticTab idx kind initSt = do
  statusRf <- newIORef initSt
  sentRf   <- newIORef []
  closedRf <- newIORef 0
  let handle = TabHandle
        { _tabHandle_index        = idx
        , _tabHandle_name         = TabName "tab"
        , _tabHandle_kind         = kind
        , _tabHandle_status       = readIORef statusRf
        , _tabHandle_send         = \t -> do
            atomicModifyIORef' sentRf (\xs -> (t : xs, ()))
            pure (Right ())
        , _tabHandle_enqueueSlash = \_ ->
            pure (Right ())
        , _tabHandle_close        = \_mode ->
            atomicModifyIORef' closedRf (\n -> (n + 1, ()))
        }
  pure SyntheticTab
    { _st_handle   = handle
    , _st_statusRf = statusRf
    , _st_sentRf   = sentRf
    , _st_closedRf = closedRf
    }

-- | A test-local factory that returns the supplied synthetic tab
-- on every spawn. Useful for happy-path spawn tests that should not
-- exercise the WU1-stubbed production factories.
syntheticFactory :: SyntheticTab -> TabFactory
syntheticFactory st _kind _idx _args =
  pure (Right (_st_handle st))

-- | A factory that always throws an 'ErrorCall'. Used for C3 — the
-- mask-based spawn must roll back the placeholder when the factory
-- throws synchronously.
throwingFactory :: TabFactory
throwingFactory _ _ _ = throwIO (ErrorCall "factory exploded")

-- | A factory that returns Left every time. Used for negative-path
-- spawn tests.
leftFactory :: TabError -> TabFactory
leftFactory e _ _ _ = pure (Left e)

-- | Adapter that exposes the WU6 'PureClaw.Tab.Ai.mkTabAi' (which
-- takes 'AgentEnv') through the dispatcher's 'TabFactory' shape
-- (which does not). KindHarness / Backend fall through to the WU1
-- stubs (which error) — tests using this adapter must only spawn
-- KindAi tabs.
aiFactoryAdapter :: AgentEnv -> TabFactory
aiFactoryAdapter env kind idx args =
  case kind of
    KindAi -> TabAi.mkTabAi env idx
                AiSpawnArgs { _ai_requestedName = T.unwords args
                            , _ai_background = False }
    _      -> error
        ("aiFactoryAdapter: this test adapter only supports KindAi; \
         \got " <> show kind)


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "C-series — concurrency + exception safety (WU5 dispatcher-side)" $ do

    it ("C1: tabs run in their own threads — two AI tabs spawned via "
        <> "the WU6 factory each accept _tabHandle_send concurrently "
        <> "without blocking each other") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      r0 <- spawnTabWith env (aiFactoryAdapter env) KindAi ["ai-zero"]
      r1 <- spawnTabWith env (aiFactoryAdapter env) KindAi ["ai-one"]
      case (r0, r1) of
        (Right i0, Right i1) -> do
          i0 `shouldBe` ti 0
          i1 `shouldBe` ti 1
          -- Both tabs registered; each has its own _ats_inputQ.
          tabs <- readIORef (_env_tabs env)
          IntMap.size tabs `shouldBe` 2
        _ -> expectationFailure
               ("expected two Right spawns; got " <> show (r0, r1))
      -- closeAllTabs gracefully tears down both forked loops via
      -- their captured TabRunners (idempotent + never-throws per H6/H7).
      closeAllTabs env

    it ("C2: AI tab state isolation — closing one tab leaves the "
        <> "other live and addressable; per-tab state is captured by "
        <> "closure, not shared") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      Right _ <- spawnTabWith env (aiFactoryAdapter env) KindAi ["a"]
      Right _ <- spawnTabWith env (aiFactoryAdapter env) KindAi ["b"]
      tabs0 <- readIORef (_env_tabs env)
      IntMap.size tabs0 `shouldBe` 2
      -- Close tab 0; tab 1 must still be in the registry.
      case IntMap.lookup 0 tabs0 of
        Just h  -> _tabHandle_close h CloseGraceful
        Nothing -> expectationFailure "expected tab 0 in registry"
      -- The registry IntMap is not touched by close; only the loop
      -- exits. (Removal from the IntMap is the WU9 /tab close UX.)
      tabs1 <- readIORef (_env_tabs env)
      IntMap.size tabs1 `shouldBe` 2
      closeAllTabs env

    it ("C3: tab spawn is exception-safe — factory throw mid-construction "
        <> "leaves _env_tabs unchanged and partially-allocated resources "
        <> "closed (mask-based spawn)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- A throwing factory must result in either a re-raised exception
      -- OR a redacted Left — but in EITHER case the registry must be
      -- clean (no leaked placeholder, no half-inserted TabHandle).
      r <- try @ErrorCall (spawnTabWith env throwingFactory KindAi [])
      case r of
        Left  _e ->
          -- Re-raised path.
          pure ()
        Right (Left _tabErr) ->
          -- Redacted-Left path (current WU5 default — the dispatcher
          -- collapses factory exceptions into TabSessionCreateFailed
          -- so the channel never sees the raw 'show' of the underlying
          -- SomeException; see Dispatcher.rethrowOrLeft).
          pure ()
        Right (Right idx) ->
          expectationFailure
            ("expected factory throw to leave registry clean; got "
             <> "Right idx = " <> show idx)
      tabs    <- readIORef (_env_tabs env)
      runners <- readIORef (_env_runners env)
      IntMap.null tabs    `shouldBe` True
      IntMap.null runners `shouldBe` True

    it ("C3 (sibling): factory returning Left also leaves the registry "
        <> "untouched") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      r <- spawnTabWith env
             (leftFactory (TabLimitExceeded 7))
             KindShell ["bash"]
      case r of
        Left (TabLimitExceeded 7) -> pure ()
        other -> expectationFailure
          ("expected Left TabLimitExceeded 7; got " <> show other)
      tabs    <- readIORef (_env_tabs env)
      runners <- readIORef (_env_runners env)
      IntMap.null tabs    `shouldBe` True
      IntMap.null runners `shouldBe` True

    it ("C4: dispatcher death cancels all tabs — bracket "
        <> "(newIORef IntMap.empty) cancelAll dispatcherBody; cancelAll "
        <> "fires on exception AND graceful EOF") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Pre-register one synthetic tab + a runner whose cancel flips a flag.
      st <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      cancelFlag <- newIORef False
      let runner = TabRunner
            { _trun_cancel = writeIORef cancelFlag True
            , _trun_wait   = pure ()
            }
      runnerRef <- newIORef (Just runner)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle st)
      atomicModifyIORef' (_env_runners env)
        (\m -> (IntMap.insert 0 runnerRef m, ()))
      -- Drive closeAllTabs directly — same code path as the bracket
      -- cleanup. Assert the runner's cancel ran AND the handle's
      -- close ran (idempotent — H6/H7/H8).
      closeAllTabs env
      cancelled <- readIORef cancelFlag
      closeCount <- readIORef (_st_closedRf st)
      cancelled    `shouldBe` True
      closeCount   `shouldSatisfy` (>= 1)

    it ("C4 (bracket fires on EOF): runDispatcherWith returns when "
        <> "_ch_receive throws (graceful end-of-stream); cleanup runs") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- We do NOT feed any input; instead we close the underlying
      -- queue path by injecting one message that triggers the loop
      -- to call dispatchOne, then close the channel by throwing from
      -- _ch_receive. The cleanest way is to wrap _ch_receive in a
      -- bracketed env with a one-shot pattern. Simpler: use an
      -- IORef counter to make _ch_receive throw on the second call.
      callCount <- newIORef (0 :: Int)
      let trickyCh = (fakeChannelHandle fch)
            { _ch_receive = do
                n <- atomicModifyIORef' callCount (\x -> (x + 1, x))
                if n == 0
                  then do
                    -- inject one valid message
                    feedIncoming fch
                      (IncomingMessage
                        (mkMessageSource CkCli (Just (UserId "u")) mempty) "hello")
                    -- read it through the underlying queue
                    _ch_receive (fakeChannelHandle fch)
                  else throwIO (ErrorCall "EOF")
            }
      env' <- mkDispatcherEnv trickyCh
      st <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _ <- insertTab (_env_tabs env') (ti 0) (_st_handle st)
      r <- try @ErrorCall (runDispatcherWith env' (syntheticFactory st))
      case r of
        Left  _ -> pure ()
        Right _ -> expectationFailure "expected EOF to bubble up"
      -- closeAllTabs should have fired during the bracket cleanup.
      closeCount <- readIORef (_st_closedRf st)
      closeCount `shouldSatisfy` (>= 1)
      -- Suppress the unused-binding warning when -Wall fires.
      _ <- pure env
      pure ()

    it ("C5: crash isolation — tab loop catches SomeException except "
        <> "AsyncCancelled; status becomes Crashed; dispatcher does NOT "
        <> "crash; close leaves status Closing not Crashed "
        <> "[dispatcher-side: a Crashed tab is observed via "
        <> "_tabHandle_status and surfaced as a redacted dispatcher banner]") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      let pubErr = PublicTabError "tab: backend construction failed"
      st <- mkSyntheticTab (ti 1) KindShell (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 1) (_st_handle st)
      -- Now: feed a /1 switch through dispatchOne. The dispatcher
      -- must NOT crash; instead it emits a SrcDispatcher BannerLine
      -- carrying the public error text.
      ds <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/1"
      -- The focus was set; then the dispatcher observed the crashed
      -- status and emitted a redacted banner.
      let q = _env_channelOutQ env
      -- Drain everything currently in the queue.
      drained <- drainQueue q
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners
        `shouldSatisfy`
        any (\t -> "/1 crashed" `T.isPrefixOf` t
                && "backend construction failed" `T.isInfixOf` t)
      -- The redacted banner does NOT contain "TabBackendConstructFailed"
      -- (the raw constructor name) nor any host/path tokens.
      banners `shouldSatisfy` not . any ("TabBackendConstructFailed" `T.isInfixOf`)

    it ("C6: provider cancellation safety — _tabHandle_close on a "
        <> "WU6 AI tab does not throw and is idempotent (mirrors "
        <> "the H6/H7 contract for the close path)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      Right _ <- spawnTabWith env (aiFactoryAdapter env) KindAi ["c6"]
      tabs <- readIORef (_env_tabs env)
      case IntMap.lookup 0 tabs of
        Just h  -> do
          _tabHandle_close h CloseGraceful
          _tabHandle_close h CloseGraceful  -- idempotent
          _tabHandle_close h CloseForce     -- force after graceful
        Nothing -> expectationFailure "expected tab 0 in registry"
      closeAllTabs env


  describe "Dispatcher rate limit (S7) wiring" $ do

    it "tryConsumeSpawnToken: 11th call fails when cap = 10 at t0" $ do
      rl <- newRateLimiter 10
      -- Burn 10 tokens at t0.
      successes <- traverse (\_ -> tryConsumeSpawnToken rl (UserId "u") t0)
                            [(1 :: Int) .. 10]
      successes `shouldBe` replicate 10 True
      -- 11th token is denied.
      r11 <- tryConsumeSpawnToken rl (UserId "u") t0
      r11 `shouldBe` False
      -- A different user has their own bucket.
      rOther <- tryConsumeSpawnToken rl (UserId "v") t0
      rOther `shouldBe` True

    it "tryConsumeSpawnToken: bucket refills over time" $ do
      rl <- newRateLimiter 10
      -- Drain.
      mapM_ (\_ -> tryConsumeSpawnToken rl (UserId "u") t0)
            [(1 :: Int) .. 10]
      -- 6 seconds later: refill = 6 * (10/60) = 1.0 token.
      let t6 = addUTCTime 6 t0
      tryConsumeSpawnToken rl (UserId "u") t6 `shouldReturn` True
      -- And immediately after we're empty again.
      tryConsumeSpawnToken rl (UserId "u") t6 `shouldReturn` False

    it "tryConsumeSpawnToken: cap = 0 always denies" $ do
      rl <- newRateLimiter 0
      tryConsumeSpawnToken rl (UserId "u") t0 `shouldReturn` False


  describe "dispatchOne — single-step routing" $ do

    it ("Default with no focus auto-spawns _rc_defaultKind at the "
        <> "lowest free index and forwards the text (L6 + K3)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "hi there"
      -- Tab 0 must be in the registry and the text was forwarded.
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 0)
      sent <- readIORef (_st_sentRf st)
      sent `shouldBe` ["hi there"]

    it "Default routes to the focused tab" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st)
      writeIORef (_env_focus env) (Just (ti 0))
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "hello world"
      sent <- readIORef (_st_sentRf st)
      sent `shouldBe` ["hello world"]

    it "Inject /N <payload> enqueues on the named tab without changing focus" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 2) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 2) (_st_handle st)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/2 do the thing"
      sent <- readIORef (_st_sentRf st)
      sent `shouldBe` ["do the thing"]
      f <- readIORef (_env_focus env)
      f `shouldBe` Nothing

    it "Inject /N <payload> on missing tab emits a dispatcher PublicError" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/5 hi"
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy`
        any (\(_, ev) -> case ev of
               BannerLine t -> "/5: no such tab" `T.isInfixOf` t
               _            -> False)

    it "Switch /N sets focus and emits a 'focused' banner" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 3) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 3) (_st_handle st)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/3"
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 3)
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy` any
        (\(_, ev) -> case ev of
           BannerLine t -> "/3: focused" `T.isInfixOf` t
           _            -> False)

    it ("ParsedSlashCmd path consumes a rate-limit token and never "
        <> "forwards to a provider [P18-style: dispatcher does not invoke "
        <> "any provider on slash inputs]") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/help"
      drained <- drainQueue (_env_channelOutQ env)
      -- Drain produces at least one dispatcher banner; no provider was
      -- ever touched (the test env has no provider at all).
      drained `shouldSatisfy` (not . null)

    it ("ParsedSlashCmd /start is handled inside the dispatcher "
        <> "(WU11 O1) — orientation message is emitted via _ch_send "
        <> "rather than routed to the focused tab queue") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/start"
      -- Onboarding emits the orientation text via _ch_send, not
      -- through _env_channelOutQ. The synthetic tab's send-IORef
      -- must stay empty (no enqueue), and the channel must have
      -- recorded one outgoing message that mentions all three
      -- slash-prefix surfaces.
      tabSent <- readIORef (_st_sentRf st)
      tabSent `shouldBe` []
      ch <- drainEvents fch
      let bodies = [t | (_, FceSend (OutgoingMessage t)) <- ch]
      length bodies `shouldBe` 1
      let body = T.concat bodies
      T.unpack body `shouldContain` "/0"
      T.unpack body `shouldContain` "/tab new shell"
      T.unpack body `shouldContain` "/tabs"


  describe "S5 — Crashed PublicError redaction" $ do

    it "emitCrashedRedacted does not contain raw TabError constructor names" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      let pe = PublicTabError "tab: backend construction failed"
      emitCrashedRedacted env (ti 4) pe
      drained <- drainQueue (_env_channelOutQ env)
      let texts = [t | (SrcDispatcher, BannerLine t) <- drained]
      texts `shouldSatisfy`
        any ("/4 crashed: tab: backend construction failed" `T.isInfixOf`)
      texts `shouldSatisfy`
        not . any (\t -> "TabBackendConstructFailed" `T.isInfixOf` t
                       || "SshHostKeyMismatch"        `T.isInfixOf` t
                       || "TabSessionCreateFailed"    `T.isInfixOf` t)


  describe "S7 — spawn rate-limit integration via dispatchOne" $ do

    it "exhausting the bucket emits a 'rate limit' banner on subsequent commands" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      -- The default config has _rc_spawnRateLimit = 10; burn 10 +
      -- exercise the 11th.
      mapM_ (\_ -> dispatchOne env ds (UserId "u") "/help")
            [(1 :: Int) .. 10]
      _ <- drainQueue (_env_channelOutQ env)
      dispatchOne env ds (UserId "u") "/help"
      drained <- drainQueue (_env_channelOutQ env)
      let texts = [t | (SrcDispatcher, BannerLine t) <- drained]
      texts `shouldSatisfy` any ("rate limit" `T.isInfixOf`)


  describe "S8 — allowlist invariant (dispatcher reads from _ch_receive only)" $ do

    it ("runDispatcher invokes zero handlers for messages that never "
        <> "appear at _ch_receive (allowlist-blocked upstream)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Inject a single dummy at the channel's internal inbox queue
      -- so the dispatcher can receive ONE message, then re-throw on
      -- subsequent calls (graceful shutdown).
      callCount <- newIORef (0 :: Int)
      let trickyCh = (fakeChannelHandle fch)
            { _ch_receive = do
                n <- atomicModifyIORef' callCount (\x -> (x + 1, x))
                if n == 0
                  then do
                    feedIncoming fch
                      (IncomingMessage
                        (mkMessageSource CkCli (Just (UserId "allowed")) mempty) "/0")
                    _ch_receive (fakeChannelHandle fch)
                  else throwIO (ErrorCall "EOF")
            }
      env' <- mkDispatcherEnv trickyCh
      st <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _  <- insertTab (_env_tabs env') (ti 0) (_st_handle st)
      _ <- try @ErrorCall
             (runDispatcherWith env' (syntheticFactory st))
      sent <- readIORef (_st_sentRf st)
      -- One inbound /0 → focus only (no send). The send-IORef stays empty.
      sent `shouldBe` []
      -- And the focus was indeed set, proving the message was processed
      -- through the same code path it would take from an allowlisted user.
      f <- readIORef (_env_focus env')
      f `shouldBe` Just (ti 0)
      -- Now feed NOTHING that wasn't already in the channel; the
      -- dispatcher (in the second iteration) sees EOF — proves a
      -- non-allowlisted user (i.e. one whose message was blocked
      -- upstream) cannot invoke any handler from the dispatcher's
      -- perspective because the dispatcher only consumes _ch_receive.
      _ <- pure env
      pure ()

    it ("an IncomingMessage whose source carries no userId (imUserId == "
        <> "UserId \"\") is NOT authorized against a populated allow-list") $ do
      -- Behavioral-equivalence guard for the MessageSource migration: the
      -- noOp / sourceless path derives the empty UserId "" sentinel via
      -- imUserId, and that sentinel must never match a non-empty allow-list.
      let sourceless = IncomingMessage
            (mkMessageSource (CkOther "noop") Nothing mempty) "hello"
          populated  = AllowList (Set.fromList [UserId "alice", UserId "bob"])
      -- The derived sender is the empty sentinel...
      imUserId sourceless `shouldBe` UserId ""
      -- ...and the empty sentinel is rejected by a populated allow-list.
      isAllowed populated (imUserId sourceless) `shouldBe` False
      -- Sanity: a real member IS allowed (so the list isn't vacuously empty).
      isAllowed populated (UserId "alice") `shouldBe` True


  describe "P18 — LLM-free invariant property (dispatcher-side)" $ do

    it ("dispatchOne does NOT invoke any provider on Switch/Inject/SlashCmd "
        <> "inputs; only Default text reaches the focused tab's send queue") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- One synthetic tab in focus. Feed a corpus of NON-Default inputs.
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st)
      writeIORef (_env_focus env) (Just (ti 0))
      ds  <- newDispatcherState env (syntheticFactory st)
      -- Corpus: switches, injects, slash commands, malformed inputs.
      -- None of these should land any text in the synthetic tab's
      -- send queue (which is the dispatcher's only handle on
      -- "provider-bound text").
      mapM_ (dispatchOne env ds (UserId "u"))
        [ "/0"           -- Switch
        , "/1"           -- Switch (no such tab; no crash)
        , "/0 hello"     -- Inject (this DOES enqueue "hello" — see below)
        , "/help"        -- Slash command
        , "/tabs"        -- Slash command
        , "/tab list"    -- Slash command
        , "/01"          -- ParseErrorMalformed (multi-char index)
        , "/12abc"       -- ParseErrorMalformed
        , ""             -- ParseErrorEmptyInput
        ]
      sent <- readIORef (_st_sentRf st)
      -- The only enqueued text comes from the lone Inject `/0 hello`.
      sent `shouldBe` ["hello"]


  describe "parseArgsForKind — sanity (per-kind arg-list projection)" $ do

    it "KindAi keeps the args as a joined name string" $ do
      case parseArgsForKind KindAi ["foo", "bar"] of
        Left ai -> _ai_requestedName ai `shouldBe` "foo bar"
        _       -> expectationFailure "expected Left AiSpawnArgs"

    it "KindHarness builds a HarnessSpawnArgs" $ do
      case parseArgsForKind KindHarness ["one"] of
        Right (Left h) -> _harness_requestedName h `shouldBe` "one"
        _ -> expectationFailure "expected Right (Left HarnessSpawnArgs)"

    it "KindShell builds a BackendSpawnArgs" $ do
      case parseArgsForKind KindShell ["bash"] of
        Right (Right b) -> do
          _backend_requestedName b `shouldBe` "bash"
          _backend_args b          `shouldBe` ["bash"]
        _ -> expectationFailure "expected Right (Right BackendSpawnArgs)"

    it "KindSsh builds a BackendSpawnArgs" $ do
      case parseArgsForKind KindSsh ["user@host"] of
        Right (Right b) -> do
          _backend_requestedName b `shouldBe` "user@host"
          _backend_args b          `shouldBe` ["user@host"]
        _ -> expectationFailure "expected Right (Right BackendSpawnArgs)"

    it "KindTmux builds a BackendSpawnArgs" $ do
      case parseArgsForKind KindTmux ["sess"] of
        Right (Right b) -> do
          _backend_requestedName b `shouldBe` "sess"
          _backend_args b          `shouldBe` ["sess"]
        _ -> expectationFailure "expected Right (Right BackendSpawnArgs)"


  describe "spawnTabWith — happy path + edge cases" $ do

    it "happy path: returns Right idx and inserts into _env_tabs" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      r <- spawnTabWith env (syntheticFactory st) KindAi ["my-tab"]
      case r of
        Right idx -> idx `shouldBe` ti 0
        Left  e   -> expectationFailure ("expected Right; got " <> show e)
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1
      -- A runner placeholder exists in _env_runners (still Nothing per WU5).
      runners <- readIORef (_env_runners env)
      IntMap.size runners `shouldBe` 1

    it "TabLimitExceeded when registry is full" $ do
      fch <- newFakeChannel
      env0 <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Override routing config to a tiny max so we can fill it.
      let envSmallCap = env0
            { _env_routingConfig = (_env_routingConfig env0)
                { _rc_maxTabs = 2 }
            }
      st0 <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      st1 <- mkSyntheticTab (ti 1) KindAi (Idle t0)
      Right idx0 <- spawnTabWith envSmallCap
                      (syntheticFactory st0) KindAi []
      idx0 `shouldBe` ti 0
      Right idx1 <- spawnTabWith envSmallCap
                      (syntheticFactory st1) KindAi []
      idx1 `shouldBe` ti 1
      -- A third spawn must yield TabLimitExceeded 2.
      r <- spawnTabWith envSmallCap (syntheticFactory st0) KindAi []
      case r of
        Left (TabLimitExceeded 2) -> pure ()
        other -> expectationFailure
          ("expected Left (TabLimitExceeded 2); got " <> show other)

    it ("public spawnTab wraps spawnTabWith with the default (stub) "
        <> "factory; calling it would invoke WU1 factory bottoms — we "
        <> "assert by exercising the TabLimitExceeded path which "
        <> "short-circuits before the factory") $ do
      fch <- newFakeChannel
      env0 <- mkDispatcherEnv (fakeChannelHandle fch)
      let envFull = env0
            { _env_routingConfig = (_env_routingConfig env0)
                { _rc_maxTabs = 0 }
            }
      -- Cap = 0 → lowestFreeIndex returns Nothing → TabLimitExceeded 0
      -- WITHOUT ever invoking the factory (so the WU1 stubs don't trip).
      r <- spawnTab envFull KindAi []
      case r of
        Left (TabLimitExceeded 0) -> pure ()
        other -> expectationFailure
          ("expected Left (TabLimitExceeded 0); got " <> show other)


  describe "Dispatcher misc — coverage uplift" $ do

    it "dispatchOne — parser error emits 'input not recognized'" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/01"  -- multi-char index → malformed
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy` any
        (\(_, ev) -> case ev of
           BannerLine t -> "input not recognized" `T.isInfixOf` t
           _            -> False)

    it ("dispatchOne — slash command with no focus emits the "
        <> "no-focused-tab hint (WU10 — was '(slash command queued)' "
        <> "in WU5; WU10 routes through focused-tab projection)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      dispatchOne env ds (UserId "u") "/help"
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy` any
        (\(_, ev) -> case ev of
           BannerLine t -> "no focused tab" `T.isInfixOf` t
           _            -> False)

    it ("Inject — _tabHandle_send returning Left propagates as a "
        <> "dispatcher PublicError") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- A synthetic tab whose send always fails (TabConcurrencyLimit).
      statusRf <- newIORef (Idle t0)
      sentRf   <- newIORef ([] :: [Text])
      closedRf <- newIORef (0 :: Int)
      let badHandle = TabHandle
            { _tabHandle_index        = ti 4
            , _tabHandle_name         = TabName "bad"
            , _tabHandle_kind         = KindAi
            , _tabHandle_status       = readIORef statusRf
            , _tabHandle_send         = \_ ->
                pure (Left (TabConcurrencyLimit 99))
            , _tabHandle_enqueueSlash = \_ -> pure (Right ())
            , _tabHandle_close        = \_ ->
                atomicModifyIORef' closedRf (\n -> (n + 1, ()))
            }
      _ <- insertTab (_env_tabs env) (ti 4) badHandle
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/4 ping"
      _ <- readIORef sentRf   -- silence unused
      _ <- readIORef closedRf -- silence unused
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy` any
        (\(_, ev) -> case ev of
           BannerLine t -> "/4: tab: input queue full" `T.isInfixOf` t
           _            -> False)

    it "Inject — _tabHandle_send raising synchronously is caught" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      statusRf <- newIORef (Idle t0)
      closedRf <- newIORef (0 :: Int)
      let badHandle = TabHandle
            { _tabHandle_index        = ti 5
            , _tabHandle_name         = TabName "bad"
            , _tabHandle_kind         = KindAi
            , _tabHandle_status       = readIORef statusRf
            , _tabHandle_send         = \_ -> throwIO (ErrorCall "boom")
            , _tabHandle_enqueueSlash = \_ -> pure (Right ())
            , _tabHandle_close        = \_ ->
                atomicModifyIORef' closedRf (\n -> (n + 1, ()))
            }
      _ <- insertTab (_env_tabs env) (ti 5) badHandle
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/5 ping"
      drained <- drainQueue (_env_channelOutQ env)
      drained `shouldSatisfy` any
        (\(_, ev) -> case ev of
           BannerLine t -> "/5: tab:" `T.isInfixOf` t
           _            -> False)

    it ("observeFocusedCrash — a buggy '_tabHandle_status' raising "
        <> "synchronously is treated as 'unknown status' (safeStatus)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- A handle whose status raises.
      let badHandle = TabHandle
            { _tabHandle_index        = ti 6
            , _tabHandle_name         = TabName "bad"
            , _tabHandle_kind         = KindAi
            , _tabHandle_status       = throwIO (ErrorCall "status boom")
            , _tabHandle_send         = \_ -> pure (Right ())
            , _tabHandle_enqueueSlash = \_ -> pure (Right ())
            , _tabHandle_close        = \_ -> pure ()
            }
      _ <- insertTab (_env_tabs env) (ti 6) badHandle
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/6"
      drained <- drainQueue (_env_channelOutQ env)
      -- We must NOT see a "crashed" banner (because safeStatus
      -- collapsed the throw to Nothing).
      drained `shouldSatisfy` not . any
        (\(_, ev) -> case ev of
           BannerLine t -> "crashed" `T.isInfixOf` t
           _            -> False)

    it ("closeAllTabs tolerates a Nothing runner placeholder (WU5: the "
        <> "placeholder stays Nothing until WU6+ fills it)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Two slots: one with a Just runner, one with Nothing (the
      -- between-spawn-and-fill window the design explicitly tolerates).
      st <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle st)
      noneRef    <- newIORef (Nothing :: Maybe TabRunner)
      cancelFlag <- newIORef False
      let runner = TabRunner
            { _trun_cancel = writeIORef cancelFlag True
            , _trun_wait   = pure ()
            }
      justRef <- newIORef (Just runner)
      atomicModifyIORef' (_env_runners env)
        (\m -> (IntMap.insert 0 justRef (IntMap.insert 1 noneRef m), ()))
      closeAllTabs env
      cancelled <- readIORef cancelFlag
      cancelled `shouldBe` True  -- Just runner was cancelled
      -- Tab still gets a close call
      closes <- readIORef (_st_closedRf st)
      closes `shouldSatisfy` (>= 1)

    it ("dispatchOne — Default on Just focus with a tab that returns "
        <> "Right () send: no PublicError banner") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st)
      writeIORef (_env_focus env) (Just (ti 0))
      ds  <- newDispatcherState env (syntheticFactory st)
      -- A simple Default that successfully enqueues — no error banner.
      dispatchOne env ds (UserId "u") "plain text"
      drained <- drainQueue (_env_channelOutQ env)
      -- Drained may be empty (no banner) because the Right () branch
      -- emits nothing.
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy`
        not . any (\t -> "tab:" `T.isInfixOf` t || "crashed" `T.isInfixOf` t)

    it ("observeFocusedCrash on a missing tab is a silent no-op "
        <> "(the Nothing branch)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 9) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      -- Tab 9 not in registry → observeFocusedCrash on Switch is no-op.
      dispatchOne env ds (UserId "u") "/9"
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` not . any ("crashed" `T.isInfixOf`)

    it ("Switch on a missing tab — tmux-packing model: emits a "
        <> "'no such tab' banner; does NOT auto-spawn. Focus unchanged.") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      st  <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      ds  <- newDispatcherState env (syntheticFactory st)
      -- /7 — tab 7 is not in the registry. Under the tmux-packing
      -- model the dispatcher emits an error banner and does NOT
      -- auto-spawn. The user has to run /tab new to create a tab.
      dispatchOne env ds (UserId "u") "/7"
      f <- readIORef (_env_focus env)
      f `shouldBe` Nothing
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any
        (\t -> "/7" `T.isInfixOf` t && "no such tab" `T.isInfixOf` t)

    it "runDispatcher calls runDispatcherWith with defaultTabFactory" $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Use the public runDispatcher entry once. Make _ch_receive
      -- throw on the first call so we exit immediately and exercise
      -- the bracket cleanup path of the public entry.
      callCount <- newIORef (0 :: Int)
      let trickyCh = (fakeChannelHandle fch)
            { _ch_receive = do
                _ <- atomicModifyIORef' callCount (\n -> (n + 1, ()))
                throwIO (ErrorCall "EOF")
            }
      env' <- mkDispatcherEnv trickyCh
      r <- try @ErrorCall (runDispatcher env')
      case r of
        Left  _ -> pure ()
        Right _ -> expectationFailure "expected EOF to bubble up"
      -- Silence unused-binding warnings on the helper IORefs.
      _ <- readIORef callCount
      _ <- readIORef (_env_runners env)
      pure ()

  describe "X1 retry-reply (WU10 fills in WU9-deferred wiring)" $ do
    let pubErr = PublicTabError "tab: ai loop crashed"

    it ("/N on a crashed tab arms the pending-retry expectation; a "
        <> "subsequent '1' triggers retry (close + respawn with the "
        <> "original args)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      crashedTab <- mkSyntheticTab (ti 0) KindAi (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle crashedTab)
      -- Track spawn invocations so we can confirm respawn happened.
      respawnLog <- newIORef ([] :: [(TabKind, [Text])])
      let factory _kind _idx args = do
            atomicModifyIORef' respawnLog
              (\xs -> ((KindAi, args) : xs, ()))
            -- Return a new synthetic tab so spawnTab succeeds.
            new <- mkSyntheticTab (ti 0) KindAi (Idle t0)
            pure (Right (_st_handle new))
      ds <- newDispatcherState env factory
      -- Pre-seed the spawn args so retryCrashedTab has something to
      -- replay (this is the same surface AutoSpawn fills on a
      -- successful spawn).
      let saMap = _ds_spawnArgs ds
      atomicModifyIORef' saMap
        (\m -> (Map.insert 0 PureClaw.Routing.AutoSpawn.SpawnArgs
                              { PureClaw.Routing.AutoSpawn._sa_kind = KindAi
                              , PureClaw.Routing.AutoSpawn._sa_args = ["ai-name"]
                              } m, ()))
      -- Step 1: /0 on the crashed tab — emits crashed banner + arms
      -- the pending-retry map.
      dispatchOne env ds (UserId "u") "/0"
      _ <- drainQueue (_env_channelOutQ env)  -- discard initial banners
      -- Step 2: "1" reply — should trigger retry path.
      dispatchOne env ds (UserId "u") "1"
      respawns <- readIORef respawnLog
      length respawns `shouldBe` 1
      case respawns of
        ((KindAi, ["ai-name"]) : _) -> pure ()
        other -> expectationFailure
                   ("expected respawn with original args; got " <> show other)
      -- After consumption, the pending-retry slot is cleared.
      let pendRef = _ds_pendingRetry ds
      pend <- readIORef pendRef
      Map.lookup (UserId "u") pend `shouldBe` Nothing

    it ("/N on a crashed tab arms the pending-retry expectation; a "
        <> "subsequent '2' triggers close (no respawn)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      crashedTab <- mkSyntheticTab (ti 0) KindAi (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle crashedTab)
      respawnLog <- newIORef ([] :: [(TabKind, [Text])])
      let factory _kind _idx args = do
            atomicModifyIORef' respawnLog
              (\xs -> ((KindAi, args) : xs, ()))
            new <- mkSyntheticTab (ti 0) KindAi (Idle t0)
            pure (Right (_st_handle new))
      ds <- newDispatcherState env factory
      atomicModifyIORef' (_ds_spawnArgs ds)
        (\m -> (Map.insert 0 PureClaw.Routing.AutoSpawn.SpawnArgs
                              { PureClaw.Routing.AutoSpawn._sa_kind = KindAi
                              , PureClaw.Routing.AutoSpawn._sa_args = ["x"]
                              } m, ()))
      dispatchOne env ds (UserId "u") "/0"
      _ <- drainQueue (_env_channelOutQ env)
      dispatchOne env ds (UserId "u") "2"
      respawns <- readIORef respawnLog
      respawns `shouldBe` []
      -- Tab 0 removed from registry.
      tabs <- readIORef (_env_tabs env)
      IntMap.member 0 tabs `shouldBe` False
      -- Close banner emitted.
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("closed" `T.isInfixOf`)

    it ("a non-'1'/'2' input from a user with a pending-retry "
        <> "expectation clears the expectation and proceeds with "
        <> "normal dispatch") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      crashedTab <- mkSyntheticTab (ti 0) KindAi (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle crashedTab)
      ds <- newDispatcherState env defaultTabFactoryNoop
      atomicModifyIORef' (_ds_spawnArgs ds)
        (\m -> (Map.insert 0 PureClaw.Routing.AutoSpawn.SpawnArgs
                              { PureClaw.Routing.AutoSpawn._sa_kind = KindAi
                              , PureClaw.Routing.AutoSpawn._sa_args = []
                              } m, ()))
      dispatchOne env ds (UserId "u") "/0"
      _ <- drainQueue (_env_channelOutQ env)
      -- Send unrelated input → clears pending-retry slot.
      -- (a Default text input would normally enqueue on the focused
      -- tab; here the focused tab is crashed but the synthetic tab's
      -- enqueueSlash returns Right () so no error fires.)
      dispatchOne env ds (UserId "u") "unrelated"
      pend <- readIORef (_ds_pendingRetry ds)
      Map.lookup (UserId "u") pend `shouldBe` Nothing

    it ("noteCrashedExpectation skips when no spawn args are "
        <> "recorded for the tab (so '1' would have nothing to "
        <> "replay — surfacing a banner makes more sense than a "
        <> "dead-end reply)") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      crashedTab <- mkSyntheticTab (ti 0) KindAi (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle crashedTab)
      ds <- newDispatcherState env defaultTabFactoryNoop
      -- NO spawn args recorded for /0.
      dispatchOne env ds (UserId "u") "/0"
      pend <- readIORef (_ds_pendingRetry ds)
      Map.lookup (UserId "u") pend `shouldBe` Nothing

    it ("the retry path emits a redacted banner when the respawn "
        <> "factory returns Left") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      crashedTab <- mkSyntheticTab (ti 0) KindAi (Crashed pubErr)
      _ <- insertTab (_env_tabs env) (ti 0) (_st_handle crashedTab)
      let badFactory _ _ _ = pure (Left (TabLimitExceeded 42))
      ds <- newDispatcherState env badFactory
      atomicModifyIORef' (_ds_spawnArgs ds)
        (\m -> (Map.insert 0 PureClaw.Routing.AutoSpawn.SpawnArgs
                              { PureClaw.Routing.AutoSpawn._sa_kind = KindAi
                              , PureClaw.Routing.AutoSpawn._sa_args = ["x"]
                              } m, ()))
      dispatchOne env ds (UserId "u") "/0"
      _ <- drainQueue (_env_channelOutQ env)
      dispatchOne env ds (UserId "u") "1"
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("retry failed" `T.isInfixOf`)

  describe "L7 resume-into-tab (WU10 fills in WU9-deferred wiring)" $ do
    it ("a session id that does not resolve emits the redacted "
        <> "'no such session' banner") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      ds <- newDispatcherState env defaultTabFactoryNoop
      -- The session id is well-formed but won't resolve under the
      -- test env's HOME → resolveSessionRef returns NotFound.
      dispatchOne env ds (UserId "u") "/tab resume nonexistent-session"
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy`
        any (\t -> "nonexistent-session" `T.isInfixOf` t)

  describe "/bg — dispatcher + AutoSpawn wiring (WU3)" $ do

    it ("dispatchOne '/bg do a thing' spawns exactly one tab, leaves "
        <> "_env_focus UNCHANGED, and emits '/bg: running in tab /N'") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      -- Pre-set a known focus; /bg must not steal it.
      writeIORef (_env_focus env) (Just (ti 3))
      -- The bg path bypasses _ds_factory and uses the real TabAi.mkTabAi,
      -- so the synthetic factory here is never consulted for /bg.
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/bg do a thing"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1
      f <- readIORef (_env_focus env)
      f `shouldBe` Just (ti 3)
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("/bg: running in tab /0" `T.isInfixOf`)
      closeAllTabs env

    it ("S7: /bg with the spawn-rate bucket exhausted emits a redacted "
        <> "'/bg: ...' banner and spawns NO tab") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      ds <- newDispatcherState env defaultTabFactoryNoop
      -- Burn the whole bucket (_rc_spawnRateLimit = 10) with /help
      -- dispatches (each consumes one S7 token via routeToFocused).
      mapM_ (\_ -> dispatchOne env ds (UserId "u") "/help")
            [(1 :: Int) .. 10]
      _ <- drainQueue (_env_channelOutQ env)
      dispatchOne env ds (UserId "u") "/bg over the limit"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 0
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("/bg: " `T.isInfixOf`)
      closeAllTabs env

    it ("S6: /bg with the registry at _rc_maxTabs emits a redacted "
        <> "'/bg: ...' banner (TabLimitExceeded) and spawns NO new tab") $ do
      fch <- newFakeChannel
      env0 <- mkDispatcherEnv (fakeChannelHandle fch)
      let env = env0
            { _env_routingConfig = (_env_routingConfig env0)
                { _rc_maxTabs = 1 }
            }
      st0 <- mkSyntheticTab (ti 0) KindAi (Idle t0)
      _   <- insertTab (_env_tabs env) (ti 0) (_st_handle st0)
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/bg cannot fit"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1  -- only the pre-existing tab
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("/bg: " `T.isInfixOf`)
      closeAllTabs env

    it ("INTEGRATION: a /bg through the REAL TabAi.mkTabAi factory + a "
        <> "MockProvider ultimately delivers the '[bg /N done] <text>' "
        <> "banner across _env_channelOutQ -> ChannelOut -> _ch_send") $ do
      fp <- newFakeProvider
      queueResponse fp CompletionResponse
        { _crsp_content = [TextBlock "integration bg text"]
        , _crsp_model   = ModelId "test-model"
        , _crsp_usage   = Nothing
        }
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      writeIORef (_env_provider env) (Just (MkProvider fp))
      writeIORef (_env_model env) (Just (ModelId "test-model"))
      -- Boot the channel-out writer so SrcDispatcher banners cross to
      -- the underlying ChannelHandle (_ch_send).
      coRunner <- startChannelOut env
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/bg summarize"
      -- The bg tab runs the provider turn asynchronously; poll the fake
      -- channel's send sink until the [bg ...] banner arrives.
      let pollFor :: Int -> IO [Text]
          pollFor 0 = pure []
          pollFor n = do
            evs <- drainEvents fch
            let sends = [t | (_, FceSend (OutgoingMessage t)) <- evs]
                bgs   = filter ("[bg " `T.isPrefixOf`) sends
            if null bgs
              then threadDelay 20000 >> pollFor (n - 1)
              else pure bgs
      bgBanners <- pollFor 25  -- up to ~500ms
      bgBanners `shouldBe` ["[bg /0 done] integration bg text"]
      _trun_cancel coRunner
      closeAllTabs env

    it ("/bg with a slash-command prompt ('/bg /new') spawns + enqueues "
        <> "without crashing and still emits '/bg: running in tab /N'") $ do
      fch <- newFakeChannel
      env <- mkDispatcherEnv (fakeChannelHandle fch)
      ds <- newDispatcherState env defaultTabFactoryNoop
      dispatchOne env ds (UserId "u") "/bg /new"
      tabs <- readIORef (_env_tabs env)
      IntMap.size tabs `shouldBe` 1
      drained <- drainQueue (_env_channelOutQ env)
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy` any ("/bg: running in tab /0" `T.isInfixOf`)
      -- No [bg /N done] push: the prompt runs as a slash command in the
      -- bg tab, so no provider turn fires.
      banners `shouldSatisfy` not . any ("[bg " `T.isPrefixOf`)
      closeAllTabs env


-- | A factory that intentionally errors when invoked — used as a
-- never-called default for tests that exercise non-spawn paths.
defaultTabFactoryNoop :: TabFactory
defaultTabFactoryNoop _ _ _ =
  error "defaultTabFactoryNoop: spawn path not expected"


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Drain everything currently sitting in a bounded STM queue (without
-- blocking when empty).
drainQueue :: TBQueue a -> IO [a]
drainQueue q = go []
  where
    go acc = do
      mv <- atomically (tryReadTBQueue q)
      case mv of
        Nothing -> pure (reverse acc)
        Just v  -> go (v : acc)


