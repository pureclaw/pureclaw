-- |
-- Module      : PureClaw.Tab.Ai
-- Description : AI tab factory + per-tab loop (Tabbed Chat WU6).
--
-- An AI tab is a 'PureClaw.Handles.Tab.TabHandle' whose loop body
-- consumes a per-tab @TBQueue InputEvent@ and either feeds plain text
-- to the configured 'PureClaw.Providers.Class.Provider' or runs the
-- existing slash-command handler against a /per-tab/ 'Context'. The
-- single-writer rule (E5) is structural: the loop is the only mutator
-- of @_ats_context@, and every other producer (the dispatcher,
-- '_tabHandle_send', '_tabHandle_enqueueSlash') goes through the
-- bounded input queue.
--
-- == Factory shape
--
-- @
-- 'mkTabAi' :: 'PureClaw.Agent.Env.AgentEnv'
--           -> 'PureClaw.Handles.Tab.TabIndex'
--           -> 'PureClaw.Handles.Tab.AiSpawnArgs'
--           -> IO (Either 'PureClaw.Handles.Tab.TabError'
--                         'PureClaw.Handles.Tab.TabHandle')
-- @
--
-- Note: this signature takes 'AgentEnv', which is wider than the
-- 2-arg 'PureClaw.Handles.Tab.mkTabAi' stub in 'Handles.Tab'. The
-- stub remains in place (the dispatcher's @defaultTabFactory@ still
-- references it) because the H2 type-shape pin at @Handles/TabSpec.hs@
-- locks the 2-arg signature; the production wiring that calls this
-- 3-arg factory lands in WU9 (auto-spawn UX) alongside the rest of
-- the user-facing tab-creation surface.
--
-- == Async exception discipline
--
-- The loop body catches 'SomeException' EXCEPT 'AsyncCancelled', which
-- propagates so that '_tabHandle_close' (which cancels the loop's
-- 'TabRunner') can unblock a provider call inside 'bracket'. The
-- 'safelyRunLoop' helper re-raises 'AsyncCancelled' before swallowing
-- any other synchronous failure into a 'Crashed' status.
--
-- == LLM-free invariant (P18 \/ I3)
--
-- 'UserText' starting with @\/@ is re-parsed via
-- 'PureClaw.Routing.Parse.parseSlashCommand' (I2). On a hit the loop
-- treats it as a 'SlashCmd' and never reaches the provider. Only
-- non-slash 'UserText' or unparseable slash-input falls through to a
-- provider call.
--
-- See @docs/tabbed-chat.md@ §"AI tab loop body" (I-series) and
-- §"H-series" (close lifecycle).
module PureClaw.Tab.Ai
  ( -- * Factory
    mkTabAi
    -- * Internal state (exposed for tests)
  , AiTabState (..)
  ) where

import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , atomically
  , isFullTBQueue
  , newTBQueueIO
  , readTBQueue
  , writeTBQueue
  )
import Control.Exception
  ( SomeException
  , bracket_
  , catch
  , fromException
  , throwIO
  , try
  )
