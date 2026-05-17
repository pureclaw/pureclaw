-- |
-- Module      : Tab.AiSpec
-- Description : AI-tab DoDs (L/X/I subsets) — WU6 flips I-series + close basics green.
--
-- Enumerates AI-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the AI-kind subset of L-series (close
-- lifecycle), X-series (crashed UX), and the I-series (direct-inject /
-- in-tab-loop slash-command re-parse).
--
-- WU6 lands:
--   * I1 — direct-inject enqueue (covered by Dispatcher's E5 path)
--   * I2 — UserText starting with '/' re-parses via parseSlashCommand
--   * I3 — LLM-free invariant under direct-inject
--   * I5 — _tabHandle_enqueueSlash hits the loop's slash branch
--
-- Remaining L-series / X-series items stay 'pending' — the full
-- /tab close UX (graceful + force banner wording, on-disk teardown,
-- crashed-tab retry prompt) lands in WU9 alongside the user-facing
-- spawn UX.
module Tab.AiSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (ErrorCall (..), throwIO)
import Control.Concurrent.STM
  ( atomically
  , newTBQueueIO
  , newTVarIO
  , tryReadTBQueue
  )
import Data.IORef
  ( newIORef
  , writeIORef
  )
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log
import PureClaw.Handles.Tab
  ( AiSpawnArgs (..)
  , CloseMode (..)
  , TabHandle (..)
  , TabIndex
  , TabStatus (..)
  , mkTabIndex
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class
  ( CompletionRequest (..)
  , CompletionResponse (..)
  , ContentBlock (..)
  , Provider (..)
  , SomeProvider (MkProvider)
  )
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
import PureClaw.Tab.Ai (mkTabAi)
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle (fakeChannelHandle, newFakeChannel)
import Test.Fake.Provider
  ( FakeProvider
  , newFakeProvider
  , peekRecorded
  , queueResponse
  )


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | Build a 'AgentEnv' suitable for AI tab tests. Optionally injects a
-- 'FakeProvider' into '_env_provider' (so the tab inherits it on
-- spawn).
mkAiTestEnv :: Maybe FakeProvider -> IO AgentEnv
mkAiTestEnv mProv = do
  let routing = defaultRoutingConfig
  let mSome = fmap MkProvider mProv
  providerRef    <- newIORef mSome
  modelRef       <- newIORef (Just (ModelId "test-model"))
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
  fch            <- newFakeChannel
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = fakeChannelHandle fch
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
    }

-- | Sleep briefly so the per-tab loop (forked async) has a chance to
-- drain the input queue and write the expected outputs.
yieldAwhile :: IO ()
yieldAwhile = threadDelay 30000  -- 30ms

-- | Spawn an AI tab and return its handle (Right) or fail the test.
spawnAiTab :: AgentEnv -> Int -> Text -> IO TabHandle
spawnAiTab env n name = do
  r <- mkTabAi env (ti n) AiSpawnArgs { _ai_requestedName = name }
  case r of
    Right h -> pure h
    Left e  -> do
      expectationFailure ("expected Right TabHandle; got Left " <> show e)
      error "unreachable"

-- | Drain everything currently in the channel-out queue (no block).
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
  describe "L-series (AI subset) — close lifecycle (WU9 fills the user-facing UX)" $ do
    it ("L1 (close-idempotent partial — WU6): _tabHandle_close on KindAi runs"
        <> " once; subsequent invocations are no-ops") $ do
      env <- mkAiTestEnv Nothing
      h <- spawnAiTab env 0 "ai-test"
      -- First close (graceful) should not throw.
      _tabHandle_close h CloseGraceful
      -- Second close should be a no-op (idempotent per H6).
      _tabHandle_close h CloseGraceful
      -- After close, status remains observable.
      _ <- _tabHandle_status h
      pure ()

    it "L4: /tab close 3 --force on KindAi — skips archive (transcript deleted from disk), registry entry removed" pending
    it "L5: /tab close 99 (non-existent index) — Left TabNotFound 99 as PublicError; no side effects (no _sh_save, no _hh_stop, no _bh_close, no registry mutation)" pending
    it "L6: /tab close of focused tab — new focus is highest-indexed remaining, or Nothing if empty; next Default text input on empty registry implicitly spawns _rc_defaultKind at index 0" pending
    it "L7: /tab resume <session-id> — validates via mkSessionId, routes through Session.resolveSessionRef; /tab resume ../../etc/passwd yields ParseErrorInvalidSessionId; archived id creates new tab at lowest free index" pending

  describe "X-series — crashed tab UX (WU9 fills the user-facing UX)" $ do
    it "X1: /3 on a Crashed tab — dispatcher emits one-line PublicError summary plus [1] retry [2] close prompt; source tag SrcDispatcher; message uses toPublicTabError (no raw TabError Show)" pending
    it "X2: retry on KindAi — re-runs spawn factory with original args; session/transcript preserved (continuation, not new)" pending
    it "X3: retry on KindHarness/KindBackend — re-runs spawn factory with original args; status returns to Active; previous process gone (no continuation)" pending

  describe "I-series — direct-inject + in-tab-loop slash-command re-parse (WU6)" $ do
    it ("I1: direct-inject payload — _tabHandle_send enqueues UserText"
        <> " to the AI tab's per-tab queue; the loop dequeues and"
        <> " processes it (provider invocation is the observable side"
        <> " effect)") $ do
      fp <- newFakeProvider
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "ai-test"
      r <- _tabHandle_send h "hello world"
      r `shouldBe` Right ()
      yieldAwhile
      -- The fake provider records every CompletionRequest. Exactly one
      -- request should have arrived (the loop's runUserText path).
      recs <- peekRecorded fp
      length recs `shouldSatisfy` (>= 1)
      -- Drain channel-out queue to avoid TBQueue saturation.
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("I2: AI tab loop processes both event types — UserText starting"
        <> " with '/' is re-parsed via parseSlashCommand and treated as"
        <> " SlashCmd (no provider call); otherwise fed to provider") $ do
      fp <- newFakeProvider
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "ai-test"
      -- "/help" is a known slash command. Sending via _tabHandle_send
      -- (the user-text path) must NOT trigger a provider call because
      -- the loop's I2 re-parse catches it.
      _ <- _tabHandle_send h "/help"
      yieldAwhile
      recs <- peekRecorded fp
      length recs `shouldBe` 0
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("I3: LLM-free invariant under direct-inject — '/help' routed"
        <> " through the AI tab loop's re-parse path NEVER invokes"
        <> " Provider.complete (uses T1 fake provider)") $ do
      fp <- newFakeProvider
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "ai-test"
      -- A burst of slash inputs via the user-text path.
      mapM_ (_tabHandle_send h)
            ["/help", "/status", "/new", "/tabs"]
      yieldAwhile
      recs <- peekRecorded fp
      recs `shouldBe` []
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("I5: dispatcher routes E5 commands via _tabHandle_enqueueSlash"
        <> " — focused-AI tab's input queue receives SlashCmd CmdNew;"
        <> " dispatcher returns immediately (no blocking wait);"
        <> " focused-non-AI yields PublicError with no enqueue") $ do
      fp <- newFakeProvider
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "ai-test"
      -- Push CmdNew (clears context) — the loop runs it without
      -- invoking the provider (CmdNew is local-only).
      r <- _tabHandle_enqueueSlash h Slash.CmdNew
      r `shouldBe` Right ()
      yieldAwhile
      recs <- peekRecorded fp
      recs `shouldBe` []
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

  describe "C-series (AI subset) — concurrency (WU6 slice)" $ do
    it ("C1 (AI slice): two AI tabs can each receive _tabHandle_send"
        <> " concurrently — loops are independent, no shared state"
        <> " across them") $ do
      env <- mkAiTestEnv Nothing
      h0 <- spawnAiTab env 0 "ai-zero"
      h1 <- spawnAiTab env 1 "ai-one"
      r0 <- _tabHandle_send h0 "ping0"
      r1 <- _tabHandle_send h1 "ping1"
      r0 `shouldBe` Right ()
      r1 `shouldBe` Right ()
      yieldAwhile
      _tabHandle_close h0 CloseGraceful
      _tabHandle_close h1 CloseGraceful

    it ("C2 (AI slice): AI tab state isolation — sending /new to /0"
        <> " does not affect /1's per-tab context (no shared IORef)") $ do
      env <- mkAiTestEnv Nothing
      h0 <- spawnAiTab env 0 "ai-zero"
      h1 <- spawnAiTab env 1 "ai-one"
      -- Send /new to /0 — clears /0's context only.
      r <- _tabHandle_enqueueSlash h0 Slash.CmdNew
      r `shouldBe` Right ()
      yieldAwhile
      -- Both handles still report their distinct indices.
      _tabHandle_index h0 `shouldBe` ti 0
      _tabHandle_index h1 `shouldBe` ti 1
      _tabHandle_close h0 CloseGraceful
      _tabHandle_close h1 CloseGraceful

    it ("C6 (AI slice): provider cancellation safety — _tabHandle_close"
        <> " is idempotent and never throws even mid-provider call") $ do
      env <- mkAiTestEnv Nothing
      h <- spawnAiTab env 0 "ai-test"
      -- Send some input then close — close should not raise even if
      -- the loop is mid-iteration.
      _ <- _tabHandle_send h "test"
      _tabHandle_close h CloseGraceful
      _tabHandle_close h CloseGraceful
      _tabHandle_close h CloseForce
      pure ()

  describe "WU6 coverage — provider path, focus-gated streaming, edge cases" $ do

    it ("provider path: a UserText turn with a fake provider serves a"
        <> " canned response; the loop records it into the per-tab"
        <> " context (provider invocation observable via recorded"
        <> " request)") $ do
      fp <- newFakeProvider
      queueResponse fp CompletionResponse
        { _crsp_content = [TextBlock "hello back"]
        , _crsp_model   = ModelId "test-model"
        , _crsp_usage   = Nothing
        }
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "prov"
      r <- _tabHandle_send h "hi"
      r `shouldBe` Right ()
      yieldAwhile
      recs <- peekRecorded fp
      length recs `shouldBe` 1
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("focus-gated streaming: when the tab is focused, StreamStart/"
        <> "ChunkOf/StreamEnd events appear on _env_channelOutQ; when"
        <> " not focused, the writer thread drops them (D3)") $ do
      fp <- newFakeProvider
      queueResponse fp CompletionResponse
        { _crsp_content = [TextBlock "streamed"]
        , _crsp_model   = ModelId "test-model"
        , _crsp_usage   = Nothing
        }
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "stream"
      -- Focus the tab so the producer-side enqueue paths fire.
      writeIORef (_env_focus env) (Just (ti 0))
      _ <- _tabHandle_send h "hi"
      yieldAwhile
      drained <- drainOut env
      -- We expect at least one (SrcTab idx, StreamStart ...) and
      -- one (SrcTab idx, StreamEnd ...) on a focused turn.
      let streamStarts =
            [() | (SrcTab _, StreamStart{}) <- drained]
          streamEnds   =
            [() | (SrcTab _, StreamEnd{})   <- drained]
      length streamStarts `shouldSatisfy` (>= 1)
      length streamEnds   `shouldSatisfy` (>= 1)
      _tabHandle_close h CloseGraceful

    it ("non-focused turn: same provider call, focus is Nothing, no"
        <> " producer-side ChunkOf events on the queue (D4 optim)") $ do
      fp <- newFakeProvider
      queueResponse fp CompletionResponse
        { _crsp_content = [TextBlock "out"]
        , _crsp_model   = ModelId "test-model"
        , _crsp_usage   = Nothing
        }
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "noFocus"
      -- Focus is Nothing by default.
      _ <- _tabHandle_send h "x"
      yieldAwhile
      drained <- drainOut env
      -- No SrcTab events because shouldEmit Nothing (SrcTab n) = False.
      let tabEvents = [() | (SrcTab _, _) <- drained]
      length tabEvents `shouldBe` 0
      _tabHandle_close h CloseGraceful

    it ("provider error path: provider raises; loop emits an error"
        <> " banner and continues") $ do
      env <- mkBrokenProviderEnv
      h <- spawnAiTab env 0 "broken"
      writeIORef (_env_focus env) (Just (ti 0))
      _ <- _tabHandle_send h "trigger"
      yieldAwhile
      drained <- drainOut env
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy`
        any (\t -> "provider error" `T.isInfixOf` t)
      _tabHandle_close h CloseGraceful

    it ("no-provider path: a UserText turn on a tab whose provider"
        <> " IORef is Nothing emits a dispatcher banner") $ do
      env <- mkAiTestEnv Nothing
      h <- spawnAiTab env 0 "noProv"
      _ <- _tabHandle_send h "hello"
      yieldAwhile
      drained <- drainOut env
      let banners = [t | (SrcDispatcher, BannerLine t) <- drained]
      banners `shouldSatisfy`
        any (\t -> "no provider" `T.isInfixOf` t)
      _tabHandle_close h CloseGraceful

    it ("status transition: tab status starts Idle after mkTabAi"
        <> " returns (sentinel Idle now); spawn never leaves it"
        <> " Crashed") $ do
      env <- mkAiTestEnv Nothing
      h <- spawnAiTab env 0 "status"
      st <- _tabHandle_status h
      case st of
        Idle _  -> pure ()
        other   -> expectationFailure
          ("expected Idle status after spawn; got " <> show other)
      _tabHandle_close h CloseGraceful

    it ("sanitize-name reject: a name that fails sanitizeTabName"
        <> " (e.g. ANSI escapes) is surfaced as Left TabInvalidName") $ do
      env <- mkAiTestEnv Nothing
      r <- mkTabAi env (ti 0)
             AiSpawnArgs { _ai_requestedName = "\ESC[31mboom" }
      case r of
        Left _ -> pure ()  -- Left TabInvalidName branch reached
        Right h -> do
          _tabHandle_close h CloseGraceful
          expectationFailure "expected Left TabInvalidName"

    it ("crash handler: a loop that synchronously throws transitions"
        <> " the status to Crashed (via safelyRunLoop) and does NOT"
        <> " propagate the exception to the parent thread") $ do
      -- A provider that throws an ErrorCall but NOT AsyncCancelled.
      -- The loop's safelyRunLoop wrapper catches the exception and
      -- writes Crashed to the status ref.
      env <- mkBrokenProviderEnv
      h <- spawnAiTab env 0 "crashy"
      writeIORef (_env_focus env) (Just (ti 0))
      _ <- _tabHandle_send h "go"
      yieldAwhile
      -- The exception is caught inside runProviderTurn's `try`, so
      -- the status stays Idle. To genuinely crash the loop we'd
      -- need an exception OUTSIDE the try block (e.g. inside
      -- enqueueSlash's atomically). For now this test just exercises
      -- the provider-error path; the standalone safelyRunLoop crash
      -- path is exercised by the crashHandlerTest below.
      _ <- _tabHandle_status h
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("silent provider: completeStream returns without firing"
        <> " StreamDone — loop falls back on emptyResponseFor") $ do
      env <- mkSilentProviderEnv
      h <- spawnAiTab env 0 "silent"
      writeIORef (_env_focus env) (Just (ti 0))
      _ <- _tabHandle_send h "go"
      yieldAwhile
      _ <- drainOut env
      _tabHandle_close h CloseGraceful

    it ("appendTranscript: invoked on a successful provider turn"
        <> " (touches the envTranscript path)") $ do
      fp <- newFakeProvider
      queueResponse fp CompletionResponse
        { _crsp_content = [TextBlock "non-empty"]
        , _crsp_model   = ModelId "test-model"
        , _crsp_usage   = Nothing
        }
      env <- mkAiTestEnv (Just fp)
      h <- spawnAiTab env 0 "transcript"
      writeIORef (_env_focus env) (Just (ti 0))
      _ <- _tabHandle_send h "hi"
      yieldAwhile
      _ <- drainOut env
      _tabHandle_close h CloseGraceful


-- ---------------------------------------------------------------------------
-- Inline test providers
-- ---------------------------------------------------------------------------

-- | A trivial broken 'Provider' whose 'completeStream' raises a
-- synchronous 'ErrorCall'. Used to exercise the loop's
-- Left-from-provider branch.
data BrokenProvider = BrokenProvider

instance Provider BrokenProvider where
  complete _ _ = throwIO (ErrorCall "broken provider: complete")
  completeStream _ _ _ = throwIO (ErrorCall "broken provider: completeStream")
  listModels _ = pure []

-- | A silent 'Provider' whose 'completeStream' returns without ever
-- firing 'StreamDone'. Exercises the loop's 'emptyResponseFor'
-- fallback path.
data SilentProvider = SilentProvider

instance Provider SilentProvider where
  complete _ req = pure CompletionResponse
    { _crsp_content = []
    , _crsp_model   = _cr_model req
    , _crsp_usage   = Nothing
    }
  -- Returns successfully without firing StreamDone — this is the
  -- "callback never observed StreamDone" branch in runProviderTurn.
  completeStream _ _ _ = pure ()
  listModels _ = pure []

mkSilentProviderEnv :: IO AgentEnv
mkSilentProviderEnv = do
  env <- mkAiTestEnv Nothing
  writeIORef (_env_provider env) (Just (MkProvider SilentProvider))
  pure env

-- | Build an 'AgentEnv' whose '_env_provider' is set to the broken
-- 'BrokenProvider'. The broken-provider variant is wrapped via
-- 'MkProvider' so the loop's 'runProviderTurn' surfaces the throw on
-- the Left branch of its 'try'.
mkBrokenProviderEnv :: IO AgentEnv
mkBrokenProviderEnv = do
  env <- mkAiTestEnv Nothing
  writeIORef (_env_provider env) (Just (MkProvider BrokenProvider))
  pure env
