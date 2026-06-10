module Agent.LoopSpec (spec) where

import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Control.Exception
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.IntMap.Strict qualified as IntMap
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Session.Types qualified as SessionTypes

import PureClaw.Agent.Env
import PureClaw.Agent.Loop
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (SessionHandle (..), mkSessionHandle, mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
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
  modelRef      <- newIORef (Just (ModelId "mock"))
  harnessRef    <- newIORef Map.empty
  targetRef     <- newIORef TargetProvider
  windowIdxRef  <- newIORef 0
  sessionRef <- newIORef =<< mkNoOpSessionHandle
  mcpRef     <- newIORef Map.empty
  -- WU3 (Tabbed Chat #51) defaults
  tabsRef       <- newIORef IntMap.empty
  focusRef      <- newIORef Nothing
  activeCountTv <- newTVarIO 0
  runnersRef    <- newIORef IntMap.empty
  let routing = defaultRoutingConfig
  channelOutQ   <- newTBQueueIO (fromIntegral (_rc_channelOutQBound routing))
  harnessReg    <- Registry.newRegistry
  pure AgentEnv
    { _env_provider     = providerRef
    , _env_model        = modelRef
    , _env_channel      = ch
    , _env_logger       = mkNoOpLogHandle
    , _env_systemPrompt = Nothing
    , _env_registry     = emptyRegistry
    , _env_vault        = vaultRef
    , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
    , _env_policy       = defaultPolicy
    , _env_harnesses    = harnessRef
    , _env_harnessRegistry = harnessReg
    , _env_target       = targetRef
    , _env_nextWindowIdx = windowIdxRef
    , _env_agentDef      = Nothing
    , _env_session       = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers   = mcpRef
    , _env_tabs          = tabsRef
    , _env_focus         = focusRef
    , _env_activeCount   = activeCountTv
    , _env_runners       = runnersRef
    , _env_channelOutQ   = channelOutQ
    , _env_routingConfig = routing
    , _env_fork          = defaultEnvFork
    , _env_broker          = Nothing
    , _env_tabRegistry = error "8c.2 stub: _env_tabRegistry not exercised in this test"
    , _env_cursors = error "8c.2 stub: _env_cursors not exercised in this test"
    , _env_exec = error "8c.2 stub: _env_exec not exercised in this test"
    , _env_relayWriter = error "8c.2 stub: _env_relayWriter not exercised in this test"
    , _env_sinks = error "8c.2 stub: _env_sinks not exercised in this test"
    , _env_wizard = error "8c.2 stub: _env_wizard not exercised in this test"
    , _env_tabOutQ = error "8c.2 stub: _env_tabOutQ not exercised in this test"
    }

-- | Like 'mkTestEnv' but with a REAL foreground session rooted under the
-- given sessions directory, so a @\/bg@ background turn (which derives the
-- sessions dir from the foreground session) writes its transcript under
-- @tmp@ rather than the real @~/.pureclaw/sessions@.
mkBgTestEnv :: Provider p => FilePath -> p -> ChannelHandle -> IO AgentEnv
mkBgTestEnv sessionsDir p ch = do
  base <- mkTestEnv p ch
  now  <- getCurrentTime
  let meta = SessionTypes.SessionMeta
        { SessionTypes._sm_id    = SessionTypes.newSessionId Nothing now
        , SessionTypes._sm_agent = Nothing
        , SessionTypes._sm_kind  = SessionTypes.SkProvider
            (SessionTypes.ProviderSpec
              (SessionTypes.inferProviderId "mock") (ModelId "mock") Nothing)
        , SessionTypes._sm_model  = "mock"
        , SessionTypes._sm_channel = "cli"
        , SessionTypes._sm_createdAt = now
        , SessionTypes._sm_lastActive = now
        , SessionTypes._sm_bootstrapConsumed = False
        , SessionTypes._sm_archived = False
        , SessionTypes._sm_description = Nothing
        , SessionTypes._sm_autoSummary = Nothing
        , SessionTypes._sm_source = Nothing
        }
  sh    <- mkSessionHandle Nothing mkNoOpLogHandle sessionsDir meta
  shRef <- newIORef sh
  pure base { _env_session = shRef }

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

    it "fires _env_onFirstStreamDone exactly once across multiple turns" $ do
      -- Drive the loop with TWO user messages so completeStream is
      -- invoked twice, then assert the one-shot callback ran exactly once.
      (channel, _sentRef) <- mkMockChannel ["first", "second"]
      baseEnv <- mkTestEnv (MockProvider "reply") channel
      counter <- newIORef (0 :: Int)
      onceRef <- newIORef (Just (modifyIORef' counter (+1)))
      let env = baseEnv { _env_onFirstStreamDone = onceRef }
      runAgentLoop env
      finalCount <- readIORef counter
      finalCount `shouldBe` 1
      -- After firing, the slot is cleared so a resume cannot re-arm.
      mAfter <- readIORef onceRef
      case mAfter of
        Nothing -> pure ()
        Just _  -> expectationFailure "expected callback slot to be cleared"

    it "does not fire the callback when no StreamDone is observed (empty input)" $ do
      (channel, _sentRef) <- mkMockChannel []
      baseEnv <- mkTestEnv (MockProvider "reply") channel
      counter <- newIORef (0 :: Int)
      onceRef <- newIORef (Just (modifyIORef' counter (+1)))
      let env = baseEnv { _env_onFirstStreamDone = onceRef }
      runAgentLoop env
      finalCount <- readIORef counter
      finalCount `shouldBe` 0

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

    -- Session origin capture (WU3): set-once provenance recorded from the
    -- first inbound message, before slash/provider branching.
    it "captures _sm_source on the first inbound message" $
      withSystemTempDirectory "pc-src" $ \tmp -> do
        let src = mkMessageSource CkSignal (ConversationId "+15551234567") (Just (UserId "+15551234567")) mempty
        channel <- mkSourcedChannel [(src, "hello")]
        env <- mkSourceCaptureEnv tmp (MockProvider "reply") channel
        runAgentLoop env
        sh <- readIORef (_env_session env)
        meta <- readIORef (_sh_meta sh)
        SessionTypes._sm_source meta `shouldBe` Just src

    it "captures _sm_source even when the inbound message content is empty" $
      withSystemTempDirectory "pc-src" $ \tmp -> do
        -- An empty-content message still has a sender; origin is about the
        -- sender, not the content, so the empty-message branch must capture.
        let src = mkMessageSource CkTelegram (ConversationId "99999") (Just (UserId "99999")) mempty
        channel <- mkSourcedChannel [(src, "")]
        env <- mkSourceCaptureEnv tmp (MockProvider "reply") channel
        runAgentLoop env
        sh <- readIORef (_env_session env)
        meta <- readIORef (_sh_meta sh)
        SessionTypes._sm_source meta `shouldBe` Just src

    it "does not overwrite _sm_source when a later message has a different sender" $
      withSystemTempDirectory "pc-src" $ \tmp -> do
        let first  = mkMessageSource CkSignal (ConversationId "+15550000001") (Just (UserId "+15550000001")) mempty
            second = mkMessageSource CkTelegram (ConversationId "99999") (Just (UserId "99999")) mempty
        channel <- mkSourcedChannel [(first, "hello"), (second, "world")]
        env <- mkSourceCaptureEnv tmp (MockProvider "reply") channel
        runAgentLoop env
        sh <- readIORef (_env_session env)
        meta <- readIORef (_sh_meta sh)
        -- Set-once: the session origin stays the FIRST sender.
        SessionTypes._sm_source meta `shouldBe` Just first

    -- /bg — run a prompt in a fresh background session (issue #52)
    it "/bg runs a background turn and pushes the result to the channel" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, sentRef) <- mkMockChannel []
        env <- mkBgTestEnv tmp (MockProvider "bg result") channel
        runBackgroundTurn env "summarize the repo"
        sent <- readIORef sentRef
        sent `shouldBe` ["[bg done] bg result"]

    it "/bg records the conversation to its own session transcript (frontend-visible)" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, _sentRef) <- mkMockChannel []
        env <- mkBgTestEnv tmp (MockProvider "bg result") channel
        runBackgroundTurn env "summarize the repo"
        -- A fresh session directory with a NON-EMPTY transcript.jsonl must
        -- exist under the sessions dir (this is what the frontend scans).
        -- The foreground test session has no turns, so its transcript is
        -- empty; exactly one non-empty transcript (the /bg session) is added.
        dirs <- listDirectory tmp
        contents <- forM dirs $ \d -> do
          let f = tmp </> d </> "transcript.jsonl"
          ex <- doesFileExist f
          if ex then readFile f else pure ""
        length (filter (not . null) contents) `shouldBe` 1

    it "/bg background turn maps a blank response to (no response)" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, sentRef) <- mkMockChannel []
        env <- mkBgTestEnv tmp (MockProvider "") channel
        runBackgroundTurn env "do nothing"
        sent <- readIORef sentRef
        sent `shouldBe` ["[bg done] (no response)"]

    it "/bg background turn with no provider reports it cannot run" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, sentRef) <- mkMockChannel []
        env <- mkBgTestEnv tmp (MockProvider "ignored") channel
        writeIORef (_env_provider env) Nothing
        runBackgroundTurn env "do thing"
        sent <- readIORef sentRef
        sent `shouldBe` ["[bg] Cannot run: no provider configured."]

    it "/bg background turn surfaces provider failure without leaking details" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, sentRef) <- mkMockChannel []
        env <- mkBgTestEnv tmp FailingProvider channel
        runBackgroundTurn env "do thing"
        sent <- readIORef sentRef
        sent `shouldBe` ["[bg] Something went wrong running the background task."]

    it "/bg in the loop acknowledges in the foreground (not the dispatcher fallback)" $
      withSystemTempDirectory "pc-bg" $ \tmp -> do
        (channel, sentRef) <- mkMockChannel ["/bg do a thing"]
        env <- mkBgTestEnv tmp (MockProvider "bg result") channel
        runAgentLoop env
        sent <- readIORef sentRef
        any (T.isInfixOf "/bg: running") sent `shouldBe` True
        any (T.isInfixOf "tabbed-chat dispatcher") sent `shouldBe` False

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
                  { _im_source = mkMessageSource CkCli (ConversationId "cli") (Just (UserId "test")) mempty
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

-- | Like 'mkMockChannel' but each queued message carries its own
-- 'MessageSource', so tests can drive the loop with messages from
-- different senders (and with empty content). Throws EOF when drained.
mkSourcedChannel :: [(MessageSource, Text)] -> IO ChannelHandle
mkSourcedChannel messages = do
  msgsRef <- newIORef messages
  pure ChannelHandle
    { _ch_receive = do
        msgs <- readIORef msgsRef
        case msgs of
          [] -> throwIO (userError "EOF" :: IOError)
          ((src, m):rest) -> do
            writeIORef msgsRef rest
            pure IncomingMessage { _im_source = src, _im_content = m }
    , _ch_send         = \_ -> pure ()
    , _ch_sendError    = \_ -> pure ()
    , _ch_sendChunk    = \_ -> pure ()
    , _ch_streaming    = True
    , _ch_readSecret   = pure ""
    , _ch_prompt       = \_ -> pure ""
    , _ch_promptSecret = \_ -> pure ""
    }

-- | Build a test env backed by a REAL on-disk session handle (rooted under
-- the given sessions dir) so origin capture via 'setSourceIfAbsent' can
-- persist. Returns the env so tests can read '_sh_meta' afterward.
mkSourceCaptureEnv :: Provider p => FilePath -> p -> ChannelHandle -> IO AgentEnv
mkSourceCaptureEnv sessionsDir p ch = do
  base <- mkTestEnv p ch
  now  <- getCurrentTime
  let meta = SessionTypes.SessionMeta
        { SessionTypes._sm_id    = SessionTypes.newSessionId Nothing now
        , SessionTypes._sm_agent = Nothing
        , SessionTypes._sm_kind  = SessionTypes.SkProvider
            (SessionTypes.ProviderSpec
              (SessionTypes.inferProviderId "mock") (ModelId "mock") Nothing)
        , SessionTypes._sm_model  = "mock"
        , SessionTypes._sm_channel = "cli"
        , SessionTypes._sm_createdAt = now
        , SessionTypes._sm_lastActive = now
        , SessionTypes._sm_bootstrapConsumed = False
        , SessionTypes._sm_archived = False
        , SessionTypes._sm_description = Nothing
        , SessionTypes._sm_autoSummary = Nothing
        , SessionTypes._sm_source = Nothing
        }
  sh    <- mkSessionHandle Nothing mkNoOpLogHandle sessionsDir meta
  shRef <- newIORef sh
  pure base { _env_session = shRef }

