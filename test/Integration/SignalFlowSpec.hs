module Integration.SignalFlowSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Data.Aeson (Value (..), object, (.=))
import Data.IntMap.Strict qualified as IntMap
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Agent.Env
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Agent.Loop
import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript (TranscriptHandle (..))
import PureClaw.Providers.Class
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (mkNoOpSessionHandle, mkSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Session.Handle qualified as Session
import PureClaw.Session.Types
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
  modelRef      <- newIORef (Just (ModelId "mock"))
  harnessRef    <- newIORef Map.empty
  harnessReg     <- Registry.newRegistry
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
    , _env_harnessRegistry  = harnessReg
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

      -- Poll until we see the response (up to 5s)
      waitForResponses sentRef 1

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
      waitForResponses sentRef 1
      atomically $ writeTQueue (_sch_inbox sc) (mkEnvelope "Second" 2000)
      waitForResponses sentRef 2

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
      waitForResponses sentRef 1

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
      waitForResponses sentRef 1  -- at least 1 response

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      sent <- readIORef sentRef
      -- Should get intermediate text + final response
      length sent `shouldSatisfy` (>= 1)

    -- End-to-end dual-storage proof (WU5): a Signal DM carrying BOTH a phone
    -- number AND a uuid must land in BOTH session.json (via _sm_source /
    -- setSourceIfAbsent, set-once on first inbound) AND transcript.jsonl (via
    -- mkTranscriptProvider's per-message source metadata on the Request entry).
    -- Uses a REAL on-disk session handle (not the noOp one) and a non-streaming
    -- provider so the transcript `complete` Request path is exercised.
    it "persists a Signal DM's phone AND uuid into both session.json and transcript.jsonl" $
      withSystemTempDirectory "pureclaw-signal-flow-spec" $ \baseDir -> do
        sc <- mkTestSignalChannelForFlow
        sentRef <- newIORef ([] :: [Text])
        let handle = (toHandle sc)
              { _ch_send = \msg -> modifyIORef sentRef (<> [_om_content msg]) }

        -- A real on-disk session handle with a fresh _sm_source = Nothing.
        let sid  = "sess-srctest"
            meta = mkSrcTestMeta sid
        sh <- mkSessionHandle Nothing mkNoOpLogHandle baseDir meta

        -- Build the test env, then OVERRIDE its (noOp) session with the real one
        -- so the agent loop's transcript writes (and set-once source capture)
        -- target the on-disk session.
        baseEnv <- mkTestEnv (EchoProvider "Echo: ") handle
        writeIORef (_env_session baseEnv) sh

        agentThread <- async $ runAgentLoop baseEnv

        -- A Signal DM carrying BOTH a phone (source) and a uuid (sourceUuid).
        let envelope = SignalEnvelope
              { _se_source    = "+15551234567"
              , _se_sourceUuid = Just "uuid-abc-123"
              , _se_timestamp = Just 1000
              , _se_dataMessage = Just SignalDataMessage
                  { _sdm_message   = "Hello"
                  , _sdm_timestamp = 1000
                  }
              }
        atomically $ writeTQueue (_sch_inbox sc) envelope
        waitForResponses sentRef 1

        cancelWith agentThread (userError "EOF")
        _ <- waitCatch agentThread

        -- Flush the transcript so transcript.jsonl is on disk before reading.
        _th_flush (Session._sh_transcript sh)

        -- session.json: phone AND uuid persisted via _sm_source.
        sessionJson <- TIO.readFile (baseDir </> T.unpack sid </> "session.json")
        T.unpack sessionJson `shouldContain` "+15551234567"
        T.unpack sessionJson `shouldContain` "uuid-abc-123"
        -- Robust structural check on the in-memory meta: _sm_source carries the
        -- phone as the user id and the uuid in the fields map.
        persisted <- readIORef (Session._sh_meta sh)
        (_ms_userId =<< _sm_source persisted)
          `shouldBe` Just (UserId "+15551234567")
        case _sm_source persisted of
          Just src ->
            Map.lookup "uuid" (_ms_fields src)
              `shouldBe` Just (String "uuid-abc-123")
          Nothing -> expectationFailure "expected _sm_source to be Just"

        -- transcript.jsonl: phone AND uuid recorded on the Request entry's
        -- metadata.source (the substring check is sufficient — both only appear
        -- because mkTranscriptProvider wrote _im_source into the Request metadata).
        transcriptJsonl <- TIO.readFile (baseDir </> T.unpack sid </> "transcript.jsonl")
        T.unpack transcriptJsonl `shouldContain` "+15551234567"
        T.unpack transcriptJsonl `shouldContain` "uuid-abc-123"

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

-- | A fresh provider-backed 'SessionMeta' with @_sm_source = Nothing@, mirroring
-- the @mkMeta@ helper shape in @test/Session/HandleSpec.hs@. Used by the
-- dual-storage end-to-end test so the agent loop captures the Signal source
-- set-once into a real on-disk @session.json@.
mkSrcTestMeta :: Text -> SessionMeta
mkSrcTestMeta sid = SessionMeta
  { _sm_id                = parseSessionId sid
  , _sm_agent             = Nothing
  , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "mock") (ModelId "mock") Nothing)
  , _sm_model             = "mock"
  , _sm_channel           = "signal"
  , _sm_createdAt         = srcTestEpoch
  , _sm_lastActive        = srcTestEpoch
  , _sm_bootstrapConsumed = False
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  , _sm_source            = Nothing
  }

-- | Fixed timestamp for 'mkSrcTestMeta' (2025-01-01T00:00:00Z).
srcTestEpoch :: UTCTime
srcTestEpoch = UTCTime (fromGregorian 2025 1 1) (secondsToDiffTime 0)

-- | Create a test SignalChannel with mock transport.
mkTestSignalChannelForFlow :: IO SignalChannel
mkTestSignalChannelForFlow = do
  inQ  <- newTQueueIO
  outQ <- newTQueueIO
  let transport = mkMockSignalTransport inQ outQ
      config = SignalConfig { _sc_account = "+1234567890", _sc_textChunkLimit = 6000, _sc_allowFrom = AllowAll }
  mkSignalChannel config transport mkNoOpLogHandle

-- | Poll an IORef until it contains at least @n@ items, with a 5-second timeout.
-- Fails the test if the timeout is reached.
waitForResponses :: IORef [a] -> Int -> IO ()
waitForResponses ref n = do
  result <- timeout 5000000 go  -- 5 seconds
  case result of
    Just () -> pure ()
    Nothing -> expectationFailure $
      "Timed out waiting for " <> show n <> " response(s)"
  where
    go = do
      xs <- readIORef ref
      if length xs >= n
        then pure ()
        else threadDelay 10000 >> go  -- check every 10ms