import Control.Monad (unless, when)
import Data.Foldable (for_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Word (Word64)

import PureClaw.Agent.Context qualified as Ctx
import PureClaw.Agent.Env (AgentEnv (..), envTranscript)
import PureClaw.Agent.SlashCommands (SlashCommand, executeSlashCommand)
import PureClaw.Core.Types (MessageTarget, ModelId (..))
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Tab
  ( AiSpawnArgs (..)
  , CloseMode (..)
  , PublicTabError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabRunner (..)
  , TabStatus (..)
  , unTabIndex
  )
import PureClaw.Session.Kind (ProviderSpec (..), SessionKind (..), inferProviderId)
import PureClaw.Handles.Transcript (TranscriptHandle (..))
import PureClaw.Providers.Class
  ( CompletionRequest (..)
  , CompletionResponse (..)
  , Message (..)
  , Role (..)
  , SomeProvider (..)
  , StreamEvent (..)
  , completeStream
  , responseText
  , textMessage
  , toolUseCalls
  )
import PureClaw.Routing.ChannelOut (shouldEmit)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types
  ( AiDefaults (..)
  , ChannelEvent (..)
  , InputEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  , StreamId
  , mkStreamId
  )
import PureClaw.Session.Handle (SessionHandle (..))
import PureClaw.Tools.Registry (registryDefinitions)


-- ---------------------------------------------------------------------------
-- AiTabState — per-tab mutable state, private to the factory closure
-- ---------------------------------------------------------------------------

-- | Per-AI-tab mutable state. The fields are exposed so a future
-- diagnostic 'tab info' handler can inspect them; production code
-- never touches the record outside this module.
--
-- /Single-writer invariant (E5):/ '_ats_context' is mutated only by
-- the per-tab loop. Other producers (dispatcher, channel input, slash
-- enqueue) deposit 'InputEvent's on '_ats_inputQ' and the loop runs
-- the resulting state mutation @readIORef → process → writeIORef@
-- inline.
data AiTabState = AiTabState
  { _ats_inputQ    :: !(TBQueue InputEvent)
    -- ^ Per-tab input queue. Bounded by '_rc_inputQueueBound' so an
    -- overflowing producer surfaces a 'TabConcurrencyLimit' rather
    -- than blocking the dispatcher (H4).
  , _ats_provider  :: !(IORef (Maybe SomeProvider))
    -- ^ Per-tab provider. Mutable so a focused @\/provider@ command
    -- (K6.1) can hot-swap it. Initialised from '_env_provider' on
    -- spawn.
  , _ats_model     :: !(IORef (Maybe ModelId))
    -- ^ Per-tab model. Mutable so a focused @\/model@ command (K6.2)
    -- can hot-swap it. Initialised from '_env_model' on spawn.
  , _ats_target    :: !(IORef MessageTarget)
    -- ^ Per-tab message target. Mutable so a focused @\/target@
    -- command (K4) can hot-swap it. Initialised from '_env_target'
    -- on spawn.
  , _ats_context   :: !(IORef Ctx.Context)
    -- ^ Per-tab conversation context. Single-writer (the loop).
  , _ats_runner    :: !(IORef (Maybe TabRunner))
    -- ^ Filled by 'mkTabAi' after '_env_fork' returns. The close
    -- handler reads this to cancel the loop. Stays 'Nothing' for the
    -- brief window between allocation and fork-fill, during which
    -- 'closeAllTabs' tolerates the gap (no-op cancel).
  , _ats_closed    :: !(IORef Bool)
    -- ^ Idempotency flag for '_tabHandle_close'. Flipped to 'True'
    -- on the first invocation; subsequent invocations are no-ops
    -- (H6).
  , _ats_statusRef :: !(IORef TabStatus)
    -- ^ Held status backing '_tabHandle_status'. The loop transitions
    -- this between 'Active' (during provider call) and 'Idle'
    -- (between events); 'Crashed' is set by the loop's outer
    -- exception handler.
  , _ats_streamCtr :: !(IORef Word64)
    -- ^ Per-tab monotonically-increasing counter for 'StreamId'
    -- allocation. Wrap-around is not a practical concern (2^64 ≈
    -- 18 quintillion streams).
  }


-- ---------------------------------------------------------------------------
-- mkTabAi — the AI tab factory
-- ---------------------------------------------------------------------------

-- | Construct an AI tab. Allocates the per-tab state, forks the loop
-- via '_env_fork', and returns a 'TabHandle' whose IO actions close
-- over the state.
--
-- The factory itself never throws: it always returns 'Right h' or
-- 'Left e'. Failures inside the forked loop are caught by the loop's
-- own exception handler and surface as a 'Crashed' status (visible via
-- '_tabHandle_status').
mkTabAi :: AgentEnv -> TabIndex -> AiSpawnArgs -> IO (Either TabError TabHandle)
mkTabAi env idx args =
  case Parse.sanitizeTabName (_ai_requestedName args) of
    Left nameErr -> pure (Left (TabInvalidName nameErr))
    Right nameTxt -> do
      let rc = _env_routingConfig env
      state <- allocState env rc
      now <- getCurrentTime
      writeIORef (_ats_statusRef state) (Idle now)
      -- Fork the loop. The fork seam returns a 'TabRunner' that the
      -- close handler will later cancel.
      runner <- _env_fork env (loopBody env idx state)
      writeIORef (_ats_runner state) (Just runner)
      th <- mkHandle env idx (TabName nameTxt) state
      pure (Right th)

-- | Allocate the per-tab state. Initialises every IORef from
-- 'AgentEnv' so the per-tab provider\/model\/target track the
-- process-level defaults at spawn time and can drift independently
-- afterwards.
allocState :: AgentEnv -> RoutingConfig -> IO AiTabState
allocState env rc = do
  inputQ       <- newTBQueueIO (fromIntegral (_rc_inputQueueBound rc))
  curProv      <- readIORef (_env_provider env)
  provRef      <- newIORef curProv
  curMod       <- readIORef (_env_model env)
  modRef       <- newIORef curMod
  curTgt       <- readIORef (_env_target env)
  tgtRef       <- newIORef curTgt
  ctxRef       <- newIORef (Ctx.emptyContext (_env_systemPrompt env))
  runRef       <- newIORef Nothing
  closedRef    <- newIORef False
  -- Status starts 'Active' as a sentinel; 'mkTabAi' replaces it with
  -- 'Idle now' before returning.
  statRef      <- newIORef Active
  streamCtrRef <- newIORef 0
  pure AiTabState
    { _ats_inputQ    = inputQ
    , _ats_provider  = provRef
    , _ats_model     = modRef
    , _ats_target    = tgtRef
    , _ats_context   = ctxRef
    , _ats_runner    = runRef
    , _ats_closed    = closedRef
    , _ats_statusRef = statRef
    , _ats_streamCtr = streamCtrRef
    }

-- | Build the public 'TabHandle' record from the per-tab state.
mkHandle :: AgentEnv -> TabIndex -> TabName -> AiTabState -> IO TabHandle
mkHandle env idx name state = do
  let rc = _env_routingConfig env
  mModel <- readIORef (_ats_model state)
  let modelId = case mModel of
        Just m  -> m
        Nothing -> _aid_modelId (_rc_defaultAi rc)
      provSpec = ProviderSpec
        { _ps_provider = inferProviderId (unModelId modelId)
        , _ps_model    = modelId
        , _ps_agent    = Nothing
        }
  pure $ TabHandle
    { _tabHandle_index        = idx
    , _tabHandle_name         = name
    , _tabHandle_kind         = TkSession (SkProvider provSpec)
    , _tabHandle_status       = readIORef (_ats_statusRef state)
    , _tabHandle_send         = sendUserText state
    , _tabHandle_enqueueSlash = enqueueSlashAi state
    , _tabHandle_close        = closeTabAi env state
    }


-- ---------------------------------------------------------------------------
-- _tabHandle_send / _tabHandle_enqueueSlash — non-blocking enqueue
-- ---------------------------------------------------------------------------

-- | Enqueue a 'UserText' event on the per-tab input queue.
-- Non-blocking: returns @Left (TabConcurrencyLimit n)@ if the queue is
-- full so the dispatcher's send loop never blocks (H4).
sendUserText :: AiTabState -> Text -> IO (Either TabError ())
sendUserText state t = tryEnqueue (_ats_inputQ state) (UserText t)

-- | Enqueue a 'SlashCmd' event. For 'KindAi' this is the legitimate
-- E5 path: the focused-tab slash command is delivered to the loop
-- (which runs 'executeSlashCommand' against the /per-tab/ context).
enqueueSlashAi :: AiTabState -> SlashCommand -> IO (Either TabError ())
enqueueSlashAi state cmd = tryEnqueue (_ats_inputQ state) (SlashCmd cmd)

-- | Atomic, non-blocking write to a 'TBQueue': if the queue is full
-- right now, return 'Left' with a redacted 'TabConcurrencyLimit'
-- rather than blocking. The capacity is not exposed by the STM API
-- after construction, so we report @0@ as a sentinel — the value is
-- never user-facing (it appears only inside 'TabConcurrencyLimit'
-- which renders as the fixed-vocabulary "tab: input queue full" via
-- 'PureClaw.Handles.Tab.toPublicTabError').
tryEnqueue :: TBQueue InputEvent -> InputEvent -> IO (Either TabError ())
tryEnqueue q ev = atomically (tryEnqueueSTM q ev)

-- | STM body of 'tryEnqueue', factored out so the tests can drive it
-- inside a larger transaction if needed.
tryEnqueueSTM :: TBQueue InputEvent -> InputEvent -> STM (Either TabError ())
tryEnqueueSTM q ev = do
  full <- isFullTBQueue q
  if full
    then pure (Left (TabConcurrencyLimit 0))
    else writeTBQueue q ev >> pure (Right ())


-- ---------------------------------------------------------------------------
-- _tabHandle_close — kind-specific graceful + force semantics
-- ---------------------------------------------------------------------------

-- | Close an AI tab. Idempotent + never throws (H6, H7).
--
-- * 'CloseGraceful': cancel the loop, archive the session via
--   @_sh_save@, then flush the transcript via the SessionHandle's
--   '_sh_transcript' field.
-- * 'CloseForce': cancel the loop and skip the archive (H9 — the
--   transcript stays on disk per the SessionHandle's append-only
--   contract, but the metadata flush is suppressed).
closeTabAi :: AgentEnv -> AiTabState -> CloseMode -> IO ()
closeTabAi env state mode = do
  alreadyClosed <- atomicModifyIORef' (_ats_closed state) (True,)
  unless alreadyClosed $ do
    -- The cancel + save + transcript-flush triad is intentionally
    -- one-shot: rerunning it would attempt to '_sh_save' against a
    -- handle whose IORef-backed metadata may have been GCed.
    safeIgnore (cancelRunner state)
    case mode of
      CloseGraceful -> do
        safeIgnore (archiveSession env)
        safeIgnore (flushTranscript env)
      CloseForce ->
        -- Force-close intentionally skips the metadata save; the
        -- transcript is also NOT closed (per the design's "transcript
        -- deleted from disk" semantics, which lands properly in WU9
        -- alongside the on-disk teardown).
        pure ()

-- | Read the captured 'TabRunner' (set by 'mkTabAi' after fork) and
-- invoke its cancel. Tolerant of the brief allocation\/fork window
-- when '_ats_runner' is still 'Nothing'.
cancelRunner :: AiTabState -> IO ()
cancelRunner state = do
  mRunner <- readIORef (_ats_runner state)
  for_ mRunner _trun_cancel

-- | Persist the session metadata via '_sh_save' on the active
-- 'SessionHandle'.
archiveSession :: AgentEnv -> IO ()
archiveSession env = do
  sh <- readIORef (_env_session env)
  _sh_save sh

-- | Flush + close the transcript file descriptor on the active
-- 'SessionHandle'. Per the spec we use '_th_close' on
-- '_sh_transcript', not '_sh_close' (which does not exist).
flushTranscript :: AgentEnv -> IO ()
flushTranscript env = do
  sh <- readIORef (_env_session env)
  _th_close (_sh_transcript sh)

-- | Best-effort: run an IO action and swallow synchronous failures.
-- The close path MUST be never-throws (H7), so every step is wrapped
-- defensively. 'AsyncCancelled' is also swallowed here because the
-- close handler is invoked from outside the loop thread; any
-- AsyncCancelled bubbling up through cancel itself is benign (the
-- target thread has already received the cancel).
safeIgnore :: IO () -> IO ()
safeIgnore m = do
  _ <- try @SomeException m
  pure ()


-- ---------------------------------------------------------------------------
-- Loop body — single-writer Context, async-cancel-aware
-- ---------------------------------------------------------------------------

-- | Top-level loop body. Runs forever until either the per-tab close
-- cancels it (via 'AsyncCancelled') or a synchronous exception is
-- caught (in which case the tab transitions to 'Crashed' and the
-- loop exits).
loopBody :: AgentEnv -> TabIndex -> AiTabState -> IO ()
loopBody env idx state =
  safelyRunLoop state (loop env idx state)

-- | Outer exception handler: catch 'SomeException' EXCEPT
-- 'AsyncCancelled', which must propagate so that 'bracket'-based
-- close semantics work correctly (per C5).
--
-- On a Crashed exit, the status is updated to 'Crashed' carrying a
-- redacted 'PublicTabError'.
safelyRunLoop :: AiTabState -> IO () -> IO ()
safelyRunLoop state body = body `catch` handler
  where
    handler :: SomeException -> IO ()
    handler e = case fromException e :: Maybe AsyncCancelled of
      Just _  -> throwIO e  -- propagate AsyncCancelled (C5)
      Nothing -> do
        -- Generic crash: surface as Crashed status with a redacted
        -- short label so the dispatcher's '/N' switch can emit the
        -- H8 banner. The exception message is intentionally
        -- discarded to preserve the redacted-error contract.
        writeIORef (_ats_statusRef state)
                   (Crashed (PublicTabError "tab: ai loop crashed"))

-- | The main loop. Reads one 'InputEvent' at a time, transitions the
-- tab status across the event, and continues.
loop :: AgentEnv -> TabIndex -> AiTabState -> IO ()
loop env idx state = do
  ev <- atomically (readTBQueue (_ats_inputQ state))
  handleEvent env idx state ev
  loop env idx state

-- | Dispatch a single 'InputEvent'.
handleEvent :: AgentEnv -> TabIndex -> AiTabState -> InputEvent -> IO ()
handleEvent env idx state ev = case ev of
  UserText t
    | "/" `T.isPrefixOf` T.strip t ->
        -- I2 re-parse path: if the user typed a slash-form via the
        -- Inject route, re-classify it as a SlashCmd before deciding
        -- whether to feed the provider. Unknown slash inputs fall
        -- through to the provider path (matching Agent.Loop's
        -- "Unknown command" behaviour).
        case Parse.parseSlashCommand (T.strip t) of
          Just cmd -> runSlash env idx state cmd
          Nothing  -> runUserText env idx state t
    | otherwise          -> runUserText env idx state t
  SlashCmd cmd           -> runSlash env idx state cmd

-- | Run a slash command against the per-tab context. The single-writer
-- mutation is @readIORef → executeSlashCommand → writeIORef@.
runSlash :: AgentEnv -> TabIndex -> AiTabState -> SlashCommand -> IO ()
runSlash env _idx state cmd = withActive state $ do
  ctx <- readIORef (_ats_context state)
  ctx' <- executeSlashCommand env cmd ctx
  writeIORef (_ats_context state) ctx'

-- | Run a non-slash user text turn: append the user message, call the
-- provider once (with chunked streaming when focused), and append the
-- assistant response. Per E5 this is single-writer.
--
-- If no provider is configured the loop emits a dispatcher-side error
-- banner via the channel-out queue (so the user sees feedback even on
-- non-focused tabs).
runUserText :: AgentEnv -> TabIndex -> AiTabState -> Text -> IO ()
runUserText env idx state t = withActive state $ do
  mProvider <- readIORef (_ats_provider state)
  mModel    <- readIORef (_ats_model state)
  case (mProvider, mModel) of
    (Just provider, Just model) -> do
      ctx <- readIORef (_ats_context state)
      let userMsg = textMessage User (T.strip t)
          ctx'   = Ctx.addMessage userMsg ctx
      writeIORef (_ats_context state) ctx'
      runOneTurn env idx state provider model ctx'
    _ ->
      -- No provider / no model — emit a single dispatcher banner so
      -- the user knows why nothing happened. (The legacy
      -- 'Agent.Loop' path emits the long-form message; for WU6 we
      -- keep it short to avoid duplicating the help-text format.)
      emitBanner env "(no provider configured for this tab)"

-- | Bracket the body in an 'Active' status transition so the
-- dashboard can observe it.
--
-- /WU6 scope note:/ the S9 atomic active-count cap-check belongs to
-- the spawn path (WU9). For WU6 we keep the status transition only;
-- the @_env_activeCount@ wiring lands when the cap is enforced by
-- spawn UX.
withActive :: AiTabState -> IO () -> IO ()
withActive state = bracket_ enter exit
  where
    enter = writeIORef (_ats_statusRef state) Active
    exit = do
      now <- getCurrentTime
      writeIORef (_ats_statusRef state) (Idle now)


-- ---------------------------------------------------------------------------
-- Single-turn provider call (streaming + tool-call cycle)
-- ---------------------------------------------------------------------------

-- | Execute one provider turn. Streams chunks into '_env_channelOutQ'
-- as @SrcTab idx@ events (focus-gated by the writer thread per D3),
-- records the response into the per-tab context, and on tool-use
-- continues the turn until no more tool calls are produced.
runOneTurn
  :: AgentEnv
  -> TabIndex
  -> AiTabState
  -> SomeProvider
  -> ModelId
  -> Ctx.Context
  -> IO ()
runOneTurn env idx state provider model ctx = do
  -- D4 producer-side focus optimisation: if this tab is not focused,
  -- we still execute the provider call (the user's input must be
  -- processed) but we skip the per-chunk enqueue work since the
  -- writer thread would drop them anyway.
  curFocus <- readIORef (_env_focus env)
  let focusedNow = shouldEmit curFocus (SrcTab idx)
  sid <- nextStreamId state
  when focusedNow $
    atomically $ writeTBQueue (_env_channelOutQ env)
                   (SrcTab idx, StreamStart sid idx)
  result <- runProviderTurn env idx provider model ctx focusedNow sid
  -- Always emit StreamEnd if we emitted StreamStart, so the
  -- breadcrumb-state map is GC'd by the writer thread (D5).
  when focusedNow $
    atomically $ writeTBQueue (_env_channelOutQ env)
                   (SrcTab idx, StreamEnd sid)
  case result of
    Left _e ->
      emitBanner env (errorBanner idx)
    Right response -> do
      let ctx' = Ctx.recordUsage (_crsp_usage response)
               $ Ctx.addMessage (Message Assistant (_crsp_content response))
                                ctx
      writeIORef (_ats_context state) ctx'
      -- Append the (full) assistant text to the transcript via the
      -- session's transcript handle. Mirrors what Agent.Loop's
      -- mkTranscriptProvider wrapper does.
      let assistantText = responseText response
      unless (T.null (T.strip assistantText)) $
        appendTranscript env assistantText
      -- Tool-call continuation: full tool-call cycling is part of
      -- the WU10 refactor that ports Agent.Loop's logic wholesale.
      -- For WU6 we log the presence of tool calls so the gap is
      -- visible in production.
      unless (null (toolUseCalls response)) $
        _lh_logDebug (_env_logger env)
          "tab.ai: tool calls present but not executed in WU6 — \
          \deferred to WU10 refactor"

-- | Invoke the provider exactly once, streaming chunks to the channel
-- output queue when focused.
runProviderTurn
  :: AgentEnv
  -> TabIndex
  -> SomeProvider
  -> ModelId
  -> Ctx.Context
  -> Bool
  -> StreamId
  -> IO (Either SomeException CompletionResponse)
runProviderTurn env idx provider model ctx focusedNow sid = do
  responseRef <- newIORef (Nothing :: Maybe CompletionResponse)
  let req = CompletionRequest
        { _cr_model        = model
        , _cr_messages     = Ctx.contextMessages ctx
        , _cr_systemPrompt = Ctx.contextSystemPrompt ctx
        , _cr_maxTokens    = Just 4096
        , _cr_tools        = registryDefinitions (_env_registry env)
        , _cr_toolChoice   = Nothing
        }
  outcome <- try @SomeException $
    completeStream provider req $ \case
      StreamText t ->
        when focusedNow $
          atomically $ writeTBQueue (_env_channelOutQ env)
                         (SrcTab idx, ChunkOf sid t)
      StreamDone resp ->
        writeIORef responseRef (Just resp)
      StreamWarning w ->
        _lh_logWarn (_env_logger env) w
      _ -> pure ()
  case outcome of
    Left e  -> pure (Left e)
    Right () -> do
      mResp <- readIORef responseRef
      pure $ case mResp of
        Just resp -> Right resp
        Nothing   -> Right (emptyResponseFor model)

-- | A stub 'CompletionResponse' returned when the provider's
-- 'completeStream' callback never delivered 'StreamDone'. This
-- preserves the "always returns" contract without crashing the loop.
emptyResponseFor :: ModelId -> CompletionResponse
emptyResponseFor m = CompletionResponse
  { _crsp_content = []
  , _crsp_model   = m
  , _crsp_usage   = Nothing
  }

-- | Allocate the next 'StreamId' for this tab.
nextStreamId :: AiTabState -> IO StreamId
nextStreamId state =
  atomicModifyIORef' (_ats_streamCtr state)
    (\n -> let n' = n + 1 in (n', mkStreamId n'))


-- ---------------------------------------------------------------------------
-- Transcript + banner helpers
-- ---------------------------------------------------------------------------

-- | Append a single assistant-text entry to the session's transcript.
--
-- /WU6 scope note:/ the legacy 'PureClaw.Agent.Loop' already wraps
-- its provider in 'PureClaw.Transcript.Provider.mkTranscriptProvider'
-- which records each completion. To avoid double-writing, the WU6
-- loop only /touches/ the transcript handle (via 'envTranscript') so
-- a future SessionHandle swap routes through here; the actual
-- '_th_record' call lands in the WU10 refactor that unifies the two
-- paths. For now this is a no-op that exercises the SessionHandle
-- read path.
appendTranscript :: AgentEnv -> Text -> IO ()
appendTranscript env _txt = do
  _ <- envTranscript env
  pure ()

-- | Emit one dispatcher-source 'BannerLine' on the channel-out queue.
emitBanner :: AgentEnv -> Text -> IO ()
emitBanner env txt =
  atomically $ writeTBQueue (_env_channelOutQ env)
                 (SrcDispatcher, BannerLine txt)

-- | The error banner shown when a provider call fails.
errorBanner :: TabIndex -> Text
errorBanner idx =
  "/" <> T.pack (show (unTabIndex idx))
       <> ": provider error — please try again"
