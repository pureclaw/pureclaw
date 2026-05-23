module PureClaw.Frontend.API
  ( -- * WAI Application
    apiApp
    -- * Environment
  , FrontendEnv (..)
    -- * Response types (exported for testing)
  , HarnessInfo (..)
  , HarnessActivity (..)
  , SessionInfo (..)
  , TranscriptEntryInfo (..)
  , AgentInfo (..)
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM)
import Data.Aeson qualified as Aeson
import Data.Aeson (ToJSON (..), FromJSON (..), object, (.=), (.:), (.:?))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Types
import Network.Wai
import System.Directory (doesFileExist, getFileSize, renameFile)
import System.FilePath ((</>), takeDirectory)

import PureClaw.Agent.AgentDef (AgentDef (..), discoverAgents, mkAgentName, unAgentName)
import PureClaw.Agent.Context
import PureClaw.Core.Types (ModelId (..), SessionId (..), unModelId, unSessionId)
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.BroadcastingTranscript (mkBroadcastingFileTranscriptHandle)
import PureClaw.Frontend.StreamBroker (StreamBroker)
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Harness.ClaudeCode (isIdle)
import PureClaw.Harness.Tmux (captureWindow)
import PureClaw.Providers.Class
import PureClaw.Session.Handle (SessionHandle (..), listSessions, loadRecentMessages, mkSessionHandle)
import PureClaw.Session.Types
import PureClaw.Handles.Transcript
import PureClaw.Transcript.Provider
import PureClaw.Transcript.Types

-- | Runtime environment for the frontend API.
data FrontendEnv = FrontendEnv
  { _fe_harnesses    :: IORef (Map.Map Text HarnessHandle)
    -- ^ Live harness handles from AgentEnv.
  , _fe_sessionsDir  :: FilePath
    -- ^ On-disk sessions directory (e.g. @~\/.pureclaw\/sessions@).
  , _fe_recentLimit  :: Int
    -- ^ Max number of recent sessions to return.
  , _fe_provider     :: IORef (Maybe SomeProvider)
    -- ^ Shared provider ref from AgentEnv.
  , _fe_model        :: IORef (Maybe ModelId)
    -- ^ Shared model ref from AgentEnv.
  , _fe_systemPrompt :: Maybe Text
    -- ^ System prompt for completions.
  , _fe_logger       :: LogHandle
    -- ^ Logger for API operations.
  , _fe_agentsDir    :: FilePath
    -- ^ On-disk agents directory (e.g. @~\/.pureclaw\/agents@).
  , _fe_defaultAgent :: Maybe Text
    -- ^ Default agent name from config.
  , _fe_broker       :: Maybe StreamBroker
    -- ^ Optional in-process broker for live transcript streaming. When
    -- 'Just', the @POST \/sessions\/\<id\>\/send@ completion path opens its
    -- transcript handle via 'mkBroadcastingFileTranscriptHandle' so that
    -- provider Request\/Response entries reach subscribers in real time
    -- (DoD D25). 'Nothing' preserves the legacy non-broadcasting path.
  }

-- | JSON-serializable harness info for the frontend.
data HarnessInfo = HarnessInfo
  { _hi_name     :: Text
  , _hi_activity :: HarnessActivity
  }
  deriving stock (Show, Eq)

instance ToJSON HarnessInfo where
  toJSON hi = object
    [ "name"     .= _hi_name hi
    , "activity" .= _hi_activity hi
    ]

-- | JSON-serializable agent info for the frontend.
data AgentInfo = AgentInfo
  { _ai_name      :: Text
  , _ai_isDefault :: Bool
  }
  deriving stock (Show, Eq)

instance ToJSON AgentInfo where
  toJSON ai = object
    [ "name"      .= _ai_name ai
    , "isDefault" .= _ai_isDefault ai
    ]

-- | JSON-serializable session info for the frontend.
data SessionInfo = SessionInfo
  { _si_id         :: Text
  , _si_agent      :: Maybe Text
  , _si_runtime    :: Text
  , _si_model      :: Text
  , _si_lastActive :: UTCTime
  , _si_createdAt  :: UTCTime
  }
  deriving stock (Show, Eq)

instance ToJSON SessionInfo where
  toJSON si = object
    [ "id"         .= _si_id si
    , "agent"      .= _si_agent si
    , "runtime"    .= _si_runtime si
    , "model"      .= _si_model si
    , "lastActive" .= _si_lastActive si
    , "createdAt"  .= _si_createdAt si
    ]

