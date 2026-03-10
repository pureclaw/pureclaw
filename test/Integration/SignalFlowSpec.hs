module Integration.SignalFlowSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Loop
import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Mock provider that echoes user messages with a prefix.
newtype EchoProvider = EchoProvider Text

instance Provider EchoProvider where
  complete (EchoProvider prefix) req =
    let userText = T.intercalate " " [t | msg <- _cr_messages req
                                         , _msg_role msg == User
                                         , TextBlock t <- _msg_content msg]
    in pure CompletionResponse
      { _crsp_content = [TextBlock (prefix <> userText)]
      , _crsp_model   = ModelId "mock"
      , _crsp_usage   = Just (Usage 10 5)
      }

spec :: Spec
spec = do
  describe "Signal end-to-end flow" $ do
    it "receives a Signal message, processes via agent, and produces a response" $ do
      -- Set up Signal channel
      sc <- mkSignalChannel (SignalConfig "+1234567890") mkNoOpLogHandle
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      -- Run agent loop in a separate thread
      agentThread <- async $
        runAgentLoop (EchoProvider "Echo: ") (ModelId "mock") handle mkNoOpLogHandle
          (Just "You are a test agent.") emptyRegistry

      -- Push a Signal envelope into the inbox
      let envelope = SignalEnvelope
            { _se_source    = "+9876543210"
            , _se_timestamp = 1000
            , _se_dataMessage = Just SignalDataMessage
                { _sdm_message = "Hello from Signal!"
                , _sdm_timestamp = 1000
                }
            }
      atomically $ writeTQueue (_sch_inbox sc) envelope

      -- Wait a bit for processing
      threadDelay 50000  -- 50ms

      -- Push EOF to terminate the loop
      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      sent <- readIORef sentRef
      length sent `shouldBe` 1
      case sent of
        (first:_) -> do
          T.unpack first `shouldContain` "Echo:"
          T.unpack first `shouldContain` "Hello from Signal!"
        _ -> expectationFailure "expected at least one message"

    it "handles multiple Signal messages in sequence" $ do
      sc <- mkSignalChannel (SignalConfig "+1234567890") mkNoOpLogHandle
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      agentThread <- async $
        runAgentLoop (EchoProvider "Re: ") (ModelId "mock") handle mkNoOpLogHandle Nothing emptyRegistry

      -- Push two messages
      let mkEnvelope txt ts = SignalEnvelope
            { _se_source = "+111"
            , _se_timestamp = ts
            , _se_dataMessage = Just SignalDataMessage { _sdm_message = txt, _sdm_timestamp = ts }
            }
      atomically $ writeTQueue (_sch_inbox sc) (mkEnvelope "First" 1000)
      threadDelay 50000
      atomically $ writeTQueue (_sch_inbox sc) (mkEnvelope "Second" 2000)
      threadDelay 50000

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      sent <- readIORef sentRef
      length sent `shouldBe` 2

    it "uses slash commands through Signal" $ do
      sc <- mkSignalChannel (SignalConfig "+1234567890") mkNoOpLogHandle
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      agentThread <- async $
        runAgentLoop (EchoProvider "Echo: ") (ModelId "mock") handle mkNoOpLogHandle Nothing emptyRegistry

      -- Send /status slash command
      let statusEnvelope = SignalEnvelope
            { _se_source = "+111"
            , _se_timestamp = 1000
            , _se_dataMessage = Just SignalDataMessage { _sdm_message = "/status", _sdm_timestamp = 1000 }
            }
      atomically $ writeTQueue (_sch_inbox sc) statusEnvelope
      threadDelay 50000

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      sent <- readIORef sentRef
      length sent `shouldBe` 1
      case sent of
        (first:_) -> T.unpack first `shouldContain` "Messages"
        _ -> expectationFailure "expected at least one message"

    it "executes tool calls end-to-end" $ do
      sc <- mkSignalChannel (SignalConfig "+1234567890") mkNoOpLogHandle
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      -- Register a test tool
      let testHandler = ToolHandler $ \_ -> pure ("tool result", False)
          testDef = ToolDefinition "test_tool" "A test tool" (object [])
          registry = registerTool testDef testHandler emptyRegistry

      agentThread <- async $
        runAgentLoop ToolCallThenTextProvider (ModelId "mock") handle mkNoOpLogHandle Nothing registry

      let envelope = SignalEnvelope
            { _se_source = "+111"
            , _se_timestamp = 1000
            , _se_dataMessage = Just SignalDataMessage { _sdm_message = "do it", _sdm_timestamp = 1000 }
            }
      atomically $ writeTQueue (_sch_inbox sc) envelope
      threadDelay 100000  -- 100ms for tool call round-trip

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      sent <- readIORef sentRef
      -- Should get intermediate text + final response
      length sent `shouldSatisfy` (>= 1)

-- | A mock provider that returns a tool call on first request, then text.
data ToolCallThenTextProvider = ToolCallThenTextProvider

instance Provider ToolCallThenTextProvider where
  complete ToolCallThenTextProvider req =
    let hasToolResult = any (any isResult . _msg_content) (_cr_messages req)
    in if hasToolResult
      then pure CompletionResponse
        { _crsp_content = [TextBlock "Done with tool."]
        , _crsp_model   = ModelId "mock"
        , _crsp_usage   = Nothing
        }
      else pure CompletionResponse
        { _crsp_content =
            [ TextBlock "Using tool..."
            , ToolUseBlock (ToolCallId "call_1") "test_tool" (object ["key" .= ("val" :: Text)])
            ]
        , _crsp_model   = ModelId "mock"
        , _crsp_usage   = Nothing
        }
    where
      isResult (ToolResultBlock {}) = True
      isResult _ = False
