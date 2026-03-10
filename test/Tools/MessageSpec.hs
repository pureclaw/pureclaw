module Tools.MessageSpec (spec) where

import Data.Aeson
import Data.IORef
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Tools.Message
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "messageTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = messageTool mkNoOpChannelHandle
      _td_name def' `shouldBe` "message"

    it "sends a message through the channel" $ do
      sentRef <- newIORef (Nothing :: Maybe OutgoingMessage)
      let ch = mkNoOpChannelHandle
            { _ch_send = writeIORef sentRef . Just
            }
          (_, handler) = messageTool ch
          input = object ["content" .= ("Hello from cron!" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "sent"
      sent <- readIORef sentRef
      sent `shouldBe` Just (OutgoingMessage "Hello from cron!")

    it "rejects empty messages" $ do
      let (_, handler) = messageTool mkNoOpChannelHandle
          input = object ["content" .= ("" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Empty"

    it "rejects whitespace-only messages" $ do
      let (_, handler) = messageTool mkNoOpChannelHandle
          input = object ["content" .= ("   \n  " :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "handles channel send errors" $ do
      let ch = mkNoOpChannelHandle
            { _ch_send = \_ -> error "Channel disconnected"
            }
          (_, handler) = messageTool ch
          input = object ["content" .= ("test" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "disconnected"

    it "rejects invalid JSON input" $ do
      let (_, handler) = messageTool mkNoOpChannelHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "sends multi-line messages" $ do
      sentRef <- newIORef (Nothing :: Maybe OutgoingMessage)
      let ch = mkNoOpChannelHandle
            { _ch_send = writeIORef sentRef . Just
            }
          (_, handler) = messageTool ch
          input = object ["content" .= ("Line 1\nLine 2\nLine 3" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` False
      sent <- readIORef sentRef
      case sent of
        Just (OutgoingMessage content) -> do
          T.unpack content `shouldContain` "Line 1"
          T.unpack content `shouldContain` "Line 3"
        Nothing -> expectationFailure "Expected message to be sent"
