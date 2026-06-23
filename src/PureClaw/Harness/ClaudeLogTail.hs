-- | Bounded JSONL tail step + injectable IO seam for the claude-code session
-- log content source.
--
-- This module is the boundary between the pure logic of 'PureClaw.Harness.JsonlTail'
-- and 'PureClaw.Harness.ClaudeLogProse' and the real filesystem IO. All IO
-- operations are injected via 'JsonlTailDeps', so the step function
-- 'tailStep' can be fully unit-tested with a fake implementation backed by an
-- 'IORef ByteString'.
--
-- == Design
--
-- 'tailStep' performs ONE bounded read-fold step:
--
--   1. Probe the file size via '_jt_size'.
--   2. If @size < offset@ the file shrank\/rotated — reset state to the
--      beginning and return immediately (the caller should re-validate the
--      path and re-call).
--   3. Backfill guard: if @offset == 0@ and @size > '_tc_backfill'@ return
--      @['TailUnavailable']@ without advancing.
--   4. Read @min(size - offset, '_tc_chunk')@ bytes via '_jt_readFrom'.
--   5. Split into complete lines via 'splitLinesBounded' with '_tc_buffer' as
--      the partial-line cap; on 'OverCap' return @['TailUnavailable']@ without
--      advancing.
--   6. Enforce '_tc_line' on each complete line; a single line longer than the
--      cap yields @['TailUnavailable']@ without advancing.
--   7. Fold each complete line via 'foldProseLine', collecting a 'TailProse'
--      per yielded 'ProseTurn'.
--   8. Advance the offset by the number of bytes consumed.
--
-- NO loop and NO async live here. The driving loop + async lifecycle live in
-- Task 5 (wiring), keeping this module pure-over-deps and fully unit-coverable.
module PureClaw.Harness.ClaudeLogTail
  ( -- * Injectable IO seam
    JsonlTailDeps (..)

    -- * DoS caps
  , TailCaps (..)
  , defaultTailCaps

    -- * Step events
  , TailEvent (..)

    -- * Step function
  , tailStep

    -- * Seek helper
  , seekStart
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Time.Clock (UTCTime)

import PureClaw.Harness.ClaudeLogPath (SafeClaudeLogPath)
import PureClaw.Harness.ClaudeLogProse
  ( ProseState
  , ProseTurn
  , emptyProseState
  , foldProseLine
  )
import PureClaw.Harness.JsonlTail
  ( Buffer
  , CompleteLine
  , Offset (..)
  , SplitCap (..)
  , emptyBuffer
  , splitLinesBounded
  , unCompleteLine
  )

-- ---------------------------------------------------------------------------
-- Injectable IO seam
-- ---------------------------------------------------------------------------

-- | All filesystem IO needed by 'tailStep' and 'seekStart', injectable for
-- testing.  The production implementation opens files with @O_NOFOLLOW@ and
-- bounds reads to the requested byte count.
--
-- The 'SafeClaudeLogPath' parameter is passed through to every operation so
-- the production implementation can re-open the file per-read without holding
-- an fd between steps.
data JsonlTailDeps = JsonlTailDeps
  { _jt_size     :: SafeClaudeLogPath -> IO Integer
    -- ^ Return the current byte length of the log file.
  , _jt_readFrom :: SafeClaudeLogPath -> Offset -> Int -> IO (ByteString, Offset)
    -- ^ @_jt_readFrom path offset n@: read UP TO @n@ bytes starting at
    -- @offset@, returning the chunk and the new offset.
  , _jt_now      :: IO UTCTime
    -- ^ Current UTC time (used downstream; injected for testability).
  }

-- ---------------------------------------------------------------------------
-- DoS caps
-- ---------------------------------------------------------------------------

-- | Caps controlling the bounded tail step. All sizes are in bytes.
data TailCaps = TailCaps
  { _tc_backfill :: !Int
    -- ^ Maximum total file size for an initial (from-0) backfill.
    -- If @offset == 0@ and @fileSize > _tc_backfill@, yield 'TailUnavailable'.
  , _tc_line     :: !Int
    -- ^ Maximum length of a single complete line.
    -- A complete line whose byte count exceeds this yields 'TailUnavailable'.
  , _tc_buffer   :: !Int
    -- ^ Maximum buffered partial-line size.
    -- Passed as the cap to 'splitLinesBounded'.
  , _tc_chunk    :: !Int
    -- ^ Maximum bytes read per step: @min(fileSize - offset, _tc_chunk)@.
  }

-- | Production-safe defaults: 32 MiB backfill, 1 MiB line, 1 MiB buffer,
-- 256 KiB chunk.
defaultTailCaps :: TailCaps
defaultTailCaps = TailCaps
  { _tc_backfill = 32 * 1024 * 1024
  , _tc_line     = 1024 * 1024
  , _tc_buffer   = 1024 * 1024
  , _tc_chunk    = 256 * 1024
  }

-- ---------------------------------------------------------------------------
-- Step events
-- ---------------------------------------------------------------------------

-- | A single event emitted by 'tailStep'.
data TailEvent
  = TailProse !ProseTurn
    -- ^ A prose turn was updated or finalized.
  | TailUnavailable
    -- ^ A DoS cap was exceeded; the caller should fall back to the tmux path.
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- seekStart
-- ---------------------------------------------------------------------------

-- | Determine the starting offset for a tailer.
--
-- @seekStart deps path mPersisted@:
--
--   * @Nothing@: seek to EOF (the current file size) — record nothing
--     historical.
--   * @Just off@: resume from the persisted offset, but if it exceeds the
--     current size (e.g. after a rotation) fall back to the current size.
seekStart
  :: JsonlTailDeps
  -> SafeClaudeLogPath
  -> Maybe Offset
  -> IO Offset
seekStart deps path Nothing = do
  sz <- _jt_size deps path
  pure (Offset sz)
seekStart deps path (Just saved@(Offset off)) = do
  sz <- _jt_size deps path
  if off > sz
    then pure (Offset sz)
    else pure saved

-- ---------------------------------------------------------------------------
-- tailStep
-- ---------------------------------------------------------------------------

-- | One bounded read-fold step of the JSONL tailer.
--
-- Returns the new @(Offset, Buffer, ProseState)@ and a (possibly empty) list
-- of 'TailEvent's.  On any cap violation, returns @[TailUnavailable]@ and
-- does NOT advance the offset (the offset in the returned triple is
-- unchanged).
--
-- Rotation\/shrink detection: if the current file size is strictly less than
-- the current offset, reset state to @(Offset 0, emptyBuffer, emptyProseState)@
-- and return no events (the caller should re-validate the path and re-call).
tailStep
  :: JsonlTailDeps
  -> TailCaps
  -> SafeClaudeLogPath
  -> (Offset, Buffer, ProseState)
  -> IO ((Offset, Buffer, ProseState), [TailEvent])
tailStep deps caps path (off@(Offset offI), buf, prose) = do
  sz <- _jt_size deps path
  if sz < offI
    -- Shrink / rotation: reset state, return no events.
    then pure ((Offset 0, emptyBuffer, emptyProseState), [])
    else do
      -- Backfill guard: if we are at offset 0 and the file is too large,
      -- signal unavailability without advancing.
      if offI == 0 && sz > fromIntegral (_tc_backfill caps)
        then pure ((off, buf, prose), [TailUnavailable])
        else do
          let toRead = fromIntegral (min (sz - offI) (fromIntegral (_tc_chunk caps))) :: Int
          if toRead == 0
            -- Nothing new to read.
            then pure ((off, buf, prose), [])
            else do
              (chunk, newOff) <- _jt_readFrom deps path off toRead
              case splitLinesBounded (_tc_buffer caps) chunk buf of
                Left OverCap ->
                  -- Buffer cap exceeded: signal unavailability, no advance.
                  pure ((off, buf, prose), [TailUnavailable])
                Right (lines_, newBuf) ->
                  -- Check each complete line against the line-length cap.
                  case enforceLineCap (_tc_line caps) lines_ of
                    Left () ->
                      -- A single line was too long: signal unavailability, no advance.
                      pure ((off, buf, prose), [TailUnavailable])
                    Right goodLines ->
                      -- Fold all complete lines into the prose state.
                      let (finalProse, evs) = foldLines goodLines prose
                      in pure ((newOff, newBuf, finalProse), evs)

-- | Check that every 'CompleteLine' is within the line-length cap.
-- Returns @Left ()@ as soon as one is too long (no advance should happen).
enforceLineCap :: Int -> [CompleteLine] -> Either () [CompleteLine]
enforceLineCap maxLine = go
  where
    go [] = Right []
    go (l : ls)
      | BS.length (unCompleteLine l) > maxLine = Left ()
      | otherwise = fmap (l :) (go ls)

-- | Fold a list of complete JSONL lines through 'foldProseLine', collecting
-- 'TailProse' events for each yielded 'ProseTurn'.
foldLines :: [CompleteLine] -> ProseState -> (ProseState, [TailEvent])
foldLines [] prose = (prose, [])
foldLines (l : ls) prose =
  let (prose', mTurn) = foldProseLine (unCompleteLine l) prose
      ev = maybe [] (\t -> [TailProse t]) mTurn
      (finalProse, restEvs) = foldLines ls prose'
  in (finalProse, ev <> restEvs)
