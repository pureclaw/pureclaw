{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | End-to-end integration test for the claude-code JSONL log content source.
--
-- This spec drives the REAL production wiring — 'defaultJsonlTailDeps' (real-FS
-- @O_NOFOLLOW@ reads via @withNoFollowFd@\/@_jt_size@\/@_jt_readFrom@),
-- 'runLogTailer', 'mkSafeClaudeLogPath' (with its real owner\/mode\/containment
-- security checks), 'recordOnce', and 'seedRecordedIds' — over a temp synthetic
-- claude-base (@<tmp>\/projects\/<slug>\/<uuid>.jsonl@, chmod 0600, owner ==
-- euid) and a fixture JSONL, with NO real @~\/.claude@ and NO real claude
-- process.
--
-- It is the integration counterpart to the unit specs (which inject FAKE
-- 'JsonlTailDeps'): it exercises the thin real-FS IO shell that the unit specs
-- deliberately leave for integration coverage, end to end.
--
-- Two assertions:
--
--   1. /Prose lands exactly once./ The tailer reads the appended fixture, folds
--      the assistant @text@ blocks into one finalized turn, and the
--      'recordOnce'-wrapped recorder writes EXACTLY ONE @Response@ transcript
--      entry with the correct prose text and the derived (UUIDv5) turn id.
--   2. /Re-attach idempotency./ Re-seeding 'recordedIds' from the now-populated
--      transcript and re-folding the SAME file from offset 0 (a real-FS read via
--      'tailStep' over 'defaultJsonlTailDeps') re-derives the SAME id, which the
--      seeded set suppresses → NO new transcript entries. This models a restarted
--      tailer\/future re-attach against a transcript that already holds the turns
--      (the realistic shape of "restart" given the binding caveat). We do NOT
--      drive a full process-restart boot→rebind cycle (out of scope).
module Integration.ClaudeLogContentSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket)
import Control.Monad qualified as Monad
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set (Set)
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
import System.Posix.Files qualified as PF
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  , mkFileTranscriptHandle
  )
import PureClaw.Harness.ClaudeLogPath
  ( SafeClaudeLogPath
  , mkClaudeBase
  , mkSafeClaudeLogPath
  )
import PureClaw.Harness.ClaudeLogProse
  ( ProseTurn (..)
  , deriveTurnId
  , emptyProseState
  )
import PureClaw.Harness.ClaudeLogTail
  ( defaultJsonlTailDeps
  , defaultTailCaps
  , TailEvent (..)
  , tailStep
  )
import PureClaw.Harness.ClaudeSession (mkClaudeSessionUuid)
import PureClaw.Harness.JsonlTail (Offset (..), emptyBuffer)
import PureClaw.Harness.LogProvider
  ( applyProseTurn
  , emptyLogTurnState
  , recordOnce
  , runLogTailer
  , seedRecordedIds
  )
import PureClaw.Harness.Reconcile (mkTurnEntry)
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , emptyFilter
  )

-- ---------------------------------------------------------------------------
-- Fixtures / constants
-- ---------------------------------------------------------------------------

-- | A valid lowercase canonical UUID accepted by 'mkClaudeSessionUuid'. Used as
-- both the on-disk log file name (@<uuid>.jsonl@) AND the session id namespacing
-- the derived turn id (so the assertion below can reproduce 'deriveTurnId').
fixtureUuid :: Text
fixtureUuid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

-- | The synthetic claude JSONL fixture. A complete two-message conversation:
-- the first assistant line (uuid @22…@) opens the turn with prose + a
-- non-terminal @tool_use@ stop_reason; an intervening solely-@tool_result@ user
-- line does NOT end it; the second assistant line appends more prose and
-- finalizes it with @end_turn@. The interleaved meta\/malformed\/real-user lines
-- exercise the fold's ignore + end-turn paths. The fold therefore yields ONE
-- finalized turn whose pinned source uuid is @22…@.
fixtureLines :: [BS.ByteString]
fixtureLines =
  [ "{\"type\":\"user\",\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"message\":{\"role\":\"user\",\"content\":\"hello there\"}}"
  , "{\"type\":\"assistant\",\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"s\"},{\"type\":\"text\",\"text\":\"Let me look at the files.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls\"}}]}}"
  , "{\"type\":\"user\",\"uuid\":\"33333333-3333-4333-8333-333333333333\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"is_error\":false,\"content\":\"a.txt\"}]}}"
  , "{\"type\":\"assistant\",\"uuid\":\"44444444-4444-4444-8444-444444444444\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\" There are two files.\"}]}}"
  , "{\"type\":\"mode\",\"uuid\":\"55555555-5555-4555-8555-555555555555\",\"mode\":\"default\"}"
  , "this line is intentionally not valid json"
  , "{\"type\":\"user\",\"uuid\":\"77777777-7777-4777-8777-777777777777\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"thanks\"}]}}"
  ]

