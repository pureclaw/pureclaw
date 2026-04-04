module Transcript.ProviderSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson (Value)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.FilePath
import System.IO.Temp
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript
import PureClaw.Providers.Class
import PureClaw.Transcript.Provider
import PureClaw.Transcript.Types

-- | A mock provider that returns a canned response.
newtype CannedProvider = CannedProvider CompletionResponse

instance Provider CannedProvider where
  complete (CannedProvider resp) _ = pure resp

-- | A mock provider that also tracks streaming via callback.
newtype StreamingMockProvider = StreamingMockProvider CompletionResponse

instance Provider StreamingMockProvider where
  complete (StreamingMockProvider resp) _ = pure resp
  completeStream (StreamingMockProvider resp) _ callback = do
    callback (StreamText "partial")
    callback (StreamDone resp)

-- | Standard test request.
testReq :: CompletionRequest
testReq = CompletionRequest
  { _cr_model        = ModelId "test-model"
  , _cr_messages     = [textMessage User "Hello"]
  , _cr_systemPrompt = Just "Be helpful"
  , _cr_maxTokens    = Just 1024
  , _cr_tools        = []
  , _cr_toolChoice   = Nothing
  }

-- | Standard test response with usage.
testResp :: CompletionResponse
testResp = CompletionResponse
  { _crsp_content = [TextBlock "Hi there!"]
  , _crsp_model   = ModelId "test-model"
  , _crsp_usage   = Just (Usage 42 17)
  }

-- | Standard test response without usage.
testRespNoUsage :: CompletionResponse
testRespNoUsage = CompletionResponse
  { _crsp_content = [TextBlock "Hi there!"]
  , _crsp_model   = ModelId "test-model"
  , _crsp_usage   = Nothing
  }

-- | Safe access to list elements by index, failing with a clear message.
entryAt :: [TranscriptEntry] -> Int -> IO TranscriptEntry
entryAt entries i
  | i < length entries = pure (entries !! i)
  | otherwise = do
      expectationFailure ("expected at least " <> show (i + 1)
                         <> " entries, got " <> show (length entries))
      -- unreachable, but satisfies the type checker
      error "unreachable"

