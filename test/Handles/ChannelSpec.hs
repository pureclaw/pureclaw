module Handles.ChannelSpec (spec) where

import Control.Exception (try)
import Data.Either (isLeft)
import Data.Text (Text)
import Test.Hspec

import PureClaw.Core.Errors (PublicError (..))
import PureClaw.Core.Types
import PureClaw.Handles.Channel

spec :: Spec
spec = do
  describe "mkNoOpChannelHandle" $ do
    it "receive returns an empty message" $ do
      msg <- _ch_receive mkNoOpChannelHandle
      imUserId msg `shouldBe` UserId ""
      _im_content msg `shouldBe` ""

    it "send succeeds silently" $ do
      _ch_send mkNoOpChannelHandle (OutgoingMessage "hello")

    it "sendError accepts PublicError" $ do
      _ch_sendError mkNoOpChannelHandle RateLimitError

    it "sendError accepts all PublicError variants" $ do
      _ch_sendError mkNoOpChannelHandle (TemporaryError "oops")
      _ch_sendError mkNoOpChannelHandle RateLimitError
      _ch_sendError mkNoOpChannelHandle NotAllowedError

    it "readSecret returns empty text" $ do
      secret <- _ch_readSecret mkNoOpChannelHandle
      secret `shouldBe` ""

  describe "IncomingMessage" $ do
    it "has Show and Eq instances" $ do
      let msg = IncomingMessage
            (mkMessageSource CkCli (ConversationId "cli") (Just (UserId "user1")) mempty) "hello"
      show msg `shouldContain` "user1"
      msg `shouldBe` msg

    it "imUserId derives the user id from a source with Just userId" $ do
      let msg = IncomingMessage
            (mkMessageSource CkSignal (ConversationId "+15551234567") (Just (UserId "+15551234567")) mempty) "hi"
      imUserId msg `shouldBe` UserId "+15551234567"
      _ms_channel (_im_source msg) `shouldBe` CkSignal

    it "imUserId yields the UserId \"\" sentinel for a Nothing source" $ do
      let msg = IncomingMessage
            (mkMessageSource (CkOther "noop") (ConversationId "noop") Nothing mempty) "hi"
      imUserId msg `shouldBe` UserId ""
      _ms_userId (_im_source msg) `shouldBe` Nothing

  describe "OutgoingMessage" $ do
    it "has Show and Eq instances" $ do
      let msg = OutgoingMessage "response"
      show msg `shouldContain` "response"
      msg `shouldBe` msg

  describe "mkCaptureChannelHandle" $ do
    it "buffers multiple _ch_send messages joined by newline" $ do
      (h, readOut) <- mkCaptureChannelHandle
      _ch_send h (OutgoingMessage "first")
      _ch_send h (OutgoingMessage "second")
      out <- readOut
      out `shouldBe` "first\nsecond"

    it "captures _ch_sendError and _ch_sendChunk output too" $ do
      (h, readOut) <- mkCaptureChannelHandle
      _ch_send h (OutgoingMessage "ok")
      _ch_sendError h (TemporaryError "boom")
      _ch_sendChunk h (ChunkText "chunk")
      out <- readOut
      out `shouldBe` "ok\nboom\nchunk"

    it "is non-streaming" $ do
      (h, _) <- mkCaptureChannelHandle
      _ch_streaming h `shouldBe` False

    it "throws InteractiveUnsupported on prompt" $ do
      (h, _) <- mkCaptureChannelHandle
      r <- try (_ch_prompt h "API key: ") :: IO (Either InteractiveUnsupported Text)
      case r of
        Left (InteractiveUnsupported label) -> label `shouldBe` "API key: "
        Right _ -> expectationFailure "expected InteractiveUnsupported"

    it "throws InteractiveUnsupported on promptSecret and readSecret" $ do
      (h, _) <- mkCaptureChannelHandle
      r1 <- try (_ch_promptSecret h "pw") :: IO (Either InteractiveUnsupported Text)
      r2 <- try (_ch_readSecret h)        :: IO (Either InteractiveUnsupported Text)
      (isLeft r1, isLeft r2) `shouldBe` (True, True)

    it "throws on _ch_receive" $ do
      (h, _) <- mkCaptureChannelHandle
      r <- try (_ch_receive h) :: IO (Either InteractiveUnsupported IncomingMessage)
      isLeft r `shouldBe` True
