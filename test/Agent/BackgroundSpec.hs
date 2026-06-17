module Agent.BackgroundSpec (spec) where

import Control.Exception
import Control.Monad (forM)
import Data.IORef
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Session.Types qualified as SessionTypes

import PureClaw.Agent.Env
import PureClaw.Agent.Loop
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Security.Policy
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (mkSessionHandle, mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
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

-- | A mock provider that always fails.
data FailingProvider = FailingProvider

instance Provider FailingProvider where
  complete FailingProvider _ = throwIO (userError "provider failure")

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
  let routing = defaultRoutingConfig
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
    , _env_onTabsChanged = pure ()
    , _env_startHarness  = noStartHarness
    , _env_runTabCommand = noRunTabCommand
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

spec :: Spec
spec = do
  describe "runBackgroundTurn" $ do
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
