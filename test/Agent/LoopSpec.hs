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
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (mkNoOpSessionHandle)
import PureClaw.Tools.Registry

import Data.Map.Strict qualified as Map

-- | A mock provider that returns a fixed text response.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider response) _ = pure CompletionResponse
    { _crsp_content = [TextBlock response]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

-- | A mock provider that records how many times it was called.
data CountingProvider = CountingProvider Text (IORef Int)

instance Provider CountingProvider where
  complete (CountingProvider response callRef) _ = do
    modifyIORef callRef (+1)
    pure CompletionResponse
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
mkTestEnv :: Provider p => p -> ChannelHandle -> IO AgentEnv
mkTestEnv p ch = do
  vaultRef      <- newIORef Nothing
  providerRef   <- newIORef (Just (MkProvider p))
  modelRef      <- newIORef (ModelId "mock")
  transcriptRef <- newIORef Nothing
  harnessRef    <- newIORef Map.empty
  targetRef     <- newIORef TargetProvider
  windowIdxRef  <- newIORef 0
  sessionHandle <- mkNoOpSessionHandle
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
    , _env_target       = targetRef
    , _env_nextWindowIdx = windowIdxRef
    , _env_agentDef      = Nothing
    , _env_session       = sessionHandle
    }

spec :: Spec
spec = do
  describe "runAgentLoop" $ do
    it "processes a message and sends response with model prefix" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      env <- mkTestEnv (MockProvider "Hi there!") channel
      runAgentLoop env
      sent <- readIORef sentRef
      sent `shouldBe` ["mock> Hi there!"]

    it "processes multiple messages" $ do
      (channel, sentRef) <- mkMockChannel ["first", "second"]
      env <- mkTestEnv (MockProvider "reply") channel
      runAgentLoop env
      sent <- readIORef sentRef
      length sent `shouldBe` 2

    it "skips empty messages" $ do
      (channel, sentRef) <- mkMockChannel ["", "  ", "hello"]
      env <- mkTestEnv (MockProvider "reply") channel
      runAgentLoop env
      sent <- readIORef sentRef
      length sent `shouldBe` 1

    it "handles provider errors gracefully" $ do
      (channel, sentRef) <- mkMockChannel ["hello"]
      errRef <- newIORef ([] :: [PublicError])
      let channel' = channel { _ch_sendError = \e -> modifyIORef errRef (e :) }
      baseEnv <- mkTestEnv FailingProvider channel
      let env = baseEnv { _env_channel = channel' }
      runAgentLoop env
      sent <- readIORef sentRef
      sent `shouldBe` []
      errs <- readIORef errRef
      length errs `shouldBe` 1

    it "handles slash commands without calling provider" $ do
      (channel, sentRef) <- mkMockChannel ["/status", "hello"]
      env <- mkTestEnv (MockProvider "reply") channel
      runAgentLoop env
      sent <- readIORef sentRef
      -- First message is /status output, second is provider reply (with model prefix)
      length sent `shouldBe` 2
      -- The /status response should contain session info
      case sent of
        (statusMsg:replyMsg:_) -> do
          T.unpack statusMsg `shouldContain` "Messages"
          replyMsg `shouldBe` "mock> reply"
        _ -> expectationFailure "expected two messages"

    -- Invariant: slash-prefixed messages NEVER reach the provider
    it "unknown slash command never calls provider" $ do
      callRef <- newIORef (0 :: Int)
      (channel, sentRef) <- mkMockChannel ["/unknown-command", "hello"]
      env <- mkTestEnv (CountingProvider "reply" callRef) channel
      runAgentLoop env
      calls <- readIORef callRef
      sent <- readIORef sentRef
      -- Provider called exactly once (for "hello"), not for the slash command
      calls `shouldBe` 1
      -- Unknown slash command gets an error response, "hello" gets a reply
      length sent `shouldBe` 2
      case sent of
        (first:_) -> T.unpack first `shouldContain` "Unknown command"
        []        -> expectationFailure "expected messages"

    it "unrecognized slash command does not add to context" $ do
      (channel, _sentRef) <- mkMockChannel ["/nosuchcommand", "/also-unknown"]
      callRef <- newIORef (0 :: Int)
      env <- mkTestEnv (CountingProvider "reply" callRef) channel
      runAgentLoop env
      calls <- readIORef callRef
      -- Provider never called — both messages were slash commands
      calls `shouldBe` 0

    it "/new clears context (provider sees fresh context)" $ do
      (channel, sentRef) <- mkMockChannel ["first message", "/new", "after reset"]
      env <- mkTestEnv (MockProvider "reply") channel
      runAgentLoop env
      sent <- readIORef sentRef
      -- Should have: reply to "first message", /new confirmation, reply to "after reset"
      length sent `shouldBe` 3

    it "streams text chunks to the channel with model prefix" $ do
      chunksRef <- newIORef ([] :: [StreamChunk])
      (channel, _sentRef) <- mkMockChannel ["hello"]
      let channel' = channel { _ch_sendChunk = \c -> modifyIORef chunksRef (<> [c]) }
      baseEnv <- mkTestEnv (StreamingProvider ["He", "llo!"]) channel
      let env = baseEnv { _env_channel = channel' }
      runAgentLoop env
      chunks <- readIORef chunksRef
      -- Should get: model prefix chunk, text chunks, ChunkDone
      length chunks `shouldSatisfy` (>= 3)
      case chunks of
        (ChunkText prefix : _) -> T.unpack prefix `shouldContain` "mock> "
        _ -> expectationFailure "expected prefix chunk first"
      last chunks `shouldBe` ChunkDone

    it "executes tool calls and sends final text with model prefix" $ do
      (channel, sentRef) <- mkMockChannel ["do something"]
      let testHandler = ToolHandler $ \_ -> pure ("tool output", False)
          testDef = ToolDefinition "test_tool" "A test tool" (object [])
          registry = registerTool testDef testHandler emptyRegistry
      baseEnv <- mkTestEnv ToolCallProvider channel
      let env = baseEnv { _env_registry = registry }
      runAgentLoop env
      sent <- readIORef sentRef
      -- Should get prefixed "Let me check." then prefixed "Done!" after tool execution
      sent `shouldBe` ["mock> Let me check.", "mock> Done!"]

    it "prefixes harness output IRC-style when target is a harness" $ do
      (channel, sentRef) <- mkMockChannel ["hello harness"]
      let mockHarness = HarnessHandle
            { _hh_send = \_ -> pure ()
            , _hh_receive = pure "response line"
            , _hh_name = "Claude Code"
            , _hh_session = "pureclaw"
            , _hh_status = pure HarnessRunning
            , _hh_stop = pure ()
            }
      baseEnv <- mkTestEnv (MockProvider "unused") channel
      harnessRef <- newIORef (Map.singleton "cc-0" mockHarness)
      targetRef <- newIORef (TargetHarness "cc-0")
      let env = baseEnv
            { _env_harnesses = harnessRef
            , _env_target = targetRef
            }
      runAgentLoop env
      sent <- readIORef sentRef
      sent `shouldBe` ["cc-0> response line"]

    it "/msg routes to specific harness with IRC prefix" $ do
      (channel, sentRef) <- mkMockChannel ["/msg cc-0 test message"]
      let mockHarness = HarnessHandle
            { _hh_send = \_ -> pure ()
            , _hh_receive = pure "harness reply"
            , _hh_name = "Claude Code"
            , _hh_session = "pureclaw"
            , _hh_status = pure HarnessRunning
            , _hh_stop = pure ()
            }
      baseEnv <- mkTestEnv (MockProvider "unused") channel
      harnessRef <- newIORef (Map.singleton "cc-0" mockHarness)
      let env = baseEnv { _env_harnesses = harnessRef }
      runAgentLoop env
      sent <- readIORef sentRef
      sent `shouldBe` ["cc-0> harness reply"]

  describe "sanitizeHarnessOutput" $ do
    it "passes through plain text unchanged" $
      sanitizeHarnessOutput "hello world" `shouldBe` "hello world"

    it "preserves newlines and tabs" $
      sanitizeHarnessOutput "line1\n\tline2\n" `shouldBe` "line1\n\tline2"

    it "strips CSI (SGR color) sequences" $
      sanitizeHarnessOutput "\ESC[32mgreen\ESC[0m" `shouldBe` "green"

    it "strips CSI sequences with parameters" $
      sanitizeHarnessOutput "\ESC[1;31mbold red\ESC[0m" `shouldBe` "bold red"

    it "strips OSC sequences terminated by BEL" $
      sanitizeHarnessOutput "\ESC]0;window title\BELtext" `shouldBe` "text"

    it "strips OSC sequences terminated by ST" $
      sanitizeHarnessOutput "\ESC]0;title\ESC\\text" `shouldBe` "text"

    it "strips DCS sequences" $
      sanitizeHarnessOutput "\ESCP+q\ESC\\text" `shouldBe` "text"

    it "strips cursor movement sequences" $
      sanitizeHarnessOutput "\ESC[2Jhello\ESC[H" `shouldBe` "hello"

    it "removes C0 control characters except newline and tab" $
      sanitizeHarnessOutput ("a\x01\x02\x07\x08\x0C" <> "b") `shouldBe` "ab"

    it "normalizes \\r\\n to \\n" $
      sanitizeHarnessOutput "line1\r\nline2\r\n" `shouldBe` "line1\nline2"

    it "normalizes bare \\r to \\n" $
      sanitizeHarnessOutput "old\rnew" `shouldBe` "old\nnew"

    it "strips charset designator sequences" $
      sanitizeHarnessOutput "\ESC(Btext" `shouldBe` "text"

    it "handles empty input" $
      sanitizeHarnessOutput "" `shouldBe` ""

    it "handles input that is only escape sequences" $
      sanitizeHarnessOutput "\ESC[31m\ESC[0m" `shouldBe` ""

    it "removes DEL (0x7F)" $
      sanitizeHarnessOutput ("ab\x7F" <> "cd") `shouldBe` "abcd"

    -- Trailing blank lines from tmux capture
    it "strips trailing blank lines from capture output" $
      sanitizeHarnessOutput "hello\nworld\n\n\n\n\n\n"
        `shouldBe` "hello\nworld"

    it "strips trailing whitespace-only lines" $
      sanitizeHarnessOutput "content\n   \n  \n\n"
        `shouldBe` "content"

    it "preserves internal blank lines" $
      sanitizeHarnessOutput "para1\n\npara2\n\n\n"
        `shouldBe` "para1\n\npara2"

    it "handles output that is entirely blank lines" $
      sanitizeHarnessOutput "\n\n\n\n"
        `shouldBe` ""

    it "strips leading blank lines" $
      sanitizeHarnessOutput "\n\n\nhello\nworld"
        `shouldBe` "hello\nworld"

    -- Real Claude Code TUI output patterns
    it "strips box-drawing block characters from Claude Code header" $
      -- U+2590 RIGHT HALF BLOCK, U+259B UPPER LEFT AND LOWER RIGHT, etc.
      sanitizeHarnessOutput " \x2590\x259B\x2588\x2588\x2588\x259C\x258C   Claude Code v2.1.75"
        `shouldBe` "    Claude Code v2.1.75"

    it "strips Private Use Area characters (Powerline symbols)" $
      -- U+E0A0 = Powerline git branch symbol
      sanitizeHarnessOutput ("on \xE0A0 main" <> " [$!?]")
        `shouldBe` "on  main [$!?]"

    it "strips line-drawing horizontal bar characters" $
      -- U+2500 BOX DRAWINGS LIGHT HORIZONTAL repeated as a divider
      let divider = T.replicate 40 "\x2500"
      in sanitizeHarnessOutput ("text\n" <> divider <> "\nmore")
        `shouldBe` "text\n\nmore"

    it "strips mixed block elements and keeps ASCII content" $
      -- Simulated Claude Code status line
      sanitizeHarnessOutput "\x259D\x259C\x2588\x2588\x2588\x2588\x2588\x259B\x2598  Opus 4.6"
        `shouldBe` "  Opus 4.6"

    it "preserves standard Latin, punctuation, and common symbols" $
      sanitizeHarnessOutput "Hello, world! Cost: $4.50 \x2014 done."
        `shouldBe` "Hello, world! Cost: $4.50 \x2014 done."

    it "preserves accented and non-Latin text" $
      sanitizeHarnessOutput "caf\xe9 na\xEFve \x00FC" <> "ber"
        `shouldBe` "caf\xe9 na\xEFve \x00FC" <> "ber"

    it "strips full-width block fill (U+2500-U+257F, U+2580-U+259F)" $
      -- A line of block fill characters that Claude Code uses as dividers
      let blockFill = T.replicate 10 "\x2580"
      in sanitizeHarnessOutput ("above\n" <> blockFill <> "\nbelow")
        `shouldBe` "above\n\nbelow"

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
        , _ch_sendError    = \_ -> pure ()
        , _ch_sendChunk    = \_ -> pure ()
        , _ch_streaming    = True
        , _ch_readSecret   = pure ""
        , _ch_prompt       = \_ -> pure ""
        , _ch_promptSecret = \_ -> pure ""
        }
  pure (channel, sentRef)