-- | The prose the fold must produce for the single finalized turn: the first
-- assistant line's text concatenated with the second's (the intervening
-- tool_result user line does not end the turn).
expectedProse :: Text
expectedProse = "Let me look at the files. There are two files."

-- | The pinned first-assistant uuid for the turn.
firstAssistantUuid :: Text
firstAssistantUuid = "22222222-2222-4222-8222-222222222222"

-- | A fixed timestamp for the recorded turn entry (the recorder supplies its own
-- ts; the tailer does not need a real clock for the assertion).
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 23) 0

-- ---------------------------------------------------------------------------
-- Temp claude-base scaffolding
-- ---------------------------------------------------------------------------

-- | The live temp scaffolding for one test: the validated log path, the on-disk
-- log file path (so the test can append to it), and a real file-backed
-- transcript handle.
data Scaffold = Scaffold
  { _sc_safePath :: !SafeClaudeLogPath
  , _sc_logFile  :: !FilePath
  , _sc_transcript :: !TranscriptHandle
  , _sc_sessionId :: !SessionId
  }

-- | Build a temp synthetic claude base @<tmp>\/projects\/<slug>\/<uuid>.jsonl@
-- (created empty, chmod 0600 so it satisfies 'mkSafeClaudeLogPath's owner\/mode
-- check — we created it, so owner == euid), obtain a 'SafeClaudeLogPath' through
-- the REAL smart constructor (all security checks run), and open a real
-- file-backed transcript handle at @<tmp>\/transcript.jsonl@. The whole temp
-- tree is force-removed on teardown.
withScaffold :: (Scaffold -> IO ()) -> IO ()
withScaffold action = bracket allocate cleanup (action . snd)
  where
    allocate :: IO (FilePath, Scaffold)
    allocate = do
      tmp <- getTemporaryDirectory
      let baseDir   = tmp </> "pureclaw-claudelog-content-test"
          projDir   = baseDir </> "projects" </> "synthetic-proj"
          logFile   = projDir </> (T.unpack fixtureUuid <> ".jsonl")
          transFile = baseDir </> "transcript.jsonl"
      -- Start clean in case a previous crashed run left the tree behind.
      removePathForcibly baseDir
      createDirectoryIfMissing True projDir
      -- Create the log file EMPTY (the tailer seeks to EOF=0, then we append).
      BS.writeFile logFile ""
      -- chmod 0600: owner read/write only — passes ownerModeOk (no group/other
      -- write; owner == euid because we just created it).
      PF.setFileMode logFile 0o600
      let eUuid = mkClaudeSessionUuid fixtureUuid
      uuid <- either (\e -> fail ("mkClaudeSessionUuid: " <> show e)) pure eUuid
      eSafe <- mkSafeClaudeLogPath (mkClaudeBase baseDir) uuid Nothing
      safePath <- either (\e -> fail ("mkSafeClaudeLogPath: " <> show e)) pure eSafe
      th <- mkFileTranscriptHandle mkNoOpLogHandle transFile
      pure
        ( baseDir
        , Scaffold
            { _sc_safePath = safePath
            , _sc_logFile  = logFile
            , _sc_transcript = th
            , _sc_sessionId = SessionId fixtureUuid
            }
        )

    cleanup :: (FilePath, Scaffold) -> IO ()
    cleanup (baseDir, sc) = do
      _th_close (_sc_transcript sc)
      removePathForcibly baseDir

-- | Append the fixture lines (newline-terminated) to the on-disk log file so the
-- running tailer reads them via the real-FS @_jt_readFrom@ path.
appendFixture :: FilePath -> IO ()
appendFixture logFile =
  BS.appendFile logFile (BS.intercalate "\n" fixtureLines <> "\n")

-- | All @Response@ entries currently in the transcript.
queryResponses :: TranscriptHandle -> IO [TranscriptEntry]
queryResponses th =
  filter ((== Response) . _te_direction) <$> _th_query th emptyFilter

-- | Poll (bounded) until the transcript holds at least one @Response@ entry.
waitForResponse :: TranscriptHandle -> IO [TranscriptEntry]
waitForResponse th = go
  where
    go = do
      es <- queryResponses th
      if null es then threadDelay 20000 >> go else pure es