-- | WAI application handling @\/api\/*@ routes.
apiApp :: FrontendEnv -> Application
apiApp env req respond = do
  let method = requestMethod req
      path   = pathInfo req
  case (method, path) of
    ("GET", ["api", "harnesses"])            -> handleHarnesses env respond
    ("GET", ["api", "sessions", "recent"])   -> handleRecentSessions env respond
    ("GET", ["api", "sessions", sid, "transcript"]) ->
      handleTranscript env sid respond
    ("POST", ["api", "sessions", "new"]) ->
      handleNewSession env req respond
    ("POST", ["api", "sessions", sid, "send"]) ->
      handleSend env sid req respond
    ("PUT", ["api", "sessions", sid, "prompt"]) ->
      handleSetPrompt env sid req respond
    ("GET", ["api", "agents"])               -> handleAgents env respond
    _                                        -> respondNotFound respond

handleHarnesses :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleHarnesses env respond = do
  harnesses <- readIORef (_fe_harnesses env)
  infos <- traverse probeHarness (Map.toList harnesses)
  respond $ jsonResponse status200 infos

-- | Probe a single harness to determine its activity.
-- Checks process status first, then does a quick screen capture
-- to distinguish thinking from idle.
probeHarness :: (Text, HarnessHandle) -> IO HarnessInfo
probeHarness (name, hh) = do
  st <- _hh_status hh
  activity <- case st of
    HarnessExited _ -> pure HarnessStopped
    HarnessRunning  -> probeActivity (_hh_session hh) name
  pure HarnessInfo
    { _hi_name     = name
    , _hi_activity = activity
    }

-- | Capture the tmux window and check if the harness is idle or thinking.
probeActivity :: Text -> Text -> IO HarnessActivity
probeActivity tmuxSession windowName = do
  let target = tmuxSession <> ":" <> extractWindowIdx windowName
  result <- try @SomeException $ captureWindow target 50
  case result of
    Left _        -> pure HarnessIdle
    Right capture -> do
      let screenText = TE.decodeUtf8Lenient capture
      pure $ if isIdle screenText then HarnessIdle else HarnessThinking

-- | Extract the window index suffix from a harness name like "claude-code-0".
extractWindowIdx :: Text -> Text
extractWindowIdx name =
  case T.splitOn "-" name of
    parts | length parts >= 2 -> last parts
    _                         -> "0"

handleRecentSessions :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleRecentSessions env respond = do
  metas <- listSessions (_fe_sessionsDir env) Nothing (_fe_recentLimit env)
  nonEmpty <- filterM (hasTranscriptEntries (_fe_sessionsDir env)) metas
  let infos = map toSessionInfo nonEmpty
  respond $ jsonResponse status200 infos

-- | Check whether a session has at least one transcript entry.
hasTranscriptEntries :: FilePath -> SessionMeta -> IO Bool
hasTranscriptEntries baseDir meta = do
  let path = baseDir </> T.unpack (unSessionId (_sm_id meta)) </> "transcript.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure False
    else do
      size <- getFileSize path
      pure (size > 0)

toSessionInfo :: SessionMeta -> SessionInfo
toSessionInfo m = SessionInfo
  { _si_id         = unSessionId (_sm_id m)
  , _si_agent      = fmap unAgentName (_sm_agent m)
  , _si_runtime    = runtimeToText (_sm_runtime m)
  , _si_model      = _sm_model m
  , _si_lastActive = _sm_lastActive m
  , _si_createdAt  = _sm_createdAt m
  }

runtimeToText :: RuntimeType -> Text
runtimeToText RTProvider      = "provider"
runtimeToText (RTHarness name) = "harness:" <> name

-- | JSON-serializable transcript entry for the frontend.
data TranscriptEntryInfo = TranscriptEntryInfo
  { _tei_id        :: Text
  , _tei_timestamp :: UTCTime
  , _tei_direction :: Text
  , _tei_payload   :: Text
  , _tei_harness   :: Maybe Text
  , _tei_model     :: Maybe Text
  }
  deriving stock (Show, Eq)

instance ToJSON TranscriptEntryInfo where
  toJSON e = object
    [ "id"        .= _tei_id e
    , "timestamp" .= _tei_timestamp e
    , "direction" .= _tei_direction e
    , "payload"   .= _tei_payload e
    , "harness"   .= _tei_harness e
    , "model"     .= _tei_model e
    ]

toTranscriptEntryInfo :: TranscriptEntry -> TranscriptEntryInfo
toTranscriptEntryInfo e = TranscriptEntryInfo
  { _tei_id        = _te_id e
  , _tei_timestamp = _te_timestamp e
  , _tei_direction = case _te_direction e of
      Request  -> "request"
      Response -> "response"
  , _tei_payload   = _te_payload e
  , _tei_harness   = _te_harness e
  , _tei_model     = _te_model e
  }

-- | Read transcript entries from a session's @transcript.jsonl@ file.
handleTranscript :: FrontendEnv -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleTranscript env sid respond = do
  -- Reject path traversal
  if T.isInfixOf ".." sid || T.isInfixOf "/" sid
    then respond $ jsonResponse status400 (object ["error" .= ("Invalid session ID" :: Text)])
    else do
      let path = _fe_sessionsDir env </> T.unpack sid </> "transcript.jsonl"
      exists <- doesFileExist path
      if not exists
        then respond $ jsonResponse status404 (object ["error" .= ("Session not found" :: Text)])
        else do
          result <- try @SomeException $ readTranscriptFile path
          case result of
            Left _ ->
              respond $ jsonResponse status500 (object ["error" .= ("Failed to read transcript" :: Text)])
            Right entries ->
              respond $ jsonResponse status200 (map toTranscriptEntryInfo entries)

-- | Read and parse a JSONL transcript file.
readTranscriptFile :: FilePath -> IO [TranscriptEntry]
readTranscriptFile path = do
  contents <- LBS.readFile path
  let linesBS = filter (not . LBS.null) (LBS.split 0x0A contents)
  pure [e | l <- linesBS, Just e <- [Aeson.decode l]]

-- | List available agents.
handleAgents :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleAgents env respond = do
  defs <- discoverAgents (_fe_logger env) (_fe_agentsDir env)
  let infos = map toAgentInfo defs
  respond $ jsonResponse status200 infos
  where
    toAgentInfo def =
      let name = unAgentName (_ad_name def)
      in AgentInfo
        { _ai_name      = name
        , _ai_isDefault = _fe_defaultAgent env == Just name
        }

-- | Request body for creating a new session.
data NewSessionRequest = NewSessionRequest
  { _nsr_agent        :: Maybe Text
  , _nsr_customPrompt :: Maybe Text
  }

instance FromJSON NewSessionRequest where
  parseJSON = Aeson.withObject "NewSessionRequest" $ \o ->
    NewSessionRequest <$> o .:? "agent" <*> o .:? "customPrompt"

-- | Create a new empty session.
handleNewSession :: FrontendEnv -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleNewSession env req respond = do
  body <- consumeBody req
  let parsed = case Aeson.eitherDecode body of
        Right r -> r
        Left _  -> NewSessionRequest Nothing Nothing
      mAgentText = _nsr_agent parsed
      mAgentName = mAgentText >>= either (const Nothing) Just . mkAgentName
      mPrefix = mAgentText >>= either (const Nothing) Just . mkSessionPrefix
  now <- getCurrentTime
  mModel <- readIORef (_fe_model env)
  let modelText = maybe "" unModelId mModel
      sid = newSessionId mPrefix now
      meta = SessionMeta
        { _sm_id                = sid
        , _sm_agent             = mAgentName
        , _sm_runtime           = RTProvider
        , _sm_model             = modelText
        , _sm_channel           = "web"
        , _sm_createdAt         = now
        , _sm_lastActive        = now
        , _sm_bootstrapConsumed = True
        }
  sh <- mkSessionHandle (_fe_broker env) (_fe_logger env) (_fe_sessionsDir env) meta
  -- Write custom prompt file if provided
  case _nsr_customPrompt parsed of
    Just prompt | not (T.null (T.strip prompt)) ->
      TIO.writeFile (_sh_dir sh </> "custom-prompt.md") prompt
    _ -> pure ()
  _sh_save sh
  respond $ jsonResponse status200 (toSessionInfo meta)

-- | Set or replace the custom prompt for a session, optionally updating
-- the agent name in @session.json@.
handleSetPrompt :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleSetPrompt env sid req respond = do
  if T.isInfixOf ".." sid || T.isInfixOf "/" sid
    then respond $ jsonResponse status400 (object ["error" .= ("Invalid session ID" :: Text)])
    else do
      let sessionDir = _fe_sessionsDir env </> T.unpack sid
          promptPath = sessionDir </> "custom-prompt.md"
          metaPath   = sessionDir </> "session.json"
      body <- consumeBody req
      case Aeson.eitherDecode body of
        Left _ ->
          respond $ jsonResponse status400 (object ["error" .= ("Invalid JSON: expected {\"prompt\": \"...\"}" :: Text)])
        Right obj -> case Map.lookup ("prompt" :: Text) (obj :: Map.Map Text Text) of
          Nothing ->
            respond $ jsonResponse status400 (object ["error" .= ("Missing 'prompt' field" :: Text)])
          Just prompt -> do
            TIO.writeFile promptPath prompt
            -- Update agent name in session metadata if a name was provided
            let mName = Map.lookup "name" obj
            case mName of
              Just name | not (T.null name) -> do
                raw <- LBS.readFile metaPath
                case Aeson.eitherDecode' raw of
                  Right meta -> do
                    let agentName = either (const Nothing) Just (mkAgentName name)
                        updated = (meta :: SessionMeta) { _sm_agent = agentName }
                        tmpP = metaPath <> ".tmp"
                    LBS.writeFile tmpP (Aeson.encode updated)
                    renameFile tmpP metaPath
                  Left _ -> pure ()
              _ -> pure ()
            respond $ jsonResponse status200 (object ["ok" .= True])

-- | Request body for sending a message.
newtype SendRequest = SendRequest { _sr_message :: Text }

instance FromJSON SendRequest where
  parseJSON = Aeson.withObject "SendRequest" $ \o ->
    SendRequest <$> o .: "message"

-- | Send a user message to a session and get a completion.
handleSend :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleSend env sid req respond = do
  -- Validate session ID
  if T.isInfixOf ".." sid || T.isInfixOf "/" sid
    then respond $ jsonResponse status400 (object ["error" .= ("Invalid session ID" :: Text)])
    else do
      let sessionDir = _fe_sessionsDir env </> T.unpack sid
          transcriptPath = sessionDir </> "transcript.jsonl"
      exists <- doesFileExist transcriptPath
      if not exists
        then respond $ jsonResponse status404 (object ["error" .= ("Session not found" :: Text)])
        else do
          -- Parse request body
          body <- consumeBody req
          case Aeson.eitherDecode body of
            Left _ ->
              respond $ jsonResponse status400 (object ["error" .= ("Invalid JSON: expected {\"message\": \"...\"}" :: Text)])
            Right (SendRequest userText) -> do
              mProvider <- readIORef (_fe_provider env)
              mModel <- readIORef (_fe_model env)
              case (mProvider, mModel) of
                (Nothing, _) ->
                  respond $ jsonResponse status503 (object ["error" .= ("No provider configured" :: Text)])
                (_, Nothing) ->
                  respond $ jsonResponse status503 (object ["error" .= ("No model configured" :: Text)])
                (Just provider, Just model) -> do
                  result <- try @SomeException $
                    doCompletion env (SessionId sid) provider model userText transcriptPath
                  case result of
                    Left e -> do
                      _lh_logError (_fe_logger env) $ "Send error: " <> T.pack (show e)
                      respond $ jsonResponse status500 (object ["error" .= ("Completion failed" :: Text)])
                    Right respText ->
                      respond $ jsonResponse status200 (object ["response" .= respText])

-- | Run a completion: load context, send to provider, record to transcript.
-- The transcript handle is opened via 'mkBroadcastingFileTranscriptHandle'
-- so the provider-wrapper Request\/Response entries reach the broker (D25)
-- when one is configured on the 'FrontendEnv'.
doCompletion
  :: FrontendEnv
  -> SessionId
  -> SomeProvider
  -> ModelId
  -> Text
  -> FilePath
  -> IO Text
doCompletion env sid provider model userText transcriptPath = do
  -- Open a (possibly broadcasting) transcript handle for recording.
  th <- mkBroadcastingFileTranscriptHandle
          (_fe_broker env) sid (_fe_logger env) transcriptPath
  -- Load recent messages for context
  history <- loadRecentMessages th 50 100000
  -- Check for per-session custom prompt, falling back to global
  let sessionDir = takeDirectory transcriptPath
      customPromptPath = sessionDir </> "custom-prompt.md"
  customExists <- doesFileExist customPromptPath
  systemPrompt <- if customExists
    then Just <$> TIO.readFile customPromptPath
    else pure (_fe_systemPrompt env)
  -- Build context with system prompt and history
  let ctx0 = foldl (flip addMessage) (emptyContext systemPrompt) history
      userMsg = textMessage User userText
      ctx = addMessage userMsg ctx0
      -- Wrap provider with transcript logging
      provider' = mkTranscriptProvider th (unModelId model) provider
      req = CompletionRequest
        { _cr_model        = model
        , _cr_messages     = contextMessages ctx
        , _cr_systemPrompt = contextSystemPrompt ctx
        , _cr_maxTokens    = Just 4096
        , _cr_tools        = []
        , _cr_toolChoice   = Nothing
        }
  resp <- complete provider' req
  _th_flush th
  _th_close th
  pure (responseText resp)

-- | Consume the full request body.
consumeBody :: Request -> IO LBS.ByteString
consumeBody req = LBS.fromChunks <$> go
  where
    go = do
      chunk <- getRequestBodyChunk req
      if BS.null chunk then pure [] else (chunk :) <$> go

-- | JSON 404 response.
respondNotFound :: (Response -> IO ResponseReceived) -> IO ResponseReceived
respondNotFound respond =
  respond $ jsonResponse status404 (object ["error" .= ("Not found" :: Text)])

-- | Build a JSON response.
jsonResponse :: ToJSON a => Status -> a -> Response
jsonResponse st body =
  responseLBS st
    [ (hContentType, "application/json")
    , ("Access-Control-Allow-Origin", "*")
    ]
    (Aeson.encode body)
