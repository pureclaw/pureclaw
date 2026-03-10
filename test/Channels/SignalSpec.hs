module Channels.SignalSpec (spec) where

import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.Either (isLeft)
import Data.Text (Text)
import Test.Hspec

import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log

spec :: Spec
spec = do
  describe "SignalConfig" $ do
    it "has Show and Eq instances" $ do
      let cfg = SignalConfig "+1234567890"
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
    it "send completes without error" $ do
      sc <- mkTestSignalChannel
      let h = toHandle sc
      _ch_send h (OutgoingMessage "test") `shouldReturn` ()

    it "sendError completes without error" $ do
      sc <- mkTestSignalChannel
      let h = toHandle sc
      _ch_sendError h (TemporaryError "oops") `shouldReturn` ()

    it "readSecret throws IOError (vault requires CLI)" $ do
      sc <- mkTestSignalChannel
      let h = toHandle sc
      result <- try @IOError (_ch_readSecret h)
      result `shouldSatisfy` isLeft

-- Helpers

mkTestSignalChannel :: IO SignalChannel
mkTestSignalChannel = mkSignalChannel (SignalConfig "+0000000000") mkNoOpLogHandle

mkTestEnvelope :: Text -> Int -> Text -> SignalEnvelope
mkTestEnvelope source ts msg =
  SignalEnvelope source ts (Just (SignalDataMessage msg ts))
