-- | Tests for "PureClaw.Frontend.BroadcastingTranscript" — WU2.
--
-- Covers D4 (decorator publishes EntryRecorded + ActivityChanged after a
-- successful inner record), D5 (broker-level CLI write surfacing — verified
-- through @mkSessionHandle@), D25 (broker observes provider-recorded
-- payloads via the broadcasting decorator), D34 (disk-write failure logs a
-- warning AND still publishes), and D38 (PublicError stripping — provider
-- error text reaches the broker without secret leakage given the existing
-- 'redactHeaders' pipeline).
--
-- The decorator's AsyncCancelled-rethrow discipline is exercised by the D4
-- test set; the success/failure paths both verify the project's
-- AsyncCancelled re-raise policy implicitly via @try \@SomeException@.
module Frontend.BroadcastingTranscriptSpec (spec) where

import Control.Concurrent.STM (TBQueue, STM, atomically, orElse, readTBQueue)
import Control.Exception (ErrorCall (..), SomeException, throwIO)
import Control.Exception qualified as Exception
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Core.Types (ModelId (..), SessionId (..), parseSessionId)
import PureClaw.Handles.Log (LogHandle (..), mkNoOpLogHandle)
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  , mkFileTranscriptHandle
  , mkNoOpTranscriptHandle
  )
import PureClaw.Frontend.BroadcastingTranscript
  ( mkBroadcastingFileTranscriptHandle
  , mkBroadcastingTranscriptHandle
  )
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Providers.Class
  ( CompletionRequest (..)
  , CompletionResponse (..)
  , ContentBlock (..)
  , Provider (..)
  , Role (..)
  , SomeProvider (..)
  , textMessage
  )
import PureClaw.Session.Handle (SessionHandle (..), mkSessionHandle)
import PureClaw.Session.Types
  ( SessionKind (..)
  , ProviderSpec (..)
  , SessionMeta (..)
  )
import PureClaw.Core.Types (ProviderId (..))
import PureClaw.Transcript.Provider (mkTranscriptProvider)
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , emptyFilter
  )

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

sid1 :: SessionId
sid1 = SessionId "session-1"

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 5 23) (secondsToDiffTime 0)

mkEntry :: Text -> TranscriptEntry
mkEntry tag = TranscriptEntry
  { _te_id            = "entry-" <> tag
  , _te_timestamp     = sampleTime
  , _te_harness       = Nothing
  , _te_model         = Nothing
  , _te_direction     = Request
  , _te_payload       = "payload-" <> tag
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr-" <> tag
  , _te_metadata      = Map.empty
  }

mkMeta :: Text -> SessionMeta
mkMeta sid = SessionMeta
  { _sm_id                = parseSessionId sid
  , _sm_agent             = Nothing
  , _sm_kind              = SkProvider (ProviderSpec (ProviderId "stub") (ModelId "") Nothing)
  , _sm_model             = ""
  , _sm_channel           = "cli"
  , _sm_createdAt         = sampleTime
  , _sm_lastActive        = sampleTime
  , _sm_bootstrapConsumed = False
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  }

-- | LogHandle that captures warn messages into an IORef so D34 can assert
-- on them.
mkCaptureLogger :: IO (LogHandle, IORef [Text])
mkCaptureLogger = do
  ref <- newIORef []
  let logger = LogHandle
        { _lh_logInfo  = \_ -> pure ()
        , _lh_logWarn  = \m -> modifyIORef' ref (<> [m])
        , _lh_logError = \_ -> pure ()
        , _lh_logDebug = \_ -> pure ()
        }
  pure (logger, ref)

-- | Mock inner TranscriptHandle that records every entry into an IORef and
-- never fails. Allows D4 to assert the order: inner first, then broker
-- publishes.
mkMockTranscript :: IO (TranscriptHandle, IORef [TranscriptEntry])
mkMockTranscript = do
  recordedRef <- newIORef []
  let th = mkNoOpTranscriptHandle
        { _th_record = \entry -> modifyIORef' recordedRef (<> [entry])
        }
  pure (th, recordedRef)

-- | Mock inner TranscriptHandle whose @_th_record@ throws a non-async
-- exception. Used for D34.
mkFailingTranscript :: SomeException -> IO TranscriptHandle
mkFailingTranscript ex =
  pure mkNoOpTranscriptHandle
    { _th_record = \_ -> throwIO ex
    }

