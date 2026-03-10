module Handles.ChannelSpec (spec) where

import Test.Hspec

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel

spec :: Spec
spec = do
  describe "mkNoOpChannelHandle" $ do
    it "receive returns an empty message" $ do
      msg <- _ch_receive mkNoOpChannelHandle
      _im_userId msg `shouldBe` UserId ""
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
      let msg = IncomingMessage (UserId "user1") "hello"
      show msg `shouldContain` "user1"
      msg `shouldBe` msg

  describe "OutgoingMessage" $ do
    it "has Show and Eq instances" $ do
      let msg = OutgoingMessage "response"
      show msg `shouldContain` "response"
      msg `shouldBe` msg
