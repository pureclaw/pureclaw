module Integration.SignalFlowSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Data.Aeson (object, (.=))
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
import PureClaw.Channels.Class
import PureClaw.Channels.Signal
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (mkNoOpSessionHandle, mkSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Session.Types
import PureClaw.Tabs.Wiring (runTabbedLoop)
import PureClaw.Tools.Registry
import System.Directory (listDirectory)

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
  let routing = defaultRoutingConfig
  -- Tabs-as-View (#79) subsystem: populate the seven tab fields so the
  -- tabbed entry point (runTabbedLoop) can be exercised. All Signal end-to-end
  -- tests now drive runTabbedLoop and rely on these fields.
  ts <- newTabSubsystem (_rc_channelOutQBound routing)
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
    , _env_routingConfig = routing
    , _env_fork          = defaultEnvFork
    , _env_broker          = Nothing
    , _env_tabRegistry = _ts_tabRegistry ts
    , _env_cursors     = _ts_cursors ts
    , _env_exec        = _ts_exec ts
    , _env_relayWriter = _ts_relayWriter ts
    , _env_sinks       = _ts_sinks ts
    , _env_wizard      = _ts_wizard ts
    , _env_tabOutQ     = _ts_tabOutQ ts
    , _env_onTabsChanged = pure ()
    , _env_startHarness  = noStartHarness
    , _env_runTabCommand = noRunTabCommand
    }

spec :: Spec
spec = do
  describe "Signal end-to-end flow" $ do
    it "receives a Signal message, processes via agent, and produces a response" $ do
      -- Set up Signal channel
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = mkRecordingHandle sc sentRef
      baseEnv <- mkTestEnv (EchoProvider "Echo: ") handle
      let env = baseEnv { _env_systemPrompt = Just "You are a test agent." }

      -- Run the tabbed loop in a separate thread.
      store <- newIORef Map.empty
      agentThread <- async $ runTabbedLoop env store

      -- On the tabbed path a plain DM only reaches the provider once the
      -- conversation has an active tab, so mint one with /nt first and wait for
      -- its confirmation banner.
      atomically $ writeTQueue (_sch_inbox sc) (mkNtEnvelope "+9876543210")
      waitForResponses sentRef 1

      -- Now the real message.
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

      -- Wait for the echo (the SECOND recorded output; the first was the banner).
      waitForResponses sentRef 2

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      -- Provider text now arrives chunked via the relay; assert on combined
      -- content rather than an exact message count.
      out <- allOutput sentRef
      T.unpack out `shouldContain` "Echo:"
      T.unpack out `shouldContain` "Hello from Signal!"

    it "handles multiple Signal messages in sequence" $ do
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = mkRecordingHandle sc sentRef

      env2 <- mkTestEnv (EchoProvider "Re: ") handle
      store <- newIORef Map.empty
      agentThread <- async $ runTabbedLoop env2 store

      -- Establish an active tab first (then wait for its banner).
      atomically $ writeTQueue (_sch_inbox sc) (mkNtEnvelope "+111")
      waitForResponses sentRef 1

      -- Push two messages; each provider reply streams in as chunks.
      let mkEnvelope txt ts = SignalEnvelope
            { _se_source = "+111"
            , _se_sourceUuid = Nothing
            , _se_timestamp = Just ts
            , _se_dataMessage = Just SignalDataMessage { _sdm_message = txt, _sdm_timestamp = ts }
            }
      atomically $ writeTQueue (_sch_inbox sc) (mkEnvelope "First" 1000)
      waitForResponses sentRef 2
      atomically $ writeTQueue (_sch_inbox sc) (mkEnvelope "Second" 2000)
      waitForResponses sentRef 3

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      -- Both echoed user texts must appear in the combined output.
      out <- allOutput sentRef
      T.unpack out `shouldContain` "First"
      T.unpack out `shouldContain` "Second"

    it "uses slash commands through Signal" $ do
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = mkRecordingHandle sc sentRef

      env3 <- mkTestEnv (EchoProvider "Echo: ") handle
      store <- newIORef Map.empty
      agentThread <- async $ runTabbedLoop env3 store

      -- /status is a non-tab slash command dispatched by fallthrough ->
      -- executeSlashCommand regardless of active tabs, so no /nt prelude needed.
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

      out <- allOutput sentRef
      T.unpack out `shouldContain` "Messages"

    it "executes tool calls end-to-end" $ do
      sc <- mkTestSignalChannelForFlow
      sentRef <- newIORef ([] :: [Text])
      let handle = mkRecordingHandle sc sentRef

      -- Register a test tool
      let testHandler = ToolHandler $ \_ -> pure ("tool result", False)
          testDef = ToolDefinition "test_tool" "A test tool" (object [])
          registry = registerTool testDef testHandler emptyRegistry
      baseEnv4 <- mkTestEnv ToolCallThenTextProvider handle
      let env = baseEnv4 { _env_registry = registry }

      store <- newIORef Map.empty
      agentThread <- async $ runTabbedLoop env store

      -- Establish an active tab so the DM reaches the provider, wait for banner.
      atomically $ writeTQueue (_sch_inbox sc) (mkNtEnvelope "+111")
      waitForResponses sentRef 1

      let envelope = SignalEnvelope
            { _se_source = "+111"
            , _se_sourceUuid = Nothing
            , _se_timestamp = Just 1000
            , _se_dataMessage = Just SignalDataMessage { _sdm_message = "do it", _sdm_timestamp = 1000 }
            }
      atomically $ writeTQueue (_sch_inbox sc) envelope
      -- Full tool cycle produces three recorded outputs:
      --   [0] /nt confirmation banner
      --   [1] "Using tool..." (first provider turn, before tool execution)
      --   [2] "Done with tool." (second provider turn, delivered asynchronously
      --       by the relay-writer AFTER the tool result is fed back)
      -- Wait for all three before reading allOutput so we don't race against
      -- the relay-writer thread that delivers [2] after cancelWith.
      waitForResponses sentRef 3

      cancelWith agentThread (userError "EOF")
      _ <- waitCatch agentThread

      -- The tool cycle ends with ToolCallThenTextProvider's final text.
      out <- allOutput sentRef
      T.unpack out `shouldContain` "Done with tool."

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
        let handle = mkRecordingHandle sc sentRef

        -- A real on-disk FOREGROUND session handle with a fresh _sm_source =
        -- Nothing. Under runTabbedLoop the conversation runs in the active
        -- tab's BOUND session (minted by /nt below), not this foreground one;
        -- this handle only roots the sessions directory (its parent, baseDir).
        let sid  = "sess-srctest"
            meta = mkSrcTestMeta sid
        sh <- mkSessionHandle Nothing mkNoOpLogHandle baseDir meta

        -- Build the test env, then OVERRIDE its (noOp) session with the real one
        -- so sessionsDirOf resolves the minted session under baseDir.
        baseEnv <- mkTestEnv (EchoProvider "Echo: ") handle
        writeIORef (_env_session baseEnv) sh

        store <- newIORef Map.empty
        agentThread <- async $ runTabbedLoop baseEnv store

        -- 1) /nt mints a default-provider tab+session for this conversation and
        --    focuses the cursor on it. The new path needs an active tab before a
        --    plain DM can reach the provider.
        let ntEnvelope = SignalEnvelope
              { _se_source     = "+15551234567"
              , _se_sourceUuid = Just "uuid-abc-123"
              , _se_timestamp  = Just 999
              , _se_dataMessage = Just SignalDataMessage
                  { _sdm_message   = "/nt"
                  , _sdm_timestamp = 999
                  }
              }
        atomically $ writeTQueue (_sch_inbox sc) ntEnvelope
        -- Wait for the /nt confirmation banner before sending the DM.
        waitForResponses sentRef 1

        -- 2) The real DM carrying BOTH a phone (source) and a uuid (sourceUuid).
        let envelope = SignalEnvelope
              { _se_source     = "+15551234567"
              , _se_sourceUuid = Just "uuid-abc-123"
              , _se_timestamp  = Just 1000
              , _se_dataMessage = Just SignalDataMessage
                  { _sdm_message   = "Hello"
                  , _sdm_timestamp = 1000
                  }
              }
        atomically $ writeTQueue (_sch_inbox sc) envelope
        -- Wait for the echo (the SECOND message; the first was the /nt banner).
        waitForResponses sentRef 2

        cancelWith agentThread (userError "EOF")
        _ <- waitCatch agentThread

        -- Locate the MINTED session dir: the subdir of baseDir that is not the
        -- foreground session's dir.
        entries <- listDirectory baseDir
        let mintedDirs = filter (/= T.unpack sid) entries
        mintedSid <- case mintedDirs of
          (d:_) -> pure d
          []    -> expectationFailure "expected a minted session dir under baseDir"
                     >> pure ""

        -- session.json (the BOUND session): phone AND uuid persisted via
        -- _sm_source (set-once on the bound session, not the foreground one).
        sessionJson <- TIO.readFile (baseDir </> mintedSid </> "session.json")
        T.unpack sessionJson `shouldContain` "+15551234567"
        T.unpack sessionJson `shouldContain` "uuid-abc-123"

        -- transcript.jsonl (the BOUND session): phone AND uuid recorded on the
        -- Request entry's metadata.source — present only because the transcript
        -- wrapper read the bound session's _sm_source per request.
        transcriptJsonl <- TIO.readFile (baseDir </> mintedSid </> "transcript.jsonl")
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

