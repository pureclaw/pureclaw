module Channels.ClassSpec (spec) where

import Test.Hspec

import PureClaw.Channels.Class
import PureClaw.Core.Types
import PureClaw.Handles.Channel

-- A trivial channel for testing the typeclass machinery.
newtype TestChannel = TestChannel IncomingMessage

instance Channel TestChannel where
  toHandle (TestChannel msg) = ChannelHandle
    { _ch_receive      = pure msg
    , _ch_send         = \_ -> pure ()
    , _ch_sendError    = \_ -> pure ()
    , _ch_sendChunk    = \_ -> pure ()
    , _ch_streaming    = False
    , _ch_readSecret   = pure ""
    , _ch_prompt       = \_ -> pure ""
    , _ch_promptSecret = \_ -> pure ""
    }

spec :: Spec
spec = do
  describe "Channel typeclass" $ do
    it "toHandle produces a working ChannelHandle" $ do
      let msg = IncomingMessage (UserId "u1") "hello"
          ch  = TestChannel msg
          h   = toHandle ch
      received <- _ch_receive h
      received `shouldBe` msg

  describe "SomeChannel" $ do
    it "wraps a Channel and extracts a handle" $ do
      let msg  = IncomingMessage (UserId "u2") "world"
          some = MkChannel (TestChannel msg)
          h    = someChannelHandle some
      received <- _ch_receive h
      received `shouldBe` msg
