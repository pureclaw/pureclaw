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
-- 'runLogTailer' is the driving loop around 'tailStep': poll and forward each
-- 'ProseTurn' to a sink. No tail offset is persisted across (re)starts — on
-- every (re)start it seeks to EOF ('seekStart' … 'Nothing'); replay correctness
-- rests entirely on the disk-seeded recorded-id set ('seedRecordedIds' +
-- 'recordOnce'), not on a saved byte offset. It
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

    -- * Log provider over a shared tail state
  , LogTurnState (..)
  , emptyLogTurnState
  , applyProseTurn
  , mkLogTurnProvider

    -- * Cached provider selection (no per-tick decode/WARN spam)
  , LogProviderState (..)
  , ResolveInputs (..)
  , selectLogProvider

    -- * Recorded-id dedup (idempotent replay)
  , seedRecordedIds
  , recordOnce

    -- * Tailer driver
  , runLogTailer
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad qualified as Monad
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

import PureClaw.Core.Types (SessionId)
import PureClaw.Handles.Harness (HarnessHandle (..))
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Transcript (TranscriptHandle (..))
import PureClaw.Harness.ClaudeLogPath
  ( ClaudeLogPathError (..)
  , SafeClaudeLogPath
  )
import PureClaw.Harness.ClaudeLogProse
  ( ProseTurn (..)
  , deriveTurnId
  , emptyProseState
  )
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
-- Log provider over a shared tail state
-- ---------------------------------------------------------------------------

-- | The mutable state shared between the tailer (writer) and the log
-- 'TurnProvider' (reader): the current turn's text, its finalize flag, and its
-- pinned @(derivedId, timestamp)@ (Nothing until the first assistant line of a
-- turn arrives).
data LogTurnState = LogTurnState
  { _lts_text      :: !Text
  , _lts_finalized :: !Bool
  , _lts_turnId    :: !(Maybe (Text, UTCTime))
  } deriving stock (Eq, Show)

-- | The initial empty turn state.
emptyLogTurnState :: LogTurnState
emptyLogTurnState = LogTurnState
  { _lts_text      = ""
  , _lts_finalized = False
  , _lts_turnId    = Nothing
  }

-- | Fold a freshly-yielded 'ProseTurn' into the shared state. The derived id is
-- @deriveTurnId sessionId (_pt_sourceUuid)@ — deterministic from durable JSONL
-- bytes (the first assistant line's uuid), pinned with the supplied event
-- timestamp @ts@. The text + finalize flag track the latest 'ProseTurn'.
applyProseTurn :: Text -> UTCTime -> ProseTurn -> LogTurnState -> LogTurnState
applyProseTurn sessionId ts pt _prev = LogTurnState
  { _lts_text      = _pt_text pt
  , _lts_finalized = _pt_finalized pt
  , _lts_turnId    = Just (deriveTurnId sessionId (_pt_sourceUuid pt), ts)
  }

-- | A log 'TurnProvider' that reads the shared 'LogTurnState' IORef. The tailer
-- sink writes the IORef (via 'applyProseTurn'); the reconcile loop reads it.
mkLogTurnProvider :: IORef LogTurnState -> TurnProvider
mkLogTurnProvider ref = TurnProvider
  { _tp_snapshot = do
      s <- readIORef ref
      pure (_lts_text s, _lts_finalized s)
  , _tp_turnId = _lts_turnId <$> readIORef ref
  }

-- ---------------------------------------------------------------------------
-- Cached provider selection (no per-tick decode/WARN spam)
-- ---------------------------------------------------------------------------

-- | Per-harness cached selection state. The reconcile loop runs the selector
-- every tick (~2s) for every bound entry; without a cache a freshly-spawned
-- claude harness — which has NO JSONL file until its first output — would
-- re-decode @session.json@, re-resolve the base, and re-attempt (and re-WARN)
-- on every tick for the entire pre-first-output window. These three states make
-- that cheap and quiet:
--
--   * 'LpResolved' — success: the log tailer has engaged; return the cached
--     log 'TurnProvider' as-is.
--   * 'LpPending' — a valid @claude-code@ harness whose log file is not present
--     YET (a 'ClaudeLogNotFound', the NORMAL pre-output state). Caches a CHEAP
--     re-attempt closure (only 'mkSafeClaudeLogPath' — the validated uuid\/base
--     are already closed over), so subsequent ticks do NOT re-decode
--     @session.json@ and do NOT WARN, yet the provider still ENGAGES the moment
--     the JSONL appears (a later 'Right' transitions to 'LpResolved').
--   * 'LpFallback' — permanently the tmux\/null fallback: not @claude-code@, no
--     or invalid uuid, OR a genuine (non-not-found) resolution error. WARNed at
--     most once; the input resolver is never re-run.
data LogProviderState
  = LpResolved !TurnProvider
  | LpPending !(IO (Either ClaudeLogPathError SafeClaudeLogPath))
  | LpFallback

-- | Outcome of the one-time \"resolve inputs\" phase (decode @session.json@,
-- resolve the claude base). Keeps the expensive\/fragile input resolution OUT
-- of the per-tick path: it runs once, and its result is cached as either a
-- permanent 'LpFallback' or a cheap re-attemptable 'LpPending'\/'LpResolved'.
data ResolveInputs
  = -- | Not a resolvable @claude-code@ log source (not @claude-code@, no uuid,
    -- invalid uuid). Carries the one-shot WARN text. Cached as 'LpFallback'.
    RiFallback !Text
  | -- | The inputs are valid; carries a CHEAP re-attempt closure that only
    -- re-runs 'mkSafeClaudeLogPath' (no @session.json@ decode, no base
    -- re-resolution). Its first result is classified by 'selectLogProvider':
    -- 'Right' → engage ('LpResolved'); 'Left' 'ClaudeLogNotFound' → 'LpPending'
    -- (re-attempt next tick, no WARN); any other 'Left' → 'LpFallback' (WARN
    -- once).
    RiReady !(IO (Either ClaudeLogPathError SafeClaudeLogPath))

