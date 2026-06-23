{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "PureClaw.Harness.LogProvider" — the turn-content provider seam
-- (Task 4) plus the recorded-id dedup + tailer driver (Task 5). The tmux
-- provider must preserve today's behavior verbatim; the null provider is the
-- handle-less fallback. 'recordOnce'/'seedRecordedIds' guarantee idempotent
-- replay across a crash/restart; 'runLogTailer' must STOP (not spin) on a
-- terminal 'TailUnavailable'.
module Harness.LogProviderSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Handles.Harness (mkNoOpHarnessHandle, _hh_snapshotTurn)
import PureClaw.Handles.Log (mkNoOpLogHandle, _lh_logWarn)
import PureClaw.Handles.Transcript (TranscriptHandle (..), mkNoOpTranscriptHandle)
import PureClaw.Harness.ClaudeLogPath
  ( SafeClaudeLogPath
  , mkClaudeBase
  , mkSafeClaudeLogPath
  )
import PureClaw.Harness.ClaudeLogProse (ProseTurn (..), deriveTurnId)
import PureClaw.Harness.ClaudeLogTail
  ( JsonlTailDeps (..)
  , defaultTailCaps
  )
import PureClaw.Harness.ClaudeSession (mkClaudeSessionUuid)
import PureClaw.Harness.JsonlTail (Offset (..))
import PureClaw.Harness.LogProvider
import PureClaw.Harness.Reconcile (mkTurnEntry)
import PureClaw.Transcript.Types (TranscriptEntry (..))

-- A fixed timestamp for deterministic turn entries.
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 23) 0

-- | Fake deps that simulate a file which is empty when the tailer seeks to EOF
-- (the FIRST '_jt_size' call → offset 0), then grows to an over-cap no-LF chunk
-- before the first read. The read from offset 0 trips the buffer cap → 'tailStep'
-- yields a terminal 'TailUnavailable' without advancing. A size counter
-- distinguishes the seek-EOF probe from later probes.
overCapDeps :: IORef Int -> ByteString -> JsonlTailDeps
overCapDeps sizeCalls bigChunk = JsonlTailDeps
  { _jt_size     = \_ -> do
      n <- atomicModifyIORef' sizeCalls (\c -> (c + 1, c))
      -- First probe (seekStart) sees an empty file → seek to offset 0.
      -- Later probes see the grown, over-cap file.
      pure $ if n == 0 then 0 else fromIntegral (BS.length bigChunk)
  , _jt_readFrom = \_ (Offset off) cap ->
      let start = fromIntegral off :: Int
          chunk = BS.take cap (BS.drop start bigChunk)
      in pure (chunk, Offset (off + fromIntegral (BS.length chunk)))
  , _jt_now      = pure t0
  }

-- | Build ANY valid 'SafeClaudeLogPath' over a minimal temp FS structure; the
-- fake deps ignore the path value entirely.
withRealPath :: (SafeClaudeLogPath -> IO ()) -> IO ()
withRealPath action = bracket allocate cleanup (action . snd)
  where
    uuidStr :: T.Text
    uuidStr = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    allocate :: IO (FilePath, SafeClaudeLogPath)
    allocate = do
      tmp <- getTemporaryDirectory
      let baseDir = tmp </> "pureclaw-logprovider-test"
          projDir = baseDir </> "projects" </> "test-proj"
          logFile = projDir </> (T.unpack uuidStr <> ".jsonl")
      createDirectoryIfMissing True projDir
      BS.writeFile logFile "{}\n"
      let claudeBase = mkClaudeBase baseDir
      Right uuid <- pure (mkClaudeSessionUuid uuidStr)
      eResult <- mkSafeClaudeLogPath claudeBase uuid Nothing
      case eResult of
        Left err -> fail ("withRealPath: mkSafeClaudeLogPath failed: " <> show err)
        Right safePath -> pure (baseDir, safePath)

    cleanup :: (FilePath, SafeClaudeLogPath) -> IO ()
    cleanup (dir, _) = removePathForcibly dir

