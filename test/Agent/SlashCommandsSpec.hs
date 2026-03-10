module Agent.SlashCommandsSpec (spec) where

import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Mock provider for testing.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider summary) _ = pure CompletionResponse
    { _crsp_content = [TextBlock summary]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

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
    let mkEnv sentRef = AgentEnv
          { _env_provider     = MkProvider (MockProvider "summary")
          , _env_model        = ModelId "test"
          , _env_channel      = mkNoOpChannelHandle
              { _ch_send = writeIORef sentRef . Just . _om_content }
          , _env_logger       = mkNoOpLogHandle
          , _env_systemPrompt = Nothing
          , _env_registry     = emptyRegistry
          }

    it "/new clears messages but keeps system prompt" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = addMessage (textMessage User "hello")
              $ emptyContext (Just "sys")
          env = mkEnv sentRef
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
          env = mkEnv sentRef
      ctx' <- executeSlashCommand env CmdNew ctx
      contextTotalInputTokens ctx' `shouldBe` 100

    it "/reset clears everything except system prompt" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "hello")
              $ emptyContext (Just "sys")
          env = mkEnv sentRef
      ctx' <- executeSlashCommand env CmdReset ctx
      contextMessages ctx' `shouldBe` []
      contextTotalInputTokens ctx' `shouldBe` 0
      contextSystemPrompt ctx' `shouldBe` Just "sys"

    it "/status shows session info" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "hello world")
              $ emptyContext Nothing
          env = mkEnv sentRef
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
          env = mkEnv sentRef
      _ <- executeSlashCommand env CmdCompact ctx
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "few messages"
        Nothing -> expectationFailure "Expected compact message"

    it "/compact with many messages compacts" $ do
      sentRef <- newIORef (Nothing :: Maybe Text)
      let msgs = [textMessage User ("msg" <> T.pack (show i)) | i <- [(1::Int)..20]]
          ctx = foldl (flip addMessage) (emptyContext Nothing) msgs
          env = mkEnv sentRef
      ctx' <- executeSlashCommand env CmdCompact ctx
      contextMessageCount ctx' `shouldSatisfy` (< 20)
      sent <- readIORef sentRef
      case sent of
        Just t -> T.unpack t `shouldContain` "Compacted"
        Nothing -> expectationFailure "Expected compact message"

  describe "SlashCommand" $ do
    it "has Show and Eq instances" $ do
      show CmdNew `shouldContain` "CmdNew"
      CmdNew `shouldBe` CmdNew
      CmdNew `shouldNotBe` CmdReset