-- | Build a recording channel handle that is REALISTIC for the non-streaming
-- Signal channel: @_ch_send@ is recorded (the path the real Signal channel
-- actually uses for every reply) and @_ch_sendChunk@ is a no-op, exactly like
-- the real Signal handle (@_ch_streaming = False@). The previous fake recorded
-- @_ch_sendChunk@, masking pureclaw-ao9 — on the real channel those chunks are
-- discarded, so every provider reply was silently lost. Post-fix the relay
-- buffers a stream's chunks and flushes them as ONE @_ch_send@ on StreamEnd, so
-- recording @_ch_send@ exercises the real delivery path.
mkRecordingHandle :: SignalChannel -> IORef [Text] -> ChannelHandle
mkRecordingHandle sc sentRef =
  (toHandle sc)
    { _ch_send      = \msg -> atomicModifyIORef' sentRef (\xs -> (xs <> [_om_content msg], ()))
    , _ch_sendChunk = \_ -> pure ()
    }

-- | Construct a Signal envelope carrying @/nt@. Delivering this first mints a
-- default-provider tab+session for the conversation and focuses the cursor on
-- it — a prerequisite on the tabbed path before a plain DM can reach the
-- provider.
mkNtEnvelope :: Text -> SignalEnvelope
mkNtEnvelope src = SignalEnvelope
  { _se_source      = src
  , _se_sourceUuid  = Nothing
  , _se_timestamp   = Just 1
  , _se_dataMessage = Just SignalDataMessage
      { _sdm_message   = "/nt"
      , _sdm_timestamp = 1
      }
  }

-- | Concatenate all recorded output (banners + relayed chunks) into one Text so
-- content assertions don't depend on how the output was chunked or banner-split.
allOutput :: IORef [Text] -> IO Text
allOutput ref = T.concat <$> readIORef ref

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
