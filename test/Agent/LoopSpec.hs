module Agent.LoopSpec (spec) where

import Control.Exception
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import PureClaw.Agent.Loop
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class

-- | A mock provider that returns a fixed response.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider response) _ = pure CompletionResponse
    { _crsp_content = response
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

-- | A mock provider that always fails.
data FailingProvider = FailingProvider

instance Provider FailingProvider where
  complete FailingProvider _ = throwIO (userError "provider failure")

spec :: Spec
spec = do
  describe "runAgentLoop" $ do
    it "processes a message and sends response" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      runAgentLoop (MockProvider "Hi there!") (ModelId "mock") channel mkNoOpLogHandle Nothing
      sent <- readIORef sentRef
      sent `shouldBe` ["Hi there!"]

    it "processes multiple messages" $ do
      (channel, sentRef) <- mkMockChannel ["first", "second"]
      runAgentLoop (MockProvider "reply") (ModelId "mock") channel mkNoOpLogHandle Nothing
      sent <- readIORef sentRef
      length sent `shouldBe` 2

    it "skips empty messages" $ do
      (channel, sentRef) <- mkMockChannel ["", "  ", "hello"]
      runAgentLoop (MockProvider "reply") (ModelId "mock") channel mkNoOpLogHandle Nothing
      sent <- readIORef sentRef
      length sent `shouldBe` 1

    it "handles provider errors gracefully" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      errRef <- newIORef ([] :: [PublicError])
      let channel' = channel { _ch_sendError = \e -> modifyIORef errRef (e :) }
      runAgentLoop FailingProvider (ModelId "mock") channel' mkNoOpLogHandle Nothing
      sent <- readIORef sentRef
      sent `shouldBe` []
      errs <- readIORef errRef
      length errs `shouldBe` 1

-- | Create a mock channel that serves messages from a list, then
-- throws IOError (simulating EOF). Captures sent messages in an IORef.
mkMockChannel :: [Text] -> IO (ChannelHandle, IORef [Text])
mkMockChannel messages = do
  msgsRef <- newIORef messages
  sentRef <- newIORef ([] :: [Text])
  let channel = ChannelHandle
        { _ch_receive = do
            msgs <- readIORef msgsRef
            case msgs of
              [] -> throwIO (userError "EOF" :: IOError)
              (m:rest) -> do
                writeIORef msgsRef rest
                pure IncomingMessage
                  { _im_userId = UserId "test"
                  , _im_content = m
                  }
        , _ch_send = \msg ->
            modifyIORef sentRef (<> [_om_content msg])
        , _ch_sendError = \_ -> pure ()
        }
  pure (channel, sentRef)