-- | True for the one error that means \"the log just is not on disk yet\" — the
-- expected, transient pre-first-output state. Every OTHER error
-- (ambiguity, symlink escape, owner\/mode) is a genuine fault that must NOT be
-- treated as Pending (it would re-attempt forever); those become 'LpFallback'.
isNotFound :: ClaudeLogPathError -> Bool
isNotFound (ClaudeLogNotFound _) = True
isNotFound _                     = False

-- | Choose the turn-content provider for one entry, caching the decision per
-- key so the per-tick path neither re-decodes inputs nor WARN-spams.
--
-- On a cache HIT: 'LpResolved' returns the cached provider; 'LpFallback'
-- returns @fallback@ (no work, no WARN); 'LpPending' cheaply RE-ATTEMPTS via the
-- cached closure — on 'Right' it transitions to 'LpResolved' (engage), on a
-- still-not-found 'Left' it stays Pending and returns @fallback@ WITHOUT
-- WARNing, and on a genuine non-not-found 'Left' it transitions to 'LpFallback'
-- (WARN once).
--
-- On a cache MISS: run the one-time @resolveInputs@. 'RiFallback' caches
-- 'LpFallback' and WARNs once; 'RiReady' runs the cheap attempt once and
-- classifies it exactly as the Pending re-attempt does.
--
-- @engage@ is the IO that seeds the recorded-id set, starts the tailer Async,
-- and builds the log 'TurnProvider' (run at most once, on the first 'Right').
selectLogProvider
  :: Ord k
  => IORef (Map k LogProviderState)
  -> k
  -> TurnProvider
  -- ^ tmux\/null fallback provider for this entry
  -> IO ResolveInputs
  -- ^ one-time input resolution (decode @session.json@, resolve base)
  -> (SafeClaudeLogPath -> IO TurnProvider)
  -- ^ engage on the first 'Right': seed + start tailer + build provider
  -> (Text -> IO ())
  -- ^ WARN sink (fired at most once per key)
  -> IO TurnProvider
selectLogProvider cacheRef key fallback resolveInputs engage warn = do
  cached <- Map.lookup key <$> readIORef cacheRef
  case cached of
    Just (LpResolved p) -> pure p
    Just LpFallback     -> pure fallback
    Just (LpPending reattempt) -> reattempt >>= classify reattempt
    Nothing -> do
      ri <- resolveInputs
      case ri of
        RiFallback warnTxt -> do
          modifyIORef' cacheRef (Map.insert key LpFallback)
          warn warnTxt
          pure fallback
        RiReady reattempt ->
          reattempt >>= classify reattempt
  where
    -- Classify one attempt result, transitioning the cache + (at most once)
    -- WARNing. A genuine fault transitions to 'LpFallback' exactly once per key
    -- — whether reached on the first attempt (cache miss) or on a later Pending
    -- re-attempt — so the WARN here fires at most once per key.
    classify reattempt = \case
      Right safePath -> do
        prov <- engage safePath
        modifyIORef' cacheRef (Map.insert key (LpResolved prov))
        pure prov
      Left err
        | isNotFound err -> do
            -- Expected pre-output state: stay Pending, re-attempt next tick,
            -- NO WARN. (Idempotent re-insert keeps the closure cached.)
            modifyIORef' cacheRef (Map.insert key (LpPending reattempt))
            pure fallback
        | otherwise -> do
            modifyIORef' cacheRef (Map.insert key LpFallback)
            warn (faultWarn err)
            pure fallback

    faultWarn err =
      "harness log unavailable (" <> textShow err <> ") — falling back to tmux"

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
  Monad.when isNew (record sid entry)

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
      -- No persisted offset: 'Nothing' seeks to EOF on every (re)start. Replay
      -- correctness rests on the disk-seeded recorded-id set, not a saved
      -- offset (see this module's header).
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
