module Tabs.WiringSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Control.Exception (throwIO)
import Control.Monad qualified as M
import Data.IntMap.Strict qualified as IntMap
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text, isInfixOf)
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import System.Directory qualified as Dir
import System.FilePath qualified as FP
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

import Data.Aeson qualified as Aeson
import MCP.Client.Config (ClientConfig (..), defaultClientConfig)
import MCP.Client.Session (withClientSession)
import MCP.Client.Transport (Transport (..))
import MCP.Types (InputSchema (..), Tool (..))

import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Tab (TabRunner (..))
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.MCP (McpServer (..))
import PureClaw.Providers.Class
  ( CompletionResponse (..)
  , ContentBlock (..)
  , Message (..)
  , Provider (..)
  , SomeProvider (..)
  , ToolDefinition (..)
  , ToolResultPart (..)
  , Usage (..)
  )
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types (RoutingConfig (..))
import PureClaw.Security.Policy (defaultPolicy)
import PureClaw.Security.Vault.Age (VaultError (..))
import PureClaw.Security.Vault.Plugin (mkMockPluginHandle)
import PureClaw.Session.Handle
  ( SessionHandle (..)
  , mkSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Session.Types qualified as SessionTypes
import PureClaw.Tabs.RelayWriter (lookupSink)
import PureClaw.Tabs.Wiring (effectiveRegistry, execOneTool, runTabbedLoop)
import PureClaw.Tools.Registry
  ( ToolHandler (..)
  , emptyRegistry
  , executeTool
  , registerTool
  , registryDefinitions
  )

-- ---------------------------------------------------------------------------
-- A provider that is never expected to be called in these loop-level tests.
-- ---------------------------------------------------------------------------

-- | A provider whose 'complete' raises if it is ever invoked. The loop tests
-- below drive only tab-router copy paths (no active tab \/ parse errors \/
-- @\/bg@ fallthrough), so no provider turn should run.
data UnusedProvider = UnusedProvider

instance Provider UnusedProvider where
  complete UnusedProvider _ = throwIO (userError "provider unexpectedly called")

-- ---------------------------------------------------------------------------
-- A trivial streaming provider that always answers with a fixed reply.
-- ---------------------------------------------------------------------------

-- | A provider whose 'complete' returns a fixed text response. The default
-- 'completeStream' (Provider class) then emits exactly one 'StreamDone'
-- carrying it — enough to drive a provider turn end-to-end through the runtime
-- worker so the @_env_onFirstStreamDone@ one-shot fires (pureclaw-8g4).
data ReplyProvider = ReplyProvider

instance Provider ReplyProvider where
  complete ReplyProvider _ = pure CompletionResponse
    { _crsp_content = [TextBlock "hello from the model"]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

-- ---------------------------------------------------------------------------
-- A streaming provider that reports token usage.
-- ---------------------------------------------------------------------------

-- | A provider whose fixed reply carries a non-zero 'Usage'. Driving a turn
-- through this provider records a transcript Response entry whose metadata
-- carries @input_tokens@ \/ @output_tokens@, so a later @\/status@ that seeds
-- its context from the bound session's transcript can recover both the message
-- count AND the cumulative token totals (pureclaw-25k).
data UsageReplyProvider = UsageReplyProvider

instance Provider UsageReplyProvider where
  complete UsageReplyProvider _ = pure CompletionResponse
    { _crsp_content = [TextBlock "hello from the model"]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Just (Usage 11 7)
    }

-- ---------------------------------------------------------------------------
-- A scripted, recording channel.
-- ---------------------------------------------------------------------------

-- | The recording sink attached to a 'scriptedChannel': everything sent via
-- '_ch_send' (banners \/ acks). '_ch_sendChunk' is a no-op — the loop-level
-- copy paths under test never stream.
newtype ChannelLog = ChannelLog
  { _clog_sent :: IORef [Text]
  }

-- | Build a channel that yields the given scripted 'IncomingMessage's in order,
-- then throws @userError "EOF"@ (an 'IOException') so 'runTabbedLoop' exits via
-- its @try \@IOException@ guard. Sends and chunks are recorded.
scriptedChannel :: [IncomingMessage] -> IO (ChannelHandle, ChannelLog)
scriptedChannel scripted = do
  pendingRef <- newIORef scripted
  sentRef    <- newIORef []
  let channel = ChannelHandle
        { _ch_receive = do
            queued <- readIORef pendingRef
            case queued of
              []         -> throwIO (userError "EOF" :: IOError)
              (m : rest) -> writeIORef pendingRef rest >> pure m
        , _ch_send      = \msg -> modifyIORef' sentRef (<> [_om_content msg])
        , _ch_sendError = \_ -> pure ()
        , _ch_sendChunk = \_ -> pure ()
        , _ch_streaming = True
        , _ch_readSecret   = pure ""
        , _ch_prompt       = \_ -> pure ""
        , _ch_promptSecret = \_ -> pure ""
        }
  pure (channel, ChannelLog sentRef)

-- | A channel like 'scriptedChannel' but where receiving a message whose
-- content satisfies @gate@ first blocks until @ready@ becomes 'True'. Used to
-- feed @\/status@ only after the prior provider turn's transcript Response
-- entry (token-usage metadata) has been flushed to disk, so the seeded
-- @\/status@ context is deterministic (pureclaw-25k).
gatedChannel
  :: (Text -> Bool)        -- ^ gate predicate over inbound content
  -> IO Bool               -- ^ readiness probe; the gate releases once it is 'True'
  -> [IncomingMessage]
  -> IO (ChannelHandle, ChannelLog)
gatedChannel gate ready scripted = do
  pendingRef <- newIORef scripted
  sentRef    <- newIORef []
  let waitReady = do
        ok <- ready
        if ok then pure () else threadDelay 1000 >> waitReady
      channel = ChannelHandle
        { _ch_receive = do
            queued <- readIORef pendingRef
            case queued of
              []         -> throwIO (userError "EOF" :: IOError)
              (m : rest) -> do
                writeIORef pendingRef rest
                M.when (gate (_im_content m)) waitReady
                pure m
        , _ch_send      = \msg -> modifyIORef' sentRef (<> [_om_content msg])
        , _ch_sendError = \_ -> pure ()
        , _ch_sendChunk = \_ -> pure ()
        , _ch_streaming = True
        , _ch_readSecret   = pure ""
        , _ch_prompt       = \_ -> pure ""
        , _ch_promptSecret = \_ -> pure ""
        }
  pure (channel, ChannelLog sentRef)

-- | A plain-text inbound message tagged with the given conversation + user, on
-- the CLI channel.
mkInbound :: Text -> Text -> Text -> IncomingMessage
mkInbound conv user content = IncomingMessage
  { _im_source  =
      mkMessageSource CkCli (ConversationId conv) (Just (UserId user)) mempty
  , _im_content = content
  }

-- ---------------------------------------------------------------------------
-- A fork that tracks spawned runners for deterministic teardown.
-- ---------------------------------------------------------------------------

-- | An '_env_fork' that records every spawned 'TabRunner' into an 'IORef' so
-- the test can 'cancel' the relay-writer thread (the only lingering thread)
-- after 'runTabbedLoop' returns.
trackingFork :: IORef [TabRunner] -> IO () -> IO TabRunner
trackingFork ref body = do
  runner <- defaultEnvFork body
  modifyIORef' ref (runner :)
  pure runner

-- | Cancel every tracked runner (idempotent; safe on already-finished asyncs).
cancelAll :: IORef [TabRunner] -> IO ()
cancelAll ref = readIORef ref >>= mapM_ _trun_cancel

-- ---------------------------------------------------------------------------
-- Tabbed AgentEnv builder: real on-disk session + the 7 tab fields from
-- newTabSubsystem.
-- ---------------------------------------------------------------------------

-- | The result of 'mkTabbedEnv': the env, the channel log, and the runner
-- tracker (so the caller can tear the relay-writer thread down).
data TabbedHarness = TabbedHarness
  { _th_env     :: !AgentEnv
  , _th_log     :: !ChannelLog
  , _th_runners :: !(IORef [TabRunner])
  }

-- | Build a tabbed 'AgentEnv' with a REAL on-disk foreground session rooted
-- under @sessionsDir@, the seven tab fields populated by 'newTabSubsystem', a
-- recording scripted channel, and a runner-tracking fork.
mkTabbedEnv :: FilePath -> [IncomingMessage] -> IO TabbedHarness
mkTabbedEnv sessionsDir scripted = do
  chan <- scriptedChannel scripted
  mkTabbedEnvChan sessionsDir chan

-- | 'mkTabbedEnv' over an explicitly-built channel + log (so tests can supply a
-- 'gatedChannel' instead of the default 'scriptedChannel').
mkTabbedEnvChan :: FilePath -> (ChannelHandle, ChannelLog) -> IO TabbedHarness
mkTabbedEnvChan sessionsDir (channel, clog) = do
  runnersTracker  <- newIORef []

  vaultRef     <- newIORef Nothing
  providerRef  <- newIORef (Just (MkProvider UnusedProvider))
  modelRef     <- newIORef (Just (ModelId "mock"))
  harnessRef   <- newIORef Map.empty
  targetRef    <- newIORef TargetProvider
  windowIdxRef <- newIORef 0
  mcpRef       <- newIORef Map.empty
  tabsRef      <- newIORef IntMap.empty
  focusRef     <- newIORef Nothing
  activeCountTv <- newTVarIO 0
  legacyRunners <- newIORef IntMap.empty
  let routing = defaultRoutingConfig
  channelOutQ <- newTBQueueIO (fromIntegral (_rc_channelOutQBound routing))
  harnessReg  <- Registry.newRegistry

  -- A real foreground session on disk so _sm_source set-once is observable.
  now <- getCurrentTime
  let meta = SessionTypes.SessionMeta
        { SessionTypes._sm_id    = SessionTypes.newSessionId Nothing now
        , SessionTypes._sm_agent = Nothing
        , SessionTypes._sm_kind  = SessionTypes.SkProvider
            (SessionTypes.ProviderSpec
              (SessionTypes.inferProviderId "mock") (ModelId "mock") Nothing)
        , SessionTypes._sm_model             = "mock"
        , SessionTypes._sm_channel           = "cli"
        , SessionTypes._sm_createdAt         = now
        , SessionTypes._sm_lastActive        = now
        , SessionTypes._sm_bootstrapConsumed = False
        , SessionTypes._sm_archived          = False
        , SessionTypes._sm_description        = Nothing
        , SessionTypes._sm_autoSummary        = Nothing
        , SessionTypes._sm_source             = Nothing
        }
  sh         <- mkSessionHandle Nothing mkNoOpLogHandle sessionsDir meta
  sessionRef <- newIORef sh

  -- The seven tab fields, freshly allocated.
  ts <- newTabSubsystem (_rc_channelOutQBound routing)

  let env = AgentEnv
        { _env_provider          = providerRef
        , _env_model             = modelRef
        , _env_channel           = channel
        , _env_logger            = mkNoOpLogHandle
        , _env_systemPrompt      = Nothing
        , _env_registry          = emptyRegistry
        , _env_vault             = vaultRef
        , _env_pluginHandle      = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
        , _env_policy            = defaultPolicy
        , _env_harnesses         = harnessRef
        , _env_harnessRegistry   = harnessReg
        , _env_target            = targetRef
        , _env_nextWindowIdx     = windowIdxRef
        , _env_agentDef          = Nothing
        , _env_session           = sessionRef
        , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
        , _env_mcpServers        = mcpRef
        , _env_tabs              = tabsRef
        , _env_focus             = focusRef
        , _env_activeCount       = activeCountTv
        , _env_runners           = legacyRunners
        , _env_channelOutQ       = channelOutQ
        , _env_routingConfig     = routing
        , _env_fork              = trackingFork runnersTracker
        , _env_broker            = Nothing
        , _env_tabRegistry       = _ts_tabRegistry ts
        , _env_cursors           = _ts_cursors ts
        , _env_exec              = _ts_exec ts
        , _env_relayWriter       = _ts_relayWriter ts
        , _env_sinks             = _ts_sinks ts
        , _env_wizard            = _ts_wizard ts
        , _env_tabOutQ           = _ts_tabOutQ ts
        }
  pure (TabbedHarness env clog runnersTracker)

-- | Variant of 'mkTabbedEnv' that overrides the provider and model refs.
-- Used by the provider\/model guidance tests (pureclaw-ahj).
mkTabbedEnvWith
  :: FilePath
  -> [IncomingMessage]
  -> Maybe SomeProvider
  -> Maybe ModelId
  -> IO TabbedHarness
mkTabbedEnvWith sessionsDir scripted mProvider mModel = do
  th <- mkTabbedEnv sessionsDir scripted
  writeIORef (_env_provider (_th_env th)) mProvider
  writeIORef (_env_model    (_th_env th)) mModel
  pure th

-- | Run 'runTabbedLoop' under a 5s timeout, then cancel the relay-writer
-- thread. Returns whether the loop completed (i.e. did NOT time out).
runLoopBounded :: TabbedHarness -> IO Bool
runLoopBounded th = do
  done <- timeout (5 * 1000000) (runTabbedLoop (_th_env th))
  cancelAll (_th_runners th)
  pure (isJust done)

-- | Read back the foreground session's captured origin.
readSource :: AgentEnv -> IO (Maybe MessageSource)
readSource env = do
  sh <- readIORef (_env_session env)
  SessionTypes._sm_source <$> readIORef (_sh_meta sh)

-- | The conversation key for a CLI conversation id (channel + conversation).
cliKey :: Text -> (ChannelKind, ConversationId)
cliKey conv = (CkCli, ConversationId conv)

-- | Assert that @needle@ is a substring of @haystack@ (Text).
shouldContain' :: Text -> Text -> Expectation
shouldContain' haystack needle =
  haystack `shouldSatisfy` (needle `isInfixOf`)

-- | 'True' once some @transcript.jsonl@ under @root@ contains an
-- @output_tokens@ field — i.e. a provider Response entry with usage metadata
-- has been flushed. Used as the gated-channel readiness probe so @\/status@ is
-- fed only after the turn's usage is on disk (pureclaw-25k).
transcriptHasUsage :: FilePath -> IO Bool
transcriptHasUsage root = do
  files <- findTranscripts root
  anyM (fmap ("output_tokens" `isInfixOf`) . TIO.readFile) files
  where
    anyM _ []       = pure False
    anyM p (x : xs) = do
      r <- p x
      if r then pure True else anyM p xs

-- | 'True' once some @transcript.jsonl@ under @root@ contains a recorded
-- provider Response (matched by the fixed assistant reply text) — i.e. a turn
-- has completed and been flushed, regardless of whether usage metadata was
-- present. Used to gate @\/status@ for the no-usage case (pureclaw-25k).
transcriptHasResponse :: FilePath -> IO Bool
transcriptHasResponse root = do
  files <- findTranscripts root
  anyM (fmap ("hello from the model" `isInfixOf`) . TIO.readFile) files
  where
    anyM _ []       = pure False
    anyM p (x : xs) = do
      r <- p x
      if r then pure True else anyM p xs

-- | All @transcript.jsonl@ files at or under @dir@ (one level of session
-- subdirectories is enough for the tabbed harness, but this recurses to be
-- safe).
findTranscripts :: FilePath -> IO [FilePath]
findTranscripts dir = do
  exists <- Dir.doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- Dir.listDirectory dir
      fmap concat $ M.forM entries $ \e -> do
        let p = dir FP.</> e
        isDir <- Dir.doesDirectoryExist p
        if isDir
          then findTranscripts p
          else pure [p | e == "transcript.jsonl"]

-- ---------------------------------------------------------------------------
-- MCP-on-tabbed-path fixtures (pureclaw-2u4)
-- ---------------------------------------------------------------------------

-- | A fake MCP 'Transport' whose receive blocks forever (no server response)
-- and whose send/close are no-ops. Paired with a tiny request timeout, a
-- 'callTool' over a session on this transport returns a caught 'RequestTimeout'
-- error result — proving the tool is REACHABLE (dispatched to the MCP handler),
-- not "Unknown tool" — without spawning a real MCP server.
fakeTransport :: IO Transport
fakeTransport = do
  block <- newEmptyMVar
  pure Transport
    { transport_send    = \_ -> pure ()
    , transport_receive = takeMVar block   -- never fires (test never fills it)
    , transport_close   = pure ()
    }

-- | A single MCP 'Tool' named "mcp_ping".
mcpPingTool :: Tool
mcpPingTool = Tool
  { name         = "mcp_ping"
  , title        = Nothing
  , description  = Just "ping exposed by a fake MCP server"
  , inputSchema  = InputSchema { schemaType = "object", properties = Nothing, required = Nothing }
  , outputSchema = Nothing
  , annotations  = Nothing
  , _meta        = Nothing
  }

-- | Build an 'McpServer' over a real 'ClientSession' (transport faked) that
-- exposes 'mcpPingTool', and run @action@ with it while the session is alive.
-- The session uses a 1ms request timeout so a tool call returns promptly.
withFakeMcpServer :: (McpServer -> IO a) -> IO a
withFakeMcpServer action = do
  transport <- fakeTransport
  let cfg = defaultClientConfig { config_request_timeout_us = 1000 }
  withClientSession transport cfg $ \session ->
    action McpServer
      { _ms_name       = "fake"
      , _ms_command    = ["fake"]
      , _ms_session    = session
      , _ms_tools      = [mcpPingTool]
      , _ms_serverInfo = Nothing
      , _ms_cleanup    = pure ()
      }

-- | Seed an env's '_env_mcpServers' with one connected MCP server.
seedMcp :: AgentEnv -> McpServer -> IO ()
seedMcp env server =
  writeIORef (_env_mcpServers env) (Map.singleton (_ms_name server) server)

spec :: Spec
spec = do
  describe "runTabbedLoop" $ do
    it "captures _sm_source (set-once) from the first inbound message" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        let msg = mkInbound "conv-a" "alice" "hello there"
        th <- mkTabbedEnv tmp [msg]
        completed <- runLoopBounded th
        completed `shouldBe` True
        src <- readSource (_th_env th)
        src `shouldBe` Just (_im_source msg)

    it "captures _sm_source even when the first message content is empty" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        -- Empty content: capture happens BEFORE dispatch, so the source is
        -- still recorded even though the message routes to a parse-error copy.
        let msg = mkInbound "conv-empty" "bob" ""
        th <- mkTabbedEnv tmp [msg]
        completed <- runLoopBounded th
        completed `shouldBe` True
        src <- readSource (_th_env th)
        src `shouldBe` Just (_im_source msg)

    it "does NOT overwrite _sm_source with a later different-sender message" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        let msg1 = mkInbound "conv-a" "alice" "first"
            msg2 = mkInbound "conv-b" "carol" "second"
        th <- mkTabbedEnv tmp [msg1, msg2]
        completed <- runLoopBounded th
        completed `shouldBe` True
        src <- readSource (_th_env th)
        -- First sender wins (set-once); the second source is ignored.
        src `shouldBe` Just (_im_source msg1)

    it "iterates the loop over every scripted message" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        -- Two plain-text messages with NO active tab each emit the "no active
        -- tab" banner; observing it twice proves both iterations ran.
        let msgs =
              [ mkInbound "conv-a" "alice" "one"
              , mkInbound "conv-a" "alice" "two"
              ]
        th <- mkTabbedEnv tmp msgs
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let banner = "no active tab — /new to start one or /tab to attach"
        length (filter (== banner) sent) `shouldBe` 2

    it "terminates cleanly on EOF (empty script, receive throws immediately)" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        th <- mkTabbedEnv tmp []
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        sent `shouldBe` []

    it "handles a whitespace-only inbound without crashing and continues" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        -- Whitespace-only is silently skipped (no parse-error emitted); a
        -- following plain message still produces the no-active-tab banner,
        -- proving the loop did not crash on the blank message.
        let msgs =
              [ mkInbound "conv-a" "alice" "   "
              , mkInbound "conv-a" "alice" "after"
              ]
        th <- mkTabbedEnv tmp msgs
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let parseErr = "could not parse that — /tabs to list, /help for commands"
            banner   = "no active tab — /new to start one or /tab to attach"
        sent `shouldNotContain` [parseErr]
        sent `shouldContain` [banner]

    it "silently skips whitespace-only input and still captures source (pureclaw-z9h)" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        -- A whitespace-only message must: (a) NOT emit a parse-error, and
        -- (b) still capture provenance (_sm_source set-once), because source
        -- capture happens BEFORE the dispatch guard (same as empty-content).
        let msg = mkInbound "conv-ws" "alice" "   "
        th <- mkTabbedEnv tmp [msg]
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let parseErr = "could not parse that — /tabs to list, /help for commands"
        sent `shouldNotContain` [parseErr]
        src <- readSource (_th_env th)
        src `shouldBe` Just (_im_source msg)

    it "acknowledges /bg in the foreground via the fallthrough" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        let msg = mkInbound "conv-a" "alice" "/bg summarize the repo"
        th <- mkTabbedEnv tmp [msg]
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let ack =
              "\x1F504 /bg: running in the background \x2014 the result will appear here when ready."
        sent `shouldContain` [ack]

    it "registers the inbound conversation's output sink" $
      withSystemTempDirectory "pc-wiring" $ \tmp -> do
        let msg = mkInbound "conv-sink" "alice" "hi"
        th <- mkTabbedEnv tmp [msg]
        completed <- runLoopBounded th
        completed `shouldBe` True
        mSink <- lookupSink (_env_sinks (_th_env th)) (cliKey "conv-sink")
        case mSink of
          Just _  -> pure ()
          Nothing -> expectationFailure "expected sink registered for conv-sink"

    it "fires the _env_onFirstStreamDone one-shot on the first provider turn (pureclaw-8g4)" $
      withSystemTempDirectory "pc-wiring-bootstrap" $ \tmp -> do
        -- End-to-end: /new mints a provider session + cursor, then a plain
        -- message drives a real provider turn through the runtime worker. The
        -- provider emits a StreamDone, which must fire the armed
        -- _env_onFirstStreamDone exactly once (restoring markBootstrapConsumed
        -- so BOOTSTRAP.md is not re-injected on every resume). Before the fix
        -- the tabbed path NEVER fired it.
        let msgs =
              [ mkInbound "conv-a" "alice" "/new"
              , mkInbound "conv-a" "alice" "say hi"
              ]
        th <- mkTabbedEnvWith tmp msgs (Just (MkProvider ReplyProvider))
                              (Just (ModelId "mock"))
        let env = _th_env th
        counter <- newIORef (0 :: Int)
        fired   <- newEmptyMVar
        writeIORef (_env_onFirstStreamDone env)
          (Just (modifyIORef' counter (+ 1) >> putMVar fired ()))
        -- Run the loop to EOF (it enqueues the turn to the async worker and
        -- returns), then wait for the worker's StreamDone to fire the hook
        -- BEFORE tearing the runners down (cancelAll would otherwise kill the
        -- worker mid-turn). The runner-tracking fork keeps the worker alive.
        completed <- timeout (5 * 1000000) (runTabbedLoop env)
        completed `shouldSatisfy` isJust
        firedInTime <- timeout (5 * 1000000) (takeMVar fired)
        cancelAll (_th_runners th)
        firedInTime `shouldBe` Just ()
        readIORef counter `shouldReturn` 1
        -- The action was read-and-cleared: the ref is now empty (no re-fire).
        cleared <- isNothing <$> readIORef (_env_onFirstStreamDone env)
        cleared `shouldBe` True

    it "/status reflects the active session transcript: messages + token totals (pureclaw-25k)" $
      withSystemTempDirectory "pc-wiring-status" $ \tmp -> do
        -- End-to-end: /new mints a provider session, a plain message drives a
        -- real provider turn (UsageReplyProvider reports Usage 11/7) recorded to
        -- the bound session's transcript, THEN /status is fed. The /status reply
        -- must reflect the live conversation: a non-zero message count, a
        -- non-zero context-token estimate, and the cumulative input/output token
        -- totals reconstructed from the transcript. Before the fix /status saw
        -- an empty context and reported all zeros (RED).
        let msgs =
              [ mkInbound "conv-a" "alice" "/new"
              , mkInbound "conv-a" "alice" "say hi"
              , mkInbound "conv-a" "alice" "/status"
              ]
        -- Feed /status only after the turn's transcript Response entry (carrying
        -- output_tokens) has been flushed under @tmp@, guaranteeing the seeded
        -- /status context is deterministic.
        chan <- gatedChannel ("/status" `isInfixOf`) (transcriptHasUsage tmp) msgs
        th   <- mkTabbedEnvChan tmp chan
        let env = _th_env th
        writeIORef (_env_provider env) (Just (MkProvider UsageReplyProvider))
        writeIORef (_env_model env)    (Just (ModelId "mock"))
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let statusBlocks = filter ("Session status:" `isInfixOf`) sent
        case statusBlocks of
          (status : _) -> do
            -- Message count: 2 (user "say hi" + assistant reply) reconstructed
            -- from the transcript, NOT 0.
            status `shouldContain'` "Messages:            2"
            -- Token totals reconstructed from the transcript Response metadata.
            status `shouldContain'` "Total input tokens:  11"
            status `shouldContain'` "Total output tokens: 7"
          [] -> expectationFailure "expected a /status block in the sent log"

    it "/status seeds messages from the transcript even when the provider reports no usage (pureclaw-25k)" $
      withSystemTempDirectory "pc-wiring-status-nousage" $ \tmp -> do
        -- ReplyProvider reports no Usage, so the transcript Response carries no
        -- token metadata: token totals stay 0 (metaInt's no-key branch), but the
        -- message count is still reconstructed from the transcript (> 0). This
        -- proves the seed is message-driven and degrades gracefully on usage.
        let msgs =
              [ mkInbound "conv-a" "alice" "/new"
              , mkInbound "conv-a" "alice" "say hi"
              , mkInbound "conv-a" "alice" "/status"
              ]
        chan <- gatedChannel ("/status" `isInfixOf`) (transcriptHasResponse tmp) msgs
        th   <- mkTabbedEnvChan tmp chan
        let env = _th_env th
        writeIORef (_env_provider env) (Just (MkProvider ReplyProvider))
        writeIORef (_env_model env)    (Just (ModelId "mock"))
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        let statusBlocks = filter ("Session status:" `isInfixOf`) sent
        case statusBlocks of
          (status : _) -> do
            status `shouldContain'` "Messages:            2"
            status `shouldContain'` "Total input tokens:  0"
            status `shouldContain'` "Total output tokens: 0"
          [] -> expectationFailure "expected a /status block in the sent log"

  describe "mkNewDefaultSession — provider/model guidance (pureclaw-ahj)" $ do
    it "/new with no provider emits guidance mentioning /provider" $
      withSystemTempDirectory "pc-wiring-guidance" $ \tmp -> do
        -- Feed /new with provider=Nothing: must get a message that mentions
        -- /provider to guide the user to configure a provider.
        let msg = mkInbound "conv-a" "alice" "/new"
        th <- mkTabbedEnvWith tmp [msg] Nothing (Just (ModelId "mock"))
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        -- The reply must mention /provider (currently it says "no default
        -- provider configured" without any /provider recipe — RED).
        any ("/provider" `isInfixOf`) sent `shouldBe` True

    it "/new with provider-but-no-model emits guidance mentioning /target" $
      withSystemTempDirectory "pc-wiring-guidance" $ \tmp -> do
        -- Feed /new with model=Nothing but provider present: must get a
        -- message that mentions /target (currently mislabeled as "no provider"
        -- with no /target recipe — RED).
        let msg = mkInbound "conv-a" "alice" "/new"
        th <- mkTabbedEnvWith tmp [msg] (Just (MkProvider UnusedProvider)) Nothing
        completed <- runLoopBounded th
        completed `shouldBe` True
        sent <- readIORef (_clog_sent (_th_log th))
        -- The reply must mention /target.
        any ("/target" `isInfixOf`) sent `shouldBe` True

  describe "effectiveRegistry / execOneTool — MCP tools on the tabbed path (pureclaw-2u4)" $ do
    it "merges connected MCP server tools into the effective registry (defs + base preserved)" $
      withSystemTempDirectory "pc-wiring-mcp" $ \tmp ->
        withFakeMcpServer $ \server -> do
          th <- mkTabbedEnv tmp []
          -- A base registry with a built-in tool, so the merge must keep BOTH.
          let builtin = ToolDefinition
                { _td_name        = "builtin_echo"
                , _td_description = "echo"
                , _td_inputSchema = Aeson.Null
                }
              baseReg = registerTool builtin (ToolHandler (\_ -> pure ("ok", False)))
                          emptyRegistry
              env = (_th_env th) { _env_registry = baseReg }
          seedMcp env server
          defs <- registryDefinitions <$> effectiveRegistry env
          let names = map _td_name defs
          names `shouldContain` ["mcp_ping"]    -- MCP tool advertised to the LLM
          names `shouldContain` ["builtin_echo"] -- base registry preserved

    it "executes a connected MCP tool (reachable, NOT \"Unknown tool\") via execOneTool" $
      withSystemTempDirectory "pc-wiring-mcp" $ \tmp ->
        withFakeMcpServer $ \server -> do
          th <- mkTabbedEnv tmp []
          let env = (_th_env th) { _env_registry = emptyRegistry }
          seedMcp env server
          -- Direct registry exec: a connected MCP tool resolves to a handler.
          res <- effectiveRegistry env >>= \reg -> executeTool reg "mcp_ping" Aeson.Null
          case res of
            Nothing -> expectationFailure "mcp_ping unreachable: executeTool returned Nothing"
            Just _  -> pure ()
          -- And through execOneTool (the per-tab runtime seam): the result must
          -- NOT be the "Unknown tool" message — it dispatched to the MCP handler.
          msg <- execOneTool env (ToolCallId "c1") "mcp_ping" Aeson.Null
          let texts =
                [ t
                | ToolResultBlock _ parts _ <- _msg_content msg
                , TRPText t <- parts
                ]
          texts `shouldNotContain` ["Unknown tool: mcp_ping"]

    it "returns the base registry unchanged when no MCP servers are connected" $
      withSystemTempDirectory "pc-wiring-mcp" $ \tmp -> do
        th <- mkTabbedEnv tmp []
        let builtin = ToolDefinition
              { _td_name        = "builtin_only"
              , _td_description = "echo"
              , _td_inputSchema = Aeson.Null
              }
            baseReg = registerTool builtin (ToolHandler (\_ -> pure ("ok", False)))
                        emptyRegistry
            env = (_th_env th) { _env_registry = baseReg }
        -- _env_mcpServers is empty (mkTabbedEnv default): the Map.null branch.
        defs <- registryDefinitions <$> effectiveRegistry env
        map _td_name defs `shouldBe` ["builtin_only"]
        -- An unknown tool on the empty-MCP path still yields "Unknown tool".
        msg <- execOneTool env (ToolCallId "c0") "nope" Aeson.Null
        let texts =
              [ t
              | ToolResultBlock _ parts _ <- _msg_content msg
              , TRPText t <- parts
              ]
        texts `shouldContain` ["Unknown tool: nope"]
