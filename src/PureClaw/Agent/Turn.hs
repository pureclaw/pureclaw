{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : PureClaw.Agent.Turn
-- Description : Env-light, single-turn provider execution with tool cycling.
--
-- == Tabs-as-View
--
-- This module is the env-light extraction of the tool-call cycle. It is the
-- reusable, per-tab core that the tabbed loop ('runTabbedLoop' via the tab
-- runtimes) drives, replacing the original env-coupled completion handler that
-- wrote @_env_channel@ directly and tail-recursed into a singleton loop.
--
-- 'runTurnWithTools' performs the logical cycle — build request, stream,
-- capture response, run any tool calls, re-complete until none remain — but
-- over an injected 'TurnDeps' record. Every effect (the provider stream, the
-- tool executor, the streaming sink, the transcript append, the 'StreamId'
-- allocator) is a field, so the function unit-tests fully with fakes: no live
-- provider, no 'PureClaw.Tools.Registry.ToolRegistry', no @AgentEnv@.
--
-- The streaming sink is a small 'TurnEvent' (start\/chunk\/end framed by a
-- 'StreamId') that carries no 'PureClaw.Handles.Tab.TabIndex' or slot
-- identity — the runtime layer (8b.3) maps 'TurnEvent' to
-- 'PureClaw.Routing.Types.ChannelEvent'. Keeping that mapping out of here is
-- what decouples 'PureClaw.Agent.Turn' from the slot\/relay machinery.
module PureClaw.Agent.Turn
  ( -- * Output events
    TurnEvent (..)
    -- * Dependencies
  , TurnDeps (..)
    -- * Running a turn
  , runTurnWithTools
    -- * Stream identifiers (re-exported for convenience)
  , StreamId
  , mkStreamId
  ) where

import Control.Exception qualified as E
import Control.Monad qualified as M
import Data.Aeson (Value)
import Data.IORef qualified as Ref
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context (Context)
import PureClaw.Agent.Context qualified as Ctx
import PureClaw.Core.Types (ModelId, ToolCallId)
import PureClaw.Providers.Class qualified as P
import PureClaw.Routing.Types (StreamId, mkStreamId)

-- ---------------------------------------------------------------------------
-- Output events
-- ---------------------------------------------------------------------------

-- | A single streaming-output event for one provider turn.
--
-- One logical streamed message is framed @'TurnStart' sid@, a sequence of
-- @'TurnChunk' sid chunk@, then @'TurnEnd' sid@. The 'StreamId' is allocated
-- once per provider completion (so a tool cycle that re-completes produces a
-- fresh 'StreamId' per leg). Deliberately env-light: no slot\/tab identity —
-- the runtime maps these to 'PureClaw.Routing.Types.ChannelEvent' in 8b.3.
--
-- @'TurnError' sid msg@ surfaces a provider failure as a visible message. The
-- the original completion handler caught a throwing stream and sent the user a
-- @TemporaryError "Something went wrong. Please try again."@; on the tabbed
-- path the throw must likewise be surfaced (pureclaw-9d0) rather than silently
-- swallowed, leaving the user with an empty 'TurnStart'\/'TurnEnd' pair.
data TurnEvent
  = TurnStart !StreamId
  | TurnChunk !StreamId !Text
  | TurnEnd   !StreamId
  | TurnError !StreamId !Text
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Dependencies
-- ---------------------------------------------------------------------------

-- | The injected effects 'runTurnWithTools' needs. Production wires:
--
--   * '_turn_stream'       — @'P.completeStream' someProvider@ (wrapped with
--                            the per-session transcript provider).
--   * '_turn_execTool'     — a closure over the session's
--                            'PureClaw.Tools.Registry.ToolRegistry' that runs
--                            one tool call and returns the tool-result
--                            'P.Message'.
--   * '_turn_emit'         — the per-conversation streaming sink.
--   * '_turn_record'       — the per-session transcript append.
--   * '_turn_nextStreamId' — a monotonic 'StreamId' allocator.
--
-- Tests inject fakes for all of these.
data TurnDeps = TurnDeps
  { _turn_stream       :: P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ()
    -- ^ Injected provider stream (prod: @'P.completeStream' someProvider@).
  , _turn_execTool     :: ToolCallId -> Text -> Value -> IO P.Message
    -- ^ Injected tool exec — runs one call, yields a tool-result 'P.Message'.
  , _turn_emit         :: TurnEvent -> IO ()
    -- ^ Injected streaming sink.
  , _turn_record       :: P.Message -> IO ()
    -- ^ Injected transcript append (user, assistant, and tool-result msgs).
  , _turn_nextStreamId :: IO StreamId
    -- ^ Allocates a fresh 'StreamId' per completion leg.
  , _turn_model        :: ModelId
  , _turn_systemPrompt :: Maybe Text
    -- ^ Overrides the context's system prompt when @'Just'@; otherwise the
    -- request falls back to 'Ctx.contextSystemPrompt' (matching Loop).
  , _turn_tools        :: [P.ToolDefinition]
  , _turn_maxTokens    :: Maybe Int
  , _turn_onStreamDone :: IO ()
    -- ^ A one-shot-style hook fired on EVERY provider 'P.StreamDone' (in
    -- addition to capturing the response). Idempotency is the action's
    -- responsibility — production wires a read-and-clear @fireOnce@ over
    -- @_env_onFirstStreamDone@ so @'markBootstrapConsumed'@ runs exactly once,
    -- restoring the the original completion handler behaviour the tabbed path
    -- dropped (pureclaw-8g4). Tests default it to @pure ()@.
  }

-- ---------------------------------------------------------------------------
-- Running a turn
-- ---------------------------------------------------------------------------

-- | Run one user turn WITH the provider's tool-call cycle, env-light.
--
-- Mirrors the original completion handler but over 'TurnDeps':
--
--   1. Append a user 'P.Message' (the text) to the 'Context' and record it.
--   2. Cycle: build a 'P.CompletionRequest' from the current context plus the
--      injected model\/system\/tools\/maxTokens; allocate a 'StreamId'; emit
--      'TurnStart'; stream — 'P.StreamText' becomes a 'TurnChunk',
--      'P.StreamWarning' is ignored, 'P.StreamDone' captures the response;
--      emit 'TurnEnd'.
--   3. Append the assistant message and record it. If 'P.toolUseCalls' is
--      empty, return the context. Otherwise run every call through
--      '_turn_execTool', append + record each tool-result message, and loop.
--   4. On a provider error (the stream throws, or yields no 'P.StreamDone'),
--      do not crash: 'TurnEnd' is still emitted (it is emitted unconditionally
--      after the stream attempt) and the context — carrying at least the user
--      message — is returned. When the stream /throws/, a 'TurnError' is also
--      emitted (after 'TurnEnd') so the failure is surfaced as a visible
--      message — restoring the legacy @TemporaryError@ visibility (pureclaw-9d0).
--      The no-'P.StreamDone' path stays a graceful, silent no-op.
runTurnWithTools :: TurnDeps -> Context -> Text -> IO Context
runTurnWithTools deps ctx0 userText = do
  let userMsg = P.textMessage P.User userText
      ctx1    = Ctx.addMessage userMsg ctx0
  _turn_record deps userMsg
  cycleTurn deps ctx1

-- | One completion leg plus the tool cycle. Recurses when the response
-- carries tool calls. Each call to 'cycleTurn' performs exactly one provider
-- completion; a tool cycle of @n@ legs invokes 'cycleTurn' @n@ times.
cycleTurn :: TurnDeps -> Context -> IO Context
cycleTurn deps ctx = do
  let req = P.CompletionRequest
        { P._cr_model        = _turn_model deps
        , P._cr_messages     = Ctx.contextMessages ctx
        , P._cr_systemPrompt = case _turn_systemPrompt deps of
            Just sys -> Just sys
            Nothing  -> Ctx.contextSystemPrompt ctx
        , P._cr_maxTokens    = _turn_maxTokens deps
        , P._cr_tools        = _turn_tools deps
        , P._cr_toolChoice   = Nothing
        }
  sid <- _turn_nextStreamId deps
  _turn_emit deps (TurnStart sid)
  responseRef <- Ref.newIORef (Nothing :: Maybe P.CompletionResponse)
  streamedRef <- Ref.newIORef False
  -- Mirror Loop's @try@ around the stream so a throwing provider does not
  -- bring the turn down. The sink, not @_env_channel@, receives framing.
  streamResult <- E.try @E.SomeException $
    _turn_stream deps req $ \case
      P.StreamText t   -> Ref.writeIORef streamedRef True >> _turn_emit deps (TurnChunk sid t)
      P.StreamWarning _ -> pure ()      -- non-fatal; logged by prod sink elsewhere
      P.StreamDone resp -> do
        Ref.writeIORef responseRef (Just resp)
        -- Fire the one-shot-style hook on every StreamDone (mirrors the legacy
        -- the original completion handler StreamDone handler that ran
        -- @_env_onFirstStreamDone@). Idempotency is the action's responsibility
        -- — production wires a read-and-clear @fireOnce@ so
        -- @markBootstrapConsumed@ runs exactly once (pureclaw-8g4).
        _turn_onStreamDone deps
      _                 -> pure ()
  -- Non-streaming providers (e.g. Ollama with @stream = False@) emit only a
  -- single 'P.StreamDone' carrying the full response and no incremental
  -- 'P.StreamText', so nothing was relayed as a 'TurnChunk' above. Mirror Loop's
  -- fallback (Loop.hs: @unless wasStreaming ... _ch_send fullText@) by emitting
  -- the whole response text as one chunk so it is displayed.
  streamed <- Ref.readIORef streamedRef
  mResp0   <- Ref.readIORef responseRef
  case mResp0 of
    Just resp | not streamed ->
      let txt = P.responseText resp
      in M.unless (T.null (T.strip txt)) $ _turn_emit deps (TurnChunk sid txt)
    _ -> pure ()
  -- 'TurnEnd' is emitted unconditionally — success, throw, or no-StreamDone —
  -- so the burst is always closed for the downstream relay.
  _turn_emit deps (TurnEnd sid)
  case streamResult of
    Left _  -> do
      -- Provider threw: surface a VISIBLE error (mirrors the legacy
      -- the original completion handler @TemporaryError@), then stop and keep the
      -- context. Emitted after 'TurnEnd' so it lands as its own message rather
      -- than as part of the (closed) stream burst (pureclaw-9d0).
      _turn_emit deps (TurnError sid "Something went wrong. Please try again.")
      pure ctx
    Right () -> do
      mResp <- Ref.readIORef responseRef
      case mResp of
        Nothing   -> pure ctx        -- no StreamDone captured: stop gracefully
        Just resp -> handleResponse deps ctx resp

-- | Fold a captured response into the context: append + record the assistant
-- message, then either finish (no tool calls) or run the calls and re-complete
-- (mirrors Loop.hs:251-268).
handleResponse :: TurnDeps -> Context -> P.CompletionResponse -> IO Context
handleResponse deps ctx resp = do
  let assistantMsg = P.Message P.Assistant (P._crsp_content resp)
      ctx'         = Ctx.recordUsage (P._crsp_usage resp)
                   $ Ctx.addMessage assistantMsg ctx
      calls        = P.toolUseCalls resp
  _turn_record deps assistantMsg
  if null calls
    then pure ctx'
    else do
      ctx'' <- M.foldM runOneCall ctx' calls
      cycleTurn deps ctx''
  where
    runOneCall :: Context -> (ToolCallId, Text, Value) -> IO Context
    runOneCall c (callId, name, input) = do
      resultMsg <- _turn_execTool deps callId name input
      _turn_record deps resultMsg
      pure (Ctx.addMessage resultMsg c)
