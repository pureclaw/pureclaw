{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      : Tabs.RuntimesSpec
-- Description : 8c.1 — the REAL per-'TabRef' runtime constructors.
--
-- 'PureClaw.Tabs.Runtimes' builds the @'Runtime' { '_rt_send', '_rt_stop' }@
-- values that "PureClaw.Tabs.Exec" manages (8c wires
-- 'mkProviderRuntime'\/'mkHarnessRuntime' into @Exec._ex_startRuntime@). This
-- spec drives both constructors entirely with fakes — a scripted provider
-- stream, a recording 'HarnessHandle', a recording @emit@ sink, and a real
-- async fork — so no live LLM or tmux is touched.
--
-- Determinism: threads are real (forked via the production-style fork), but
-- every assertion synchronises on an 'MVar' handshake driven by the fake
-- stream\/receive completing — never on a fixed sleep. The fake stream signals
-- on its @done@ 'MVar' after replaying one script; the fake harness receive
-- signals on @recvDone@ once it has handed back its scripted output, so a test
-- blocks until the worker\/drainer has actually finished the unit of work it
-- asserts on.
module Tabs.RuntimesSpec (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , tryPutMVar
  )
import Control.Monad (void, when)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Test.Hspec

import PureClaw.Agent.Context qualified as Ctx
import PureClaw.Core.Types (ModelId (..), SessionId (..), ToolCallId (..))
import PureClaw.Handles.Harness
  ( HarnessHandle (..)
  , HarnessStatus (..)
  )
import PureClaw.Handles.Tab (TabError, TabRunner (..))
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Providers.Class qualified as P
import PureClaw.Routing.Types (ChannelEvent (..))
import PureClaw.Tabs.Exec (Runtime (..))
import PureClaw.Tabs.Runtimes
  ( HarnessRuntimeDeps (..)
  , ProviderRuntimeDeps (..)
  , mkHarnessRuntime
  , mkProviderRuntime
  )
import PureClaw.Tabs.Types (TabRef (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Shared fakes / helpers
-- ---------------------------------------------------------------------------

-- | The ref every test binds its runtime to.
testRef :: TabRef
testRef = BoundSession (SessionId "rt-test")

-- | A real async fork matching the production '_env_fork' shape so the worker
-- / drainer / writer threads actually run.
realFork :: IO () -> IO TabRunner
realFork body = do
  a <- Async.async body
  pure TabRunner
    { _trun_cancel = Async.cancel a
    , _trun_wait   = void (Async.wait a)
    }

-- | A canned completion response.
mkResp :: [P.ContentBlock] -> P.CompletionResponse
mkResp blocks = P.CompletionResponse
  { P._crsp_content = blocks
  , P._crsp_model   = ModelId "fake-model"
  , P._crsp_usage   = Nothing
  }

-- | A scripted provider stream: each call pops the next script (a list of
-- 'P.StreamEvent') and replays it to the callback, then signals completion on
-- @done@ so the test can block until the turn finished. When the scripts are
-- exhausted it signals immediately (no events) — a turn driven after the
-- script runs out still terminates.
scriptedStream
  :: IORef [[P.StreamEvent]]
  -> MVar ()
  -> (P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ())
scriptedStream scriptsRef done _req cb = do
  scripts <- readIORef scriptsRef
  case scripts of
    []           -> putMVar done ()
    (evs : rest) -> do
      writeIORef scriptsRef rest
      mapM_ cb evs
      putMVar done ()

-- | A recording emit sink: appends every @(ref, event)@ to an IORef.
recordingEmit
  :: IORef [(TabRef, ChannelEvent)]
  -> (TabRef -> ChannelEvent -> IO ())
recordingEmit ref r ev = modifyIORef' ref (++ [(r, ev)])

-- | Build 'ProviderRuntimeDeps' with sane defaults; callers override fields.
mkProvDeps
  :: (P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ())
  -> (ToolCallId -> Text -> Aeson.Value -> IO P.Message)
  -> (TabRef -> ChannelEvent -> IO ())
  -> (P.Message -> IO ())
  -> IO Ctx.Context
  -> ProviderRuntimeDeps
mkProvDeps stream execTool emit record seedCtx = ProviderRuntimeDeps
  { _prd_ref          = testRef
  , _prd_emit         = emit
  , _prd_stream       = stream
  , _prd_execTool     = execTool
  , _prd_record       = record
  , _prd_seedCtx      = seedCtx
  , _prd_model        = ModelId "fake-model"
  , _prd_systemPrompt = Nothing
  , _prd_tools        = pure []
  , _prd_maxTokens    = Just 4096
  , _prd_onStreamDone = pure ()
  , _prd_fork         = realFork
  , _prd_inputBound   = 64
  }

-- | A tool-exec fn that records (callId, name) and returns a fixed result.
recordingExec
  :: IORef [(ToolCallId, Text)]
  -> (ToolCallId -> Text -> Aeson.Value -> IO P.Message)
recordingExec ref callId name _input = do
  modifyIORef' ref (++ [(callId, name)])
  pure (P.toolResultMessage [(callId, [P.TRPText "result"], False)])

-- | A no-op exec (no tool calls expected on this path).
noExec :: ToolCallId -> Text -> Aeson.Value -> IO P.Message
noExec callId _ _ = pure (P.toolResultMessage [(callId, [P.TRPText ""], False)])

-- ---------------------------------------------------------------------------
-- Harness fakes
-- ---------------------------------------------------------------------------

-- | A recording harness handle plus the IORefs/MVars the test reads.
data FakeHarness = FakeHarness
  { _fh_handle   :: HarnessHandle
  , _fh_sent     :: IORef [ByteString]  -- ^ bytes passed to '_hh_send'
  , _fh_stops    :: IORef Int           -- ^ how many times '_hh_stop' fired
  , _fh_sendDone :: MVar ByteString     -- ^ fires once per '_hh_send' call
  }

-- | Build a fake harness whose '_hh_receive' replays a scripted list of
-- outputs (one per call, then "" forever). It signals on @recvDone@ exactly
-- once — when the script first drains — so the drainer's emit is assertable
-- without a sleep. '_hh_send' records the bytes AND signals '_fh_sendDone' so
-- a test can block until the writer thread has actually forwarded input.
-- '_hh_status' is driven by @statusRef@; '_hh_stop' counts.
mkFakeHarness
  :: IORef [ByteString]   -- ^ scripted receive outputs
  -> IORef HarnessStatus  -- ^ mutable status
  -> MVar ()              -- ^ signalled once when scripted outputs are drained
  -> IORef Bool           -- ^ "already signalled" latch
  -> IO FakeHarness
mkFakeHarness scriptRef statusRef recvDone signalled = do
  sent     <- newIORef []
  stops    <- newIORef 0
  sendDone <- newEmptyMVar
  let recv = atomicModifyIORef' scriptRef $ \case
        []       -> ([], "")        -- drained: keep returning empty
        (b : bs) -> (bs, b)
      handle = HarnessHandle
        { _hh_send     = \bs -> do
            modifyIORef' sent (++ [bs])
            putMVar sendDone bs
        , _hh_receive  = do
            out <- recv
            remaining <- readIORef scriptRef
            -- Signal exactly once when the script first drains.
            case remaining of
              [] -> do
                fired <- atomicModifyIORef' signalled (True,)
                if fired then pure () else putMVar recvDone ()
              _  -> pure ()
            pure out
        , _hh_snapshot = \_ -> pure ""
        , _hh_name     = "fake"
        , _hh_session  = "fake-sess"
        , _hh_status   = readIORef statusRef
        , _hh_stop     = modifyIORef' stops (+ 1)
        }
  pure (FakeHarness handle sent stops sendDone)

mkHarnDeps
  :: HarnessHandle
  -> (TabRef -> ChannelEvent -> IO ())
  -> HarnessRuntimeDeps
mkHarnDeps handle emit = HarnessRuntimeDeps
  { _hrd_ref        = testRef
  , _hrd_emit       = emit
  , _hrd_handle     = handle
  , _hrd_fork       = realFork
  , _hrd_pollMicros = 1000
  , _hrd_sendBound  = 64
  }

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "mkProviderRuntime — happy path" $
    it "runs one turn: emits StreamStart/ChunkOf/StreamEnd (ref-tagged), seeds [user,assistant], records both" $ do
      scripts <- newIORef
        [ [ P.StreamText "a", P.StreamText "b"
          , P.StreamDone (mkResp [P.TextBlock "ab"]) ] ]
      done    <- newEmptyMVar
      emits   <- newIORef []
      execRef <- newIORef []
      seedRef <- newIORef (Ctx.emptyContext Nothing)
      -- Records sync: the test's record sink signals 'recordedAsst' once the
      -- assistant message lands. That append happens AFTER 'TurnEnd' is emitted,
      -- so by the time it fires turn 1's full emit burst (Start, chunks, End) is
      -- present — a deterministic handshake with no sleep.
      records      <- newIORef []
      recordedAsst <- newEmptyMVar
      let recordSink m = do
            modifyIORef' records (++ [m])
            n <- length <$> readIORef records
            when (n == 2) (putMVar recordedAsst ())
      -- A trailing empty script captures the SECOND turn's request, proving the
      -- single-writer Context persisted turn 1's [user, assistant] (E5) and
      -- exercising the worker's writeIORef-then-loop path.
      reqRef <- newIORef (Nothing :: Maybe P.CompletionRequest)
      modifyIORef' scripts (++ [[]])
      let capturingStream req cb = do
            scriptsLeft <- readIORef scripts
            case scriptsLeft of
              (s : rest) | null s -> do        -- the trailing empty script
                writeIORef scripts rest
                writeIORef reqRef (Just req)
                putMVar done ()
              _ -> scriptedStream scripts done req cb
          deps = mkProvDeps capturingStream (recordingExec execRef)
                            (recordingEmit emits) recordSink
                            (readIORef seedRef)
      rt <- mkProviderRuntime deps
      r  <- _rt_send rt "hi"
      r `shouldSatisfy` isRight
      takeMVar done                 -- iteration 1 streamed
      takeMVar recordedAsst         -- iteration 1's assistant recorded (burst closed)
      -- Snapshot turn-1 emits BEFORE sending turn 2 (whose own TurnStart would
      -- otherwise inflate the StreamStart count).
      turn1 <- map snd <$> readIORef emits
      [ t | ChunkOf _ t <- turn1 ] `shouldBe` ["a", "b"]
      length [ () | StreamStart _ _ <- turn1 ] `shouldBe` 1
      length [ () | StreamEnd _    <- turn1 ] `shouldBe` 1
      recs <- readIORef records
      map P._msg_role recs `shouldBe` [P.User, P.Assistant]
      -- Now drive turn 2 to confirm the Context accumulated turn 1.
      _ <- _rt_send rt "again"
      takeMVar done                 -- iteration 2 started -> iteration 1 fully done
      _rt_stop rt
      -- Every emitted event is ref-tagged.
      evs <- readIORef emits
      map fst evs `shouldBe` replicate (length evs) testRef
      Just req2 <- readIORef reqRef
      map P._msg_role (P._cr_messages req2) `shouldBe` [P.User, P.Assistant, P.User]
      -- Forcing the request's model/tools/maxTokens exercises the worker's
      -- field projections (_prd_model deps, etc.) threaded into TurnDeps.
      P._cr_model req2     `shouldBe` ModelId "fake-model"
      P._cr_tools req2     `shouldBe` []
      P._cr_maxTokens req2 `shouldBe` Just 4096
      P._cr_systemPrompt req2 `shouldBe` Nothing

  describe "mkProviderRuntime — tool cycle" $
    it "executes the tool, re-completes, emits two stream cycles" $ do
      scripts <- newIORef
        [ [ P.StreamDone (mkResp [P.ToolUseBlock (ToolCallId "c1") "search" Aeson.Null]) ]
        , [ P.StreamDone (mkResp [P.TextBlock "done"]) ]
        ]
      done    <- newEmptyMVar
      emits   <- newIORef []
      records <- newIORef []
      execRef <- newIORef []
      seedRef <- newIORef (Ctx.emptyContext Nothing)
      let deps = mkProvDeps (scriptedStream scripts done) (recordingExec execRef)
                            (recordingEmit emits) (\m -> modifyIORef' records (++ [m]))
                            (readIORef seedRef)
      -- Trailing empty script + a second send: waiting for iteration 2 to start
      -- guarantees iteration 1 (both completion legs + the writeIORef) finished.
      modifyIORef' scripts (++ [[]])
      rt <- mkProviderRuntime deps
      _ <- _rt_send rt "go"
      takeMVar done                 -- first completion (tool call)
      takeMVar done                 -- second completion (final)
      -- Snapshot the two-leg burst BEFORE the sync send (whose own TurnStart
      -- would inflate the count).
      turn1 <- map snd <$> readIORef emits
      length [ () | StreamStart _ _ <- turn1 ] `shouldBe` 2
      _ <- _rt_send rt "next"
      takeMVar done                 -- iteration 2 -> iteration 1 fully done
      _rt_stop rt
      execed <- readIORef execRef
      execed `shouldBe` [(ToolCallId "c1", "search")]

  describe "mkProviderRuntime - provider error" $
    it "emits a visible FullMsg error when the stream throws (pureclaw-9d0)" $ do
      -- Regression for pureclaw-9d0: a throwing provider stream must surface a
      -- VISIBLE error to the channel. The env-light turn emits TurnError, which
      -- the runtime maps to a FullMsg ChannelEvent carrying the legacy
      -- "Something went wrong" message (not a silent StreamStart/StreamEnd pair).
      gotError <- newEmptyMVar
      emits    <- newIORef []
      records  <- newIORef []
      seedRef  <- newIORef (Ctx.emptyContext Nothing)
      -- The emit sink signals once a FullMsg lands, giving a deterministic
      -- handshake (no sleep): the error emit happens inside the worker turn,
      -- after which the test can assert on the recorded events.
      let onEmit r ev = do
            modifyIORef' emits (++ [(r, ev)])
            case ev of
              FullMsg _ _ -> void (tryPutMVar gotError ())
              _           -> pure ()
          boomStream _req _cb = ioError (userError "provider boom")
          deps = mkProvDeps boomStream noExec onEmit
                            (\m -> modifyIORef' records (++ [m]))
                            (readIORef seedRef)
      rt <- mkProviderRuntime deps
      _ <- _rt_send rt "hi"
      takeMVar gotError             -- the error FullMsg was emitted
      _rt_stop rt
      evs <- readIORef emits
      let fulls = [ t | (_, FullMsg _ t) <- evs ]
      fulls `shouldContain` ["Something went wrong. Please try again."]
      -- The error event is ref-tagged like every other emit.
      map fst evs `shouldBe` replicate (length evs) testRef

  describe "mkProviderRuntime — stop" $
    it "cancels the worker; a later send runs no further turn; stop is idempotent" $ do
      scripts <- newIORef
        [ [ P.StreamDone (mkResp [P.TextBlock "one"]) ] ]
      done    <- newEmptyMVar
      emits   <- newIORef []
      records <- newIORef []
      seedRef <- newIORef (Ctx.emptyContext Nothing)
      let deps = mkProvDeps (scriptedStream scripts done) noExec
                            (recordingEmit emits) (\m -> modifyIORef' records (++ [m]))
                            (readIORef seedRef)
      rt <- mkProviderRuntime deps
      _ <- _rt_send rt "first"
      takeMVar done
      _rt_stop rt
      _rt_stop rt                  -- idempotent
      emitsBefore <- length <$> readIORef emits
      _ <- _rt_send rt "second"
      emitsAfter <- length <$> readIORef emits
      emitsAfter `shouldBe` emitsBefore

  describe "mkProviderRuntime — input queue full" $
    it "returns Left when the worker is stalled and the bounded queue fills" $ do
      -- Gate the stream on an MVar the test never fills, so the worker stalls
      -- in its first turn and never drains further input. With a bound of 1 the
      -- queue then fills and a later send returns Left (back-pressure), exactly
      -- like the legacy per-tab loop.
      gate    <- newEmptyMVar
      emits   <- newIORef []
      records <- newIORef []
      seedRef <- newIORef (Ctx.emptyContext Nothing)
      let stallStream _req _cb = takeMVar gate  -- blocks forever (test never puts)
          deps = (mkProvDeps stallStream noExec
                             (recordingEmit emits) (\m -> modifyIORef' records (++ [m]))
                             (readIORef seedRef))
                   { _prd_inputBound = 1 }
      rt <- mkProviderRuntime deps
      result <- sendUntilLeft rt 50
      -- Force the Left payload: back-pressure surfaces as 'TabConcurrencyLimit'.
      assertConcurrencyLimit result
      -- Bound teardown so a regression that swallows the cancel surfaces as a
      -- fast failure here instead of a 6h CI hang (see "stop while mid-stream").
      stopWithin rt

  describe "mkProviderRuntime — stop while mid-stream" $
    it "cancels a worker blocked inside the provider stream (no teardown hang)" $ do
      -- The worker reaches the provider stream and blocks there forever; '_rt_stop'
      -- must still terminate it. A catch-all @try@ that swallowed the
      -- 'AsyncCancelled' from '_rt_stop' (Async.cancel) would leave the worker
      -- alive and the canceller's wait blocked forever — the provider-runtime
      -- teardown hang. The MVar handshake makes "worker is mid-stream" exact, so
      -- this is deterministic, not timing-dependent.
      started <- newEmptyMVar
      gate    <- newEmptyMVar          -- never filled: the stream blocks forever
      emits   <- newIORef []
      records <- newIORef []
      seedRef <- newIORef (Ctx.emptyContext Nothing)
      let stallStream _req _cb = putMVar started () >> takeMVar gate
          deps = mkProvDeps stallStream noExec
                            (recordingEmit emits) (\m -> modifyIORef' records (++ [m]))
                            (readIORef seedRef)
      rt <- mkProviderRuntime deps
      _rt_send rt "go" `shouldReturn` Right ()
      takeMVar started                 -- worker is now blocked INSIDE the stream
      stopWithin rt

  describe "mkHarnessRuntime — send queue full" $
    it "returns Left when the writer is stalled and the bounded queue fills" $ do
      stops    <- newIORef (0 :: Int)
      sendGate <- newEmptyMVar
      -- A harness whose '_hh_send' blocks forever (stalling the writer) and
      -- whose '_hh_receive' always returns "" (the drainer just polls). The
      -- bounded send queue then fills and '_rt_send' surfaces back-pressure.
      let handle = HarnessHandle
            { _hh_send     = \_ -> takeMVar sendGate
            , _hh_receive  = pure ""
            , _hh_snapshot = \_ -> pure ""
            , _hh_name     = "fake"
            , _hh_session  = "fake-sess"
            , _hh_status   = pure HarnessRunning
            , _hh_stop     = modifyIORef' stops (+ 1)
            }
      emits <- newIORef []
      let deps = (mkHarnDeps handle (recordingEmit emits)) { _hrd_sendBound = 1 }
      rt <- mkHarnessRuntime deps
      result <- sendUntilLeft rt 50
      assertConcurrencyLimit result
      _rt_stop rt
      readIORef stops `shouldReturn` 0   -- harness never stopped

  describe "mkHarnessRuntime — drainer + writer" $
    it "emits sanitized FullMsg from receive; send records bytes to _hh_send" $ do
      scriptRef <- newIORef [TE.encodeUtf8 "out\n"]
      statusRef <- newIORef HarnessRunning
      recvDone  <- newEmptyMVar
      signalled <- newIORef False
      fh <- mkFakeHarness scriptRef statusRef recvDone signalled
      emits   <- newIORef []
      emitted <- newEmptyMVar       -- fires once when the drainer EMITS a FullMsg
      -- Synchronise on the EMIT, not on _hh_receive: the fake signals recvDone
      -- INSIDE receive, BEFORE the drainer emits the FullMsg, so gating on
      -- recvDone could race _rt_stop ahead of the emit (cancelling the drainer
      -- mid-cycle -> "[] does not contain [\"out\"]"). Gating on the emit is exact.
      let recordingEmitThenSignal r ev = do
            recordingEmit emits r ev
            case ev of
              FullMsg _ _ -> void (tryPutMVar emitted ())
              _           -> pure ()
          deps = mkHarnDeps (_fh_handle fh) recordingEmitThenSignal
      rt <- mkHarnessRuntime deps
      takeMVar emitted              -- drainer has emitted the FullMsg
      sendR <- _rt_send rt "cmd"
      sendR `shouldSatisfy` isRight
      forwarded <- takeMVar (_fh_sendDone fh)  -- block until writer forwarded it
      forwarded `shouldBe` TE.encodeUtf8 "cmd"
      _rt_stop rt
      evs <- readIORef emits
      let fulls = [ t | (_, FullMsg _ t) <- evs ]
      fulls `shouldContain` ["out"]
      -- Output is ref-tagged.
      map fst evs `shouldBe` replicate (length evs) testRef
      readIORef (_fh_sent fh) `shouldReturn` [TE.encodeUtf8 "cmd"]

  describe "mkHarnessRuntime — stop does not stop the harness" $
    it "cancels both threads but never calls _hh_stop" $ do
      scriptRef <- newIORef []
      statusRef <- newIORef HarnessRunning
      recvDone  <- newEmptyMVar
      signalled <- newIORef False
      fh <- mkFakeHarness scriptRef statusRef recvDone signalled
      emits <- newIORef []
      let deps = mkHarnDeps (_fh_handle fh) (recordingEmit emits)
      rt <- mkHarnessRuntime deps
      _rt_stop rt
      _rt_stop rt                  -- idempotent
      readIORef (_fh_stops fh) `shouldReturn` 0

  describe "mkHarnessRuntime — exited harness" $
    it "stops the drainer without throwing when _hh_status reports exited" $ do
      stops      <- newIORef (0 :: Int)
      statusSeen <- newEmptyMVar
      -- '_hh_status' reports exited and signals once it has been read, so the
      -- test waits for the drainer to actually observe the exit (and take the
      -- HarnessExited branch) before stopping — making the stop deterministic.
      let handle = HarnessHandle
            { _hh_send     = \_ -> pure ()
            , _hh_receive  = pure ""
            , _hh_snapshot = \_ -> pure ""
            , _hh_name     = "fake"
            , _hh_session  = "fake-sess"
            , _hh_status   = do
                _ <- tryPutMVar statusSeen ()
                pure (HarnessExited ExitSuccess)
            , _hh_stop     = modifyIORef' stops (+ 1)
            }
      emits <- newIORef []
      let deps = mkHarnDeps handle (recordingEmit emits)
      rt <- mkHarnessRuntime deps
      takeMVar statusSeen           -- drainer observed exited -> took the branch
      _rt_stop rt
      readIORef stops `shouldReturn` 0   -- harness never stopped, no throw

-- | Send into a runtime up to @n@ times, stopping early as soon as a send
-- returns 'Left' (the queue-full back-pressure path). Returns that result (or
-- the last 'Right' if @n@ sends never back-pressure). Bounded so a runtime that
-- never back-pressures fails the assertion rather than looping forever.
sendUntilLeft :: Runtime -> Int -> IO (Either TabError ())
sendUntilLeft _  0 = pure (Right ())
sendUntilLeft rt n = do
  r <- _rt_send rt "fill"
  case r of
    Left _   -> pure r
    Right () -> sendUntilLeft rt (n - 1)

-- | Assert a 'sendUntilLeft' result is the back-pressure 'Left' carrying a
-- 'TabConcurrencyLimit'. Pattern-matching the payload forces the error value
-- (so the constructor is genuinely exercised, not held as an unforced thunk).
assertConcurrencyLimit :: Either TabError () -> Expectation
assertConcurrencyLimit = \case
  Left (Tab.TabConcurrencyLimit _) -> pure ()
  Left other                       ->
    expectationFailure ("expected TabConcurrencyLimit, got " <> show other)
  Right ()                         ->
    expectationFailure "expected Left (back-pressure), got Right ()"

-- | Stop a runtime, asserting teardown COMPLETES within a generous bound. A
-- runtime whose worker swallows the cancel never terminates, so '_rt_stop'
-- (Async.cancel) would block forever; the timeout converts that regression into
-- a fast, clear test failure instead of a multi-hour CI hang.
stopWithin :: Runtime -> Expectation
stopWithin rt = do
  done <- timeout 5000000 (_rt_stop rt)   -- 5s; teardown is otherwise instant
  done `shouldBe` Just ()
