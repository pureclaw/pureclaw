module Agent.SlashCommandsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock
import System.Directory qualified as Dir
import System.Environment (setEnv, getEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import System.FilePath ((</>))

import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.CLI.Config
import PureClaw.Core.Types
import PureClaw.Session.Handle (SessionHandle (..), mkNoOpSessionHandle, noOpOnFirstStreamDoneRef)
import PureClaw.Session.Types (SessionMeta (..), RuntimeType (..))
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Harness.Tmux
import PureClaw.Handles.Transcript
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Tools.Registry
import PureClaw.Transcript.Types

-- | Mock provider for testing.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider summary) _ = pure CompletionResponse
    { _crsp_content = [TextBlock summary]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }
  listModels _ = pure [ModelId "llama3", ModelId "test", ModelId "mock"]

-- | Build a mock VaultHandle backed by IORef state.
-- Starts unlocked with no secrets.
mkMockVaultHandle :: IO VaultHandle
mkMockVaultHandle = do
  lockedRef  <- newIORef False
  secretsRef <- newIORef ([] :: [(Text, ByteString)])
  initedRef  <- newIORef False
  pure VaultHandle
    { _vh_init = do
        inited <- readIORef initedRef
        if inited
          then pure (Left VaultAlreadyExists)
          else writeIORef initedRef True >> pure (Right ())

    , _vh_put = \name val -> do
        modifyIORef secretsRef (\ss -> (name, val) : filter ((/= name) . fst) ss)
        pure (Right ())

    , _vh_get = \name -> do
        secrets <- readIORef secretsRef
        case lookup name secrets of
          Nothing  -> pure (Left (VaultCorrupted "no such key"))
          Just val -> pure (Right val)

    , _vh_delete = \name -> do
        secrets <- readIORef secretsRef
        case lookup name secrets of
          Nothing -> pure (Left (VaultCorrupted "no such key"))
          Just _  -> do
            modifyIORef secretsRef (filter ((/= name) . fst))
            pure (Right ())

    , _vh_list = do
        secrets <- readIORef secretsRef
        pure (Right (map fst secrets))

    , _vh_lock = writeIORef lockedRef True

    , _vh_unlock = writeIORef lockedRef False >> pure (Right ())

    , _vh_status = do
        locked  <- readIORef lockedRef
        secrets <- readIORef secretsRef
        pure VaultStatus
          { _vs_locked      = locked
          , _vs_secretCount = length secrets
          , _vs_keyType     = "X25519"
          }

    , _vh_rekey = \_ _ _ -> pure (Right ())
    }

-- | Pop the next message from a queue IORef. Throws IOError on empty.
popMsg :: IORef [Text] -> IO Text
popMsg msgsRef = do
  msgs <- readIORef msgsRef
  case msgs of
    []     -> throwIO (userError "EOF" :: IOError)
    (m:rest) -> do
      writeIORef msgsRef rest
      pure m

-- | Build a mock channel that pops prompt/secret responses from a queue.
mkMockChannel :: IORef (Maybe Text) -> IORef [Text] -> ChannelHandle
mkMockChannel sentRef msgsRef = mkNoOpChannelHandle
  { _ch_send         = writeIORef sentRef . Just . _om_content
  , _ch_receive      = do
      m <- popMsg msgsRef
      pure (IncomingMessage (UserId "test") m)
  , _ch_prompt       = \_ -> popMsg msgsRef
  , _ch_promptSecret = \_ -> popMsg msgsRef
  }

-- | Like mkMockChannel but captures ALL sent messages (not just the last).
mkMockChannelAll :: IORef [Text] -> IORef [Text] -> ChannelHandle
mkMockChannelAll allSentRef msgsRef = mkNoOpChannelHandle
  { _ch_send         = \msg -> modifyIORef allSentRef (_om_content msg :)
  , _ch_receive      = do
      m <- popMsg msgsRef
      pure (IncomingMessage (UserId "test") m)
  , _ch_prompt       = \_ -> popMsg msgsRef
  , _ch_promptSecret = \_ -> popMsg msgsRef
  }

-- | Run an IO action with HOME set to a temporary directory.
-- Prevents tests that call getPureclawDir from writing to the real config.
withTempHome :: IO a -> IO a
withTempHome action =
  withSystemTempDirectory "pureclaw-test-home" $ \tmpDir -> do
    origHome <- getEnv "HOME"
    bracket_
      (setEnv "HOME" tmpDir)
      (setEnv "HOME" origHome)
      action

