module Transcript.CombinatorSpec (spec) where

import Control.Exception
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.FilePath
import System.IO.Error
import System.IO.Temp
import Test.Hspec

import PureClaw.Handles.Log
import PureClaw.Handles.Transcript
import PureClaw.Transcript.Combinator
import PureClaw.Transcript.Types

-- | Helper to get the first and second entries from a two-element list,
-- avoiding the partial 'head' function.
getReqResp :: [TranscriptEntry] -> IO (TranscriptEntry, TranscriptEntry)
getReqResp [req, resp] = pure (req, resp)
getReqResp entries = do
  expectationFailure ("Expected exactly 2 entries, got " <> show (length entries))
  error "unreachable"

spec :: Spec
spec = do
  describe "withTranscript" $ do
    it "logs a Request and Response entry for a successful call" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path

        let wrappedFn :: ByteString -> IO ByteString
            wrappedFn input = pure ("response:" <> input)

        result <- withTranscript th Nothing (Just "test-source") wrappedFn "hello"
        result `shouldBe` "response:hello"

        _th_flush th
        entries <- _th_query th emptyFilter
        length entries `shouldBe` 2

        (reqEntry, respEntry) <- getReqResp entries
        _te_direction reqEntry `shouldBe` Request
        _te_direction respEntry `shouldBe` Response

    it "uses the same correlation ID for Request and Response" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path

        _ <- withTranscript th Nothing (Just "test-source") (\_ -> pure "ok") "input"
        _th_flush th
        entries <- _th_query th emptyFilter

        (reqEntry, respEntry) <- getReqResp entries
        _te_correlationId reqEntry `shouldBe` _te_correlationId respEntry
        -- Correlation ID should be non-empty
        _te_correlationId reqEntry `shouldSatisfy` (not . T.null)

    it "records duration >= 0 on the Response entry" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path

        _ <- withTranscript th Nothing (Just "test-source") (\_ -> pure "ok") "input"
        _th_flush th
        entries <- _th_query th emptyFilter

        (reqEntry, respEntry) <- getReqResp entries
        case _te_durationMs respEntry of
          Nothing -> expectationFailure "Expected Just duration, got Nothing"
          Just ms -> ms `shouldSatisfy` (>= 0)

        -- Request entry should have no duration
        _te_durationMs reqEntry `shouldBe` Nothing

    it "sets the source name on both entries" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path

        _ <- withTranscript th Nothing (Just "my-provider") (\_ -> pure "ok") "input"
        _th_flush th
        entries <- _th_query th emptyFilter

        (reqEntry, respEntry) <- getReqResp entries
        _te_model reqEntry `shouldBe` Just "my-provider"
        _te_model respEntry `shouldBe` Just "my-provider"

    it "catches exceptions, logs error metadata, and re-throws" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path

        let failingFn :: ByteString -> IO ByteString
            failingFn _ = throwIO (userError "boom")

        withTranscript th Nothing (Just "test-source") failingFn "input"
          `shouldThrow` isUserError

        _th_flush th
        entries <- _th_query th emptyFilter
        length entries `shouldBe` 2

        (_reqEntry, respEntry) <- getReqResp entries
        _te_direction respEntry `shouldBe` Response
        -- Should have "error" key in metadata
        Map.member "error" (_te_metadata respEntry) `shouldBe` True
        -- The error metadata should contain "boom"
        case Map.lookup "error" (_te_metadata respEntry) of
          Just (Aeson.String errMsg) -> errMsg `shouldSatisfy` T.isInfixOf "boom"
          other -> expectationFailure ("Expected String metadata, got: " <> show other)

    it "does not fail if transcript recording throws" $ do
      recordCallRef <- newIORef (0 :: Int)
      let brokenHandle = TranscriptHandle
            { _th_record = \_ -> do
                modifyIORef' recordCallRef (+ 1)
                throwIO (userError "transcript write failed")
            , _th_query = \_ -> pure []
            , _th_getPath = pure ""
            , _th_flush = pure ()
            , _th_close = pure ()
            }

      -- The wrapped function should still succeed even though recording fails
      result <- withTranscript brokenHandle Nothing (Just "test-source") (\_ -> pure "ok") "input"
      result `shouldBe` "ok"

      -- Verify that recording was attempted
      calls <- readIORef recordCallRef
      calls `shouldSatisfy` (> 0)

    it "encodes input payload correctly in the Request entry" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inputBytes = "test-payload-bytes"

        _ <- withTranscript th Nothing (Just "test-source") (\_ -> pure "ok") inputBytes
        _th_flush th
        entries <- _th_query th emptyFilter

        (reqEntry, _respEntry) <- getReqResp entries
        decodePayload (_te_payload reqEntry) `shouldBe` Just inputBytes

    it "encodes output payload correctly in the Response entry" $
      withSystemTempDirectory "transcript-combinator" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let outputBytes = "response-payload-bytes"

        _ <- withTranscript th Nothing (Just "test-source") (\_ -> pure outputBytes) "input"
        _th_flush th
        entries <- _th_query th emptyFilter

        (_reqEntry, respEntry) <- getReqResp entries
        decodePayload (_te_payload respEntry) `shouldBe` Just outputBytes
