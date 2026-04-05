module Integration.SignalFlowSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Env
import PureClaw.Agent.Loop
import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Tools.Registry

import Data.Map.Strict qualified as Map

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

-- | Build a test AgentEnv from a provider and channel.
mkTestEnv :: Provider p => p -> ChannelHandle -> IO AgentEnv
mkTestEnv p ch = do
  vaultRef      <- newIORef Nothing
  providerRef   <- newIORef (Just (MkProvider p))
  modelRef      <- newIORef (ModelId "mock")
  transcriptRef <- newIORef Nothing
  harnessRef    <- newIORef Map.empty
  pure AgentEnv
    { _env_provider     = providerRef
    , _env_model        = modelRef
    , _env_channel      = ch
    , _env_logger       = mkNoOpLogHandle
    , _env_systemPrompt = Nothing
    , _env_registry     = emptyRegistry
    , _env_vault        = vaultRef
    , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
    , _env_transcript   = transcriptRef
    , _env_policy       = defaultPolicy
    , _env_harnesses    = harnessRef
    }

spec :: Spec
spec = do
  describe "Signal end-to-end flow" $ do
    it "receives a Signal message, processes via agent, and produces a response" $ do
      -- Set up Signal channel
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }
      baseEnv <- mkTestEnv (EchoProvider "Echo: ") handle
      let env = baseEnv { _env_systemPrompt = Just "You are a test agent." }

      -- Run agent loop in a separate thread
      agentThread <- async $ runAgentLoop env

      -- Push a Signal envelope into the inbox
      let envelope = SignalEnvelope
            { _se_sourceUuid = Nothing
            , _se_source    = "+9876543210"
            , _se_timestamp = Just 1000
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
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      env2 <- mkTestEnv (EchoProvider "Re: ") handle
      agentThread <- async $ runAgentLoop env2

      -- Push two messages
      let mkEnvelope txt ts = SignalEnvelope
            { _se_source = "+111"
            , _se_sourceUuid = Nothing
            , _se_timestamp = Just ts
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
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      env3 <- mkTestEnv (EchoProvider "Echo: ") handle
      agentThread <- async $ runAgentLoop env3

      -- Send /status slash command
      let statusEnvelope = SignalEnvelope
            { _se_source = "+111"
            , _se_sourceUuid = Nothing
            , _se_timestamp = Just 1000
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
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = (toHandle sc)
            { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

      -- Register a test tool
      let testHandler = ToolHandler $ \_ -> pure ("tool result", False)
          testDef = ToolDefinition "test_tool" "A test tool" (object [])
          registry = registerTool testDef testHandler emptyRegistry
      baseEnv4 <- mkTestEnv ToolCallThenTextProvider handle
      let env = baseEnv4 { _env_registry = registry }

      agentThread <- async $ runAgentLoop env

      let envelope = SignalEnvelope
            { _se_source = "+111"
            , _se_sourceUuid = Nothing
            , _se_timestamp = Just 1000
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

-- | Create a test SignalChannel with mock transport.
mkTestSignalChannelForFlow :: IO SignalChannel
mkTestSignalChannelForFlow = do
  inQ  <- newTQueueIO
  outQ <- newTQueueIO
  let transport = mkMockSignalTransport inQ outQ
      config = SignalConfig { _sc_account = "+1234567890", _sc_textChunkLimit = 6000, _sc_allowFrom = AllowAll }
  mkSignalChannel config transport mkNoOpLogHandle
