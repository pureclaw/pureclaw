module Agent.LoopSpec (spec) where

import Control.Exception
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Env
import PureClaw.Agent.Loop
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | A mock provider that returns a fixed text response.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider response) _ = pure CompletionResponse
    { _crsp_content = [TextBlock response]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

-- | A mock provider that always fails.
data FailingProvider = FailingProvider

instance Provider FailingProvider where
  complete FailingProvider _ = throwIO (userError "provider failure")

-- | A mock provider that streams text chunks.
newtype StreamingProvider = StreamingProvider [Text]

instance Provider StreamingProvider where
  complete (StreamingProvider chunks) _ = pure CompletionResponse
    { _crsp_content = [TextBlock (mconcat chunks)]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }
  completeStream (StreamingProvider chunks) _ callback = do
    mapM_ (callback . StreamText) chunks
    callback $ StreamDone CompletionResponse
      { _crsp_content = [TextBlock (mconcat chunks)]
      , _crsp_model   = ModelId "mock"
      , _crsp_usage   = Nothing
      }

-- | A mock provider that returns a tool use block, then text on the follow-up.
data ToolCallProvider = ToolCallProvider

instance Provider ToolCallProvider where
  complete ToolCallProvider req =
    -- If the messages contain a tool result, return text. Otherwise, return a tool call.
    let hasToolResult = any (any hasResult . _msg_content) (_cr_messages req)
    in if hasToolResult
      then pure CompletionResponse
        { _crsp_content = [TextBlock "Done!"]
        , _crsp_model   = ModelId "mock"
        , _crsp_usage   = Nothing
        }
      else pure CompletionResponse
        { _crsp_content =
            [ TextBlock "Let me check."
            , ToolUseBlock (ToolCallId "call_1") "test_tool" (object ["key" .= ("value" :: Text)])
            ]
        , _crsp_model   = ModelId "mock"
        , _crsp_usage   = Nothing
        }
    where
      hasResult (ToolResultBlock {}) = True
      hasResult _ = False

-- | Build a test AgentEnv from a provider and channel.
mkTestEnv :: Provider p => p -> ChannelHandle -> AgentEnv
mkTestEnv p ch = AgentEnv
  { _env_provider     = MkProvider p
  , _env_model        = ModelId "mock"
  , _env_channel      = ch
  , _env_logger       = mkNoOpLogHandle
  , _env_systemPrompt = Nothing
  , _env_registry     = emptyRegistry
  }

spec :: Spec
spec = do
  describe "runAgentLoop" $ do
    it "processes a message and sends response" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      runAgentLoop (mkTestEnv (MockProvider "Hi there!") channel)
      sent <- readIORef sentRef
      sent `shouldBe` ["Hi there!"]

    it "processes multiple messages" $ do
      (channel, sentRef) <- mkMockChannel ["first", "second"]
      runAgentLoop (mkTestEnv (MockProvider "reply") channel)
      sent <- readIORef sentRef
      length sent `shouldBe` 2

    it "skips empty messages" $ do
      (channel, sentRef) <- mkMockChannel ["", "  ", "hello"]
      runAgentLoop (mkTestEnv (MockProvider "reply") channel)
      sent <- readIORef sentRef
      length sent `shouldBe` 1

    it "handles provider errors gracefully" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      errRef <- newIORef ([] :: [PublicError])
      let channel' = channel { _ch_sendError = \e -> modifyIORef errRef (e :) }
          env = (mkTestEnv FailingProvider channel) { _env_channel = channel' }
      runAgentLoop env
      sent <- readIORef sentRef
      sent `shouldBe` []
      errs <- readIORef errRef
      length errs `shouldBe` 1

    it "handles slash commands without calling provider" $ do
      (channel, sentRef) <- mkMockChannel ["/status", "hello"]
      runAgentLoop (mkTestEnv (MockProvider "reply") channel)
      sent <- readIORef sentRef
      -- First message is /status output, second is provider reply
      length sent `shouldBe` 2
      -- The /status response should contain session info
      case sent of
        (statusMsg:replyMsg:_) -> do
          T.unpack statusMsg `shouldContain` "Messages"
          replyMsg `shouldBe` "reply"
        _ -> expectationFailure "expected two messages"

    it "/new clears context (provider sees fresh context)" $ do
      (channel, sentRef) <- mkMockChannel ["first message", "/new", "after reset"]
      runAgentLoop (mkTestEnv (MockProvider "reply") channel)
      sent <- readIORef sentRef
      -- Should have: reply to "first message", /new confirmation, reply to "after reset"
      length sent `shouldBe` 3

    it "streams text chunks to the channel" $ do
      chunksRef <- newIORef ([] :: [StreamChunk])
      (channel, _sentRef) <- mkMockChannel ["hello"]
      let channel' = channel { _ch_sendChunk = \c -> modifyIORef chunksRef (<> [c]) }
          env = (mkTestEnv (StreamingProvider ["He", "llo!"]) channel) { _env_channel = channel' }
      runAgentLoop env
      chunks <- readIORef chunksRef
      -- Should get text chunks plus ChunkDone
      length chunks `shouldSatisfy` (>= 2)
      last chunks `shouldBe` ChunkDone

    it "executes tool calls and sends final text" $ do
      (channel, sentRef) <- mkMockChannel ["do something"]
      let testHandler = ToolHandler $ \_ -> pure ("tool output", False)
          testDef = ToolDefinition "test_tool" "A test tool" (object [])
          registry = registerTool testDef testHandler emptyRegistry
          env = (mkTestEnv ToolCallProvider channel) { _env_registry = registry }
      runAgentLoop env
      sent <- readIORef sentRef
      -- Should get "Let me check." from first response, then "Done!" after tool execution
      sent `shouldBe` ["Let me check.", "Done!"]

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
        , _ch_sendChunk = \_ -> pure ()
        }
  pure (channel, sentRef)