spec :: Spec
spec = do
  describe "tmuxProvider" $ do
    it "preserves _hh_snapshotTurn text and never finalizes/derives id" $ do
      let hh = mkNoOpHarnessHandle { _hh_snapshotTurn = pure "snapshot" }
          p  = tmuxProvider hh
      (txt, fin) <- _tp_snapshot p
      mid <- _tp_turnId p
      (txt, fin, mid) `shouldBe` ("snapshot", False, Nothing)

  describe "nullProvider" $ do
    it "yields empty text, never finalizes, derives no id" $ do
      (txt, fin) <- _tp_snapshot nullProvider
      mid <- _tp_turnId nullProvider
      (txt, fin, mid) `shouldBe` ("", False, Nothing)

  describe "mkLogTurnProvider / applyProseTurn" $ do
    it "reads the shared tail state: text, finalize flag, and derived id" $ do
      ref <- newIORef emptyLogTurnState
      let p = mkLogTurnProvider ref
      -- Empty state first.
      (txt0, fin0) <- _tp_snapshot p
      mid0 <- _tp_turnId p
      (txt0, fin0, mid0) `shouldBe` ("", False, Nothing)
      -- Tailer writes a growing, not-yet-final turn.
      modifyIORef' ref
        (applyProseTurn "sess-x" t0 (ProseTurn "uuid-1" "Hello" False))
      (txt1, fin1) <- _tp_snapshot p
      mid1 <- _tp_turnId p
      txt1 `shouldBe` "Hello"
      fin1 `shouldBe` False
      mid1 `shouldBe` Just (deriveTurnId "sess-x" "uuid-1", t0)
      -- Then a finalized turn under the SAME pinned source uuid → same id.
      modifyIORef' ref
        (applyProseTurn "sess-x" t0 (ProseTurn "uuid-1" "Hello world" True))
      (txt2, fin2) <- _tp_snapshot p
      mid2 <- _tp_turnId p
      txt2 `shouldBe` "Hello world"
      fin2 `shouldBe` True
      mid2 `shouldBe` Just (deriveTurnId "sess-x" "uuid-1", t0)

  describe "recordOnce" $ do
    it "skips a _te_id already in the seeded set (crash/restart idempotency)" $ do
      ref <- newIORef (Set.fromList ["derived-1"] :: Set Text) -- seeded from disk
      recorded <- newIORef ([] :: [(SessionId, TranscriptEntry)])
      let sid = SessionId "sess-a"
          rec s e = modifyIORef' recorded ((s, e) :)
      recordOnce ref rec sid (mkTurnEntry "derived-1" t0 "AB") -- already present → skip
      recordOnce ref rec sid (mkTurnEntry "derived-2" t0 "CD") -- new → record
      ids <- map (_te_id . snd) <$> readIORef recorded
      ids `shouldBe` ["derived-2"]

    it "adds a newly recorded id to the set so a re-record is skipped" $ do
      ref <- newIORef (Set.empty :: Set Text)
      recorded <- newIORef ([] :: [(SessionId, TranscriptEntry)])
      let sid = SessionId "sess-a"
          rec s e = modifyIORef' recorded ((s, e) :)
      recordOnce ref rec sid (mkTurnEntry "derived-9" t0 "X")
      recordOnce ref rec sid (mkTurnEntry "derived-9" t0 "X") -- same id again → skip
      ids <- map (_te_id . snd) <$> readIORef recorded
      ids `shouldBe` ["derived-9"]
      finalSet <- readIORef ref
      Set.member "derived-9" finalSet `shouldBe` True

  describe "seedRecordedIds" $ do
    it "reads ids via the untrimmed query (every entry, emptyFilter)" $ do
      let entries =
            [ mkTurnEntry "id-1" t0 "a"
            , mkTurnEntry "id-2" t0 "b"
            , mkTurnEntry "id-3" t0 "c"
            ]
          th = mkNoOpTranscriptHandle { _th_query = \_ -> pure entries }
      s <- seedRecordedIds th
      s `shouldBe` Set.fromList ["id-1", "id-2", "id-3"]

  describe "runLogTailer" $ do
    it "stops + WARNs on a terminal TailUnavailable (does not spin)" $
      withRealPath $ \path -> do
        -- A 2 MiB no-LF chunk over default caps → tailStep yields
        -- [TailUnavailable] and does NOT advance. runLogTailer must treat that
        -- as terminal: WARN once and STOP. timeout bounds a regression where it
        -- re-loops on the unchanged offset (infinite spin).
        let bigChunk = BS.replicate (2 * 1024 * 1024) 0x61
        sizeCalls <- newIORef 0
        let deps = overCapDeps sizeCalls bigChunk
        warns <- newMVar (0 :: Int)
        sink <- newIORef ([] :: [ProseTurn])
        let logH = mkNoOpLogHandle
                     { _lh_logWarn = \_ -> modifyMVar_ warns (pure . (+ 1)) }
        result <- timeout (2 * 1000 * 1000) $
          runLogTailer deps defaultTailCaps logH path
            (\pt -> modifyIORef' sink (pt :))
        result `shouldBe` Just ()
        n <- readMVar warns
        n `shouldBe` 1
        readIORef sink `shouldReturn` []

    it "forwards an emitted ProseTurn to the sink, then keeps polling" $
      withRealPath $ \path -> do
        -- The file is empty at seekStart (offset 0), then grows by one complete
        -- assistant line. runLogTailer reads it, folds a ProseTurn, and forwards
        -- it to the sink (covering the emit/go continuation). We then cancel.
        let asstLine =
              "{\"type\":\"assistant\",\"uuid\":\"u1\",\"message\":{\"role\":\"assistant\""
                <> ",\"content\":[{\"type\":\"text\",\"text\":\"Hi\"}]}}\n"
        sizeCalls <- newIORef (0 :: Int)
        let deps = JsonlTailDeps
              { _jt_size = \_ -> do
                  n <- atomicModifyIORef' sizeCalls (\c -> (c + 1, c))
                  pure $ if n == 0 then 0 else fromIntegral (BS.length asstLine)
              , _jt_readFrom = \_ (Offset off) cap ->
                  let start = fromIntegral off :: Int
                      chunk = BS.take cap (BS.drop start asstLine)
                  in pure (chunk, Offset (off + fromIntegral (BS.length chunk)))
              , _jt_now = pure t0
              }
        got <- newMVar ([] :: [Text])
        a <- Async.async $
          runLogTailer deps defaultTailCaps mkNoOpLogHandle path
            (\pt -> modifyMVar_ got (pure . (_pt_text pt :)))
        -- Wait until the sink has received the prose, then cancel.
        let waitForEmit = do
              xs <- readMVar got
              if null xs then threadDelay 20000 >> waitForEmit else pure xs
        emitted <- timeout (2 * 1000 * 1000) waitForEmit
        Async.cancel a
        _ <- Async.waitCatch a
        emitted `shouldBe` Just ["Hi"]

    it "re-raises an async cancellation on teardown (darwin-CI-hang invariant)" $
      withRealPath $ \path -> do
        -- An empty, never-growing file: seek to EOF (0), then every tailStep
        -- reads nothing and threadDelays. Cancelling the runLogTailer Async must
        -- deliver AsyncCancelled, which runLogTailer RE-RAISES (not swallows).
        let deps = JsonlTailDeps
              { _jt_size = \_ -> pure 0
              , _jt_readFrom = \_ off _ -> pure (BS.empty, off)
              , _jt_now = pure t0
              }
        a <- Async.async $
          runLogTailer deps defaultTailCaps mkNoOpLogHandle path (\_ -> pure ())
        Async.cancel a
        r <- Async.waitCatch a
        -- The cancellation propagated as an async exception (re-raised), so
        -- waitCatch sees a Left, not a clean Right ().
        case r of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected the cancellation to be re-raised"

    it "WARNs and stops on a non-async loop exception (not swallowed silently)" $
      withRealPath $ \path -> do
        -- _jt_size throws a synchronous IOException on the first probe (during
        -- seekStart). runLogTailer must catch it, WARN, and return cleanly.
        let deps = JsonlTailDeps
              { _jt_size = \_ -> ioError (userError "boom")
              , _jt_readFrom = \_ off _ -> pure (BS.empty, off)
              , _jt_now = pure t0
              }
        warns <- newMVar (0 :: Int)
        let logH = mkNoOpLogHandle
                     { _lh_logWarn = \_ -> modifyMVar_ warns (pure . (+ 1)) }
        result <- timeout (2 * 1000 * 1000) $
          runLogTailer deps defaultTailCaps logH path (\_ -> pure ())
        result `shouldBe` Just ()
        readMVar warns `shouldReturn` 1
