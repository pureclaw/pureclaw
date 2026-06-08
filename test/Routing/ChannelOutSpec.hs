-- |
-- Module      : Routing.ChannelOutSpec
-- Description : D-series tests for the ChannelOut writer thread (WU4).
--
-- Flips the D1–D6 'pending' tests from the WU0 scaffold green now that
-- 'PureClaw.Routing.ChannelOut' has landed. The writer thread reads
-- @_env_channelOutQ@, gates 'SrcTab' events on @_env_focus@, and
-- emits the D5 breadcrumb on the first drop of an AI-tab stream.
--
-- == Scope
--
--   * D1 — focus gate: only the focused tab's events reach the channel.
--   * D2 — non-focused tab events are dropped from the channel
--     (transcript persistence is owned by the AI tab loop in WU6 and
--     is verified there).
--   * D3 — serialised emission via a single bounded TBQueue.
--   * D4 — 'shouldEmit' producer-side helper short-circuits before
--     the queue write.
--   * D5 — mid-stream switch breadcrumb (AI tab) + zero-breadcrumb
--     contract for dropped 'FullMsg' (non-AI tabs).
--   * D6 — no other proactive non-focus notifications from the writer
--     (a non-focused tab's outputs are silently dropped; status
--     announcements are the dispatcher's job and use 'SrcDispatcher').
--
-- == Justified scope extension
--
-- WU4 adds a small private 'mkChannelOutTestEnv' helper that builds a
-- minimal 'AgentEnv' suitable for driving the writer's @oneStep@ a
-- finite number of times. It mirrors the pattern in
-- 'Routing.RegistrySpec.mkE3TestEnv' but is local to this spec to
-- avoid leaking test-helper exports.
module Routing.ChannelOutSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, lengthTBQueue, newTBQueueIO, newTVarIO, writeTBQueue)
import Control.Monad (forM_, replicateM_, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Log
import PureClaw.Handles.Tab
  ( TabIndex
  , TabRunner (..)
  , mkTabIndex
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.ChannelOut
  ( BreadcrumbState (..)
  , breadcrumbText
  , newBreadcrumbStateRef
  , oneStep
  , runChannelOutThread
  , shouldEmit
  , startChannelOut
  )
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  , StreamId
  , mkStreamId
  )
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Tools.Registry (emptyRegistry)

import Test.Fake.ChannelHandle
  ( FakeChannel
  , FakeChannelEvent (..)
  , drainEvents
  , fakeChannelHandle
  , newFakeChannel
  )


-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

-- | Build a minimal 'AgentEnv' with the supplied 'ChannelHandle' and an
-- empty channel-out queue. Suitable for driving @oneStep@ a finite
-- number of times in a single thread.
mkChannelOutTestEnv :: ChannelHandle -> IO AgentEnv
mkChannelOutTestEnv ch = do
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
  focusRef       <- newIORef Nothing
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO (fromIntegral (_rc_channelOutQBound routing))
  pure AgentEnv
    { _env_provider         = providerRef
    , _env_model            = modelRef
    , _env_channel          = ch
    , _env_logger           = mkNoOpLogHandle
    , _env_systemPrompt     = Nothing
    , _env_registry         = emptyRegistry
    , _env_vault            = vaultRef
    , _env_pluginHandle     = mkPluginHandle
    , _env_policy           = defaultPolicy
    , _env_harnesses        = harnessRef
    , _env_harnessRegistry  = harnessReg
    , _env_target           = targetRef
    , _env_nextWindowIdx    = windowIdxRef
    , _env_agentDef         = Nothing :: Maybe AgentDef
    , _env_session          = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
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


-- | Push a single @(OutputSource, ChannelEvent)@ pair onto the env's
-- channel-out queue.
enqueueOne :: AgentEnv -> (OutputSource, ChannelEvent) -> IO ()
enqueueOne env pair =
  atomically (writeTBQueue (_env_channelOutQ env) pair)

-- | Push many pairs in order.
enqueueMany :: AgentEnv -> [(OutputSource, ChannelEvent)] -> IO ()
enqueueMany env = mapM_ (enqueueOne env)

-- | Set the focus IORef.
setFocus :: AgentEnv -> Maybe TabIndex -> IO ()
setFocus env = writeIORef (_env_focus env)

-- | Convenience: build a 'TabIndex' from a non-negative 'Int'.
ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | Strip the timestamps from a drained event list so assertions stay
-- legible.
withoutTimestamps :: [(a, b)] -> [b]
withoutTimestamps = map snd

-- | Drive @oneStep@ exactly @n@ times against the supplied env, then
-- drain the fake channel's recorded outbound events.
runWriterN :: AgentEnv -> FakeChannel -> Int -> IO [FakeChannelEvent]
runWriterN env fch n = do
  stateRef <- newBreadcrumbStateRef
  replicateM_ n (oneStep env stateRef)
  withoutTimestamps <$> drainEvents fch

-- | Like 'runWriterN' but with a caller-supplied state ref (so tests
-- can re-use the same breadcrumb state across multiple invocations
-- and inspect it afterwards).
runWriterNWithState
  :: AgentEnv
  -> FakeChannel
  -> IORef (Map StreamId BreadcrumbState)
  -> Int
  -> IO [FakeChannelEvent]
runWriterNWithState env fch stateRef n = do
  replicateM_ n (oneStep env stateRef)
  withoutTimestamps <$> drainEvents fch

-- | Helper for converting an 'Int' to 'Text'.
tShowInt :: Int -> Text
tShowInt = T.pack . show

-- | Spin in 1 ms increments up to @maxMs@ milliseconds, returning as
-- soon as the channel-out queue is empty. Used by the round-trip
-- async smoke test to wait for the writer thread to drain the queue
-- without resorting to a fixed-duration sleep.
waitForQueueDrain :: AgentEnv -> Int -> IO ()
waitForQueueDrain env = go
  where
    go 0 = pure ()
    go n = do
      len <- atomically (lengthTBQueue (_env_channelOutQ env))
      if len == 0
        then pure ()
        else do
          threadDelay 1000
          go (n - 1)


-- ---------------------------------------------------------------------------
-- D-series specs
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "D-series — channel emission & focused-only display (WU4)" $ do

    -- ----- D1 -----------------------------------------------------------
    it "D1: only focused tab writes to channel — SrcTab events for the focused index emit; SrcTab events for other indices are dropped" $ do
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      enqueueMany env
        [ (SrcTab (ti 0), FullMsg (ti 0) "from-zero")
        , (SrcTab (ti 1), FullMsg (ti 1) "from-one")
        ]
      events <- runWriterN env fch 2
      events `shouldBe`
        [ FceSend (OutgoingMessage "from-zero")
        ]

    -- ----- D2 -----------------------------------------------------------
    it "D2: non-focused tab events are dropped from the channel — channel observes nothing from /1 while focused on /0 (transcript persistence is owned by WU6 Tab.Ai)" $ do
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      enqueueMany env
        [ (SrcTab (ti 1), FullMsg (ti 1) "noise-1")
        , (SrcTab (ti 1), FullMsg (ti 1) "noise-2")
        , (SrcTab (ti 1), FullMsg (ti 1) "noise-3")
        ]
      events <- runWriterN env fch 3
      -- Channel saw nothing — non-AI tabs do not breadcrumb on drop
      -- and FullMsg events from non-focused tabs are silently dropped.
      events `shouldBe` []

    -- ----- D3 -----------------------------------------------------------
    it "D3: writer is the authoritative focus gate — SrcDispatcher events always emit; SrcTab events from N tabs interleave through the writer producing the expected serialised order" $ do
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      enqueueMany env
        [ (SrcDispatcher,  BannerLine "boot")
        , (SrcTab (ti 0),  FullMsg (ti 0) "alpha")
        , (SrcTab (ti 1),  FullMsg (ti 1) "drop-1a")
        , (SrcTab (ti 2),  FullMsg (ti 2) "drop-2a")
        , (SrcDispatcher,  BannerLine "midway")
        , (SrcTab (ti 0),  FullMsg (ti 0) "beta")
        , (SrcTab (ti 1),  FullMsg (ti 1) "drop-1b")
        , (SrcDispatcher,  BannerLine "fin")
        ]
      events <- runWriterN env fch 8
      events `shouldBe`
        [ FceSend (OutgoingMessage "boot")
        , FceSend (OutgoingMessage "alpha")
        , FceSend (OutgoingMessage "midway")
        , FceSend (OutgoingMessage "beta")
        , FceSend (OutgoingMessage "fin")
        ]
      qlen <- atomically (lengthTBQueue (_env_channelOutQ env))
      qlen `shouldBe` 0

    -- ----- D4 -----------------------------------------------------------
    describe "D4: producer-side shouldEmit short-circuits work for non-focused producers" $ do
      it "SrcDispatcher always returns True regardless of focus" $ do
        shouldEmit Nothing       SrcDispatcher `shouldBe` True
        shouldEmit (Just (ti 0)) SrcDispatcher `shouldBe` True
        shouldEmit (Just (ti 9)) SrcDispatcher `shouldBe` True
      it "SrcTab n returns True iff focus == Just n" $ do
        shouldEmit Nothing       (SrcTab (ti 0)) `shouldBe` False
        shouldEmit (Just (ti 0)) (SrcTab (ti 0)) `shouldBe` True
        shouldEmit (Just (ti 1)) (SrcTab (ti 0)) `shouldBe` False
        shouldEmit (Just (ti 0)) (SrcTab (ti 1)) `shouldBe` False
      it "a producer using shouldEmit to gate its enqueue keeps the channel-out queue empty when the producer is non-focused (10k chunk smoke)" $ do
        fch <- newFakeChannel
        env <- mkChannelOutTestEnv (fakeChannelHandle fch)
        setFocus env (Just (ti 0))
        focusSnapshot <- readIORef (_env_focus env)
        forM_ [1 .. (10000 :: Int)] $ \i -> do
          let src = SrcTab (ti 1)
              ev  = ChunkOf (mkStreamId 1) ("chunk-" <> tShowInt i)
          when (shouldEmit focusSnapshot src)
            (enqueueOne env (src, ev))
        len <- atomically (lengthTBQueue (_env_channelOutQ env))
        len `shouldBe` 0

    -- ----- D5 -----------------------------------------------------------
    describe "D5: mid-stream switch breadcrumb (AI tabs only)" $ do
      it "focus moves mid-stream — exactly one SrcDispatcher BannerLine emitted; subsequent ChunkOf drops on the same StreamId are silent; StreamEnd GCs the map entry" $ do
        fch <- newFakeChannel
        env <- mkChannelOutTestEnv (fakeChannelHandle fch)
        stateRef <- newBreadcrumbStateRef
        let sid = mkStreamId 7
            owner = ti 0
        -- Phase 1: /0 focused; emit StreamStart + first chunk.
        setFocus env (Just owner)
        enqueueMany env
          [ (SrcTab owner, StreamStart sid owner)
          , (SrcTab owner, ChunkOf sid "hello-")
          ]
        phase1 <- runWriterNWithState env fch stateRef 2
        phase1 `shouldBe`
          [ FceSendChunk (ChunkText "hello-")
          ]
        s1 <- readIORef stateRef
        Map.lookup sid s1 `shouldBe` Just Pending
        -- Phase 2: user switches to /1, /0 keeps streaming. First drop
        -- emits the breadcrumb; subsequent drops are silent.
        setFocus env (Just (ti 1))
        enqueueMany env
          [ (SrcTab owner, ChunkOf sid "world-")
          , (SrcTab owner, ChunkOf sid "extra-")
          , (SrcTab owner, ChunkOf sid "trailing")
          ]
        phase2 <- runWriterNWithState env fch stateRef 3
        phase2 `shouldBe`
          [ FceSend (OutgoingMessage (breadcrumbText owner))
          ]
        s2 <- readIORef stateRef
        Map.lookup sid s2 `shouldBe` Just Emitted
        -- Phase 3: StreamEnd arrives (still non-focused). The drop is
        -- silent, and the state entry is GC'd.
        enqueueOne env (SrcTab owner, StreamEnd sid)
        phase3 <- runWriterNWithState env fch stateRef 1
        phase3 `shouldBe` []
        s3 <- readIORef stateRef
        Map.lookup sid s3 `shouldBe` Nothing

      it "non-AI tab FullMsg drops emit zero breadcrumbs (per D5 backend rule)" $ do
        fch <- newFakeChannel
        env <- mkChannelOutTestEnv (fakeChannelHandle fch)
        setFocus env (Just (ti 1))
        enqueueMany env
          [ (SrcTab (ti 0), FullMsg (ti 0) "shell-line-1")
          , (SrcTab (ti 0), FullMsg (ti 0) "shell-line-2")
          , (SrcTab (ti 0), FullMsg (ti 0) "shell-line-3")
          ]
        events <- runWriterN env fch 3
        events `shouldBe` []

      it "a StreamId that was never observed as Pending still emits exactly one breadcrumb on first drop (focus moved before StreamStart arrived)" $ do
        fch <- newFakeChannel
        env <- mkChannelOutTestEnv (fakeChannelHandle fch)
        stateRef <- newBreadcrumbStateRef
        setFocus env (Just (ti 1))
        let sid = mkStreamId 42
            owner = ti 0
        enqueueMany env
          [ (SrcTab owner, StreamStart sid owner)
          , (SrcTab owner, ChunkOf sid "a")
          , (SrcTab owner, ChunkOf sid "b")
          , (SrcTab owner, StreamEnd sid)
          ]
        events <- runWriterNWithState env fch stateRef 4
        events `shouldBe`
          [ FceSend (OutgoingMessage (breadcrumbText owner))
          ]
        -- And the state entry is GC'd after StreamEnd.
        sFinal <- readIORef stateRef
        Map.lookup sid sFinal `shouldBe` Nothing

      it "a focused tab's StreamStart + Chunks + StreamEnd produce the expected channel emissions in order, and the map entry is GC'd at end" $ do
        fch <- newFakeChannel
        env <- mkChannelOutTestEnv (fakeChannelHandle fch)
        stateRef <- newBreadcrumbStateRef
        let sid = mkStreamId 11
            owner = ti 3
        setFocus env (Just owner)
        enqueueMany env
          [ (SrcTab owner, StreamStart sid owner)
          , (SrcTab owner, ChunkOf sid "ping-")
          , (SrcTab owner, ChunkOf sid "pong")
          , (SrcTab owner, StreamEnd sid)
          ]
        events <- runWriterNWithState env fch stateRef 4
        events `shouldBe`
          [ FceSendChunk (ChunkText "ping-")
          , FceSendChunk (ChunkText "pong")
          , FceSendChunk ChunkDone
          ]
        sFinal <- readIORef stateRef
        Map.lookup sid sFinal `shouldBe` Nothing

    -- ----- D6 -----------------------------------------------------------
    it "D6: no other proactive non-focus notifications — a non-focused tab's outputs (FullMsg, stray BannerLine, StreamEnd-only) are silently dropped" $ do
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      let sid = mkStreamId 99
      enqueueMany env
        [ (SrcTab (ti 1), FullMsg (ti 1) "noise-1")
        , (SrcTab (ti 1), FullMsg (ti 1) "noise-2")
        , (SrcTab (ti 1), BannerLine "should-not-happen")
        , (SrcTab (ti 1), StreamEnd sid)
        , (SrcTab (ti 1), FullMsg (ti 1) "noise-3")
        ]
      events <- runWriterN env fch 5
      events `shouldBe` []

  -- ---------------------------------------------------------------------
  -- WU4 boundary smoke tests
  -- ---------------------------------------------------------------------
  describe "ChannelOut — WU4 boundary smoke tests" $ do

    it "breadcrumbText format matches the D5 specification ('/N has new output - /N to view')" $ do
      breadcrumbText (ti 0) `shouldBe` "/0 has new output - /0 to view"
      breadcrumbText (ti 7) `shouldBe` "/7 has new output - /7 to view"

    it "BreadcrumbState constructors are distinct (Pending /= Emitted) and Show is derived" $ do
      Pending `shouldNotBe` Emitted
      show Pending `shouldBe` "Pending"
      show Emitted `shouldBe` "Emitted"

    it "emitWithStreamTracking handles non-stream-bearing events (FullMsg, ChunkOf, BannerLine) without updating breadcrumb state — only StreamStart and StreamEnd touch the map" $ do
      -- Driven through oneStep with a focused tab; this exercises the
      -- '_ -> pure ()' fall-through in 'emitWithStreamTracking'.
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      stateRef <- newBreadcrumbStateRef
      setFocus env (Just (ti 0))
      enqueueMany env
        [ (SrcTab (ti 0), FullMsg (ti 0) "hello")
        , (SrcTab (ti 0), ChunkOf (mkStreamId 100) "midstream-without-start")
        , (SrcTab (ti 0), BannerLine "dispatcher-banner-via-tab-source")
        ]
      events <- runWriterNWithState env fch stateRef 3
      events `shouldBe`
        [ FceSend (OutgoingMessage "hello")
        , FceSendChunk (ChunkText "midstream-without-start")
        , FceSend (OutgoingMessage "dispatcher-banner-via-tab-source")
        ]
      -- The breadcrumb map should be untouched (no stream lifecycle
      -- events were processed).
      s <- readIORef stateRef
      Map.null s `shouldBe` True

    it "dropWithBreadcrumb's defensive arms (FullMsg, stray BannerLine on SrcTab) are silent no-ops" $ do
      -- This exercises the BannerLine{} -> pure () defensive branch in
      -- dropWithBreadcrumb (line should not crash even if a tab
      -- erroneously enqueues a BannerLine via SrcTab).
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      -- Non-focused FullMsg + BannerLine; both should produce no
      -- channel output.
      enqueueMany env
        [ (SrcTab (ti 1), FullMsg (ti 1) "drop-me-1")
        , (SrcTab (ti 1), BannerLine "drop-me-2")
        ]
      events <- runWriterN env fch 2
      events `shouldBe` []

    it "runChannelOutThread loops through queued events when started via startChannelOut + defaultEnvFork (round-trip smoke)" $ do
      -- Spawns the real production loop body via the default async-backed
      -- _env_fork, feeds it some events, drains, then cancels through the
      -- returned 'TabRunner'. Exercises the production
      -- 'runChannelOutThread' loop body end-to-end.
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      setFocus env (Just (ti 0))
      runner <- startChannelOut env
      -- Enqueue a few events; the running writer thread will consume
      -- them out of the bounded TBQueue.
      enqueueMany env
        [ (SrcDispatcher,  BannerLine "boot")
        , (SrcTab (ti 0),  FullMsg (ti 0) "hello")
        , (SrcTab (ti 1),  FullMsg (ti 1) "dropped-non-focus")
        ]
      -- Wait until the queue is drained (the writer is async). The
      -- 50 ms cap is well above the expected drain time on any
      -- realistic machine; the loop is a tight STM consumer.
      waitForQueueDrain env 50
      _trun_cancel runner
      events <- withoutTimestamps <$> drainEvents fch
      events `shouldBe`
        [ FceSend (OutgoingMessage "boot")
        , FceSend (OutgoingMessage "hello")
        ]

    it "startChannelOut forks the writer through the supplied _env_fork test seam" $ do
      -- Inject a test fork that records whether the body was handed
      -- off and provides a cancel that flips a flag.
      fch <- newFakeChannel
      env <- mkChannelOutTestEnv (fakeChannelHandle fch)
      handedOff <- newIORef False
      cancelled <- newIORef False
      let env' = env
            { _env_fork = \_body -> do
                writeIORef handedOff True
                pure TabRunner
                  { _trun_cancel = writeIORef cancelled True
                  , _trun_wait   = pure ()
                  }
            }
      runner <- startChannelOut env'
      readIORef handedOff `shouldReturn` True
      _trun_cancel runner
      readIORef cancelled `shouldReturn` True

    it "runChannelOutThread has the exported type AgentEnv -> IO () (type-shape check)" $ do
      let _runner :: AgentEnv -> IO ()
          _runner = runChannelOutThread
      True `shouldBe` True
