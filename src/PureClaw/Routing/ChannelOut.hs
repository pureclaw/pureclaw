-- |
-- Module      : PureClaw.Routing.ChannelOut
-- Description : Single-writer channel-emission thread for Tabbed Chat (WU4).
--
-- A dedicated writer thread that consumes from
-- 'PureClaw.Agent.Env._env_channelOutQ' and, for each
-- @('OutputSource', 'ChannelEvent')@ pair, decides whether to emit to
-- the underlying 'ChannelHandle' or drop the event based on the
-- current '_env_focus'.
--
-- == Behaviour
--
-- * 'SrcDispatcher' events emit unconditionally (switch confirms,
--   dashboards, errors, breadcrumbs).
-- * 'SrcTab' @n@ events emit only when @_env_focus == Just n@;
--   otherwise they are dropped.
-- * Per the D5 mid-stream switch breadcrumb rule: on the FIRST drop of
--   an AI-tab stream (identified by 'StreamId') the writer emits one
--   @SrcDispatcher BannerLine "/N has new output - /N to view"@.
--   Subsequent drops of the same 'StreamId' are silent. 'StreamEnd'
--   cleans up the breadcrumb state.
-- * Dropped 'FullMsg' events (from non-AI tabs) do NOT emit a
--   breadcrumb — shell\/ssh output is line-oriented and per-line
--   breadcrumbs would be noisy (per D5 backend rule).
--
-- == Public API
--
-- * 'runChannelOutThread' — the writer loop body (runs forever until
--   asynchronously cancelled).
-- * 'startChannelOut' — fork the loop via @_env_fork@ and return the
--   resulting 'TabRunner'.
-- * 'shouldEmit' — producer-side focus pre-check helper exposed so tab
--   loops (WU6\/7\/8) can skip enqueue work when not focused (D4).
-- * 'breadcrumbText' — public for test assertions; the exact wording
--   required by D5.
--
-- See @docs\/tabbed-chat.md@ §"Channel emission via ChannelOut writer"
-- and the D-series DoDs for the full design.
module PureClaw.Routing.ChannelOut
  ( -- * Writer thread
    runChannelOutThread
  , startChannelOut
    -- * Producer-side helper (D4)
  , shouldEmit
    -- * Breadcrumb wording (exposed for tests)
  , breadcrumbText
    -- * Internal state (exposed for tests)
  , BreadcrumbState (..)
    -- * Test seam — drive one iteration with an explicit state ref.
    -- Exposed so unit tests can run the loop body a finite number of
    -- times without spawning a thread that would otherwise never
    -- return ('runChannelOutThread' loops forever).
  , oneStep
  , newBreadcrumbStateRef
  ) where

import Control.Concurrent.STM (atomically, readTBQueue)
import Control.Monad (forever, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Env
import PureClaw.Handles.Channel
import PureClaw.Handles.Tab
import PureClaw.Routing.Types


-- ---------------------------------------------------------------------------
-- BreadcrumbState
-- ---------------------------------------------------------------------------

-- | Per-'StreamId' state tracking whether the writer has already
-- emitted a mid-stream-switch breadcrumb for that stream.
--
-- * 'Pending' — the stream's owner has been focused so far (the writer
--   has emitted at least one event for this 'StreamId' without
--   dropping any). The next drop will produce a breadcrumb.
-- * 'Emitted' — a breadcrumb has already been emitted for this
--   'StreamId'; subsequent drops are silent.
--
-- The map entry is removed when the writer observes 'StreamEnd' for
-- the stream (regardless of emit\/drop outcome).
data BreadcrumbState
  = Pending
  | Emitted
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- Producer-side helper (D4)
-- ---------------------------------------------------------------------------

-- | Decide whether a producer should bother enqueueing a channel event
-- given the current focus.
--
-- This is an OPTIMISATION, not the authoritative focus gate: the
-- writer thread re-applies the same predicate on dequeue (D3). Tab
-- loops use this to avoid building large 'ChannelEvent' values for
-- non-focused streams (e.g. a fast-streaming non-focused tab would
-- otherwise saturate the bounded @_env_channelOutQ@).
--
-- The focus argument is the current value of @_env_focus@ (an
-- @'IORef' ('Maybe' 'TabIndex')@); the source argument is the
-- 'OutputSource' the producer is about to enqueue.
--
-- * 'SrcDispatcher' events are ALWAYS eligible to emit (dispatcher
--   breadcrumbs, switch confirms, errors must never be dropped).
-- * 'SrcTab' @n@ events are eligible only when the focus equals
--   @'Just' n@.
shouldEmit :: Maybe TabIndex -> OutputSource -> Bool
shouldEmit _     SrcDispatcher = True
shouldEmit focus (SrcTab n)    = focus == Just n


-- ---------------------------------------------------------------------------
-- Breadcrumb wording (D5)
-- ---------------------------------------------------------------------------

-- | The exact breadcrumb text emitted on the first drop of an AI-tab
-- stream. Format: @"/N has new output - /N to view"@ where @N@ is the
-- owner tab's index.
--
-- Exposed publicly so tests can pin the wording without re-deriving
-- it. Status-neutral phrasing per D5.
breadcrumbText :: TabIndex -> Text
breadcrumbText idx =
  let nTxt = T.pack (show (unTabIndex idx))
  in "/" <> nTxt <> " has new output - /" <> nTxt <> " to view"


-- ---------------------------------------------------------------------------
-- Writer thread
-- ---------------------------------------------------------------------------

