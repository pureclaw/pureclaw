module Channels.SignalSpec (spec) where

import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log

spec :: Spec
spec = do
  describe "SignalConfig" $ do
    it "has Show and Eq instances" $ do
      let cfg = SignalConfig { _sc_account = "+1234567890", _sc_textChunkLimit = 6000 }
      show cfg `shouldContain` "SignalConfig"
      cfg `shouldBe` cfg

  describe "mkSignalChannel" $ do
    it "creates a channel that can receive pushed envelopes" $ do
      sc <- mkTestSignalChannel
      let env = mkTestEnvelope "+1234567890" 1000 "Hello from Signal"
      atomically $ writeTQueue (_sch_inbox sc) env
      let h = toHandle sc
      msg <- _ch_receive h
      _im_content msg `shouldBe` "Hello from Signal"

    it "extracts sender as userId" $ do
      sc <- mkTestSignalChannel
      let env = mkTestEnvelope "+9876543210" 2000 "Hi"
      atomically $ writeTQueue (_sch_inbox sc) env
      msg <- _ch_receive (toHandle sc)
      _im_userId msg `shouldBe` UserId "+9876543210"

    it "handles envelope with no dataMessage" $ do
      sc <- mkTestSignalChannel
      let env = SignalEnvelope "+1111111111" 3000 Nothing
      atomically $ writeTQueue (_sch_inbox sc) env
      msg <- _ch_receive (toHandle sc)
      _im_content msg `shouldBe` ""

  describe "parseSignalEnvelope" $ do
    it "parses a valid envelope JSON" $ do
      let json = object
            [ "source" .= ("+1234567890" :: String)
            , "timestamp" .= (1000 :: Int)
            , "dataMessage" .= object
                [ "message" .= ("hello" :: String)
                , "timestamp" .= (1000 :: Int)
                ]
            ]
      case parseSignalEnvelope json of
        Left err -> expectationFailure err
        Right env -> do
          _se_source env `shouldBe` "+1234567890"
          _se_timestamp env `shouldBe` 1000
          case _se_dataMessage env of
            Nothing -> expectationFailure "expected dataMessage"
            Just dm -> _sdm_message dm `shouldBe` "hello"

    it "parses envelope without dataMessage" $ do
      let json = object
            [ "source" .= ("+1234567890" :: String)
            , "timestamp" .= (2000 :: Int)
            ]
      case parseSignalEnvelope json of
        Left err -> expectationFailure err
        Right env -> _se_dataMessage env `shouldBe` Nothing

    it "rejects invalid JSON" $ do
      let json = object ["wrong" .= ("field" :: String)]
      parseSignalEnvelope json `shouldSatisfy` isLeft

  describe "SignalEnvelope" $ do
    it "has Show and Eq instances" $ do
      let env = mkTestEnvelope "+1234567890" 1000 "hi"
      show env `shouldContain` "SignalEnvelope"
      env `shouldBe` env

  describe "SignalDataMessage" $ do
    it "has Show and Eq instances" $ do
      let dm = SignalDataMessage "hello" 1000
      show dm `shouldContain` "SignalDataMessage"
      dm `shouldBe` dm

  describe "send and sendError" $ do
    it "sends via transport to the last sender" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
          config = SignalConfig { _sc_account = "+0000000000", _sc_textChunkLimit = 6000 }
      sc <- mkSignalChannel config transport mkNoOpLogHandle
      -- Push a message from a specific sender
      let env = mkTestEnvelope "+9876543210" 1000 "Hello"
      atomically $ writeTQueue (_sch_inbox sc) env
      let h = toHandle sc
      _ <- _ch_receive h
      -- Now send a response — it should go to the last sender
      _ch_send h (OutgoingMessage "Reply")
      (recipient, body) <- atomically $ readTQueue outQ
      recipient `shouldBe` "+9876543210"
      body `shouldBe` "Reply"

    it "chunks long messages" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
          config = SignalConfig { _sc_account = "+0000000000", _sc_textChunkLimit = 20 }
      sc <- mkSignalChannel config transport mkNoOpLogHandle
      -- Set up a sender
      let env = mkTestEnvelope "+111" 1000 "Hi"
      atomically $ writeTQueue (_sch_inbox sc) env
      _ <- _ch_receive (toHandle sc)
      -- Send a long message
      _ch_send (toHandle sc) (OutgoingMessage "This is a message that exceeds the chunk limit")
      -- Should receive multiple chunks
      chunks <- drainQueue outQ
      length chunks `shouldSatisfy` (> 1)
      all (\(_, body) -> T.length body <= 20) chunks `shouldBe` True

    it "sendError sends via transport" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
          config = SignalConfig { _sc_account = "+0000000000", _sc_textChunkLimit = 6000 }
      sc <- mkSignalChannel config transport mkNoOpLogHandle
      let env = mkTestEnvelope "+111" 1000 "Hi"
      atomically $ writeTQueue (_sch_inbox sc) env
      _ <- _ch_receive (toHandle sc)
      _ch_sendError (toHandle sc) (TemporaryError "oops")
      (_, body) <- atomically $ readTQueue outQ
      body `shouldSatisfy` T.isInfixOf "oops"

    it "readSecret throws IOError (vault requires CLI)" $ do
      sc <- mkTestSignalChannel
      let h = toHandle sc
      result <- try @IOError (_ch_readSecret h)
      result `shouldSatisfy` isLeft

-- Helpers

mkTestSignalChannel :: IO SignalChannel
mkTestSignalChannel = do
  inQ  <- newTQueueIO
  outQ <- newTQueueIO
  let transport = mkMockSignalTransport inQ outQ
      config = SignalConfig { _sc_account = "+0000000000", _sc_textChunkLimit = 6000 }
  mkSignalChannel config transport mkNoOpLogHandle

mkTestEnvelope :: Text -> Int -> Text -> SignalEnvelope
mkTestEnvelope source ts msg =
  SignalEnvelope source ts (Just (SignalDataMessage msg ts))

-- | Drain all available items from a TQueue (non-blocking).
drainQueue :: TQueue a -> IO [a]
drainQueue q = atomically $ do
  let go acc = do
        mVal <- tryReadTQueue q
        case mVal of
          Nothing  -> pure (reverse acc)
          Just val -> go (val : acc)
  go []