spec :: Spec
spec = describe "ClaudeLogContent (integration)" $ do
  it "records assistant prose exactly once with the derived id (real-FS tailer)" $
    withScaffold $ \sc -> do
      let th  = _sc_transcript sc
          sid = _sc_sessionId sc
      -- The derived id the recorder must use (reproduced from public helpers).
      let derivedId = deriveTurnId fixtureUuid firstAssistantUuid
      -- Shared recorded-id set + shared turn state (mirrors production wiring).
      recordedIds <- newIORef =<< seedRecordedIds th  -- empty transcript → empty set
      turnState   <- newIORef emptyLogTurnState
      -- The sink mirrors production: fold each ProseTurn into the shared state,
      -- and on the FINALIZED turn record it ONCE via recordOnce (the durable
      -- single-writer). recordOnce dedups by the derived id.
      let sink pt = do
            modifyIORef' turnState (applyProseTurn fixtureUuid t0 pt)
            Monad.when (_pt_finalized pt) $ do
              let tid   = deriveTurnId fixtureUuid (_pt_sourceUuid pt)
                  entry = mkTurnEntry tid t0 (_pt_text pt)
              recordOnce recordedIds (\_ e -> _th_record th e) sid entry
      -- Start the REAL tailer over the REAL FS deps; it seeks to EOF (0) on the
      -- empty file, then polls. Append the fixture so it reads it live.
      a <- Async.async $
        runRealTailer (_sc_safePath sc) sink
      -- Let the tailer's seekStart probe the EMPTY file (offset 0) before we
      -- append, so the appended fixture is genuinely read by a subsequent poll
      -- rather than skipped past by a seek-to-EOF that raced ahead of the write.
      threadDelay 300000
      appendFixture (_sc_logFile sc)
      mEntries <- timeout (5 * 1000 * 1000) (waitForResponse th)
      Async.cancel a
      _ <- Async.waitCatch a
      case mEntries of
        Nothing -> expectationFailure "timed out waiting for a recorded Response"
        Just entries -> case entries of
          [e] -> do
            _te_direction e `shouldBe` Response
            _te_payload e `shouldBe` expectedProse
            _te_id e `shouldBe` derivedId
            -- A harness turn is self-correlated (id == correlationId).
            _te_correlationId e `shouldBe` derivedId
          _ -> expectationFailure
                 ("expected exactly one Response, got " <> show (length entries))

  it "re-attach is idempotent: re-folding the same file records nothing new" $
    withScaffold $ \sc -> do
      let th = _sc_transcript sc
      -- Phase 1: populate the transcript exactly as above.
      appendFixture (_sc_logFile sc)
      recordedIds1 <- newIORef =<< seedRecordedIds th
      runFoldOnce sc recordedIds1
      after1 <- queryResponses th
      length after1 `shouldBe` 1
      -- Phase 2 (re-attach): a FRESH recorded-id set seeded from the NOW-populated
      -- transcript, re-folding the SAME file from offset 0 over the real-FS deps.
      -- The derived id is already disk-seeded → recordOnce suppresses it.
      recordedIds2 <- newIORef =<< seedRecordedIds th
      runFoldOnce sc recordedIds2
      after2 <- queryResponses th
      length after2 `shouldBe` 1   -- unchanged: no new entry
      -- And the single entry is byte-identical (same id + payload).
      map _te_id after2 `shouldBe` map _te_id after1
      map _te_payload after2 `shouldBe` map _te_payload after1

-- | Run 'runLogTailer' over the production real-FS 'defaultJsonlTailDeps'.
runRealTailer :: SafeClaudeLogPath -> (ProseTurn -> IO ()) -> IO ()
runRealTailer = runLogTailer defaultJsonlTailDeps defaultTailCaps mkNoOpLogHandle

-- | Re-fold the WHOLE log file from offset 0 via real-FS 'tailStep' calls (a
-- bounded read loop driven directly, so it reads the already-present content
-- rather than seeking to EOF), recording each finalized turn once through the
-- supplied (possibly disk-seeded) recorded-id set. Returns when the file is
-- fully consumed.
runFoldOnce :: Scaffold -> IORef (Set Text) -> IO ()
runFoldOnce sc recordedIds = go (Offset 0, emptyBuffer, emptyProseState)
  where
    th  = _sc_transcript sc
    sid = _sc_sessionId sc
    path = _sc_safePath sc

    go st@(off0, _, _) = do
      (st'@(off1, _, _), evs) <- tailStep defaultJsonlTailDeps defaultTailCaps path st
      Monad.forM_ evs $ \case
        TailProse pt ->
          Monad.when (_pt_finalized pt) $ do
            let tid   = deriveTurnId fixtureUuid (_pt_sourceUuid pt)
                entry = mkTurnEntry tid t0 (_pt_text pt)
            recordOnce recordedIds (\_ e -> _th_record th e) sid entry
        TailUnavailable -> pure ()
      -- Stop once the offset stops advancing (whole file consumed).
      if off1 == off0 then pure () else go st'