-- | Run the channel-out writer loop forever.
--
-- Repeatedly:
--
-- 1. Reads one @('OutputSource', 'ChannelEvent')@ pair off
--    @_env_channelOutQ@ (STM-blocking).
-- 2. Reads @_env_focus@ to decide emit vs drop.
-- 3. Emits via the underlying 'ChannelHandle' or updates the
--    breadcrumb state, per the D-series rules.
--
-- The loop never terminates on its own — it must be cancelled
-- asynchronously via the 'TabRunner' returned by 'startChannelOut'.
runChannelOutThread :: AgentEnv -> IO ()
runChannelOutThread env = do
  stateRef <- newBreadcrumbStateRef
  forever (oneStep env stateRef)

-- | Spawn the writer loop using the environment's @_env_fork@ test
-- seam, returning the 'TabRunner' through which the caller can cancel
-- or wait on the writer.
--
-- The writer is intended to be started once at dispatcher boot (WU5)
-- and torn down via the same @bracket@ that cancels the per-tab
-- runners.
startChannelOut :: AgentEnv -> IO TabRunner
startChannelOut env = _env_fork env (runChannelOutThread env)


-- ---------------------------------------------------------------------------
-- One iteration (factored out for clarity + testability)
-- ---------------------------------------------------------------------------

-- | Allocate a fresh, empty breadcrumb-state 'IORef'. Exposed so unit
-- tests can drive 'oneStep' a finite number of times with their own
-- state ref; production code paths obtain the ref implicitly via
-- 'runChannelOutThread'.
newBreadcrumbStateRef :: IO (IORef (Map StreamId BreadcrumbState))
newBreadcrumbStateRef = newIORef Map.empty

-- | Process exactly one queue entry.
--
-- Exposed as a test seam ('runChannelOutThread' loops forever and so
-- is awkward to drive deterministically in a unit test). Production
-- code paths invoke this transitively via 'runChannelOutThread'.
oneStep :: AgentEnv -> IORef (Map StreamId BreadcrumbState) -> IO ()
oneStep env stateRef = do
  (src, ev) <- atomically (readTBQueue (_env_channelOutQ env))
  focus <- readIORef (_env_focus env)
  case src of
    SrcDispatcher -> emitEvent (_env_channel env) ev
    SrcTab n
      | focus == Just n -> emitWithStreamTracking (_env_channel env) stateRef ev
      | otherwise       -> dropWithBreadcrumb (_env_channel env) stateRef n ev

-- | Emit a 'ChannelEvent' that originated from the focused tab,
-- updating the breadcrumb-state map for stream lifecycle bookkeeping
-- (so that a later focus change mid-stream is correctly noticed).
emitWithStreamTracking
  :: ChannelHandle
  -> IORef (Map StreamId BreadcrumbState)
  -> ChannelEvent
  -> IO ()
emitWithStreamTracking ch stateRef ev = do
  case ev of
    StreamStart sid _ ->
      -- The owner tab is currently focused; register the stream as
      -- 'Pending' so a later drop emits exactly one breadcrumb.
      atomicModifyIORef' stateRef
        (\m -> (Map.insert sid Pending m, ()))
    StreamEnd sid ->
      -- GC the breadcrumb state on stream end (regardless of focus).
      atomicModifyIORef' stateRef
        (\m -> (Map.delete sid m, ()))
    _ -> pure ()
  emitEvent ch ev

-- | Handle a dropped 'SrcTab' event (focus does not match the source
-- tab). For stream-bearing events on an AI tab we may emit one
-- breadcrumb; for 'FullMsg' (non-AI tabs) we always drop silently.
dropWithBreadcrumb
  :: ChannelHandle
  -> IORef (Map StreamId BreadcrumbState)
  -> TabIndex
  -> ChannelEvent
  -> IO ()
dropWithBreadcrumb ch stateRef owner ev =
  case ev of
    StreamStart sid _ -> handleStreamDrop ch stateRef owner sid
    ChunkOf sid _     -> handleStreamDrop ch stateRef owner sid
    StreamEnd sid     ->
      -- Drop AND clean up: even if the stream's body went unread the
      -- map entry must not leak.
      atomicModifyIORef' stateRef
        (\m -> (Map.delete sid m, ()))
    FullMsg{}   -> pure ()  -- non-AI tab drops never breadcrumb (D5).
    BannerLine{} -> pure () -- BannerLine should only ever arrive on
                            -- SrcDispatcher; defensive no-op here.

-- | Common breadcrumb logic shared by 'StreamStart' and 'ChunkOf'
-- drops. Emits a breadcrumb iff the stream has not already been
-- breadcrumbed; updates the state map in lock-step with the emission
-- decision.
handleStreamDrop
  :: ChannelHandle
  -> IORef (Map StreamId BreadcrumbState)
  -> TabIndex
  -> StreamId
  -> IO ()
handleStreamDrop ch stateRef owner sid = do
  shouldBreadcrumb <- atomicModifyIORef' stateRef $ \m ->
    case Map.lookup sid m of
      Just Emitted -> (m, False)
      _            -> (Map.insert sid Emitted m, True)
  when shouldBreadcrumb (emitEvent ch (BannerLine (breadcrumbText owner)))

-- | Translate a 'ChannelEvent' into the underlying 'ChannelHandle'
-- calls. 'StreamStart' is metadata for the writer's state machine and
-- has no on-channel representation.
emitEvent :: ChannelHandle -> ChannelEvent -> IO ()
emitEvent ch ev = case ev of
  StreamStart{}   -> pure ()
  ChunkOf _ t     -> _ch_sendChunk ch (ChunkText t)
  StreamEnd _     -> _ch_sendChunk ch ChunkDone
  FullMsg _ t     -> _ch_send ch (OutgoingMessage t)
  BannerLine t    -> _ch_send ch (OutgoingMessage t)
