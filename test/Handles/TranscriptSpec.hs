module Handles.TranscriptSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
import System.FilePath
import System.IO.Temp
import System.Posix.Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types
import Test.Hspec
import Control.Exception (throwIO, try)
import System.IO.Error

import PureClaw.Handles.Log
import PureClaw.Handles.Transcript
import PureClaw.Transcript.Types

-- Helper: fixed timestamps for deterministic tests
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2025 1 1) 0

t1 :: UTCTime
t1 = UTCTime (fromGregorian 2025 1 1) 3600

t2 :: UTCTime
t2 = UTCTime (fromGregorian 2025 1 1) 7200

-- Helper: build a minimal entry
mkEntry :: Text -> UTCTime -> Text -> Direction -> TranscriptEntry
mkEntry eid ts src dir = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = ts
  , _te_harness       = Nothing
  , _te_model         = Just src
  , _te_direction     = dir
  , _te_payload       = encodePayload "hello"
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr-1"
  , _te_metadata      = Map.empty
  }

-- | Capturing logger that records warnings in an IORef.
mkCapturingLogHandle :: IORef [Text] -> LogHandle
mkCapturingLogHandle ref = LogHandle
  { _lh_logInfo  = \_ -> pure ()
  , _lh_logWarn  = \msg -> modifyIORef' ref (++ [msg])
  , _lh_logError = \_ -> pure ()
  , _lh_logDebug = \_ -> pure ()
  }

