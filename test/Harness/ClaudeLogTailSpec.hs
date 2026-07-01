{-# LANGUAGE OverloadedStrings #-}

-- | Tests for 'PureClaw.Harness.ClaudeLogTail': bounded JSONL tail step +
-- 'JsonlTailDeps' seam. All tests use a fake 'JsonlTailDeps' backed by an
-- 'IORef ByteString' — no real filesystem IO in the logic under test.
module Harness.ClaudeLogTailSpec (spec) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.FilePath ((</>))
import Test.Hspec

import PureClaw.Harness.ClaudeLogPath
  ( SafeClaudeLogPath
  , mkClaudeBase
  , mkSafeClaudeLogPath
  )
import PureClaw.Harness.ClaudeLogProse (emptyProseState)
import PureClaw.Harness.ClaudeLogTail
  ( JsonlTailDeps (..)
  , TailCaps (..)
  , TailEvent (..)
  , defaultTailCaps
  , seekStart
  , tailStep
  )
import PureClaw.Harness.ClaudeSession (mkClaudeSessionUuid)
import PureClaw.Harness.JsonlTail (Offset (..), emptyBuffer)

-- ---------------------------------------------------------------------------
-- Fixed timestamp (pure — no clock calls in tests)
-- ---------------------------------------------------------------------------

fixedTs :: UTCTime
fixedTs = UTCTime (fromGregorian 2026 6 22) (secondsToDiffTime 0)

-- ---------------------------------------------------------------------------
-- A complete JSONL assistant line (real shape from fixture)
-- ---------------------------------------------------------------------------

-- | A self-contained assistant event line with a terminal stop_reason.
-- This line matches the shape of lines in test/fixtures/claude-jsonl/events.jsonl.
assistantLine :: ByteString
assistantLine =
  "{\"type\":\"assistant\",\"uuid\":\"44444444-4444-4444-8444-444444444444\""
  <> ",\"parentUuid\":\"33333333-3333-4333-8333-333333333333\""
  <> ",\"requestId\":\"req_2\""
  <> ",\"sessionId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\""
  <> ",\"timestamp\":\"2026-06-04T20:00:03.000Z\""
  <> ",\"cwd\":\"/Users/zoe/proj\",\"gitBranch\":\"main\""
  <> ",\"userType\":\"external\",\"version\":\"1.0.0\""
  <> ",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\""
  <> ",\"model\":\"claude-opus-4-8\""
  <> ",\"stop_reason\":\"end_turn\""
  <> ",\"stop_sequence\":null"
  <> ",\"usage\":{\"input_tokens\":30,\"output_tokens\":8}"
  <> ",\"content\":[{\"type\":\"text\",\"text\":\"There are two files: a.txt and b.txt.\"}]}}"
  <> "\n"

-- ---------------------------------------------------------------------------
-- Fake JsonlTailDeps backed by an IORef ByteString
-- ---------------------------------------------------------------------------

-- | Fake deps: all operations read/size from the IORef; path is ignored.
fakeDeps :: IORef ByteString -> JsonlTailDeps
fakeDeps ref = JsonlTailDeps
  { _jt_size     = \_path -> do
      bs <- readIORef ref
      pure (fromIntegral (BS.length bs))
  , _jt_readFrom = \_path (Offset off) n -> do
      bs <- readIORef ref
      let start = fromIntegral off :: Int
          chunk = BS.take n (BS.drop start bs)
      pure (chunk, Offset (off + fromIntegral (BS.length chunk)))
  , _jt_now      = pure fixedTs
  }

-- ---------------------------------------------------------------------------
-- SafeClaudeLogPath fixture: minimal real FS structure
-- ---------------------------------------------------------------------------

-- | 'SafeClaudeLogPath' has a hidden constructor; the only way to obtain one
-- is via 'mkSafeClaudeLogPath'. We build the minimal directory/file structure
-- that satisfies the validation checks (containment + owner/mode), then clean
-- up afterwards.  The fake deps ignore the path value entirely, so we only
-- need ANY valid 'SafeClaudeLogPath'.
withRealPath :: (SafeClaudeLogPath -> IO ()) -> IO ()
withRealPath action =
  bracket allocate cleanup (\(_, p) -> action p)
  where
    uuidStr :: T.Text
    uuidStr = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    allocate :: IO (FilePath, SafeClaudeLogPath)
    allocate = do
      tmp <- getTemporaryDirectory
      let baseDir  = tmp </> "pureclaw-claudelogtail-test"
          projDir  = baseDir </> "projects" </> "test-proj"
          logFile  = projDir </> (T.unpack uuidStr <> ".jsonl")
      createDirectoryIfMissing True projDir
      BS.writeFile logFile assistantLine
      let claudeBase = mkClaudeBase baseDir
      Right uuid <- pure (mkClaudeSessionUuid uuidStr)
      eResult <- mkSafeClaudeLogPath claudeBase uuid Nothing
      case eResult of
        Left err ->
          fail ("withRealPath: mkSafeClaudeLogPath failed: " <> show err)
        Right safePath ->
          pure (baseDir, safePath)

    cleanup :: (FilePath, SafeClaudeLogPath) -> IO ()
    cleanup (dir, _) = removePathForcibly dir

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

isTailProse :: TailEvent -> Bool
isTailProse (TailProse _) = True
isTailProse TailUnavailable = False

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "ClaudeLogTail" $
  around withRealPath $ do

    it "tailStep emits prose for newly-appended complete lines and advances offset" $ \path -> do
      ref <- newIORef assistantLine
      let deps = fakeDeps ref
          st0  = (Offset 0, emptyBuffer, emptyProseState)
      ((newOff, _, _), evs) <- tailStep deps defaultTailCaps path st0
      evs `shouldSatisfy` any isTailProse
      newOff `shouldNotBe` Offset 0

    it "tailStep buffers a partial line until its newline arrives" $ \path -> do
      -- First call: partial line (no trailing LF)
      let partial = BS.init assistantLine  -- strip the '\n'
      ref <- newIORef partial
      let deps = fakeDeps ref
          st0  = (Offset 0, emptyBuffer, emptyProseState)
      ((off1, buf1, prose1), evs1) <- tailStep deps defaultTailCaps path st0
      -- No complete line yet
      evs1 `shouldSatisfy` (not . any isTailProse)
      -- Second call: the full line is now available
      writeIORef ref assistantLine
      ((off2, _, _), evs2) <- tailStep deps defaultTailCaps path (off1, buf1, prose1)
      evs2 `shouldSatisfy` any isTailProse
      off2 `shouldNotBe` off1

    it "tailStep over the buffer cap yields [TailUnavailable] and does not advance" $ \path -> do
      -- 2 MiB of 'a' with no newline; caps at 1 MiB buffer + large enough chunk to read it all
      let big = BS.replicate (2 * 1024 * 1024) 0x61
      ref <- newIORef big
      let deps = fakeDeps ref
          caps = defaultTailCaps
                   { _tc_buffer = 1024 * 1024
                   , _tc_chunk  = 4 * 1024 * 1024
                   }
          st0 = (Offset 0, emptyBuffer, emptyProseState)
      ((newOff, _, _), evs) <- tailStep deps caps path st0
      evs `shouldBe` [TailUnavailable]
      newOff `shouldBe` Offset 0

    it "seekStart with Nothing seeks to EOF (current file size)" $ \path -> do
      let content = assistantLine <> assistantLine
      ref <- newIORef content
      let deps = fakeDeps ref
      off <- seekStart deps path Nothing
      off `shouldBe` Offset (fromIntegral (BS.length content))

    it "seekStart with a persisted offset within bounds returns that offset" $ \path -> do
      ref <- newIORef assistantLine
      let deps  = fakeDeps ref
          saved = Offset 10
      off <- seekStart deps path (Just saved)
      off `shouldBe` saved

    it "seekStart with a persisted offset exceeding size falls back to size" $ \path -> do
      let content = BS.take 5 assistantLine  -- only 5 bytes in file
      ref <- newIORef content
      let deps  = fakeDeps ref
          saved = Offset 999  -- exceeds file size
      off <- seekStart deps path (Just saved)
      off `shouldBe` Offset 5

    it "tailStep resets offset to 0 on shrink (size < offset)" $ \path -> do
      -- First, advance past some content
      ref <- newIORef assistantLine
      let deps = fakeDeps ref
          st0  = (Offset 0, emptyBuffer, emptyProseState)
      (st1@(off1, _, _), _) <- tailStep deps defaultTailCaps path st0
      off1 `shouldNotBe` Offset 0
      -- Now shrink the file to empty — size < offset
      writeIORef ref BS.empty
      ((resetOff, _, _), _) <- tailStep deps defaultTailCaps path st1
      resetOff `shouldBe` Offset 0

    it "tailStep backfill guard: from-0 when file size > _tc_backfill → [TailUnavailable]" $ \path -> do
      -- File larger than backfill cap; must not advance
      let content = BS.replicate 20 0x61 <> "\n"  -- 21 bytes with LF
      ref <- newIORef content
      let deps = fakeDeps ref
          caps = defaultTailCaps { _tc_backfill = 10, _tc_chunk = 1024 }
          st0  = (Offset 0, emptyBuffer, emptyProseState)
      ((newOff, _, _), evs) <- tailStep deps caps path st0
      evs `shouldBe` [TailUnavailable]
      newOff `shouldBe` Offset 0

    it "tailStep per-line cap: a complete line exceeding _tc_line yields [TailUnavailable] without advancing" $ \path -> do
      -- 65 bytes of 'a' + '\n' = a complete line whose content (65 bytes, after
      -- the '\n' is stripped by splitLines) exceeds _tc_line = 64.
      -- _tc_buffer = 16384 >> line length so the buffer cap does NOT fire first.
      -- _tc_chunk is large enough to read the whole line in one go.
      let lineContent = BS.replicate 65 0x61  -- 65 × 'a'
          content     = lineContent <> "\n"
      ref <- newIORef content
      let deps = fakeDeps ref
          caps = defaultTailCaps
                   { _tc_line    = 64
                   , _tc_buffer  = 16384
                   , _tc_chunk   = 16384
                   , _tc_backfill = 16384
                   }
          st0 = (Offset 0, emptyBuffer, emptyProseState)
      ((newOff, _, _), evs) <- tailStep deps caps path st0
      evs     `shouldBe` [TailUnavailable]
      newOff  `shouldBe` Offset 0
