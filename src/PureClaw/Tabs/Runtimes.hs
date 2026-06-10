{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : PureClaw.Tabs.Runtimes
-- Description : The real per-'TabRef' runtime constructors (Tabs-as-View 8c.1).
--
-- "PureClaw.Tabs.Exec" owns a refcounted registry of started
-- @'Runtime' { '_rt_send', '_rt_stop' }@ values, one per live 'TabRef', but
-- defers their CONSTRUCTION to an injected seam (@Exec._ex_startRuntime@). This
-- module supplies the two real constructors that seam is wired to at the 8c.2
-- flip:
--
--   * 'mkProviderRuntime' — an LLM-backed session. A single forked worker
--     serialises turns so it stays the /only/ writer of the session 'Context'
--     (invariant E5). Input text arrives on a bounded queue; each turn runs the
--     env-light 'PureClaw.Agent.Turn.runTurnWithTools' and streams output to an
--     injected ref-tagged sink.
--   * 'mkHarnessRuntime' — an external tmux harness. A forked /writer/ drains
--     queued input to @_hh_send@; a forked /drainer/ polls @_hh_receive@,
--     sanitises each non-empty capture, and emits it as a 'FullMsg'.
--
-- == Injected seams (no live LLM / tmux here)
--
-- Every effect is a field of 'ProviderRuntimeDeps' \/ 'HarnessRuntimeDeps' —
-- the provider stream, the tool executor, the transcript append, the context
-- seed, the 'HarnessHandle', and the fork primitive (the @_env_fork@ seam). So
-- both constructors unit-test fully with fakes (see @test\/Tabs\/RuntimesSpec@):
-- a scripted stream, a recording harness handle, a recording emit sink, and a
-- real async fork, synchronised by 'MVar' handshakes rather than sleeps.
--
-- == TurnEvent -> ChannelEvent mapping
--
-- 'runTurnWithTools' emits the env-light 'PureClaw.Agent.Turn.TurnEvent'
-- (start\/chunk\/end framed by a 'StreamId', carrying no slot identity). The
-- provider worker maps each to a 'ChannelEvent' and tags it with the runtime's
-- own 'TabRef' before calling '_prd_emit':
--
-- @
--   'TurnStart' sid    -> 'StreamStart' sid placeholderSlot
--   'TurnChunk' sid t   -> 'ChunkOf' sid t
--   'TurnEnd'   sid     -> 'StreamEnd' sid
--   'TurnError' _sid t  -> 'FullMsg' placeholderSlot t
-- @
--
-- 'TurnError' carries a provider-failure message (pureclaw-9d0); it maps to a
-- whole-message 'FullMsg' (not stream framing) so the error reaches every
-- channel — including the non-streaming Signal\/Telegram path.
--
-- The 'Tab.TabIndex' embedded in 'StreamStart' is __vestigial__: the relay now
-- routes purely by 'TabRef' (spike §4), so the slot is a fixed placeholder
-- (@'Tab.mkTabIndex' 0@). Downstream consumers must not read it.
--
-- == Stop semantics
--
-- '_rt_stop' cancels the runtime's worker\/drainer\/writer threads and is
-- idempotent (it forwards to the async-cancel '_trun_cancel', itself
-- idempotent) and never throws. For a harness, '_rt_stop' deliberately does
-- __not__ call @_hh_stop@: detaching a tab leaves the harness running in tmux,
-- re-attachable later (spike §6).
module PureClaw.Tabs.Runtimes
  ( -- * Provider-session runtime
    ProviderRuntimeDeps (..)
  , mkProviderRuntime
    -- * Harness runtime
  , HarnessRuntimeDeps (..)
  , mkHarnessRuntime
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( atomically
  , isFullTBQueue
  , newTBQueueIO
  , readTBQueue
  , writeTBQueue
  )
import Control.Monad (forever, unless)
import Data.Aeson (Value)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NE
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import PureClaw.Agent.Context (Context)
import PureClaw.Agent.Turn
  ( TurnDeps (..)
  , TurnEvent (..)
  , runTurnWithTools
  )
import PureClaw.Core.Types (ModelId, ToolCallId)
import PureClaw.Handles.Harness
  ( HarnessHandle (..)
  , HarnessStatus (..)
  , sanitizeHarnessOutput
  )
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Providers.Class qualified as P
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , StreamId
  , mkStreamId
  )
import PureClaw.Tabs.Exec (Runtime (..))
import PureClaw.Tabs.Types (TabRef)

-- ---------------------------------------------------------------------------
-- Provider-session runtime
-- ---------------------------------------------------------------------------

-- | The injected effects 'mkProviderRuntime' needs. Production wires:
--
--   * '_prd_emit'    — tag + enqueue onto the relay-writer queue.
--   * '_prd_stream'  — @'P.completeStream' someProvider@ (transcript-wrapped).
--   * '_prd_execTool'— a closure over the session's tool registry.
--   * '_prd_record'  — @messageToEntry >>> _th_record@ for the session.
--   * '_prd_seedCtx' — @loadRecentMessages + replaceMessages@ (or 'emptyContext').
--   * '_prd_fork'    — the @_env_fork@ seam.
--
-- Tests inject fakes for all of these.
data ProviderRuntimeDeps = ProviderRuntimeDeps
  { _prd_ref          :: TabRef
    -- ^ This runtime's tab ref (a @BoundSession@). Every emitted event is
    --   tagged with it.
  , _prd_emit         :: TabRef -> ChannelEvent -> IO ()
    -- ^ Output sink: tags + enqueues to the relay-writer queue.
  , _prd_stream       :: P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ()
    -- ^ Provider stream (prod: @'P.completeStream' someProvider@).
  , _prd_execTool     :: ToolCallId -> Text -> Value -> IO P.Message
    -- ^ Injected tool exec — runs one call, yields a tool-result message.
  , _prd_record       :: P.Message -> IO ()
    -- ^ Per-session transcript append.
  , _prd_seedCtx      :: IO Context
    -- ^ Seed the conversation 'Context' (prod: from the session transcript).
  , _prd_model        :: ModelId
  , _prd_systemPrompt :: Maybe Text
  , _prd_tools        :: IO [P.ToolDefinition]
    -- ^ Advertised tool definitions, read PER TURN (so tools connected after
    --   the tab was created — e.g. via @\/mcp connect@ — are still advertised
    --   to the LLM, matching the legacy loop's per-turn @effectiveRegistry@).
  , _prd_maxTokens    :: Maybe Int
  , _prd_fork         :: IO () -> IO Tab.TabRunner
    -- ^ The @_env_fork@ seam.
  , _prd_inputBound   :: Int
    -- ^ Input queue capacity.
  }

-- | Build + start a provider-session runtime.
--
-- Seeds the 'Context' via '_prd_seedCtx' into an 'IORef' owned by the single
-- forked worker (so the worker is the sole Context writer). The worker loops
-- forever reading one user text off a bounded 'TBQueue', running
-- 'runTurnWithTools', and writing the resulting 'Context' back. '_rt_send'
-- non-blockingly enqueues onto that queue (returns @'Left' …@ when full, like
-- the legacy per-tab loop); '_rt_stop' cancels the worker.
mkProviderRuntime :: ProviderRuntimeDeps -> IO Runtime
mkProviderRuntime deps = do
  ctx0   <- _prd_seedCtx deps
  ctxRef <- newIORef ctx0
  inputQ <- newTBQueueIO (fromIntegral (max 1 (_prd_inputBound deps)))
  sidRef <- newIORef (0 :: Word64)
  let mkTurnDeps tools = TurnDeps
        { _turn_stream       = _prd_stream deps
        , _turn_execTool     = _prd_execTool deps
        , _turn_emit         = emitTurnEvent deps
        , _turn_record       = _prd_record deps
        , _turn_nextStreamId = nextStreamId sidRef
        , _turn_model        = _prd_model deps
        , _turn_systemPrompt = _prd_systemPrompt deps
        , _turn_tools        = tools
        , _turn_maxTokens    = _prd_maxTokens deps
        }
      worker = forever $ do
        userText <- atomically (readTBQueue inputQ)
        -- Read the advertised tools PER TURN so tools connected after this tab
        -- was created (e.g. via @/mcp connect@) are still seen (pureclaw-2u4).
        tools <- _prd_tools deps
        ctx   <- readIORef ctxRef
        ctx'  <- runTurnWithTools (mkTurnDeps tools) ctx userText
        writeIORef ctxRef ctx'
  runner <- _prd_fork deps worker
  pure Runtime
    { _rt_send = \t -> atomically $ do
        full <- isFullTBQueue inputQ
        if full
          then pure (Left (Tab.TabConcurrencyLimit 0))
          else do
            writeTBQueue inputQ t
            pure (Right ())
    , _rt_stop = Tab._trun_cancel runner
    }

-- | Map one env-light 'TurnEvent' to a ref-tagged 'ChannelEvent' and emit it.
--
-- The 'Tab.TabIndex' in 'StreamStart' is the vestigial 'placeholderSlot' (the
-- relay routes by 'TabRef', not slot).
emitTurnEvent :: ProviderRuntimeDeps -> TurnEvent -> IO ()
emitTurnEvent deps = \case
  TurnStart sid   -> emit (StreamStart sid placeholderSlot)
  TurnChunk sid t -> emit (ChunkOf sid t)
  TurnEnd   sid   -> emit (StreamEnd sid)
  -- A provider failure: relay the legacy "Something went wrong" text as a
  -- whole-message 'FullMsg' (pureclaw-9d0). 'FullMsg' reaches every channel
  -- via @_ch_send@ — including the non-streaming Signal\/Telegram path (ao9) —
  -- whereas the stream framing only reaches streaming sinks.
  TurnError _sid t -> emit (FullMsg placeholderSlot t)
  where
    emit = _prd_emit deps (_prd_ref deps)

-- | The vestigial slot stamped into 'StreamStart'. Built via the
-- comprehension-filter trick (mirroring "PureClaw.Tabs.Types") so the
-- impossible @'Tab.mkTabIndex' 0 == Nothing@ branch introduces no uncoverable
-- alternative and the value is total (no partial @head@\/@fromJust@).
placeholderSlot :: Tab.TabIndex
placeholderSlot = NE.head (NE.fromList (Maybe.catMaybes [Tab.mkTabIndex 0]))

-- | Allocate a fresh, monotonically-increasing 'StreamId' (one per completion
-- leg). Atomic so concurrent reads (there are none today — single worker — but
-- the contract is allocator-safe) never collide.
nextStreamId :: IORef Word64 -> IO StreamId
nextStreamId ref = do
  n <- atomicModifyIORef' ref (\k -> (k + 1, k))
  pure (mkStreamId n)

-- ---------------------------------------------------------------------------
-- Harness runtime
-- ---------------------------------------------------------------------------

-- | The injected effects 'mkHarnessRuntime' needs.
data HarnessRuntimeDeps = HarnessRuntimeDeps
  { _hrd_ref        :: TabRef
    -- ^ This runtime's tab ref (a @BoundHarness@). Output is tagged with it.
  , _hrd_emit       :: TabRef -> ChannelEvent -> IO ()
    -- ^ Output sink: tags + enqueues to the relay-writer queue.
  , _hrd_handle     :: HarnessHandle
    -- ^ The harness I/O handle (@_hh_send@\/@_hh_receive@\/@_hh_status@).
  , _hrd_fork       :: IO () -> IO Tab.TabRunner
    -- ^ The @_env_fork@ seam (forks the drainer + writer).
  , _hrd_pollMicros :: Int
    -- ^ Drainer sleep between @_hh_receive@ polls (microseconds).
  , _hrd_sendBound  :: Int
    -- ^ Send queue capacity.
  }

-- | Build + start a harness runtime.
--
-- Forks a /writer/ that drains a bounded send queue to @_hh_send@, and a
-- /drainer/ that polls @_hh_receive@: each non-empty capture is sanitised
-- ('sanitizeHarnessOutput', decoded as UTF-8) and emitted as a ref-tagged
-- 'FullMsg'. When @_hh_status@ reports 'HarnessExited' the drainer stops
-- (without throwing). '_rt_send' enqueues the UTF-8 bytes of its argument;
-- '_rt_stop' cancels both threads but does __not__ stop the harness.
mkHarnessRuntime :: HarnessRuntimeDeps -> IO Runtime
mkHarnessRuntime deps = do
  let h = _hrd_handle deps
  sendQ <- newTBQueueIO (fromIntegral (max 1 (_hrd_sendBound deps)))
  let writer = forever $ do
        bs <- atomically (readTBQueue sendQ)
        _hh_send h bs
      drainer = do
        status <- _hh_status h
        case status of
          HarnessExited _ -> pure ()   -- harness gone: stop draining, no throw
          HarnessRunning  -> do
            out <- _hh_receive h
            unless (BS.null out) $ do
              let txt = sanitizeHarnessOutput (TE.decodeUtf8 out)
              unless (T.null txt) $
                _hrd_emit deps (_hrd_ref deps) (FullMsg placeholderSlot txt)
            threadDelay (max 0 (_hrd_pollMicros deps))
            drainer
  writerRunner  <- _hrd_fork deps writer
  drainerRunner <- _hrd_fork deps drainer
  pure Runtime
    { _rt_send = \t -> atomically $ do
        full <- isFullTBQueue sendQ
        if full
          then pure (Left (Tab.TabConcurrencyLimit 0))
          else do
            writeTBQueue sendQ (TE.encodeUtf8 t)
            pure (Right ())
    , _rt_stop = do
        -- Cancel both threads; do NOT call _hh_stop (harness keeps running).
        Tab._trun_cancel drainerRunner
        Tab._trun_cancel writerRunner
    }
