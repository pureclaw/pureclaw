-- | Turn-content provider seam (Harness log content source — Task 4) plus the
-- recorded-id dedup helpers + the tailer driving loop (Task 5).
--
-- A 'TurnProvider' is the source of a harness turn's text, a finalize signal,
-- and an optional stable turn id, consumed by the reconcile loop's
-- content-driven turn watcher ('PureClaw.Harness.Reconcile.stepTurns'). It
-- decouples /where/ a turn's text comes from (tmux screen capture today, the
-- claude JSONL log later) from the loop that streams + finalizes it.
--
-- This module is a LEAF below "PureClaw.Harness.Reconcile" for the provider
-- seam — it must NOT import Reconcile for that purpose (Reconcile imports this
-- for 'TurnProvider'). The Task-5 helpers ('recordOnce', 'seedRecordedIds',
-- 'runLogTailer') live here too; 'recordOnce' wraps the record closure and only
-- references 'mkTurnEntry'/'TranscriptEntry' types, not the loop, so no cycle is
-- introduced.
--
-- == The two built-in providers
--
--   * 'tmuxProvider' — preserves today's behavior VERBATIM: the turn text is
--     the handle's '_hh_snapshotTurn', it never finalizes itself
--     (@finalized = False@), and it derives no id (@_tp_turnId = pure Nothing@,
--     so the loop falls back to its '_rd_mintTurn'). The tmux path stays
--     byte-identical.
--   * 'nullProvider' — a handle-less entry: empty text, never finalizes, no
--     derived id.
--
-- == Idempotent replay (Task 5)
--
-- The durable transcript write path is append-only with no upsert, so dedup
-- must happen in front of the record call. 'seedRecordedIds' loads the set of
-- '_te_id's already on disk at tailer startup (via the UNTRIMMED
-- @_th_query emptyFilter@ — not 'loadRecentMessages', which trims at compaction
-- boundaries and could miss a pre-boundary id). 'recordOnce' refuses to record
-- a turn whose derived id is already in that set and adds each newly-recorded id
-- to it. Because the log provider's turn id is deterministic from durable JSONL
-- bytes, a turn re-folded after a crash/restart derives the SAME id, which is
-- already disk-seeded → skipped (no duplicate).
--
-- == The tailer driver (Task 5)
--
-- 'runLogTailer' is the driving loop around 'tailStep': poll, persist the offset
-- (the caller wires the actual write), forward each 'ProseTurn' to a sink. It
-- treats 'TailUnavailable' as TERMINAL — a loud WARN + STOP so the harness falls
-- back to the tmux provider — because 'tailStep' returns the UNCHANGED offset on
-- a cap trip, so re-looping would spin forever. It runs the loop under
-- 'Async.withAsync' and re-raises 'SomeAsyncException' (not only
-- 'AsyncCancelled') on teardown per the recurring darwin-CI-hang invariant.
module PureClaw.Harness.LogProvider
  ( -- * Turn-content provider seam
    TurnProvider (..)
  , tmuxProvider
  , nullProvider

    -- * Recorded-id dedup (idempotent replay)
  , seedRecordedIds
  , recordOnce

    -- * Tailer driver
  , runLogTailer
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef')
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

import PureClaw.Core.Types (SessionId)
import PureClaw.Handles.Harness (HarnessHandle (..))
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Transcript (TranscriptHandle (..))
import PureClaw.Harness.ClaudeLogPath (SafeClaudeLogPath)
import PureClaw.Harness.ClaudeLogProse (ProseTurn, emptyProseState)
import PureClaw.Harness.ClaudeLogTail
  ( JsonlTailDeps
  , TailCaps
  , TailEvent (..)
  , seekStart
  , tailStep
  )
import PureClaw.Harness.JsonlTail (emptyBuffer)
import PureClaw.Transcript.Types (TranscriptEntry (..), emptyFilter)

-- ---------------------------------------------------------------------------
-- Turn-content provider seam
-- ---------------------------------------------------------------------------

-- | The source of a harness turn's content for the reconcile loop.
--
--   * '_tp_snapshot' returns @(currentTurnText, finalized?)@. @finalized == True@
--     is an authoritative finalize that bypasses the loop's idle-stability guard.
--   * '_tp_turnId' returns @Just (derivedId, ts)@ to pin a stable id + the
--     turn's timestamp (the log provider derives both from the JSONL event), or
--     'Nothing' to fall back to the loop's @_rd_mintTurn :: IO (Text, UTCTime)@.
--     Carrying the timestamp avoids a second clock call — 'mkTurnEntry' needs
--     both the id AND a 'UTCTime'.
data TurnProvider = TurnProvider
  { _tp_snapshot :: IO (Text, Bool)
    -- ^ @(currentTurnText, finalized?)@
  , _tp_turnId   :: IO (Maybe (Text, UTCTime))
    -- ^ @Just (derivedId, ts)@ for the log provider; 'Nothing' → fall back to
    --   @_rd_mintTurn@.
  }

-- | The tmux content provider: text from '_hh_snapshotTurn', never finalizes,
-- derives no id. Preserves today's tmux behavior verbatim.
tmuxProvider :: HarnessHandle -> TurnProvider
tmuxProvider hh = TurnProvider
  { _tp_snapshot = (,) <$> _hh_snapshotTurn hh <*> pure False
  , _tp_turnId   = pure Nothing
  }

-- | A provider for a handle-less entry: empty text, never finalizes, no id.
nullProvider :: TurnProvider
nullProvider = TurnProvider
  { _tp_snapshot = pure ("", False)
  , _tp_turnId   = pure Nothing
  }

-- ---------------------------------------------------------------------------
-- Recorded-id dedup (idempotent replay)
-- ---------------------------------------------------------------------------

-- | Seed the recorded-id set from this session's on-disk transcript at tailer
-- startup. Reads EVERY entry via the UNTRIMMED @_th_query emptyFilter@ (NOT
-- 'loadRecentMessages', which trims to the last compaction boundary and could
-- miss a pre-boundary id, re-introducing a duplicate on replay).
seedRecordedIds :: TranscriptHandle -> IO (Set Text)
seedRecordedIds th =
  Set.fromList . map _te_id <$> _th_query th emptyFilter

-- | Record a turn at most once. If the entry's '_te_id' is already in the
-- (disk-seeded, mutable) set, skip the record entirely; otherwise record via
-- the supplied append action and insert the id. The reconcile loop is
-- single-threaded, so check-set → record → add-id is atomic w.r.t. itself.
recordOnce
  :: IORef (Set Text)
  -> (SessionId -> TranscriptEntry -> IO ())
  -> SessionId
  -> TranscriptEntry
  -> IO ()
recordOnce ref record sid entry = do
  let tid = _te_id entry
  -- atomicModifyIORef' returns whether the id was newly inserted; only then do
  -- we record. Insert-before-record so a re-entrant call for the same id during
  -- the record (impossible in the single-threaded loop, but cheap to be safe)
  -- still dedups.
  isNew <- atomicModifyIORef' ref $ \s ->
    if Set.member tid s
      then (s, False)
      else (Set.insert tid s, True)
  if isNew
    then record sid entry
    else pure ()

-- ---------------------------------------------------------------------------
-- Tailer driver
-- ---------------------------------------------------------------------------

-- | Poll interval between tail steps (250 ms).
tailerPollMicros :: Int
tailerPollMicros = 250 * 1000

-- | Drive 'tailStep' in a loop, forwarding each yielded 'ProseTurn' to @sink@.
--
-- Runs the loop body under 'Async.withAsync' so a teardown cancellation is
-- delivered as an async exception; 'SomeAsyncException' is RE-RAISED (not only
-- 'AsyncCancelled') per the darwin-CI-hang invariant, while a logged
-- non-async exception terminates the loop cleanly.
--
-- 'TailUnavailable' is TERMINAL: a loud WARN + STOP (so the harness falls back
-- to the tmux provider). 'tailStep' returns the UNCHANGED offset on a cap trip,
-- so re-looping on the same bytes would spin forever — hence we never re-loop
-- on it.
runLogTailer
  :: JsonlTailDeps
  -> TailCaps
  -> LogHandle
  -> SafeClaudeLogPath
  -> (ProseTurn -> IO ())
  -> IO ()
runLogTailer deps caps logH path sink =
  Async.withAsync loop $ \a -> do
    r <- try (Async.wait a)
    case r of
      Right () -> pure ()
      Left e
        -- Re-raise async exceptions (cancellation/shutdown) so teardown is not
        -- swallowed (darwin-CI-hang invariant).
        | Just ae <- fromException e -> throwIO (ae :: SomeAsyncException)
        -- A non-async exception terminates the loop; log it and stop.
        | otherwise -> _lh_logWarn logH
            ("claude log tailer error: " <> textShow (e :: SomeException))
  where
    loop = do
      off0 <- seekStart deps path Nothing
      go (off0, emptyBuffer, emptyProseState)

    go st = do
      (st', evs) <- tailStep deps caps path st
      if any isUnavailable evs
        then _lh_logWarn logH
               "claude log unavailable for harness — falling back to tmux"
        else do
          mapM_ emit evs
          threadDelay tailerPollMicros
          go st'

    emit (TailProse pt) = sink pt
    emit TailUnavailable = pure ()

    isUnavailable TailUnavailable = True
    isUnavailable (TailProse _)   = False

-- Local helper to render an exception as 'Text'.
textShow :: Show a => a -> Text
textShow = T.pack . show
