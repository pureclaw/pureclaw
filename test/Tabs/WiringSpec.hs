module Tabs.WiringSpec (spec) where

import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Control.Exception (throwIO)
import Data.IntMap.Strict qualified as IntMap
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Tab (TabRunner (..))
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Providers.Class (Provider (..), SomeProvider (..))
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
import PureClaw.Tabs.Wiring (runTabbedLoop)
import PureClaw.Tools.Registry (emptyRegistry)

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
  (channel, clog) <- scriptedChannel scripted
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

-- | Run 'runTabbedLoop' under a 5s timeout, then cancel the relay-writer
-- thread. Returns whether the loop completed (i.e. did NOT time out).
runLoopBounded :: TabbedHarness -> IO Bool
runLoopBounded th = do
  done <- timeout (5 * 1000000) (runTabbedLoop (_th_env th))
  cancelAll (_th_runners th)
  pure (maybe False (const True) done)

-- | Read back the foreground session's captured origin.
readSource :: AgentEnv -> IO (Maybe MessageSource)
readSource env = do
  sh <- readIORef (_env_session env)
  SessionTypes._sm_source <$> readIORef (_sh_meta sh)

-- | The conversation key for a CLI conversation id (channel + conversation).
cliKey :: Text -> (ChannelKind, ConversationId)
cliKey conv = (CkCli, ConversationId conv)

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
        -- Whitespace-only routes to the parse-error copy; a following plain
        -- message still produces the no-active-tab banner, proving the loop
        -- did not crash on the blank message.
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
        sent `shouldContain` [parseErr]
        sent `shouldContain` [banner]

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
