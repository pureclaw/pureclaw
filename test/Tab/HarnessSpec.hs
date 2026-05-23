{-# LANGUAGE LambdaCase #-}
-- |
-- Module      : Tab.HarnessSpec
-- Description : Harness-tab DoDs (L\/I subsets) — WU7 flips I4 + L2 green.
--
-- Enumerates harness-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the KindHarness subsets of L-series and
-- I-series. WU7 lands:
--
--   * L2 — '/tab close' on KindHarness is destructive (calls '_hh_stop',
--          does NOT archive a transcript).
--   * I4 — slash-prefixed direct-inject is opaque text to the harness
--          (the harness sees the literal '/cmd' bytes).
--
-- Other H-series KindHarness items (H4, H6–H11) are exercised through
-- the WU6 'Handles.TabSpec' KindAi tests for the AI-tab factory path;
-- the harness-tab equivalents live here.
module Tab.HarnessSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( atomically
  , newTBQueueIO
  , newTVarIO
  , tryReadTBQueue
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either qualified
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
import System.Exit qualified
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types
import PureClaw.Handles.Channel (mkNoOpChannelHandle)
import PureClaw.Handles.Harness
  ( HarnessHandle (..)
  , HarnessStatus (..)
  )
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Tab
  ( CloseMode (..)
  , HarnessSpawnArgs (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabStatus (..)
  , mkTabIndex
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  )
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tab.Harness (mkTabHarness)
import PureClaw.Tools.Registry (emptyRegistry)


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | Per-test capture of harness side effects so the test can assert on
-- what got 'sent' or whether '_hh_stop' was invoked.
data HarnessCapture = HarnessCapture
  { _hc_sends   :: IORef [ByteString]
  , _hc_stopped :: IORef Int  -- count of _hh_stop invocations
  , _hc_outputs :: IORef [ByteString]
    -- ^ Queue of outputs the fake harness will produce on each
    -- '_hh_receive' call. Test seeds this; head is consumed per call.
  }

newHarnessCapture :: IO HarnessCapture
newHarnessCapture = HarnessCapture
  <$> newIORef []
  <*> newIORef 0
  <*> newIORef []

-- | Build a fake 'HarnessHandle' that records sends and serves a
-- pre-seeded list of outputs.
mkFakeHarness :: HarnessCapture -> HarnessHandle
mkFakeHarness cap = HarnessHandle
  { _hh_send    = \bs -> atomicModifyIORef' (_hc_sends cap) (\xs -> (xs <> [bs], ()))
  , _hh_receive = atomicModifyIORef' (_hc_outputs cap) $ \case
      []     -> ([], BS.empty)
      (h:t)  -> (t, h)
  , _hh_name    = "fake-harness"
  , _hh_session = "fake-session"
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = atomicModifyIORef' (_hc_stopped cap) (\n -> (n + 1, ()))
  }

-- | Build a minimal 'AgentEnv' with an empty harness registry so
-- 'mkTabHarness' can look up by name. Tests that want a working
-- harness call 'registerHarness' on the returned env's
-- '_env_harnesses' IORef.
mkHarnessTestEnv :: IO AgentEnv
mkHarnessTestEnv = do
  let routing = defaultRoutingConfig
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
    , _env_channel           = mkNoOpChannelHandle
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

-- | Insert a 'HarnessHandle' into the env's '_env_harnesses' under the
-- given name so 'mkTabHarness' can adopt it by lookup.
registerHarness :: AgentEnv -> Text -> HarnessHandle -> IO ()
registerHarness env name hh = atomicModifyIORef' (_env_harnesses env)
  (\m -> (Map.insert name hh m, ()))

-- | Spawn a harness tab. Fails the test if the factory returns 'Left'.
spawnHarnessTab :: AgentEnv -> Int -> Text -> IO TabHandle
spawnHarnessTab env n name = do
  r <- mkTabHarness env (ti n) HarnessSpawnArgs { _harness_requestedName = name }
  case r of
    Right h -> pure h
    Left e  -> do
      expectationFailure ("expected Right TabHandle; got Left " <> show e)
      error "unreachable"

-- | Briefly yield so the drainer\/writer helper threads get a chance
-- to run.
yieldAwhile :: IO ()
yieldAwhile = threadDelay 50000  -- 50ms

-- | Drain channel-out queue (non-blocking).
drainOut :: AgentEnv -> IO [(OutputSource, ChannelEvent)]
drainOut env = go []
  where
    go acc = do
      mv <- atomically (tryReadTBQueue (_env_channelOutQ env))
      case mv of
        Nothing -> pure (reverse acc)
        Just v  -> go (v : acc)


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "L-series (Harness subset) — close lifecycle (WU7)" $ do
    it ("L2 (WU7): /tab close on KindHarness — destructive: _hh_stop"
        <> " runs, registry entry unaffected (registry-side eviction"
        <> " lands in WU9), transcript NOT archived") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-l2" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-l2"
      _tabHandle_close h CloseGraceful
      stopped <- readIORef (_hc_stopped cap)
      stopped `shouldSatisfy` (>= 1)
      -- No transcript path was touched — the test session handle is a
      -- no-op so the strongest assertion we can make here is that
      -- close itself was the destructive path (above) and that close
      -- is idempotent (next test).

    it "L2-idempotent (H6 KindHarness): close is idempotent" $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-idem" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-idem"
      _tabHandle_close h CloseGraceful
      _tabHandle_close h CloseGraceful  -- repeat — no throw
      _tabHandle_close h CloseForce     -- still no throw
      -- The destructive _hh_stop only runs on the FIRST close
      -- (subsequent invocations are no-ops per the idempotency flag).
      stopped <- readIORef (_hc_stopped cap)
      stopped `shouldBe` 1

  describe "H-series (Harness subset) — handle contract (WU7)" $ do
    it "H7 (KindHarness): _tabHandle_close never throws on graceful + force" $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-h7" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-h7"
      _tabHandle_close h CloseGraceful `shouldReturn` ()
      _tabHandle_close h CloseForce    `shouldReturn` ()

    it ("H8 (KindHarness): close calls _hh_stop on the underlying"
        <> " HarnessHandle (destructive)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-h8" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-h8"
      _tabHandle_close h CloseGraceful
      stopped <- readIORef (_hc_stopped cap)
      stopped `shouldBe` 1

    it ("H9 (KindHarness): --force is a no-op distinct from graceful"
        <> " — both are destructive for non-AI kinds (no archive)") $ do
      -- Two separate tabs so we can observe stop on each.
      env <- mkHarnessTestEnv
      cap1 <- newHarnessCapture
      cap2 <- newHarnessCapture
      registerHarness env "h-graceful" (mkFakeHarness cap1)
      h1 <- spawnHarnessTab env 0 "h-graceful"
      _tabHandle_close h1 CloseGraceful
      stopped1 <- readIORef (_hc_stopped cap1)
      stopped1 `shouldBe` 1
      registerHarness env "h-force" (mkFakeHarness cap2)
      h2 <- spawnHarnessTab env 1 "h-force"
      _tabHandle_close h2 CloseForce
      stopped2 <- readIORef (_hc_stopped cap2)
      stopped2 `shouldBe` 1

    it ("H11 (KindHarness): _tabHandle_name routes through"
        <> " sanitizeTabName — a name containing ANSI escapes is"
        <> " rejected as Left TabInvalidName") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "\ESC[31mboom" (mkFakeHarness cap)
      r   <- mkTabHarness env (ti 0)
               HarnessSpawnArgs { _harness_requestedName = "\ESC[31mboom" }
      case r of
        Left (TabInvalidName _) -> pure ()
        Left other ->
          expectationFailure
            ("expected Left TabInvalidName; got Left " <> show other)
        Right _ ->
          expectationFailure "expected Left TabInvalidName; got Right"

    it ("H12 (KindHarness): _tabHandle_kind is KindHarness (pure"
        <> " field)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-h12" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-h12"
      _tabHandle_kind h `shouldBe` KindHarness
      _tabHandle_close h CloseGraceful

    it ("H4 (KindHarness): _tabHandle_send is non-blocking; overflow"
        <> " surfaces Left TabConcurrencyLimit") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      -- A blocking harness: _hh_send never returns, so the writer
      -- thread cannot drain the queue, and the producer side fills it
      -- to capacity.
      let blockingHh = (mkFakeHarness cap)
            { _hh_send = \_ -> threadDelay 1000000  -- 1s (effectively
                                                    -- blocked vs the
                                                    -- 50ms test window)
            }
      registerHarness env "h-h4" blockingHh
      h   <- spawnHarnessTab env 0 "h-h4"
      -- Default _rc_inputQueueBound is 64; burst >> bound to trigger.
      results <- mapM (\i ->
                        _tabHandle_send h
                          ("msg-" <> T.pack (show (i :: Int))))
                      [1 .. 200]
      let overflowErrs = Data.Either.lefts results
      overflowErrs `shouldSatisfy` (not . null)
      mapM_ (\e -> show e `shouldContain` "TabConcurrencyLimit") overflowErrs
      _tabHandle_close h CloseGraceful

  describe "I-series (Harness subset) — direct-inject opaque text (WU7)" $ do
    it ("I4 (WU7): non-AI tab (Harness) treats slash-prefix on"
        <> " direct-inject as opaque text — '/0 /pwd' sent to harness"
        <> " as literal '/pwd'; no slash-command parser in non-AI tabs") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-i4" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-i4"
      -- The dispatcher would strip "/0 " and forward "/pwd" to the
      -- tab. The factory must NOT re-parse the slash; it must enqueue
      -- the bytes verbatim for the writer thread to forward.
      r <- _tabHandle_send h "/pwd"
      r `shouldBe` Right ()
      yieldAwhile
      sends <- readIORef (_hc_sends cap)
      sends `shouldContain` ["/pwd"]
      _tabHandle_close h CloseGraceful

    it ("H13 / I4 (KindHarness): _tabHandle_enqueueSlash returns"
        <> " Left TabUnsupportedCommand without enqueueing — harness"
        <> " tabs do not run slash commands") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-h13" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-h13"
      r <- _tabHandle_enqueueSlash h Slash.CmdHelp
      case r of
        Left (TabUnsupportedCommand _) -> pure ()
        other ->
          expectationFailure
            ("expected Left TabUnsupportedCommand; got " <> show other)
      -- No bytes should have been forwarded to the harness.
      yieldAwhile
      sends <- readIORef (_hc_sends cap)
      sends `shouldBe` []
      _tabHandle_close h CloseGraceful

  describe "D5 (Harness subset) — FullMsg emission (WU7)" $ do
    it ("D5 (Harness): drainer emits FullMsg via _env_channelOutQ when"
        <> " the tab is focused; non-empty output round-trips to the"
        <> " queue as (SrcTab idx, FullMsg idx text)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      -- Seed one non-empty output that the drainer will consume.
      writeIORef (_hc_outputs cap) ["hello from harness\n"]
      registerHarness env "h-d5" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-d5"
      -- Focus the tab so the producer-side enqueue fires.
      writeIORef (_env_focus env) (Just (ti 0))
      -- Wait a couple of drainer ticks (drainerSleepMicros = 100ms).
      threadDelay 250000  -- 250ms
      drained <- drainOut env
      let fullMsgs = [t | (SrcTab _, FullMsg _ t) <- drained]
      fullMsgs `shouldSatisfy` any (T.isInfixOf "hello from harness")
      _tabHandle_close h CloseGraceful

    it ("D4 (Harness): non-focused tab — drainer skips the producer"
        <> " enqueue work (no SrcTab events on the queue)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      writeIORef (_hc_outputs cap) ["silent output\n"]
      registerHarness env "h-d4" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-d4"
      -- Focus stays Nothing.
      threadDelay 250000
      drained <- drainOut env
      let tabEvents = [() | (SrcTab _, _) <- drained]
      tabEvents `shouldBe` []
      _tabHandle_close h CloseGraceful

  describe "WU7 coverage — lookup failure, status, drainer lifecycle" $ do
    it ("mkTabHarness with unknown harness name returns"
        <> " Left TabNotFound") $ do
      env <- mkHarnessTestEnv
      -- No harness registered with this name.
      r <- mkTabHarness env (ti 0)
             HarnessSpawnArgs { _harness_requestedName = "nope" }
      case r of
        Left (TabNotFound _) -> pure ()
        Left other ->
          expectationFailure
            ("expected Left TabNotFound; got Left " <> show other)
        Right _ ->
          expectationFailure "expected Left TabNotFound; got Right"

    it ("status after spawn is Idle (sentinel replaced before mkTabHarness"
        <> " returns)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-status" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-status"
      st <- _tabHandle_status h
      case st of
        Idle _ -> pure ()
        other ->
          expectationFailure
            ("expected Idle status after spawn; got " <> show other)
      _tabHandle_close h CloseGraceful

    it ("drainer terminates silently when the harness exits"
        <> " (HarnessExited)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      -- A harness that immediately reports exited.
      let exitedHh = (mkFakeHarness cap)
            { _hh_status = pure
                (HarnessExited System.Exit.ExitSuccess)
            }
      registerHarness env "h-exit" exitedHh
      h   <- spawnHarnessTab env 0 "h-exit"
      -- Give the drainer a tick to observe the exited status and
      -- terminate via HarnessExitedSignal. The drainer hits
      -- '_hh_status' first thing on each iteration, so this triggers
      -- the silent-exit path on the very first tick. We wait long
      -- enough (200 ms) to outlast both 'drainerSleepMicros' and any
      -- thread-scheduling jitter.
      threadDelay 200000
      -- The drainer's silent-exit path is what we're exercising; the
      -- status should still be Idle (not Crashed) because
      -- HarnessExitedSignal is swallowed in 'safelyRun'.
      st <- _tabHandle_status h
      case st of
        Idle _ -> pure ()
        other ->
          expectationFailure
            ("expected Idle status after harness exit; got " <> show other)
      _tabHandle_close h CloseGraceful

    it ("crash handler: a helper thread that synchronously throws"
        <> " transitions the status to Crashed") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      -- A harness whose _hh_status raises a synchronous exception.
      let crashyHh = (mkFakeHarness cap)
            { _hh_status = error "broken harness status"
            }
      registerHarness env "h-crash" crashyHh
      h   <- spawnHarnessTab env 0 "h-crash"
      -- Let the drainer hit the broken status read.
      threadDelay 250000
      st <- _tabHandle_status h
      case st of
        Crashed _ -> pure ()
        other ->
          -- The writer thread may have crashed instead, or both —
          -- accept any Crashed transition.
          expectationFailure
            ("expected Crashed status after crashy harness; got "
              <> show other)
      _tabHandle_close h CloseGraceful

    it ("writer thread forwards bytes to _hh_send (round-trip"
        <> " through the bounded queue)") $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "h-writer" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "h-writer"
      _ <- _tabHandle_send h "ping"
      _ <- _tabHandle_send h "pong"
      yieldAwhile
      sends <- readIORef (_hc_sends cap)
      sends `shouldContain` ["ping"]
      sends `shouldContain` ["pong"]
      _tabHandle_close h CloseGraceful

    it "_tabHandle_name is wrapped in TabName via sanitizeTabName" $ do
      env <- mkHarnessTestEnv
      cap <- newHarnessCapture
      registerHarness env "happy-name" (mkFakeHarness cap)
      h   <- spawnHarnessTab env 0 "happy-name"
      let TabName n = _tabHandle_name h
      n `shouldBe` "happy-name"
      _tabHandle_close h CloseGraceful