spec :: Spec
spec = do
  ---------------------------------------------------------------------------
  -- DoD 1: _th_record appends a valid JSONL line to a temp file
  ---------------------------------------------------------------------------
  describe "_th_record" $ do
    it "appends a valid JSONL line to the file" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let entry = mkEntry "id-1" t0 "ollama/llama3" Request
        _th_record handle entry
        _th_flush handle
        rawContents <- readFileRaw path
        let contents = LBS.fromStrict rawContents
            lines' = filter (not . LBS.null) (LBS.split 0x0a contents)
        length lines' `shouldBe` 1
        case lines' of
          (first':_) -> Aeson.decode first' `shouldBe` Just entry
          []         -> expectationFailure "expected at least one JSONL line"
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 2: _th_query emptyFilter returns all recorded entries in order
  ---------------------------------------------------------------------------
  describe "_th_query emptyFilter" $ do
    it "returns all recorded entries in order" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let e1 = mkEntry "id-1" t0 "src-a" Request
            e2 = mkEntry "id-2" t1 "src-b" Response
            e3 = mkEntry "id-3" t2 "src-a" Request
        _th_record handle e1
        _th_record handle e2
        _th_record handle e3
        _th_flush handle
        result <- _th_query handle emptyFilter
        result `shouldBe` [e1, e2, e3]
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 3: _th_query with source filter returns only matching entries
  ---------------------------------------------------------------------------
  describe "_th_query with source filter" $ do
    it "returns only matching entries" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let e1 = mkEntry "id-1" t0 "ollama" Request
            e2 = mkEntry "id-2" t1 "claude" Response
            e3 = mkEntry "id-3" t2 "ollama" Request
        _th_record handle e1
        _th_record handle e2
        _th_record handle e3
        _th_flush handle
        let f = emptyFilter { _tf_model = Just "ollama" }
        result <- _th_query handle f
        result `shouldBe` [e1, e3]
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 4: _th_query with limit returns at most N entries
  ---------------------------------------------------------------------------
  describe "_th_query with limit" $ do
    it "returns at most N entries" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let entries = [ mkEntry ("id-" <> T.pack (show i)) (addUTCTime (fromIntegral i) t0) "src" Request
                      | i <- [1..10 :: Int]
                      ]
        mapM_ (_th_record handle) entries
        _th_flush handle
        let f = emptyFilter { _tf_limit = Just 3 }
        result <- _th_query handle f
        length result `shouldBe` 3
        result `shouldBe` take 3 entries
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 5: _th_close is idempotent (double close does not throw)
  ---------------------------------------------------------------------------
  describe "_th_close" $ do
    it "is idempotent (double close does not throw)" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        _th_close handle
        _th_close handle  -- should not throw

  ---------------------------------------------------------------------------
  -- DoD 6: Writes after close are silently dropped
  ---------------------------------------------------------------------------
  describe "writes after close" $ do
    it "are silently dropped" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let e1 = mkEntry "id-1" t0 "src" Request
        _th_record handle e1
        _th_flush handle
        _th_close handle
        -- Write after close — should be silently dropped
        let e2 = mkEntry "id-2" t1 "src" Response
        _th_record handle e2
        -- Re-open to verify only e1 is in the file
        handle2 <- mkFileTranscriptHandle mkNoOpLogHandle path
        result <- _th_query handle2 emptyFilter
        result `shouldBe` [e1]
        _th_close handle2

  ---------------------------------------------------------------------------
  -- DoD 7: Queries after close return []
  ---------------------------------------------------------------------------
  describe "queries after close" $ do
    it "return []" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let e1 = mkEntry "id-1" t0 "src" Request
        _th_record handle e1
        _th_flush handle
        _th_close handle
        result <- _th_query handle emptyFilter
        result `shouldBe` []

  ---------------------------------------------------------------------------
  -- DoD 8: File permissions are 0600 on the JSONL file
  ---------------------------------------------------------------------------
  describe "file permissions" $ do
    it "JSONL file has 0600 permissions" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        _th_record handle (mkEntry "id-1" t0 "src" Request)
        _th_flush handle
        status <- getFileStatus path
        let mode = fileMode status .&. 0o777
        mode `shouldBe` 0o600
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 9: Directory permissions are 0700 on the transcript directory
  ---------------------------------------------------------------------------
  describe "directory permissions" $ do
    it "created directory has 0700 permissions" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let subDir = tmpDir </> "transcripts"
            path = subDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        _th_record handle (mkEntry "id-1" t0 "src" Request)
        _th_flush handle
        status <- getFileStatus subDir
        let mode = fileMode status .&. 0o777
        mode `shouldBe` 0o700
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 10: Malformed JSONL lines in file are skipped without crashing
  ---------------------------------------------------------------------------
  describe "malformed JSONL lines" $ do
    it "are skipped without crashing (log warning)" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        warningsRef <- newIORef []
        let capturingLog = mkCapturingLogHandle warningsRef
            path = tmpDir </> "transcript.jsonl"
        -- Write a valid entry, a malformed line, and another valid entry
        let e1 = mkEntry "id-1" t0 "src" Request
            e2 = mkEntry "id-2" t1 "src" Response
        writeFile path ""
        appendFile path (lbsToString (Aeson.encode e1) ++ "\n")
        appendFile path "this is not valid json\n"
        appendFile path (lbsToString (Aeson.encode e2) ++ "\n")
        handle <- mkFileTranscriptHandle capturingLog path
        result <- _th_query handle emptyFilter
        result `shouldBe` [e1, e2]
        warnings <- readIORef warningsRef
        length warnings `shouldBe` 1
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 11: mkNoOpTranscriptHandle record/query/close all work as no-ops
  ---------------------------------------------------------------------------
  describe "mkNoOpTranscriptHandle" $ do
    it "record is a no-op" $ do
      let handle = mkNoOpTranscriptHandle
      _th_record handle (mkEntry "id-1" t0 "src" Request)

    it "query returns []" $ do
      let handle = mkNoOpTranscriptHandle
      result <- _th_query handle emptyFilter
      result `shouldBe` []

    it "close is a no-op" $ do
      let handle = mkNoOpTranscriptHandle
      _th_close handle
      _th_close handle  -- double close

    it "flush is a no-op" $ do
      let handle = mkNoOpTranscriptHandle
      _th_flush handle

    it "getPath returns empty string" $ do
      let handle = mkNoOpTranscriptHandle
      p <- _th_getPath handle
      p `shouldBe` ""

  ---------------------------------------------------------------------------
  -- DoD 12: _th_flush forces pending writes to disk
  ---------------------------------------------------------------------------
  describe "_th_flush" $ do
    it "forces pending writes to disk" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        let e1 = mkEntry "id-1" t0 "src" Request
        _th_record handle e1
        _th_flush handle
        -- After flush, file should contain the entry
        rawContents <- readFileRaw path
        let contents = LBS.fromStrict rawContents
            lines' = filter (not . LBS.null) (LBS.split 0x0a contents)
        length lines' `shouldBe` 1
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 13: _th_getPath returns the correct file path
  ---------------------------------------------------------------------------
  describe "_th_getPath" $ do
    it "returns the correct file path" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        result <- _th_getPath handle
        result `shouldBe` path
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD 14: Fresh handle with no entries — _th_query emptyFilter returns []
  ---------------------------------------------------------------------------
  describe "fresh handle with no entries" $ do
    it "_th_query emptyFilter returns []" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        result <- _th_query handle emptyFilter
        result `shouldBe` []
        _th_close handle

  ---------------------------------------------------------------------------
  -- DoD bonus: _th_flush after close is a no-op
  ---------------------------------------------------------------------------
  describe "_th_flush after close" $ do
    it "is a no-op" $ do
      withSystemTempDirectory "transcript-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        handle <- mkFileTranscriptHandle mkNoOpLogHandle path
        _th_close handle
        _th_flush handle  -- should not throw

-- | Read a file strictly using raw POSIX fd operations, bypassing
-- GHC RTS file locking.
readFileRaw :: FilePath -> IO BS.ByteString
readFileRaw fp = do
  rfd <- Posix.openFd fp Posix.ReadOnly Posix.defaultFileFlags
  let chunkSize :: ByteCount
      chunkSize = 65536
      go acc = do
        result <- try (PosixBS.fdRead rfd chunkSize)
        case result of
          Left e
            | isEOFError e -> pure (BS.concat (reverse acc))
            | otherwise    -> throwIO (e :: IOError)
          Right chunk
            | BS.null chunk -> pure (BS.concat (reverse acc))
            | otherwise     -> go (chunk : acc)
  contents <- go []
  Posix.closeFd rfd
  pure contents

-- | Convert lazy ByteString to String for writeFile
lbsToString :: LBS.ByteString -> String
lbsToString = map (toEnum . fromEnum) . LBS.unpack
