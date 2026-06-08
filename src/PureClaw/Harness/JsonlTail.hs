-- | Pure, dependency-free core of the JSONL session-log tail.
--
-- A claude-code session log is an append-only file of LF-terminated JSON
-- records. A tailer reads it in arbitrary byte chunks as it grows; chunk
-- boundaries fall wherever the OS happens to return, so a single logical line
-- may be split across two (or more) reads. This module provides the pure
-- splitting logic that turns a stream of byte chunks into a stream of complete
-- lines, buffering any trailing partial line until its terminating LF arrives.
--
-- This is the pure foundation only: there is no IO, no dependency record, and
-- no tailer loop here. WU5 extends this same module with @JsonlTailDeps@ and
-- the loop that drives 'splitLines' over a growing file.
module PureClaw.Harness.JsonlTail
  ( -- * Offsets
    Offset (..)

    -- * Complete lines
  , CompleteLine
  , unCompleteLine

    -- * Incremental line buffer
  , Buffer
  , emptyBuffer
  , unBuffer

    -- * Splitting
  , splitLines
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

-- | A byte offset into a growing log file.
--
-- 'Integer' (not 'Int') because log files may in principle exceed a 64-bit
-- offset, and because the tailer arithmetic should never silently overflow.
-- The value constructor is exported so the (future) IO tailer can construct
-- and pattern-match offsets directly; an offset carries no invariant beyond
-- "a number of bytes".
newtype Offset = Offset Integer
  deriving stock (Eq, Ord, Show)

-- | One complete, LF-delimited line — the bytes /without/ the terminating
-- @\\n@. A line may be empty (two consecutive newlines, or a leading newline).
--
-- A carriage return (@\\r@) is ordinary content: claude-code logs are
-- LF-terminated, so a @\\r@ immediately before the @\\n@ stays inside these
-- bytes (CRLF is /not/ treated specially). The value constructor is
-- intentionally hidden — 'CompleteLine' values are only ever produced by
-- 'splitLines', and consumers read the bytes back with 'unCompleteLine'.
newtype CompleteLine = CompleteLine ByteString
  deriving stock (Eq, Ord, Show)

-- | The raw bytes of a complete line, without its terminating LF.
unCompleteLine :: CompleteLine -> ByteString
unCompleteLine (CompleteLine bs) = bs

-- | Carries the trailing partial (un-terminated) bytes between successive
-- reads. After a chunk is processed, everything after the last @\\n@ is held
-- here and prepended to the next incoming chunk.
--
-- The value constructor is hidden: a 'Buffer' is only ever produced by
-- 'emptyBuffer' or threaded out of 'splitLines'. Use 'unBuffer' to inspect the
-- pending bytes (primarily for tests and diagnostics).
newtype Buffer = Buffer ByteString
  deriving stock (Eq, Ord, Show)

-- | The initial, empty buffer — no pending partial line.
emptyBuffer :: Buffer
emptyBuffer = Buffer BS.empty

-- | The pending (un-terminated) bytes currently held in the buffer.
unBuffer :: Buffer -> ByteString
unBuffer (Buffer bs) = bs

-- | Split an incoming byte chunk into complete LF-delimited lines plus a
-- residual buffer.
--
-- The incoming 'Buffer' (the partial line left over from previous reads) is
-- prepended to the chunk, so a line split across reads reassembles once its
-- @\\n@ arrives. Every complete line (the bytes up to, but not including, each
-- @\\n@) is emitted in order; the bytes after the final @\\n@ — which have no
-- terminator yet — are carried in the returned 'Buffer' and are /not/ emitted.
--
-- Edge-case semantics (all pinned down by tests):
--
--   * __Empty input__: no lines; the buffer is returned unchanged.
--   * __No LF__: the whole (buffer @<>@ chunk) is buffered; no lines.
--   * __Trailing LF__ (@"a\\n"@): emits @["a"]@, residual empty.
--   * __Leading LF__ (@"\\nx\\n"@): emits @["", "x"]@ (leading empty line).
--   * __Consecutive LFs__ (@"a\\n\\nb\\n"@): emits @["a", "", "b"]@.
--   * __Lone LF__ (@"\\n"@): emits a single empty line @[""]@.
--   * __CR preserved__ (@"a\\r\\nb\\n"@): emits @["a\\r", "b"]@ — the @\\r@
--     stays on the first line; CRLF is not special-cased.
--
-- Total function: no partial functions, no exceptions, for any input.
splitLines :: ByteString -> Buffer -> ([CompleteLine], Buffer)
splitLines chunk (Buffer pending) = (map CompleteLine completed, Buffer residual)
  where
    -- Reassemble: the buffered partial precedes the fresh bytes.
    combined :: ByteString
    combined = pending <> chunk

    -- 'BS.split' on a stream containing @n@ LF separators yields @n + 1@
    -- pieces (one per inter-separator gap, including empties). The trailing
    -- piece is everything after the final LF — un-terminated — so it becomes
    -- the residual; the earlier pieces are the complete lines.
    --
    -- The one exception is /empty/ input: 'BS.split' returns @[]@ (zero
    -- pieces) for the empty 'ByteString', which 'splitLast' maps to no lines
    -- and an empty residual. (For any non-empty input 'BS.split' is non-empty.)
    (completed, residual) = splitLast (BS.split 0x0A combined)

-- | Separate the pieces of a 'BS.split' into the complete lines (all but the
-- last piece) and the residual partial (the last piece). For the @[]@ result
-- that 'BS.split' produces on empty input, there are no lines and the residual
-- is empty. Total in all cases.
splitLast :: [ByteString] -> ([ByteString], ByteString)
splitLast [] = ([], BS.empty)
splitLast [x] = ([], x)
splitLast (x : xs) =
  let (initLines, lst) = splitLast xs
   in (x : initLines, lst)
