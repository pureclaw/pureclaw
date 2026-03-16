module Agent.SlashCommandsSpec (spec) where

import Control.Exception
import Data.ByteString (ByteString)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Environment (setEnv, getEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Plugin
import PureClaw.Tools.Registry

-- | Mock provider for testing.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider summary) _ = pure CompletionResponse
    { _crsp_content = [TextBlock summary]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

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

    it "parses /reset" $ do
      parseSlashCommand "/reset" `shouldBe` Just CmdReset

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

  describe "executeSlashCommand" $ do
    let mkEnv sentRef = do
          vaultRef    <- newIORef Nothing
          providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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

    it "/reset clears everything except system prompt" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "hello")
              $ emptyContext (Just "sys")
      env <- mkEnv sentRef
      ctx' <- executeSlashCommand env CmdReset ctx
      contextMessages ctx' `shouldBe` []
      contextTotalInputTokens ctx' `shouldBe` 0
      contextSystemPrompt ctx' `shouldBe` Just "sys"

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
          T.unpack t `shouldContain` "Messages: 1"
          T.unpack t `shouldContain` "100"
          T.unpack t `shouldContain` "50"
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdProvider (ProviderConfigure "badname")) ctx
      allSent <- readIORef allSentRef
      let combined = T.unpack (T.intercalate " " allSent)
      combined `shouldContain` "Unknown provider"
      combined `shouldContain` "Supported providers"

  describe "vault commands — no vault configured" $ do
    let mkEnvNoVault sentRef = do
          vaultRef    <- newIORef Nothing
          providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
          pure AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            }

    it "/vault setup presents menu with passphrase option" $ withTempHome $ do
      allSentRef <- newIORef ([] :: [Text])
      msgsRef <- newIORef ["bad"]  -- invalid choice to end quickly
      vaultRef    <- newIORef Nothing
      providerRef <- newIORef (Just (MkProvider (MockProvider "summary")))
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let yubikey = AgePlugin
            { _ap_name   = "yubikey"
            , _ap_binary = "age-plugin-yubikey"
            , _ap_label  = "YubiKey PIV"
            }
          env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [yubikey] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannelAll allSentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let ch = mkMockChannelAll allSentRef msgsRef
          env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = ch
                { _ch_promptSecret = \_ -> ioError (userError "readSecret not supported") }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkMockChannel sentRef msgsRef
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send         = writeIORef sentRef . Just . _om_content
                , _ch_promptSecret = \_ -> ioError (userError "readSecret not supported")
                }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            }
          ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultAdd "mykey")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Error reading secret"
        Nothing -> expectationFailure "Expected error message"

    it "/vault unknown subcommand refers to /help" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      vault <- mkMockVaultHandle
      env <- mkEnvWithVault sentRef vault
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env (CmdVault (VaultUnknown "foo")) ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> do
          T.unpack t `shouldContain` "Unknown vault command"
          T.unpack t `shouldContain` "/help"
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
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
      let env = AgentEnv
            { _env_provider     = providerRef
            , _env_model        = ModelId "test"
            , _env_channel      = mkNoOpChannelHandle
                { _ch_send = writeIORef sentRef . Just . _om_content }
            , _env_logger       = mkNoOpLogHandle
            , _env_systemPrompt = Nothing
            , _env_registry     = emptyRegistry
            , _env_vault        = vaultRef
            , _env_pluginHandle = mkMockPluginHandle [] (\_ -> Left (AgeError "mock"))
            }
          ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      ctx' <- executeSlashCommand env CmdHelp ctx
      ctx' `shouldBe` ctx

  describe "SlashCommand" $ do
    it "has Show and Eq instances" $ do
      show CmdNew `shouldContain` "CmdNew"
      CmdNew `shouldBe` CmdNew
      CmdNew `shouldNotBe` CmdReset

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