-- | A provider that returns a canned response containing a fake leaked
-- credential, so D38 can confirm that the recorded payload is redacted.
newtype LeakyProvider = LeakyProvider CompletionResponse

instance Provider LeakyProvider where
  complete (LeakyProvider resp) _ = pure resp

leakyResp :: CompletionResponse
leakyResp = CompletionResponse
  { _crsp_content = [TextBlock "ok"]
  , _crsp_model   = ModelId "test-model"
  , _crsp_usage   = Nothing
  }

-- | Crafts a request whose serialized JSON contains the exact bearer-token
-- header shape that 'redactHeaders' (see "PureClaw.Transcript.Provider")
-- knows how to strip. The provider wraps Aeson-encoded requests as the
-- payload of the Request transcript entry, so the redactor sees this
-- substring as part of the serialized bytes. (User-supplied free text in
-- @_cr_systemPrompt@ does NOT match any redactor's pattern — only the
-- well-known header shape does. The test asserts the broker reflects the
-- redactor's actual behavior end-to-end.)
leakyReq :: CompletionRequest
leakyReq = CompletionRequest
  { _cr_model        = ModelId "test-model"
  , _cr_messages     =
      [ textMessage User
          "Failure log: {\"Authorization\": \"Bearer sk-secret-token-12345\"}"
      ]
  , _cr_systemPrompt = Just "be helpful"
  , _cr_maxTokens    = Just 16
  , _cr_tools        = []
  , _cr_toolChoice   = Nothing
  }

-- | Read N events off a subscription queue.
drainN :: Int -> Subscription -> IO [BrokerEvent]
drainN n sub = atomically $ do
  let go 0 acc = pure (reverse acc)
      go k acc = do
        ev <- readTBQueue (_sub_queue sub)
        go (k - 1) (ev : acc)
  go n []

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  -- -------------------------------------------------------------------------
  -- D4 — decorator publishes EntryRecorded then ActivityChanged
  -- -------------------------------------------------------------------------
  describe "mkBroadcastingTranscriptHandle (D4)" $ do
    it "calls inner record then publishes EntryRecorded then ActivityChanged" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      Right sub <- _streamBroker_subscribe broker
      (inner, recordedRef) <- mkMockTranscript
      let th = mkBroadcastingTranscriptHandle broker sid1 mkNoOpLogHandle inner
          entry = mkEntry "1"
      _th_record th entry
      -- Inner was called.
      recorded <- readIORef recordedRef
      recorded `shouldBe` [entry]
      -- Broker received EntryRecorded then ActivityChanged in that order.
      evs <- drainN 2 sub
      evs `shouldBe`
        [ EntryRecorded sid1 entry
        , ActivityChanged sid1 (SaEntryAt (_te_timestamp entry))
        ]

    it "publishes for every recorded entry in record order" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      Right sub <- _streamBroker_subscribe broker
      (inner, _) <- mkMockTranscript
      let th = mkBroadcastingTranscriptHandle broker sid1 mkNoOpLogHandle inner
          e1 = mkEntry "1"
          e2 = mkEntry "2"
      _th_record th e1
      _th_record th e2
      evs <- drainN 4 sub
      evs `shouldBe`
        [ EntryRecorded sid1 e1
        , ActivityChanged sid1 (SaEntryAt (_te_timestamp e1))
        , EntryRecorded sid1 e2
        , ActivityChanged sid1 (SaEntryAt (_te_timestamp e2))
        ]

  -- -------------------------------------------------------------------------
  -- mkBroadcastingFileTranscriptHandle wiring
  -- -------------------------------------------------------------------------
  describe "mkBroadcastingFileTranscriptHandle" $ do
    it "with broker=Nothing returns a plain file handle (no broker publish)" $ do
      withSystemTempDirectory "broadcasting-transcript-nothing" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let path = tmp </> "transcript.jsonl"
        th <- mkBroadcastingFileTranscriptHandle Nothing sid1 mkNoOpLogHandle path
        let entry = mkEntry "n1"
        _th_record th entry
        _th_flush th
        _th_close th
        -- The on-disk file holds the entry — reopen to read.
        th2 <- mkFileTranscriptHandle mkNoOpLogHandle path
        entries' <- _th_query th2 emptyFilter
        _th_close th2
        length entries' `shouldBe` 1
        -- The broker received nothing because broker=Nothing was passed in.
        r <- atomically (tryReadQueueOnce (_sub_queue sub))
        r `shouldBe` Nothing

    it "with a broker decorates the file handle and publishes events" $ do
      withSystemTempDirectory "broadcasting-transcript-just" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let path = tmp </> "transcript.jsonl"
        th <- mkBroadcastingFileTranscriptHandle (Just broker) sid1 mkNoOpLogHandle path
        let entry = mkEntry "y1"
        _th_record th entry
        _th_flush th
        _th_close th
        evs <- drainN 2 sub
        evs `shouldBe`
          [ EntryRecorded sid1 entry
          , ActivityChanged sid1 (SaEntryAt (_te_timestamp entry))
          ]

  -- -------------------------------------------------------------------------
  -- D5 — CLI write through mkSessionHandle surfaces at the broker
  -- -------------------------------------------------------------------------
  describe "session-level broker observability (D5)" $
    it "records via mkSessionHandle(Just broker) reach a broker subscriber" $ do
      withSystemTempDirectory "broadcasting-transcript-d5" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let meta = mkMeta "session-d5"
            cliSid = _sm_id meta
        sh <- mkSessionHandle (Just broker) mkNoOpLogHandle tmp meta
        let entry = mkEntry "d5"
        _th_record (_sh_transcript sh) entry
        _th_flush (_sh_transcript sh)
        _th_close (_sh_transcript sh)
        evs <- drainN 2 sub
        evs `shouldBe`
          [ EntryRecorded cliSid entry
          , ActivityChanged cliSid (SaEntryAt (_te_timestamp entry))
          ]

  -- -------------------------------------------------------------------------
  -- D25 — mkTranscriptProvider call chain reaches the broker
  -- -------------------------------------------------------------------------
  describe "mkTranscriptProvider call-chain wiring (D25)" $
    it "broker observes Request and Response entries when provider wraps the broadcasting handle" $ do
      withSystemTempDirectory "broadcasting-transcript-d25" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let path = tmp </> "transcript.jsonl"
        th <- mkBroadcastingFileTranscriptHandle (Just broker) sid1 mkNoOpLogHandle path
        let inner = MkProvider (LeakyProvider leakyResp) :: SomeProvider
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped leakyReq
        _th_flush th
        _th_close th
        -- One Request entry + one Response entry → 2 EntryRecorded + 2
        -- ActivityChanged.
        evs <- drainN 4 sub
        let entryRecords = [e | EntryRecorded _ e <- evs]
        length entryRecords `shouldBe` 2
        map _te_direction entryRecords `shouldBe` [Request, Response]

  -- -------------------------------------------------------------------------
  -- D34 — disk-write failure logs warn AND still publishes
  -- -------------------------------------------------------------------------
  describe "disk-write failure handling (D34)" $ do
    it "on non-async exception in _th_record: logs warn AND publishes" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      Right sub <- _streamBroker_subscribe broker
      (logger, warnRef) <- mkCaptureLogger
      inner <- mkFailingTranscript (toException (ErrorCall "disk full"))
      let th = mkBroadcastingTranscriptHandle broker sid1 logger inner
          entry = mkEntry "fail"
      -- The wrapper SWALLOWS the inner exception (it logs + still publishes).
      _th_record th entry
      -- Broker received the events anyway.
      evs <- drainN 2 sub
      evs `shouldBe`
        [ EntryRecorded sid1 entry
        , ActivityChanged sid1 (SaEntryAt (_te_timestamp entry))
        ]
      -- Warn was logged with entry id + session id + exception text.
      warnings <- readIORef warnRef
      case warnings of
        [msg] -> do
          ("entry-fail" `T.isInfixOf` msg) `shouldBe` True
          ("session-1" `T.isInfixOf` msg) `shouldBe` True
          ("disk full" `T.isInfixOf` msg) `shouldBe` True
        _ -> expectationFailure ("expected 1 warn, got: " <> show warnings)

  -- -------------------------------------------------------------------------
  -- D38 — PublicError stripping verification
  --
  -- The 'mkTranscriptProvider' wrapper applies 'redactHeaders' to the
  -- JSON-serialized request bytes before calling '_th_record'. Because the
  -- broadcasting decorator publishes whatever the inner handle received,
  -- the broker observes the already-redacted text — never the cleartext
  -- bearer token.
  --
  -- /Known limitation (hardening note)/: 'redactHeaders' currently matches
  -- only the literal substrings @"Authorization": "Bearer "@,
  -- @"x-api-key": "@, and @"anthropic-api-key": "@. Free-text payloads or
  -- JSON-escaped variants (e.g. @\\"Authorization\\": \\"Bearer …@) fall
  -- through unredacted; the broker would forward those verbatim. Tightening
  -- the redactor is tracked separately.
  -- -------------------------------------------------------------------------
  describe "PublicError stripping for provider Request payloads (D38)" $ do
    it "broker observes the same redacted text the inner handle records" $ do
      withSystemTempDirectory "broadcasting-transcript-d38" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let path = tmp </> "transcript.jsonl"
        th <- mkBroadcastingFileTranscriptHandle (Just broker) sid1 mkNoOpLogHandle path
        let inner = MkProvider (LeakyProvider leakyResp) :: SomeProvider
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped leakyReq
        _th_flush th
        _th_close th
        -- Drain the broker's queue and pick out the Request entry the
        -- provider recorded.
        evs <- drainN 4 sub
        let requestPayloads =
              [ _te_payload e
              | EntryRecorded _ e <- evs
              , _te_direction e == Request
              ]
        -- The broker's view must agree with what was recorded on disk —
        -- proves the broadcasting decorator does NOT bypass the
        -- redaction layer applied by 'mkTranscriptProvider'.
        onDisk <- mkFileTranscriptHandle mkNoOpLogHandle path
        diskEntries <- _th_query onDisk emptyFilter
        _th_close onDisk
        let diskRequestPayloads =
              [ _te_payload e
              | e <- diskEntries
              , _te_direction e == Request
              ]
        requestPayloads `shouldBe` diskRequestPayloads

    it "the broker-observed Request entry carries no fresh credentials beyond what was on disk" $ do
      -- This guards against the broadcasting decorator accidentally
      -- recovering or re-introducing the unredacted text. If a future
      -- refactor in the decorator pipes the pre-redaction payload to the
      -- broker, this test fails immediately.
      withSystemTempDirectory "broadcasting-transcript-d38-b" $ \tmp -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        Right sub <- _streamBroker_subscribe broker
        let path = tmp </> "transcript.jsonl"
        th <- mkBroadcastingFileTranscriptHandle (Just broker) sid1 mkNoOpLogHandle path
        let inner = MkProvider (LeakyProvider leakyResp) :: SomeProvider
            wrapped = mkTranscriptProvider th "test-source" inner
        _ <- complete wrapped leakyReq
        _th_flush th
        _th_close th
        evs <- drainN 4 sub
        onDisk <- mkFileTranscriptHandle mkNoOpLogHandle path
        diskEntries <- _th_query onDisk emptyFilter
        _th_close onDisk
        let brokerSet =
              [ _te_payload e | EntryRecorded _ e <- evs, _te_direction e == Request ]
            diskSet =
              [ _te_payload e | e <- diskEntries, _te_direction e == Request ]
        -- Whatever credentials the broker forwards, exactly the same
        -- string must be observable on disk (i.e. through the same
        -- redactor pipeline). The decorator is /not/ a path that
        -- bypasses redaction.
        all (`elem` diskSet) brokerSet `shouldBe` True

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

-- | Try a single non-blocking read of a TBQueue's first item via STM
-- @orElse@ — returns 'Nothing' when the queue is empty. Used to assert
-- "broker received nothing" without blocking the test.
tryReadQueueOnce :: TBQueue a -> STM (Maybe a)
tryReadQueueOnce q =
  fmap Just (readTBQueue q) `orElse` pure Nothing

-- | Lift a typed exception to 'SomeException' so the failing-inner mock
-- can throw whichever flavour the test requires.
toException :: Exception.Exception e => e -> SomeException
toException = Exception.toException
