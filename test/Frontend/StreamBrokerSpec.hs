-- | Tests for "PureClaw.Frontend.StreamBroker" — WU1.
--
-- Covers D1 (publish/subscribe round-trip + cleanup), D2 (3 subscribers × 10
-- ordered events), D3 (STM-atomic overflow protocol), and the subscriber cap
-- behavior (subscribe returns @Left SubscriberCapReached@ once the global cap
-- is reached).
module Frontend.StreamBrokerSpec (spec) where

import Control.Concurrent.STM (atomically, readTBQueue, readTVarIO, writeTVar)
import Control.Monad (forM_, replicateM)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.StreamBroker
  ( BrokerConfig (..)
  , BrokerError (..)
  , BrokerEvent (..)
  , BrokerStats (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Transcript.Types
  ( Direction (Request)
  , TranscriptEntry (..)
  )

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

sid1 :: SessionId
sid1 = SessionId "session-1"

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 5 23) (secondsToDiffTime 0)

textShow :: Int -> Text
textShow = T.pack . show

mkEntry :: Int -> TranscriptEntry
mkEntry n = TranscriptEntry
  { _te_id            = "entry-" <> textShow n
  , _te_timestamp     = sampleTime
  , _te_harness       = Nothing
  , _te_model         = Nothing
  , _te_direction     = Request
  , _te_payload       = "payload-" <> textShow n
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr-" <> textShow n
  , _te_metadata      = Map.empty
  }

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "mkInProcessBroker / publish + subscribe (D1)" $ do
    it "publish→subscribe round-trips a known event" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let entry = mkEntry 1
              event = EntryRecorded sid1 entry
          _streamBroker_publish broker event
          received <- atomically (readTBQueue (_sub_queue sub))
          received `shouldBe` event

    it "preserves publish order across a single subscriber" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let events = [EntryRecorded sid1 (mkEntry n) | n <- [1 .. 5]]
          forM_ events (_streamBroker_publish broker)
          received <-
            atomically $ replicateM (length events) (readTBQueue (_sub_queue sub))
          received `shouldBe` events

    it "_sub_cancel removes the subscriber from introspect" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          pre <- _streamBroker_introspect broker
          _bs_subscriberCount pre `shouldBe` 1
          _sub_cancel sub
          post <- _streamBroker_introspect broker
          _bs_subscriberCount post `shouldBe` 0

  describe "fanout (D2)" $
    it "3 subscribers each receive all 10 events in publish order" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subs <-
        replicateM 3 $ do
          r <- _streamBroker_subscribe broker
          case r of
            Right s -> pure s
            Left e  -> fail $ "subscribe failed: " <> show e
      let events = [EntryRecorded sid1 (mkEntry n) | n <- [1 .. 10]]
      forM_ events (_streamBroker_publish broker)
      forM_ subs $ \sub -> do
        received <-
          atomically $ replicateM (length events) (readTBQueue (_sub_queue sub))
        received `shouldBe` events

  describe "overflow protocol (D3)" $ do
    let smallCfg = defaultBrokerConfig {_bc_queueDepth = 2}

    it "fills the queue then drops oldest + sets overflow when capacity exceeded" $ do
      broker <- mkInProcessBroker smallCfg
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let e1 = EntryRecorded sid1 (mkEntry 1)
              e2 = EntryRecorded sid1 (mkEntry 2)
              e3 = EntryRecorded sid1 (mkEntry 3)
          -- Fill: queue has [e1, e2]; overflow still False.
          _streamBroker_publish broker e1
          _streamBroker_publish broker e2
          ovBefore <- readTVarIO (_sub_overflow sub)
          ovBefore `shouldBe` False
          -- Overflow: queue becomes [e2, e3]; overflow becomes True.
          _streamBroker_publish broker e3
          ovAfter <- readTVarIO (_sub_overflow sub)
          ovAfter `shouldBe` True
          drained <- atomically $ replicateM 2 (readTBQueue (_sub_queue sub))
          drained `shouldBe` [e2, e3]

    it "subsequent publishes after overflow write normally when queue has space" $ do
      broker <- mkInProcessBroker smallCfg
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let e1 = EntryRecorded sid1 (mkEntry 1)
              e2 = EntryRecorded sid1 (mkEntry 2)
              e3 = EntryRecorded sid1 (mkEntry 3)
              e4 = EntryRecorded sid1 (mkEntry 4)
          _streamBroker_publish broker e1
          _streamBroker_publish broker e2
          _streamBroker_publish broker e3 -- triggers overflow
          -- Drain to make room
          _ <- atomically (readTBQueue (_sub_queue sub))
          _ <- atomically (readTBQueue (_sub_queue sub))
          -- Reset the overflow flag — per spec, the subscriber owns the reset.
          atomically (writeTVar (_sub_overflow sub) False)
          _streamBroker_publish broker e4
          ovFinal <- readTVarIO (_sub_overflow sub)
          ovFinal `shouldBe` False
          tail4 <- atomically (readTBQueue (_sub_queue sub))
          tail4 `shouldBe` e4

    it "overflow stays True until the subscriber resets it (no auto-reset in v1)" $ do
      broker <- mkInProcessBroker smallCfg
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let e1 = EntryRecorded sid1 (mkEntry 1)
              e2 = EntryRecorded sid1 (mkEntry 2)
              e3 = EntryRecorded sid1 (mkEntry 3)
          _streamBroker_publish broker e1
          _streamBroker_publish broker e2
          _streamBroker_publish broker e3 -- overflow set
          _ <- atomically (readTBQueue (_sub_queue sub))
          _ <- atomically (readTBQueue (_sub_queue sub))
          ovStill <- readTVarIO (_sub_overflow sub)
          ovStill `shouldBe` True

  describe "subscriber cap" $ do
    it "rejects with Left SubscriberCapReached when global cap is exceeded" $ do
      let cfg = defaultBrokerConfig {_bc_maxSubscribers = 2}
      broker <- mkInProcessBroker cfg
      r1 <- _streamBroker_subscribe broker
      r2 <- _streamBroker_subscribe broker
      case (r1, r2) of
        (Right _, Right _) -> pure ()
        _ -> expectationFailure "first two subscribes should succeed"
      result <- _streamBroker_subscribe broker
      case result of
        Left SubscriberCapReached -> pure ()
        Right _ ->
          expectationFailure "third subscribe should have been rejected"

    it "cancelling a subscriber frees a slot under the cap" $ do
      let cfg = defaultBrokerConfig {_bc_maxSubscribers = 1}
      broker <- mkInProcessBroker cfg
      r1 <- _streamBroker_subscribe broker
      case r1 of
        Right s1 -> do
          rDenied <- _streamBroker_subscribe broker
          case rDenied of
            Left SubscriberCapReached -> pure ()
            Right _ ->
              expectationFailure "second subscribe should have been rejected"
          _sub_cancel s1
          r3 <- _streamBroker_subscribe broker
          case r3 of
            Right _ -> pure ()
            Left e  ->
              expectationFailure ("expected success after cancel; got " <> show e)
        Left e -> expectationFailure ("first subscribe failed: " <> show e)

  describe "ActivityChanged events" $
    it "ActivityChanged round-trips with SaHarnessStatus" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right sub -> do
          let ev = ActivityChanged sid1 (SaHarnessStatus HarnessThinking)
          _streamBroker_publish broker ev
          received <- atomically (readTBQueue (_sub_queue sub))
          received `shouldBe` ev

  describe "_streamBroker_currentActivity" $ do
    it "returns Nothing for a session that never published activity" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      st <- _streamBroker_currentActivity broker sid1
      st `shouldBe` Nothing

    it "remembers the most recent SaHarnessStatus per session" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      _streamBroker_publish broker
        (ActivityChanged sid1 (SaHarnessStatus HarnessThinking))
      st1 <- _streamBroker_currentActivity broker sid1
      st1 `shouldBe` Just HarnessThinking
      _streamBroker_publish broker
        (ActivityChanged sid1 (SaHarnessStatus HarnessIdle))
      st2 <- _streamBroker_currentActivity broker sid1
      st2 `shouldBe` Just HarnessIdle

    it "tracks distinct sessions independently" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      let sid2 = SessionId "session-2"
      _streamBroker_publish broker
        (ActivityChanged sid1 (SaHarnessStatus HarnessThinking))
      _streamBroker_publish broker
        (ActivityChanged sid2 (SaHarnessStatus HarnessIdle))
      st1 <- _streamBroker_currentActivity broker sid1
      st2 <- _streamBroker_currentActivity broker sid2
      st1 `shouldBe` Just HarnessThinking
      st2 `shouldBe` Just HarnessIdle

  describe "introspect" $
    it "queueDepths reflects per-subscriber queue size" $ do
      broker <- mkInProcessBroker defaultBrokerConfig
      subResult <- _streamBroker_subscribe broker
      case subResult of
        Left e -> expectationFailure ("subscribe failed: " <> show e)
        Right _sub -> do
          stats0 <- _streamBroker_introspect broker
          _bs_queueDepths stats0 `shouldBe` [0]
          _streamBroker_publish broker (EntryRecorded sid1 (mkEntry 1))
          stats1 <- _streamBroker_introspect broker
          _bs_queueDepths stats1 `shouldBe` [1]