spec :: Spec
spec = do
  ---------------------------------------------------------------------------
  -- DoD 1: Logged provider returns same CompletionResponse as inner provider
  ---------------------------------------------------------------------------
  describe "mkTranscriptProvider complete" $ do
    it "returns the same CompletionResponse as the inner provider" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        resp <- complete wrapped testReq
        resp `shouldBe` testResp
        _th_close th

  ---------------------------------------------------------------------------
  -- DoD 2: Request and Response transcript entries appear after complete
  ---------------------------------------------------------------------------
  describe "transcript entries" $ do
    it "records Request and Response entries after complete" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        length entries `shouldBe` 2
        reqEntry <- entryAt entries 0
        respEntry <- entryAt entries 1
        _te_direction reqEntry `shouldBe` Request
        _te_direction respEntry `shouldBe` Response
        _th_close th

    it "entries share the same correlationId" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        length entries `shouldBe` 2
        e0 <- entryAt entries 0
        e1 <- entryAt entries 1
        _te_correlationId e0 `shouldBe` _te_correlationId e1
        _th_close th

    it "entries have the correct source" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "my-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        all (\e -> _te_source e == "my-source") entries `shouldBe` True
        _th_close th

  ---------------------------------------------------------------------------
  -- DoD 3: Authorization Bearer header is redacted in request payload
  ---------------------------------------------------------------------------
  describe "redactHeaders" $ do
    it "redacts Authorization: Bearer headers" $ do
      let input = "\"Authorization\": \"Bearer sk-abc123xyz\""
      redactHeaders input `shouldBe` "\"Authorization\": \"Bearer <REDACTED>\""

    it "redacts x-api-key headers" $ do
      let input = "\"x-api-key\": \"sk-abc123xyz\""
      redactHeaders input `shouldBe` "\"x-api-key\": \"<REDACTED>\""

    it "redacts anthropic-api-key headers" $ do
      let input = "\"anthropic-api-key\": \"sk-ant-abc123\""
      redactHeaders input `shouldBe` "\"anthropic-api-key\": \"<REDACTED>\""

    it "redacts multiple headers in the same text" $ do
      let input = T.unlines
            [ "\"Authorization\": \"Bearer sk-123\""
            , "\"x-api-key\": \"secret\""
            , "\"anthropic-api-key\": \"key\""
            ]
          result = redactHeaders input
      T.isInfixOf "sk-123" result `shouldBe` False
      T.isInfixOf "secret" result `shouldBe` False
      T.isInfixOf "<REDACTED>" result `shouldBe` True

    it "leaves non-sensitive headers untouched" $ do
      let input = "\"content-type\": \"application/json\""
      redactHeaders input `shouldBe` input

    it "leaves text without headers untouched" $ do
      let input = "just some plain text"
      redactHeaders input `shouldBe` input

  ---------------------------------------------------------------------------
  -- DoD 6: Response payloads are NOT redacted
  ---------------------------------------------------------------------------
  describe "response payload" $ do
    it "is not redacted" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        respEntry <- entryAt entries 1
        let payload = _te_payload respEntry
        -- The response payload should contain the raw response JSON
        case decodePayload payload of
          Nothing -> expectationFailure "could not decode response payload"
          Just bs -> case Aeson.decode (toLazy bs) of
            Nothing -> expectationFailure "could not parse response payload JSON"
            Just val -> do
              -- Response should contain the text block content
              let txt = Aeson.encode (val :: Value)
              T.isInfixOf "Hi there!" (toText txt) `shouldBe` True
        _th_close th

  ---------------------------------------------------------------------------
  -- DoD 7: Token usage appears in metadata
  ---------------------------------------------------------------------------
  describe "metadata" $ do
    it "contains input_tokens and output_tokens from usage" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        respEntry <- entryAt entries 1
        let meta = _te_metadata respEntry
        Map.lookup "input_tokens" meta `shouldBe` Just (Aeson.Number 42)
        Map.lookup "output_tokens" meta `shouldBe` Just (Aeson.Number 17)
        _th_close th

    it "omits token fields when usage is Nothing" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testRespNoUsage)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        respEntry <- entryAt entries 1
        let meta = _te_metadata respEntry
        Map.lookup "input_tokens" meta `shouldBe` Nothing
        Map.lookup "output_tokens" meta `shouldBe` Nothing
        _th_close th

  ---------------------------------------------------------------------------
  -- DoD 8: Model name appears in metadata
  ---------------------------------------------------------------------------
    it "contains the model name" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (CannedProvider testResp)
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped testReq
        _th_flush th
        entries <- _th_query th emptyFilter
        respEntry <- entryAt entries 1
        let meta = _te_metadata respEntry
        Map.lookup "model" meta `shouldBe` Just (Aeson.String "test-model")
        _th_close th

  ---------------------------------------------------------------------------
  -- DoD 9: Streaming calls log the final StreamDone response
  ---------------------------------------------------------------------------
  describe "mkTranscriptProvider completeStream" $ do
    it "logs Request and Response entries" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (StreamingMockProvider testResp)
            wrapped = mkTranscriptProvider th "stream-source" inner
        eventsRef <- newIORef ([] :: [StreamEvent])
        completeStream wrapped testReq (\ev -> modifyIORef' eventsRef (++ [ev]))
        _th_flush th
        entries <- _th_query th emptyFilter
        length entries `shouldBe` 2
        reqEntry <- entryAt entries 0
        respEntry <- entryAt entries 1
        _te_direction reqEntry `shouldBe` Request
        _te_direction respEntry `shouldBe` Response
        _th_close th

    it "passes stream events through to the callback" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (StreamingMockProvider testResp)
            wrapped = mkTranscriptProvider th "stream-source" inner
        eventsRef <- newIORef ([] :: [StreamEvent])
        completeStream wrapped testReq (\ev -> modifyIORef' eventsRef (++ [ev]))
        events <- readIORef eventsRef
        -- Should receive both StreamText and StreamDone
        length events `shouldBe` 2
        _th_close th

    it "includes token usage in streaming response metadata" $ do
      withSystemTempDirectory "transcript-provider-test" $ \tmpDir -> do
        let path = tmpDir </> "transcript.jsonl"
        th <- mkFileTranscriptHandle mkNoOpLogHandle path
        let inner = MkProvider (StreamingMockProvider testResp)
            wrapped = mkTranscriptProvider th "stream-source" inner
        completeStream wrapped testReq (\_ -> pure ())
        _th_flush th
        entries <- _th_query th emptyFilter
        respEntry <- entryAt entries 1
        let meta = _te_metadata respEntry
        Map.lookup "input_tokens" meta `shouldBe` Just (Aeson.Number 42)
        Map.lookup "output_tokens" meta `shouldBe` Just (Aeson.Number 17)
        _th_close th

-- Helper to convert strict ByteString to lazy
toLazy :: BS.ByteString -> LBS.ByteString
toLazy = LBS.fromStrict

-- Helper to convert lazy ByteString to Text
toText :: LBS.ByteString -> T.Text
toText = T.pack . map (toEnum . fromEnum) . LBS.unpack