spec :: Spec
spec = do
  describe "parseSlashCommand" $ do
    it "parses /new" $ do
      parseSlashCommand "/new" `shouldBe` Just CmdNew

    it "rejects /reset (removed)" $ do
      parseSlashCommand "/reset" `shouldBe` Nothing

    it "parses /status" $ do
      parseSlashCommand "/status" `shouldBe` Just CmdStatus

    it "parses /compact" $ do
      parseSlashCommand "/compact" `shouldBe` Just CmdCompact

    it "parses /vault setup" $ do
      parseSlashCommand "/vault setup" `shouldBe` Just (CmdVault VaultSetup)

    it "parses /vault list" $ do
      parseSlashCommand "/vault list" `shouldBe` Just (CmdVault VaultList)

    it "parses /vault lock" $ do
      parseSlashCommand "/vault lock" `shouldBe` Just (CmdVault VaultLock)

    it "parses /vault unlock" $ do
      parseSlashCommand "/vault unlock" `shouldBe` Just (CmdVault VaultUnlock)

    it "parses /vault status" $ do
      parseSlashCommand "/vault status" `shouldBe` Just (CmdVault VaultStatus')

    it "parses /vault add <name>" $ do
      parseSlashCommand "/vault add mykey" `shouldBe` Just (CmdVault (VaultAdd "mykey"))

    it "parses /vault delete <name>" $ do
      parseSlashCommand "/vault delete mykey" `shouldBe` Just (CmdVault (VaultDelete "mykey"))

    it "parses unknown /vault subcommand" $ do
      parseSlashCommand "/vault foo" `shouldBe` Just (CmdVault (VaultUnknown "foo"))

    it "parses bare /vault as unknown" $ do
      parseSlashCommand "/vault" `shouldBe` Just (CmdVault (VaultUnknown ""))

    it "parses /provider with no arg as list" $ do
      parseSlashCommand "/provider" `shouldBe` Just (CmdProvider ProviderList)

    it "parses /provider with trailing space as list" $ do
      parseSlashCommand "/provider " `shouldBe` Just (CmdProvider ProviderList)

    it "parses /provider anthropic" $ do
      parseSlashCommand "/provider anthropic" `shouldBe` Just (CmdProvider (ProviderConfigure "anthropic"))

    it "parses /provider case-insensitively but preserves arg case" $ do
      parseSlashCommand "/Provider Anthropic" `shouldBe` Just (CmdProvider (ProviderConfigure "Anthropic"))

    it "parses /target with no arg as show" $ do
      parseSlashCommand "/target" `shouldBe` Just (CmdTarget Nothing)

    it "parses /target with arg as switch" $ do
      parseSlashCommand "/target llama3" `shouldBe` Just (CmdTarget (Just "llama3"))

    it "parses /target with trailing space as show" $ do
      parseSlashCommand "/target " `shouldBe` Just (CmdTarget Nothing)

    it "parses /target default (no arg)" $ do
      parseSlashCommand "/target default" `shouldBe` Just (CmdTargetDefault Nothing)

    it "parses /target default <name>" $ do
      parseSlashCommand "/target default claude-code-0" `shouldBe` Just (CmdTargetDefault (Just "claude-code-0"))

    it "is case-insensitive" $ do
      parseSlashCommand "/NEW" `shouldBe` Just CmdNew
      parseSlashCommand "/Status" `shouldBe` Just CmdStatus

    it "strips whitespace" $ do
      parseSlashCommand "  /new  " `shouldBe` Just CmdNew

    it "returns Nothing for non-commands" $ do
      parseSlashCommand "hello" `shouldBe` Nothing

    it "returns Nothing for unknown commands" $ do
      parseSlashCommand "/unknown" `shouldBe` Nothing

    it "returns Nothing for empty input" $ do
      parseSlashCommand "" `shouldBe` Nothing

    it "parses /msg with target and message" $ do
      parseSlashCommand "/msg claude-code-0 hello world"
        `shouldBe` Just (CmdMsg "claude-code-0" "hello world")

    it "parses /msg case-insensitively for command" $ do
      parseSlashCommand "/MSG cc-1 test message"
        `shouldBe` Just (CmdMsg "cc-1" "test message")

    it "returns Nothing for /msg with no arguments" $ do
      parseSlashCommand "/msg" `shouldBe` Nothing

    it "returns Nothing for /msg with target but no message" $ do
      parseSlashCommand "/msg claude-code-0" `shouldBe` Nothing

    it "returns Nothing for /msg with target and only spaces" $ do
      parseSlashCommand "/msg claude-code-0   " `shouldBe` Nothing

    it "preserves message body case in /msg" $ do
      parseSlashCommand "/msg cc-0 List All TODO Items"
        `shouldBe` Just (CmdMsg "cc-0" "List All TODO Items")

  describe "executeSlashCommand" $ do
    let mkEnv sentRef = do
          vaultRef    <- newIORef Nothing
          providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef    <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/new clears messages but keeps system prompt" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = addMessage (textMessage User "hello")
              $ emptyContext (Just "sys")
      env <- mkEnv sentRef
      ctx' <- executeSlashCommand env CmdNew ctx
      contextMessages ctx' `shouldBe` []
      contextSystemPrompt ctx' `shouldBe` Just "sys"
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "cleared"
        Nothing -> expectationFailure "Expected message"

    it "/new preserves usage counters" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "hello")
              $ emptyContext Nothing
      env <- mkEnv sentRef
      ctx' <- executeSlashCommand env CmdNew ctx
      contextTotalInputTokens ctx' `shouldBe` 100

    it "/status shows session info" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "hello world")
              $ emptyContext Nothing
      env <- mkEnv sentRef
      ctx' <- executeSlashCommand env CmdStatus ctx
      ctx' `shouldBe` ctx  -- status doesn't modify context
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Messages:"
          T.unpack t `shouldContain` "1"
          T.unpack t `shouldContain` "100"
          T.unpack t `shouldContain` "50"
          T.unpack t `shouldContain` "Target:"
        Nothing -> expectationFailure "Expected status message"

    it "/compact with few messages returns NotNeeded" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      env <- mkEnv sentRef
      _ <- executeSlashCommand env CmdCompact ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "few messages"
        Nothing -> expectationFailure "Expected compact message"

    it "/compact with many messages compacts" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let msgs = [textMessage User ("msg" <> T.pack (show i)) | i <- [(1::Int)..20]]
          ctx = foldl (flip addMessage) (emptyContext Nothing) msgs
      env <- mkEnv sentRef
      ctx' <- executeSlashCommand env CmdCompact ctx
      contextMessageCount ctx' `shouldSatisfy` (< 20)
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Compacted"
        Nothing -> expectationFailure "Expected compact message"

  describe "provider commands" $ do
    it "/provider with no arg lists available providers" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider ProviderList) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Available providers"
          T.unpack t `shouldContain` "anthropic"
          T.unpack t `shouldContain` "openai"
          T.unpack t `shouldContain` "openrouter"
          T.unpack t `shouldContain` "ollama"
        Nothing -> expectationFailure "Expected provider list"

    it "/provider with no vault shows helpful message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider ProviderList) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Vault not configured"
        Nothing -> expectationFailure "Expected message"

    it "/provider unknown-name shows error" $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ([] :: [Text])
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider (ProviderConfigure "badname")) ctx
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "Unknown provider"
      combined `shouldContain` "Supported providers"

    it "/provider ollama with default URL stores provider and model in config.toml" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["", "llama3"]  -- empty = accept default URL, then model name
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider (ProviderConfigure "ollama")) ctx
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "configured successfully"
      -- Verify provider and model were hot-swapped in session
      newModel <- readIORef modelRef
      newModel `shouldBe` ModelId "llama3"
      mProvider <- readIORef providerRef
      case mProvider of
        Just _  -> pure ()
        Nothing -> expectationFailure "Expected provider to be set"
      -- Verify config.toml has provider and model
      pureclawDir <- getPureclawDir
      cfg <- loadFileConfig (pureclawDir </> "config.toml")
      _fc_provider cfg `shouldBe` Just "ollama"
      _fc_model cfg `shouldBe` Just "llama3"
      _fc_baseUrl cfg `shouldBe` Nothing  -- default URL not stored

    it "/provider ollama with custom URL stores provider, model, and base_url in config.toml" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["http://myhost:11434", "mistral"]
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider (ProviderConfigure "ollama")) ctx
      -- Verify config.toml has all three fields
      pureclawDir <- getPureclawDir
      cfg <- loadFileConfig (pureclawDir </> "config.toml")
      _fc_provider cfg `shouldBe` Just "ollama"
      _fc_model cfg `shouldBe` Just "mistral"
      _fc_baseUrl cfg `shouldBe` Just "http://myhost:11434"

  describe "target commands" $ do
    it "/target with no arg shows current target (provider)" $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ([] :: [Text])
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTarget Nothing) ctx
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "Current target: model: test"

    it "/target <name> switches to model when no matching harness" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ([] :: [Text])
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTarget (Just "llama3")) ctx
      -- Verify model IORef was updated
      newModel <- readIORef modelRef
      newModel `shouldBe` ModelId "llama3"
      -- Verify target is TargetProvider
      newTarget <- readIORef targetRef
      newTarget `shouldBe` TargetProvider
      -- Verify config.toml was updated
      pureclawDir <- getPureclawDir
      cfg <- loadFileConfig (pureclawDir </> "config.toml")
      _fc_model cfg `shouldBe` Just "llama3"
      -- Verify success message
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "Target switched to model: llama3"

    it "/target <name> switches to harness when name matches running harness" $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ([] :: [Text])
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef (Map.singleton "claude-code" mkNoOpHarnessHandle)
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTarget (Just "claude-code")) ctx
      -- Verify target switched to harness
      newTarget <- readIORef targetRef
      newTarget `shouldBe` TargetHarness "claude-code"
      -- Model should be unchanged
      newModel <- readIORef modelRef
      newModel `shouldBe` ModelId "test"
      -- Verify success message
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "Target switched to harness: claude-code"

  describe "/msg command" $ do
    it "sends message to a running harness and returns prefixed output" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      receivedRef <- newIORef (Nothing :: Maybe ByteString)
      let mockHarness = mkNoOpHarnessHandle
            { _hh_send = writeIORef receivedRef . Just
            , _hh_receive = pure (TE.encodeUtf8 "some output")
            , _hh_name = "Claude Code"
            }
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef (Map.singleton "claude-code-0" mockHarness)
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 1
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdMsg "claude-code-0" "list TODOs") ctx
      -- Verify message was sent to harness
      received <- readIORef receivedRef
      received `shouldBe` Just (TE.encodeUtf8 "list TODOs")
      -- Verify output is prefixed IRC-style
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "claude-code-0> some output"
        Nothing -> expectationFailure "Expected prefixed output"

    it "returns error for nonexistent harness" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdMsg "nonexistent" "hello") ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No running harness"
        Nothing -> expectationFailure "Expected error message"

    it "does not change the global target" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let mockHarness = mkNoOpHarnessHandle
            { _hh_receive = pure (TE.encodeUtf8 "reply")
            , _hh_name = "Claude Code"
            }
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef (Map.singleton "cc-0" mockHarness)
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 1
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdMsg "cc-0" "test") ctx
      -- Global target should still be TargetProvider
      target <- readIORef targetRef
      target `shouldBe` TargetProvider

  describe "vault commands — no vault configured" $ do
    let mkEnvNoVault sentRef = do
          vaultRef    <- newIORef Nothing
          providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef    <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/vault list with no vault → helpful message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkEnvNoVault sentRef
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultList) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No vault configured"
        Nothing -> expectationFailure "Expected message"

    it "/vault lock with no vault → helpful message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkEnvNoVault sentRef
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultLock) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No vault configured"
        Nothing -> expectationFailure "Expected message"

    it "/vault setup with no vault and invalid choice → cancelled" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      msgsRef <- newIORef ["bad"]
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Invalid choice"
        Nothing -> expectationFailure "Expected message"

    it "/vault setup from fresh install with uninitialized vault handle succeeds" $ withTempHome $ do
      -- Reproduces the bug: resolvePassphraseVault returns Just vault even
      -- when the vault file doesn't exist. When the user then runs
      -- /vault setup, executeVaultSetup sees Just vault and tries to rekey
      -- instead of calling firstTimeSetup. The rekey fails with VaultNotFound.
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["1", "test-passphrase"]  -- pick passphrase, then enter it
      -- Create a vault handle but do NOT call _vh_init — simulates
      -- the state after resolvePassphraseVault on a fresh install.
      uninitVault <- mkMockVaultHandle
      let vaultWithRealisticRekey = uninitVault
            { _vh_rekey = \_ _ _ -> pure (Left VaultNotFound)
            }
      vaultRef    <- newIORef (Just vaultWithRealisticRekey)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      allSent <- readIORef allSentRef
      -- Should NOT contain "Rekey failed" — it should succeed with firstTimeSetup
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldNotContain` "Rekey failed"
      combined `shouldNotContain` "VaultNotFound"
      -- Should indicate successful vault creation
      combined `shouldContain` "created"

  describe "vault commands — with mock vault" $ do
    let mkEnvWithVault sentRef vault = do
          vaultRef    <- newIORef (Just vault)
          providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef    <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/vault setup presents menu with passphrase option" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["bad"]  -- invalid choice to end quickly
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      allSent <- readIORef allSentRef
      let menuMsg = last allSent  -- menu is sent first (list is in reverse)
      T.unpack menuMsg `shouldContain` "Passphrase"
      T.unpack menuMsg `shouldContain` "Choose your vault"

    it "/vault setup shows detected plugins in menu" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["bad"]  -- invalid choice to end quickly
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let yubikey = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
          env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [yubikey] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      allSent <- readIORef allSentRef
      let menuMsg = last allSent
      T.unpack menuMsg `shouldContain` "YubiKey PIV"
      T.unpack menuMsg `shouldContain` "2."  -- yubikey should be option 2

    it "/vault setup rekeys existing vault with passphrase" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      -- User picks "1" (passphrase), then enters passphrase, then confirms rekey
      msgsRef <- newIORef ["1", "test-passphrase", "y"]
      vault <- mkMockVaultHandle
      _ <- _vh_init vault
      vaultRef <- newIORef (Just vault)
      rekeyCalledRef <- newIORef False
      let vaultWithRekey = vault
            { _vh_rekey = \_ _ confirmFn -> do
                writeIORef rekeyCalledRef True
                _ <- confirmFn "Confirm rekey?"
                pure (Right ())
            }
      writeIORef vaultRef (Just vaultWithRekey)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      rekeyCalled <- readIORef rekeyCalledRef
      rekeyCalled `shouldBe` True
      allSent <- readIORef allSentRef
      case allSent of
        (lastMsg:_) -> T.unpack lastMsg `shouldContain` "rekeyed"
        []          -> expectationFailure "Expected messages"

    it "/vault setup rekey cancelled by user" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      -- User picks "1" (passphrase), then enters passphrase, then refuses rekey
      msgsRef <- newIORef ["1", "test-passphrase", "n"]
      vault <- mkMockVaultHandle
      _ <- _vh_init vault
      vaultRef <- newIORef (Just vault)
      let vaultWithRekey = vault
            { _vh_rekey = \_ _ confirmFn -> do
                confirmed <- confirmFn "Confirm rekey?"
                if confirmed
                  then pure (Right ())
                  else pure (Left (VaultCorrupted "rekey cancelled by user"))
            }
      writeIORef vaultRef (Just vaultWithRekey)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      allSent <- readIORef allSentRef
      case allSent of
        (lastMsg:_) -> T.unpack lastMsg `shouldContain` "cancelled"
        []          -> expectationFailure "Expected messages"

    it "/vault setup passphrase read error" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["1"]  -- pick passphrase
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let ch = mkMockChannelAll allSentRef msgsRef
          env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = ch
                { _ch_promptSecret = \_ -> ioError (userError "readSecret not supported") }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultSetup) ctx
      allSent <- readIORef allSentRef
      case allSent of
        (lastMsg:_) -> T.unpack lastMsg `shouldContain` "Error reading passphrase"
        []          -> expectationFailure "Expected messages"

    it "/vault list with empty vault" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultList) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "empty"
        Nothing -> expectationFailure "Expected message"

    it "/vault list with secrets shows formatted list" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      _ <- _vh_put vault "alpha" "v1"
      _ <- _vh_put vault "beta" "v2"
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultList) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "alpha"
          T.unpack t `shouldContain` "beta"
        Nothing -> expectationFailure "Expected message"

    it "/vault lock delegates to handle and sends confirmation" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultLock) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "locked"
        Nothing -> expectationFailure "Expected message"
      -- Verify vault is actually locked
      status <- _vh_status vault
      _vs_locked status `shouldBe` True

    it "/vault unlock delegates to handle" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      -- Lock first
      _vh_lock vault
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultUnlock) ctx
      status <- _vh_status vault
      _vs_locked status `shouldBe` False

    it "/vault status formats the status block" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      _ <- _vh_put vault "key1" "val"
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault VaultStatus') ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "State"
          T.unpack t `shouldContain` "Secrets"
          T.unpack t `shouldContain` "Key"
        Nothing -> expectationFailure "Expected message"

    it "/vault delete with confirmation deletes secret" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      msgsRef <- newIORef ["y"]
      vault <- mkMockVaultHandle
      _ <- _vh_put vault "todelete" "val"
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultDelete "todelete")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldNotContain` "Cancelled"
        Nothing -> expectationFailure "Expected message"
      -- Secret should be gone
      result <- _vh_get vault "todelete"
      result `shouldBe` Left (VaultCorrupted "no such key")

    it "/vault delete with cancellation does not delete" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      msgsRef <- newIORef ["n"]
      vault <- mkMockVaultHandle
      _ <- _vh_put vault "keep" (TE.encodeUtf8 "val")
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultDelete "keep")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Cancelled"
        Nothing -> expectationFailure "Expected message"
      -- Secret should still be there
      result <- _vh_get vault "keep"
      result `shouldBe` Right (TE.encodeUtf8 "val")

    it "/vault add on non-CLI channel sends error message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      vaultRef    <- newIORef (Just vault)
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send         = writeIORef sentRef . Just . _om_content
                , _ch_promptSecret = \_ -> ioError (userError "readSecret not supported")
                }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultAdd "mykey")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Error reading secret"
        Nothing -> expectationFailure "Expected error message"

    it "/vault unknown subcommand refers to /vault" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultUnknown "foo")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Unknown vault command"
          T.unpack t `shouldContain` "/vault"
        Nothing -> expectationFailure "Expected help text"

  describe "allCommandSpecs / CommandSpec registry" $ do
    it "is non-empty" $
      length allCommandSpecs `shouldSatisfy` (> 0)

    it "every spec parses its own syntax keyword" $
      -- Each spec's _cs_parse should recognise the command it was built for.
      -- We verify this by checking that parseSlashCommand can find all
      -- non-argument commands (the ones whose syntax has no '<').
      let noArgSpecs = filter (not . T.isInfixOf "<" . _cs_syntax) allCommandSpecs
      in mapM_ (\s -> parseSlashCommand (_cs_syntax s) `shouldSatisfy` (not . null)) noArgSpecs

    it "parseSlashCommand covers all spec syntaxes (no orphan specs)" $
      -- No spec should produce Nothing when its own syntax is parsed.
      -- Argument-bearing commands ("/vault add <name>") need a concrete arg,
      -- so we only test exact-match specs here.
      let exactSpecs = filter (not . T.isInfixOf "<" . _cs_syntax) allCommandSpecs
      in mapM_ (\s -> parseSlashCommand (_cs_syntax s) `shouldSatisfy` (not . null)) exactSpecs

  describe "parseSlashCommand — /help" $ do
    it "parses /help" $
      parseSlashCommand "/help" `shouldBe` Just CmdHelp

    it "parses /HELP (case-insensitive)" $
      parseSlashCommand "/HELP" `shouldBe` Just CmdHelp

    it "parses /Help with surrounding whitespace" $
      parseSlashCommand "  /help  " `shouldBe` Just CmdHelp

  describe "executeSlashCommand — /help" $ do
    it "/help sends a message containing all command syntaxes" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdHelp ctx
      sent <- readIORef sentRef
      case sent of
        Nothing -> expectationFailure "Expected /help output"
        Just t  -> do
          -- Every spec syntax should appear in the /help output
          mapM_ (\s -> T.unpack t `shouldContain` T.unpack (_cs_syntax s)) allCommandSpecs

    it "/help output contains group headings" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdHelp ctx
      sent <- readIORef sentRef
      case sent of
        Nothing -> expectationFailure "Expected /help output"
        Just t  -> do
          T.unpack t `shouldContain` "Session"
          T.unpack t `shouldContain` "Provider"
          T.unpack t `shouldContain` "Vault"

    it "/help does not modify context" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      ctx' <- executeSlashCommand env CmdHelp ctx
      ctx' `shouldBe` ctx

  describe "SlashCommand" $ do
    it "has Show and Eq instances" $ do
      show CmdNew `shouldContain` "CmdNew"
      CmdNew `shouldBe` CmdNew
      CmdNew `shouldNotBe` CmdHelp

    it "CmdHelp has Show and Eq instances" $ do
      show CmdHelp `shouldContain` "CmdHelp"
      CmdHelp `shouldBe` CmdHelp
      CmdHelp `shouldNotBe` CmdNew

    it "vault subcommands have Show and Eq instances" $ do
      show (CmdVault VaultList) `shouldContain` "VaultList"
      CmdVault VaultList `shouldBe` CmdVault VaultList
      CmdVault VaultList `shouldNotBe` CmdVault VaultLock

    it "provider subcommands have Show and Eq instances" $ do
      show (CmdProvider ProviderList) `shouldContain` "ProviderList"
      CmdProvider ProviderList `shouldBe` CmdProvider ProviderList
      CmdProvider ProviderList `shouldNotBe` CmdProvider (ProviderConfigure "x")

    it "transcript subcommands have Show and Eq instances" $ do
      show (CmdTranscript TranscriptPath) `shouldContain` "TranscriptPath"
      CmdTranscript TranscriptPath `shouldBe` CmdTranscript TranscriptPath
      CmdTranscript TranscriptPath `shouldNotBe` CmdTranscript (TranscriptRecent Nothing)

  describe "discoverHarnesses" $ do
    it "returns empty map when no tmux session exists" $ do
      let th = mkNoOpTranscriptHandle
      -- Use a unique session name that won't collide with a running pureclaw
      (harnesses, nextIdx) <- discoverHarnessesIn "pureclaw-test-no-session" th
      Map.null harnesses `shouldBe` True
      nextIdx `shouldBe` 0

    it "discovers harnesses from tmux session (integration)" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-discover"
          -- Start the session and rename window 0 to look like a harness
          _ <- startTmuxSession sName
          renameWindow sName 0 "claude-code-0"
          let th = mkNoOpTranscriptHandle
          (harnesses, nextIdx) <- discoverHarnessesIn sName th
          -- Should discover the harness
          Map.member "claude-code-0" harnesses `shouldBe` True
          nextIdx `shouldBe` 1
          -- Verify the handle has the right name
          case Map.lookup "claude-code-0" harnesses of
            Just hh -> _hh_name hh `shouldBe` "Claude Code"
            Nothing -> expectationFailure "expected claude-code-0 in map"
          -- Clean up
          stopTmuxSession sName

  describe "parseSlashCommand — /transcript" $ do
    it "parses /transcript as TranscriptRecent Nothing" $
      parseSlashCommand "/transcript" `shouldBe` Just (CmdTranscript (TranscriptRecent Nothing))

    it "parses /transcript 50 as TranscriptRecent (Just 50)" $
      parseSlashCommand "/transcript 50" `shouldBe` Just (CmdTranscript (TranscriptRecent (Just 50)))

    it "parses /transcript search ollama as TranscriptSearch" $
      parseSlashCommand "/transcript search ollama" `shouldBe` Just (CmdTranscript (TranscriptSearch "ollama"))

    it "parses /transcript path as TranscriptPath" $
      parseSlashCommand "/transcript path" `shouldBe` Just (CmdTranscript TranscriptPath)

    it "parses /transcript unknown as TranscriptUnknown" $
      parseSlashCommand "/transcript unknown" `shouldBe` Just (CmdTranscript (TranscriptUnknown "unknown"))

    it "is case-insensitive on keywords" $
      parseSlashCommand "/TRANSCRIPT PATH" `shouldBe` Just (CmdTranscript TranscriptPath)

    it "preserves argument case for search" $
      parseSlashCommand "/transcript search Ollama" `shouldBe` Just (CmdTranscript (TranscriptSearch "Ollama"))

  describe "executeSlashCommand — /transcript" $ do
    it "/transcript recent on a no-op session reports no entries" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptRecent Nothing)) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No entries found"
        Nothing -> expectationFailure "Expected message"

    it "/transcript path returns the file path" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let th = mkNoOpTranscriptHandle { _th_getPath = pure "/tmp/test-transcript.jsonl" }
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript TranscriptPath) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "/tmp/test-transcript.jsonl"
        Nothing -> expectationFailure "Expected path message"

    it "/transcript recent returns formatted entries" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      now <- getCurrentTime
      let entry = TranscriptEntry
            { _te_id            = "uuid-1"
            , _te_timestamp     = now
            , _te_harness       = Nothing
            , _te_model         = Just "ollama/llama3"
            , _te_direction     = Request
            , _te_payload       = "base64data"
            , _te_durationMs    = Just 42
            , _te_correlationId = "corr-1"
            , _te_metadata      = Map.empty
            }
          th = mkNoOpTranscriptHandle { _th_query = \_ -> pure [entry] }
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptRecent Nothing)) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "ollama/llama3"
          T.unpack t `shouldContain` "Request"
          T.unpack t `shouldContain` "42ms"
        Nothing -> expectationFailure "Expected formatted entries"

    it "/transcript recent with empty results shows message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let th = mkNoOpTranscriptHandle { _th_query = \_ -> pure [] }
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptRecent Nothing)) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No entries"
        Nothing -> expectationFailure "Expected empty message"

    it "/transcript search queries with source filter" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      now <- getCurrentTime
      let matchEntry = TranscriptEntry
            { _te_id            = "uuid-m"
            , _te_timestamp     = now
            , _te_harness       = Nothing
            , _te_model         = Just "ollama"
            , _te_direction     = Request
            , _te_payload       = "base64data"
            , _te_durationMs    = Nothing
            , _te_correlationId = "corr-m"
            , _te_metadata      = Map.empty
            }
          noMatchEntry = TranscriptEntry
            { _te_id            = "uuid-n"
            , _te_timestamp     = now
            , _te_harness       = Nothing
            , _te_model         = Just "claude"
            , _te_direction     = Request
            , _te_payload       = "base64data"
            , _te_durationMs    = Nothing
            , _te_correlationId = "corr-n"
            , _te_metadata      = Map.empty
            }
          th = mkNoOpTranscriptHandle
            { _th_query = \_ -> pure [matchEntry, noMatchEntry]
            }
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptSearch "ollama")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "ollama"
          T.unpack t `shouldNotContain` "claude"
        Nothing -> expectationFailure "Expected search results"

    it "/transcript unknown shows error message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let th = mkNoOpTranscriptHandle
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptUnknown "badcmd")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Unknown transcript command"
          T.unpack t `shouldContain` "badcmd"
        Nothing -> expectationFailure "Expected error message"

    it "/transcript path with no transcript configured shows helpful message" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript TranscriptPath) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No transcript configured"
        Nothing -> expectationFailure "Expected message"

    it "/help contains Transcript group heading" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef    <- newIORef (ModelId "test")
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      sessionRef <- newIORef =<< mkNoOpSessionHandle
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdHelp ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Transcript"
        Nothing -> expectationFailure "Expected /help output"

    it "/transcript response without duration omits ms suffix" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      now <- getCurrentTime
      let entry = TranscriptEntry
            { _te_id            = "uuid-2"
            , _te_timestamp     = now
            , _te_harness       = Just "claude-code"
            , _te_model         = Nothing
            , _te_direction     = Response
            , _te_payload       = "base64data"
            , _te_durationMs    = Nothing
            , _te_correlationId = "corr-2"
            , _te_metadata      = Map.empty
            }
          th = mkNoOpTranscriptHandle { _th_query = \_ -> pure [entry] }
      sessionRef <- do
        base <- mkNoOpSessionHandle
        newIORef base { _sh_transcript = th }
      harnessRef    <- newIORef Map.empty
      targetRef     <- newIORef TargetProvider
      windowIdxRef  <- newIORef 0
      vaultRef      <- newIORef Nothing
      providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
      modelRef      <- newIORef (ModelId "test")
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdTranscript (TranscriptRecent Nothing)) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "claude-code"
          T.unpack t `shouldContain` "Response"
          T.unpack t `shouldNotContain` "ms"
        Nothing -> expectationFailure "Expected formatted entries"

  -- -------------------------------------------------------------------------
  -- /agent commands (WU1 Session D)
  -- -------------------------------------------------------------------------

  describe "parseSlashCommand — /agent" $ do
    it "parses /agent list" $
      parseSlashCommand "/agent list" `shouldBe` Just (CmdAgent AgentList)

    it "parses /AGENT LIST case-insensitively" $
      parseSlashCommand "/AGENT LIST" `shouldBe` Just (CmdAgent AgentList)

    it "parses /agent info with no argument" $
      parseSlashCommand "/agent info" `shouldBe` Just (CmdAgent (AgentInfo Nothing))

    it "parses /agent info <name> preserving case" $
      parseSlashCommand "/agent info Zoe" `shouldBe` Just (CmdAgent (AgentInfo (Just "Zoe")))

    it "/agent start is no longer recognised (use /session new)" $
      parseSlashCommand "/agent start zoe" `shouldBe` Just (CmdAgent (AgentUnknown "start"))

    it "parses /agent default (no arg)" $
      parseSlashCommand "/agent default" `shouldBe` Just (CmdAgent (AgentDefault Nothing))

    it "parses /agent default <name>" $
      parseSlashCommand "/agent default zoe" `shouldBe` Just (CmdAgent (AgentDefault (Just "zoe")))

    it "returns AgentUnknown for bare /agent" $
      parseSlashCommand "/agent" `shouldBe` Just (CmdAgent (AgentUnknown ""))

  describe "executeSlashCommand — /agent list" $ do
    let mkAgentEnv sentRef = do
          vaultRef      <- newIORef Nothing
          providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef      <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/agent list lists discovered agent names" $ withTempHome $ do
      home <- getEnv "HOME"
      let agentsDir = home </> ".pureclaw" </> "agents"
      Dir.createDirectoryIfMissing True (agentsDir </> "zoe")
      Dir.createDirectoryIfMissing True (agentsDir </> "ops")
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkAgentEnv sentRef
      _ <- executeSlashCommand env (CmdAgent AgentList) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "zoe"
          T.unpack t `shouldContain` "ops"
        Nothing -> expectationFailure "Expected /agent list output"

    it "/agent list with no agents dir shows helpful message" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkAgentEnv sentRef
      _ <- executeSlashCommand env (CmdAgent AgentList) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain`
          "No agents found. Create one at ~/.pureclaw/agents/<name>/"
        Nothing -> expectationFailure "Expected empty message"

  describe "executeSlashCommand — /agent info" $ do
    let mkAgentEnv2 sentRef = do
          vaultRef      <- newIORef Nothing
          providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef      <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/agent info <name> shows files and frontmatter" $ withTempHome $ do
      home <- getEnv "HOME"
      let zoeDir = home </> ".pureclaw" </> "agents" </> "zoe"
      Dir.createDirectoryIfMissing True zoeDir
      writeFile (zoeDir </> "SOUL.md") "soul body"
      writeFile (zoeDir </> "AGENTS.md") "---\nmodel = \"claude-opus\"\n---\nbody"
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkAgentEnv2 sentRef
      _ <- executeSlashCommand env (CmdAgent (AgentInfo (Just "zoe"))) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "zoe"
          T.unpack t `shouldContain` "SOUL.md"
          T.unpack t `shouldContain` "AGENTS.md"
          T.unpack t `shouldContain` "claude-opus"
        Nothing -> expectationFailure "Expected /agent info output"

    it "/agent info <name> for missing agent lists available" $ withTempHome $ do
      home <- getEnv "HOME"
      let agentsDir = home </> ".pureclaw" </> "agents"
      Dir.createDirectoryIfMissing True (agentsDir </> "zoe")
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkAgentEnv2 sentRef
      _ <- executeSlashCommand env (CmdAgent (AgentInfo (Just "nonexistent"))) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Agent \"nonexistent\" not found"
          T.unpack t `shouldContain` "Available agents"
          T.unpack t `shouldContain` "zoe"
        Nothing -> expectationFailure "Expected not-found message"

    it "/agent info with no argument reports no agent selected" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkAgentEnv2 sentRef
      _ <- executeSlashCommand env (CmdAgent (AgentInfo Nothing)) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "No agent selected. Use --agent <name>."
        Nothing -> expectationFailure "Expected no-agent-selected message"

  describe "agent name tab completion" $ do
    it "agentNameMatches returns all names on empty prefix" $
      agentNameMatches ["zoe", "ops", "alice"] "" `shouldMatchList` ["zoe", "ops", "alice"]

    it "agentNameMatches filters by prefix" $
      agentNameMatches ["zoe", "ops", "zeus"] "z" `shouldMatchList` ["zoe", "zeus"]

    it "agentNameMatches is case-insensitive" $
      agentNameMatches ["Zoe", "Ops"] "z" `shouldMatchList` ["Zoe"]

    it "agentNameMatches returns empty for empty candidate list" $
      agentNameMatches [] "z" `shouldBe` []

  describe "parseSlashCommand — /session" $ do
    it "parses /session new" $
      parseSlashCommand "/session new" `shouldBe` Just (CmdSession (SessionNew Nothing Nothing))

    it "parses /session new <agent>" $
      parseSlashCommand "/session new zoe"
        `shouldBe` Just (CmdSession (SessionNew (Just "zoe") Nothing))

    it "parses /session new <agent> --target <name>" $
      parseSlashCommand "/session new zoe --target claude-code-0"
        `shouldBe` Just (CmdSession (SessionNew (Just "zoe") (Just "claude-code-0")))

    it "parses /session new --target <name> (no agent)" $
      parseSlashCommand "/session new --target claude-code-0"
        `shouldBe` Just (CmdSession (SessionNew Nothing (Just "claude-code-0")))

    it "parses /session new case-insensitively" $
      parseSlashCommand "/SESSION NEW zoe --TARGET claude-code-0"
        `shouldBe` Just (CmdSession (SessionNew (Just "zoe") (Just "claude-code-0")))

    it "parses /session list (no arg)" $
      parseSlashCommand "/session list" `shouldBe` Just (CmdSession (SessionList Nothing))

    it "parses /session list <agent>" $
      parseSlashCommand "/session list zoe" `shouldBe` Just (CmdSession (SessionList (Just "zoe")))

    it "parses /session resume <id>" $
      parseSlashCommand "/session resume abc-123" `shouldBe` Just (CmdSession (SessionResume "abc-123"))

    it "rejects /session resume with no argument (falls through to unknown)" $
      parseSlashCommand "/session resume" `shouldBe` Just (CmdSession (SessionUnknown "resume"))

    it "parses /session last" $
      parseSlashCommand "/session last" `shouldBe` Just (CmdSession SessionLast)

    it "parses /last as /session last alias" $
      parseSlashCommand "/last" `shouldBe` Just (CmdSession SessionLast)

    it "parses /session info" $
      parseSlashCommand "/session info" `shouldBe` Just (CmdSession SessionInfo)

    it "/session reset falls through to unknown (removed — sessions are immutable)" $
      parseSlashCommand "/session reset" `shouldBe` Just (CmdSession (SessionUnknown "reset"))

    it "parses /session compact" $
      parseSlashCommand "/session compact" `shouldBe` Just (CmdSession SessionCompact)

    it "parses /session case-insensitively" $
      parseSlashCommand "/SESSION NEW" `shouldBe` Just (CmdSession (SessionNew Nothing Nothing))

    it "parses bare /session as unknown" $
      parseSlashCommand "/session" `shouldBe` Just (CmdSession (SessionUnknown ""))

    it "parses /session foo as unknown subcommand" $
      parseSlashCommand "/session foo" `shouldBe` Just (CmdSession (SessionUnknown "foo"))

    it "/new still parses to CmdNew (backward compat)" $
      parseSlashCommand "/new" `shouldBe` Just CmdNew

    it "/reset is no longer recognised (sessions are immutable)" $
      parseSlashCommand "/reset" `shouldBe` Nothing

    it "/status still parses to CmdStatus (backward compat)" $
      parseSlashCommand "/status" `shouldBe` Just CmdStatus

    it "/compact still parses to CmdCompact (backward compat)" $
      parseSlashCommand "/compact" `shouldBe` Just CmdCompact

  describe "executeSlashCommand — /session" $ do
    let mkSessionEnv sentRef = do
          vaultRef      <- newIORef Nothing
          providerRef   <- newIORef (Just (MkProvider (MockProvider "summary")))
          modelRef      <- newIORef (ModelId "test")
          harnessRef    <- newIORef Map.empty
          targetRef     <- newIORef TargetProvider
          windowIdxRef  <- newIORef 0
          sessionRef <- newIORef =<< mkNoOpSessionHandle
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = modelRef
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            , _env_policy       = defaultPolicy
            , _env_harnesses    = harnessRef
            , _env_target       = targetRef
            , _env_nextWindowIdx = windowIdxRef
            , _env_agentDef      = Nothing
            , _env_session       = sessionRef
            , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
            }

    it "/session new writes session.json on disk and returns a confirmation" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "New session created:"
        Nothing -> expectationFailure "Expected new-session confirmation"
      -- Verify a session.json was written under the sessions dir
      home <- getEnv "HOME"
      let sessionsDir = home </> ".pureclaw" </> "sessions"
      entries <- Dir.listDirectory sessionsDir
      entries `shouldSatisfy` (not . null)

    it "/session new clears messages" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let ctx = addMessage (textMessage User "hello") (emptyContext (Just "sys"))
      ctx' <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) ctx
      contextMessages ctx' `shouldBe` []

    it "/session new --target rejects when target is not running" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let ctx = emptyContext Nothing
      ctx' <- executeSlashCommand env (CmdSession (SessionNew Nothing (Just "ghost-0"))) ctx
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "not running"
        Nothing -> expectationFailure "Expected error about target not running"
      -- Context should be unchanged (no clear)
      contextMessages ctx' `shouldBe` contextMessages ctx

    it "/session new --target creates session with RTHarness when harness exists" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let harnessName = "claude-code-0"
          mockHarness = mkNoOpHarnessHandle { _hh_name = harnessName }
      writeIORef (_env_harnesses env) (Map.singleton harnessName mockHarness)
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing (Just harnessName))) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> do
          T.unpack t `shouldContain` "New session created:"
          T.unpack t `shouldContain` "harness:claude-code-0"
        Nothing -> expectationFailure "Expected session creation confirmation"
      activeHandle <- readIORef (_env_session env)
      meta <- readIORef (_sh_meta activeHandle)
      _sm_runtime meta `shouldBe` RTHarness harnessName

    it "/session new --target sets target to TargetHarness" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let harnessName = "claude-code-0"
          mockHarness = mkNoOpHarnessHandle { _hh_name = harnessName }
      writeIORef (_env_harnesses env) (Map.singleton harnessName mockHarness)
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing (Just harnessName))) (emptyContext Nothing)
      target <- readIORef (_env_target env)
      target `shouldBe` TargetHarness harnessName

    it "/session new (no target) sets target to TargetProvider" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      writeIORef (_env_target env) (TargetHarness "something")
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      target <- readIORef (_env_target env)
      target `shouldBe` TargetProvider

    it "/session list with empty dir shows 'No sessions found.'" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      _ <- executeSlashCommand env (CmdSession (SessionList Nothing)) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "No sessions found."
        Nothing -> expectationFailure "Expected empty-list message"

    it "/session list lists existing sessions" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      -- Create two sessions
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      writeIORef sentRef Nothing
      _ <- executeSlashCommand env (CmdSession (SessionList Nothing)) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "Sessions:"
        Nothing -> expectationFailure "Expected list output"

    it "/session resume missing returns not-found message" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      _ <- executeSlashCommand env (CmdSession (SessionResume "ghost")) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "No session matching ghost found."
        Nothing -> expectationFailure "Expected not-found message"

    it "/session resume <exact-id> returns a Resumed message" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      -- Create a session
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      home <- getEnv "HOME"
      let sessionsDir = home </> ".pureclaw" </> "sessions"
      entries <- Dir.listDirectory sessionsDir
      case entries of
        (sid : _) -> do
          writeIORef sentRef Nothing
          _ <- executeSlashCommand env (CmdSession (SessionResume (T.pack sid))) (emptyContext Nothing)
          sent <- readIORef sentRef
          case sent of
            Just t  -> T.unpack t `shouldContain` "Resumed session"
            Nothing -> expectationFailure "Expected resume confirmation"
        [] -> expectationFailure "Expected at least one session dir"

    it "/session last with no sessions reports none" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      _ <- executeSlashCommand env (CmdSession SessionLast) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "No sessions found."
        Nothing -> expectationFailure "Expected empty message"

    it "/session last resumes most recent after creating" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      writeIORef sentRef Nothing
      _ <- executeSlashCommand env (CmdSession SessionLast) (emptyContext Nothing)
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "Resumed session"
        Nothing -> expectationFailure "Expected resume confirmation"

    it "/session new swaps the active session in _env_session IORef" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      -- Read the initial session id (from the no-op handle)
      initialHandle <- readIORef (_env_session env)
      initialMeta   <- readIORef (_sh_meta initialHandle)
      let initialId = _sm_id initialMeta
      -- Run /session new
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      -- The active session handle should now point at a different SessionMeta
      -- with a fresh ID. If the implementation used `_ <- mkSessionHandle ...`
      -- (discard), this assertion fails because _env_session still holds the
      -- no-op handle with id "noop".
      newHandle <- readIORef (_env_session env)
      newMeta   <- readIORef (_sh_meta newHandle)
      let newId = _sm_id newMeta
      newId `shouldNotBe` initialId
      unSessionId newId `shouldNotBe` "noop"

    it "/session resume swaps the active session to the resumed one" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      -- Create two sessions via /session new so we have two on disk.
      -- Delay between creates so the millisecond-resolution session IDs differ.
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      threadDelay 2000  -- 2 ms
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      -- After the second /session new, the active session is the second one.
      activeAfterSecond <- readIORef (_env_session env)
      metaAfterSecond   <- readIORef (_sh_meta activeAfterSecond)
      let secondId = _sm_id metaAfterSecond
      -- Enumerate sessions on disk and pick one that is NOT the current active.
      home <- getEnv "HOME"
      let sessionsDir = home </> ".pureclaw" </> "sessions"
      entries <- Dir.listDirectory sessionsDir
      let otherIds = filter (/= T.unpack (unSessionId secondId)) entries
      case otherIds of
        (otherSid : _) -> do
          _ <- executeSlashCommand env
                 (CmdSession (SessionResume (T.pack otherSid)))
                 (emptyContext Nothing)
          -- Verify the active session is now `otherSid`.
          afterHandle <- readIORef (_env_session env)
          afterMeta   <- readIORef (_sh_meta afterHandle)
          T.unpack (unSessionId (_sm_id afterMeta)) `shouldBe` otherSid
          _sm_id afterMeta `shouldNotBe` secondId
        [] -> expectationFailure "Expected at least two sessions on disk"

    it "/session last swaps the active session to the most recent on disk" $ withTempHome $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      -- Create a session and capture its id.
      _ <- executeSlashCommand env (CmdSession (SessionNew Nothing Nothing)) (emptyContext Nothing)
      createdHandle <- readIORef (_env_session env)
      createdMeta   <- readIORef (_sh_meta createdHandle)
      let createdId = _sm_id createdMeta
      -- Replace the active handle with a fresh no-op so we can observe the swap.
      noop <- mkNoOpSessionHandle
      writeIORef (_env_session env) noop
      -- /session last should swap the active handle back to the recent session.
      _ <- executeSlashCommand env (CmdSession SessionLast) (emptyContext Nothing)
      afterHandle <- readIORef (_env_session env)
      afterMeta   <- readIORef (_sh_meta afterHandle)
      _sm_id afterMeta `shouldBe` createdId
      unSessionId (_sm_id afterMeta) `shouldNotBe` "noop"

    it "/session info shows session fields" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let ctx = recordUsage (Just (Usage 42 17))
              $ addMessage (textMessage User "hello")
              $ emptyContext Nothing
      _ <- executeSlashCommand env (CmdSession SessionInfo) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Session info:"
          T.unpack t `shouldContain` "Session:"
          T.unpack t `shouldContain` "Runtime:"
          T.unpack t `shouldContain` "Messages:"
          T.unpack t `shouldContain` "42"
          T.unpack t `shouldContain` "17"
        Nothing -> expectationFailure "Expected session info output"

    it "/session compact routes through compact handler" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      env <- mkSessionEnv sentRef
      let ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      _ <- executeSlashCommand env (CmdSession SessionCompact) ctx
      sent <- readIORef sentRef
      case sent of
        Just t  -> T.unpack t `shouldContain` "few messages"
        Nothing -> expectationFailure "Expected compact message"

  describe "session id tab completion" $ do
    it "sessionIdMatches returns all on empty prefix" $
      sessionIdMatches ["a-1", "b-2", "c-3"] "" `shouldMatchList` ["a-1", "b-2", "c-3"]

    it "sessionIdMatches filters by prefix" $
      sessionIdMatches ["zoe-1", "ops-2", "zoe-3"] "zoe" `shouldMatchList` ["zoe-1", "zoe-3"]

    it "sessionIdMatches is case-insensitive" $
      sessionIdMatches ["Zoe-1", "Ops-2"] "z" `shouldMatchList` ["Zoe-1"]

    it "sessionIdMatches on empty candidate list is empty" $
      sessionIdMatches [] "x" `shouldBe` []
