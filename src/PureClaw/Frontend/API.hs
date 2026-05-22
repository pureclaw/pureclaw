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
  , ProviderInfo (..)
  , TabSnapshot (..)
    -- * New tab request/response (exported for testing)
  , NewTabRequest (..)
  , NewTabResponse (..)
  ) where

import Control.Exception (IOException, SomeException, try)
import Control.Monad (filterM)
import Data.Aeson qualified as Aeson
import Data.Aeson (ToJSON (..), FromJSON (..), object, (.=), (.:), (.:?))
import Data.Aeson.Types qualified as AesonTypes
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Vector qualified as V
import System.IO (IOMode (..), withFile)
import Data.ByteString.Char8 qualified as BSC
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
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Tab (TabKind (..))
import PureClaw.Harness.ClaudeCode (isIdle)
import PureClaw.Harness.Tmux (captureWindow)
import PureClaw.Providers.Class
import PureClaw.Session.Handle
  ( SessionHandle (..)
  , SetArchivedError (..)
  , SetDescriptionError (..)
  , listSessions
  , loadRecentMessages
  , mkSessionHandle
  , setArchived
  , setDescription
  )
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
  , _fe_maxTabs      :: Int
    -- ^ Maximum number of tabs allowed (A8 enforcement).
  , _fe_tabCount     :: IORef Int
    -- ^ Current number of open tabs.
  , _fe_listTabs     :: IO [TabSnapshot]
    -- ^ Callback returning a point-in-time snapshot of all open tabs.
    -- Wired by the dispatcher; returns @[]@ when no tab registry exists.
  , _fe_closeTab     :: Int -> IO (Either Text ())
    -- ^ Callback to close a tab by index. The dispatcher provides the
    -- real implementation; the default stub returns @Left \"not wired\"@.
    -- On success, the tab is removed from the registry and its resources
    -- are cleaned up (session saved for session-backed tabs, process
    -- killed for raw shells).
  , _fe_listModels   :: Text -> IO [Text]
    -- ^ List model IDs for the named provider. Runs the live
    -- @\/v1\/models@ call on the provider using the currently
    -- configured credentials. Returns @[]@ if the provider is
    -- unknown, no credentials are configured, or the call fails.
    -- Never throws.
  , _fe_listProviders :: IO [ProviderInfo]
    -- ^ List the providers the user has actually configured
    -- (API key present in flag\/env\/vault, or Ollama reachable).
    -- Each entry carries @isDefault@: true for the one provider the
    -- running PureClaw instance is configured to use (from CLI flag or
    -- config file). Never throws.
  }

-- | Activity state of a harness, derived from tmux screen capture.
data HarnessActivity
  = HarnessThinking
  | HarnessIdle
  | HarnessStopped
  deriving stock (Show, Eq)

instance ToJSON HarnessActivity where
  toJSON HarnessThinking = Aeson.String "thinking"
  toJSON HarnessIdle     = Aeson.String "idle"
  toJSON HarnessStopped  = Aeson.String "stopped"

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

-- | JSON-serializable provider info for the frontend. @isDefault@ marks
-- the provider that the running PureClaw instance is configured to use
-- (from the CLI @--provider@ flag or the config file @provider@ field),
-- and is true for at most one entry.
data ProviderInfo = ProviderInfo
  { _pi_name      :: Text
  , _pi_isDefault :: Bool
  }
  deriving stock (Show, Eq)

instance ToJSON ProviderInfo where
  toJSON pi_ = object
    [ "name"      .= _pi_name pi_
    , "isDefault" .= _pi_isDefault pi_
    ]

-- | A point-in-time snapshot of a single tab, pre-resolved to
-- JSON-friendly text values. The snapshot callback in 'FrontendEnv'
-- produces these; the API layer simply serializes them.
data TabSnapshot = TabSnapshot
  { _ts_index     :: !Int
  , _ts_kind      :: !Text
    -- ^ @\"provider\"@, @\"harness\"@, or @\"raw_shell\"@.
  , _ts_name      :: !Text
    -- ^ Human-readable tab name.
  , _ts_status    :: !Text
    -- ^ @\"running\"@, @\"idle\"@, or @\"crashed\"@.
  , _ts_sessionId :: !(Maybe Text)
    -- ^ Session ID for session-backed tabs; 'Nothing' for raw shells.
  }
  deriving stock (Show, Eq)

instance ToJSON TabSnapshot where
  toJSON ts = object
    [ "index"      .= _ts_index ts
    , "kind"       .= _ts_kind ts
    , "name"       .= _ts_name ts
    , "status"     .= _ts_status ts
    , "session_id" .= _ts_sessionId ts
    ]

-- | JSON-serializable session info for the frontend.
data SessionInfo = SessionInfo
  { _si_id                   :: Text
  , _si_agent                :: Maybe Text
  , _si_runtime              :: Text
  , _si_model                :: Text
  , _si_lastActive           :: UTCTime
  , _si_createdAt            :: UTCTime
  , _si_description          :: Maybe Text
    -- ^ User-set session description (preferred display title).
  , _si_autoSummary          :: Maybe Text
    -- ^ Model-generated short summary; cached in session.json.
  , _si_firstMessageSnippet  :: Maybe Text
    -- ^ Cheap fallback: a trimmed prefix of the first user message
    -- in the transcript. Computed on demand in 'handleRecentSessions'.
  }
  deriving stock (Show, Eq)

instance ToJSON SessionInfo where
  toJSON si = object
    [ "id"                  .= _si_id si
    , "agent"               .= _si_agent si
    , "runtime"             .= _si_runtime si
    , "model"               .= _si_model si
    , "lastActive"          .= _si_lastActive si
    , "createdAt"           .= _si_createdAt si
    , "description"         .= _si_description si
    , "autoSummary"         .= _si_autoSummary si
    , "firstMessageSnippet" .= _si_firstMessageSnippet si
    ]

-- | WAI application handling @\/api\/*@ routes.
apiApp :: FrontendEnv -> Application
apiApp env req respond = do
  let method = requestMethod req
      path   = pathInfo req
  case (method, path) of
    ("GET", ["api", "harnesses"])            -> handleHarnesses env respond
    ("GET", ["api", "tabs"])                 -> handleListTabs env respond
    ("GET", ["api", "sessions", "recent"])   -> handleRecentSessions env respond
    ("GET", ["api", "sessions", "archived"]) -> handleArchivedSessions env respond
    ("GET", ["api", "sessions", sid, "transcript"]) ->
      handleTranscript env sid respond
    ("POST", ["api", "tabs", tidx, "close"]) ->
      handleCloseTab env tidx respond
    ("POST", ["api", "tabs", "new"]) ->
      handleNewTab env req respond
    ("POST", ["api", "sessions", "new"]) ->
      handleNewSessionGone respond
    ("POST", ["api", "sessions", sid, "send"]) ->
      handleSend env sid req respond
    ("PUT", ["api", "sessions", sid, "prompt"]) ->
      handleSetPrompt env sid req respond
    ("POST", ["api", "sessions", sid, "archive"]) ->
      handleSetArchived env sid True respond
    ("POST", ["api", "sessions", sid, "unarchive"]) ->
      handleSetArchived env sid False respond
    ("PUT", ["api", "sessions", sid, "description"]) ->
      handleSetDescription env sid req respond
    ("GET", ["api", "agents"])               -> handleAgents env respond
    ("GET", ["api", "providers"])            -> handleListProviders env respond
    ("GET", ["api", "providers", name, "models"]) ->
      handleListProviderModels env name respond
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

-- | Return all currently open tabs as a JSON array.
handleListTabs :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleListTabs env respond = do
  tabs <- _fe_listTabs env
  respond $ jsonResponse status200 tabs

-- | Close a tab by index via the '_fe_closeTab' callback.
handleCloseTab :: FrontendEnv -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleCloseTab env tidxText respond =
  case reads (T.unpack tidxText) :: [(Int, String)] of
    [(idx, "")] -> do
      result <- _fe_closeTab env idx
      case result of
        Right () ->
          respond $ jsonResponse status200 (object ["closed" .= True])
        Left errMsg ->
          respond $ jsonResponse status404 (object ["error" .= errMsg])
    _ ->
      respond $ jsonResponse status400 (object ["error" .= ("Invalid tab index" :: Text)])

handleRecentSessions :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleRecentSessions env respond = do
  let limit   = _fe_recentLimit env
      baseDir = _fe_sessionsDir env
  -- Over-fetch so the empty-transcript filter below can't shrink the
  -- visible count: listSessions already does a full directory scan and
  -- sorts the whole metadata set, so a generous bound is essentially
  -- free. Empty / archived sessions are dropped here, not erased on
  -- disk — archiving is purely a UI hint controlled by the user.
  metas    <- listSessions baseDir Nothing (limit * 3)
  -- Collect session IDs that are currently shown in an active tab so
  -- the same session does not appear in both "Active Tabs" and
  -- "Recent Sessions" simultaneously.
  tabs <- _fe_listTabs env
  let activeTabSids = [s | TabSnapshot { _ts_sessionId = Just s } <- tabs]
      notInTab m    = unSessionId (_sm_id m) `notElem` activeTabSids
      visible       = filter (\m -> not (_sm_archived m) && notInTab m) metas
  nonEmpty <- filterM (hasTranscriptEntries baseDir) visible
  let chosen = take limit nonEmpty
  -- Read a first-message snippet per session (bounded read per file).
  -- This is the cheap display fallback when no user description and no
  -- model-generated summary exist yet.
  snippets <- traverse (firstMessageSnippet baseDir) chosen
  let infos = zipWith toSessionInfo chosen snippets
  respond $ jsonResponse status200 infos

-- | Return all archived sessions, sorted by last-active descending.
handleArchivedSessions :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleArchivedSessions env respond = do
  let baseDir = _fe_sessionsDir env
  -- Load all sessions with a generous limit; filter to archived-only.
  metas <- listSessions baseDir Nothing 1000
  let archived = filter _sm_archived metas
      infos = map (`toSessionInfo` Nothing) archived
  respond $ jsonResponse status200 infos

-- | Toggle the archive flag on a session. The 'archived' argument is
-- the **target** value (True for /archive, False for /unarchive), so
-- the routes are idempotent: archiving an already-archived session is
-- a no-op success. The session directory and transcript are never
-- removed — see Session.Handle.setArchived for the disk-side contract.
handleSetArchived
  :: FrontendEnv
  -> Text
  -> Bool
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
handleSetArchived env sidText archived respond = do
  let sid = SessionId sidText
  result <- setArchived (_fe_sessionsDir env) sid archived
  case result of
    Right () ->
      respond $ jsonResponse status200 (object ["archived" .= archived])
    Left SetArchivedSessionMissing ->
      respondNotFound respond
    Left (SetArchivedParseFailed msg) ->
      respond $ jsonResponse status500 (object ["error" .= msg])

-- | Update the user-provided description on a session.
-- Body shape: @{"description": "..."}@ or @{"description": null}@ (clears).
-- Trims whitespace; an all-whitespace string clears the field.
handleSetDescription
  :: FrontendEnv
  -> Text
  -> Request
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
handleSetDescription env sidText req respond = do
  body <- strictRequestBody req
  case Aeson.eitherDecode' body of
    Left err -> respond $ jsonResponse status400 (object ["error" .= T.pack err])
    Right (DescBody mDesc) -> do
      result <- setDescription (_fe_sessionsDir env) (SessionId sidText) mDesc
      case result of
        Right () ->
          respond $ jsonResponse status200 (object ["description" .= mDesc])
        Left SetDescriptionSessionMissing ->
          respondNotFound respond
        Left (SetDescriptionParseFailed msg) ->
          respond $ jsonResponse status500 (object ["error" .= msg])

-- | Body parser that accepts @{"description": <string|null>}@; absent
-- or non-string values normalise to 'Nothing' (which clears the field).
newtype DescBody = DescBody (Maybe Text)
instance FromJSON DescBody where
  parseJSON = Aeson.withObject "DescBody" $ \o -> DescBody <$> o .:? "description"

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

toSessionInfo :: SessionMeta -> Maybe Text -> SessionInfo
toSessionInfo m snippet = SessionInfo
  { _si_id                  = unSessionId (_sm_id m)
  , _si_agent               = fmap unAgentName (_sm_agent m)
  , _si_runtime             = sessionKindToText (_sm_kind m)
  , _si_model               = _sm_model m
  , _si_lastActive          = _sm_lastActive m
  , _si_createdAt           = _sm_createdAt m
  , _si_description         = _sm_description m
  , _si_autoSummary         = _sm_autoSummary m
  , _si_firstMessageSnippet = snippet
  }

-- | Cheap fallback for display: read just the first line of the
-- session's @transcript.jsonl@, decode it as a 'TranscriptEntry', and
-- extract a short snippet of the first user message. Returns 'Nothing'
-- when there's no transcript, the first entry isn't a request, or any
-- decoding step fails. The returned string is at most
-- 'snippetCharBudget' chars with newlines normalised to spaces.
--
-- Cost is one bounded read per call (we don't load the whole transcript).
firstMessageSnippet :: FilePath -> SessionMeta -> IO (Maybe Text)
firstMessageSnippet baseDir meta = do
  let path = baseDir </> T.unpack (unSessionId (_sm_id meta)) </> "transcript.jsonl"
  result <- try @IOException $ withFile path ReadMode BSC.hGetLine
  case result of
    Left _    -> pure Nothing
    Right line -> case Aeson.eitherDecodeStrict' line :: Either String TranscriptEntry of
      Left _ -> pure Nothing
      Right entry
        | _te_direction entry /= Request -> pure Nothing
        | otherwise -> pure (snippetFromPayload (_te_payload entry))

snippetCharBudget :: Int
snippetCharBudget = 120

-- | Extract a display snippet from a request payload. Two shapes:
-- (1) JSON object with a "messages" array (provider request) — pull
--     text out of the first message; (2) plain text (harness send) —
--     use the payload directly. Trimmed, newline-normalised, and
--     truncated to 'snippetCharBudget' characters.
snippetFromPayload :: Text -> Maybe Text
snippetFromPayload raw = trimAndTruncate <$>
  case Aeson.decodeStrict (TE.encodeUtf8 raw) of
    Just (Aeson.Object o)
      | Just (Aeson.Array msgs) <- KM.lookup "messages" o
      , not (V.null msgs)
      -> messageText (V.unsafeHead msgs)
    _ -> Just raw
  where
    -- Anthropic-style message content: either a plain string or an
    -- array of {type:"text", text:"..."} blocks. We just want a
    -- human-readable lead.
    messageText :: Aeson.Value -> Maybe Text
    messageText (Aeson.Object m) = case KM.lookup "content" m of
      Just (Aeson.String s) -> Just s
      Just (Aeson.Array bs) -> Just (T.intercalate " " [t | Aeson.Object b <- V.toList bs
                                                          , Just (Aeson.String t) <- [KM.lookup "text" b]])
      _                     -> Nothing
    messageText _ = Nothing

    trimAndTruncate :: Text -> Text
    trimAndTruncate t =
      let normalized = T.unwords (T.words t)  -- collapse whitespace incl. newlines
      in  if T.length normalized > snippetCharBudget
            then T.take (snippetCharBudget - 1) normalized <> "\x2026"
            else normalized

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

-- | List available models for a given provider name. Delegates to the
-- @_fe_listModels@ callback, which makes a live HTTP call to the
-- provider's @\/v1\/models@ endpoint with the configured credentials.
-- Returns @[]@ when the provider is unknown, the call fails, or no
-- credentials are configured — the frontend then offers only the
-- "Custom…" free-text affordance.
handleListProviderModels
  :: FrontendEnv
  -> Text
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
handleListProviderModels env name respond = do
  ids <- _fe_listModels env name
  respond $ jsonResponse status200 ids

-- | List the providers the user has actually configured. Used by the
-- New Tab dialog to filter its provider dropdown so only usable
-- providers appear. See '_fe_listProviders' for what "configured" means.
handleListProviders
  :: FrontendEnv
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
handleListProviders env respond = do
  names <- _fe_listProviders env
  respond $ jsonResponse status200 names

-- ---------------------------------------------------------------------------
-- POST /api/tabs/new — unified tab creation endpoint
-- ---------------------------------------------------------------------------

-- | Request body for creating a new tab.
--
-- @
-- { "kind": { "tag": "session",
--             "session_kind": { "tag": "provider",
--                               "provider": "anthropic",
--                               "model": "..." } } }
-- @
--
-- OR:
--
-- @
-- { "kind": { "tag": "raw_shell",
--             "backend": { "tag": "local" } } }
-- @
newtype NewTabRequest = NewTabRequest
  { _ntr_kind :: TabKind
  }

instance FromJSON NewTabRequest where
  parseJSON = Aeson.withObject "NewTabRequest" $ \o -> do
    kindObj <- o .: "kind"
    tabKind <- parseTabKind kindObj
    pure (NewTabRequest tabKind)

-- | Parse a 'TabKind' from the JSON envelope used by POST /api/tabs/new.
--
-- Two top-level tags:
--
--   * @\"session\"@ → expects a @\"session_kind\"@ sub-object whose
--     shape is the existing 'SessionKind' JSON (tag-discriminated:
--     @\"provider\"@ or @\"harness\"@).
--   * @\"raw_shell\"@ → expects a @\"backend\"@ sub-object whose shape
--     is the existing 'TerminalBackend' JSON (tag-discriminated).
parseTabKind :: Aeson.Value -> AesonTypes.Parser TabKind
parseTabKind = Aeson.withObject "TabKind" $ \o -> do
  tag <- o .: "tag" :: AesonTypes.Parser Text
  case tag of
    "session" -> do
      sk <- o .: "session_kind"
      TkSession <$> Aeson.parseJSON sk
    "raw_shell" -> do
      be <- o .: "backend"
      TkRawShell <$> Aeson.parseJSON be
    other -> fail ("unknown TabKind tag: " ++ T.unpack other)

-- | Response body for a successful tab creation.
data NewTabResponse = NewTabResponse
  { _ntresp_tabIndex  :: Int
  , _ntresp_sessionId :: Maybe Text
  , _ntresp_kind      :: Text
  }

instance ToJSON NewTabResponse where
  toJSON r = object
    [ "tab_index"  .= _ntresp_tabIndex r
    , "session_id" .= _ntresp_sessionId r
    , "kind"       .= _ntresp_kind r
    ]

-- | Handle POST /api/tabs/new.
--
-- Creates a new tab (session-backed or raw shell), enforces the maxTabs
-- limit (A8), and returns a JSON response with the tab index, session
-- ID (if any), and kind description.
handleNewTab :: FrontendEnv -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleNewTab env req respond = do
  body <- consumeBody req
  case Aeson.eitherDecode body of
    Left err ->
      respond $ jsonResponse status400
        (object ["error" .= ("Invalid JSON: " <> T.pack err)])
    Right (NewTabRequest tabKind) -> do
      -- A8: enforce maxTabs limit
      curCount <- readIORef (_fe_tabCount env)
      if curCount >= _fe_maxTabs env
        then respond $ jsonResponse status409
               (object ["error" .= ("maximum tab count reached" :: Text)])
        else createTab env tabKind respond

-- | Actually create the tab and return a response.
createTab :: FrontendEnv -> TabKind -> (Response -> IO ResponseReceived) -> IO ResponseReceived
createTab env tabKind respond = do
  curCount <- readIORef (_fe_tabCount env)
  -- Bump tab count
  writeIORef (_fe_tabCount env) (curCount + 1)
  case tabKind of
    TkSession sk -> do
      -- Create a session for session-backed tabs
      now <- getCurrentTime
      mModel <- readIORef (_fe_model env)
      let modelText = maybe "" unModelId mModel
          sid = newSessionId Nothing now
          -- Carry the agent name through from the request: the
          -- frontend uses it as the display name for the session
          -- (e.g. the chat input placeholder), and the agent's
          -- definition was already used to build the system prompt.
          -- Without this, the metadata loses the association and
          -- recent-sessions UI falls back to the session id.
          agentName = case sk of
            SkProvider ps -> _ps_agent ps
            SkHarness  _  -> Nothing
          meta = SessionMeta
            { _sm_id                = sid
            , _sm_agent             = agentName
            , _sm_kind              = sk
            , _sm_model             = modelText
            , _sm_channel           = "web"
            , _sm_createdAt         = now
            , _sm_lastActive        = now
            , _sm_bootstrapConsumed = True
            , _sm_archived          = False
            , _sm_description       = Nothing
            , _sm_autoSummary       = Nothing
            }
      sh <- mkSessionHandle (_fe_logger env) (_fe_sessionsDir env) meta
      _sh_save sh
      respond $ jsonResponse status200 NewTabResponse
        { _ntresp_tabIndex  = curCount
        , _ntresp_sessionId = Just (unSessionId sid)
        , _ntresp_kind      = tabKindLabel tabKind
        }
    TkRawShell _backend -> do
      respond $ jsonResponse status200 NewTabResponse
        { _ntresp_tabIndex  = curCount
        , _ntresp_sessionId = Nothing
        , _ntresp_kind      = tabKindLabel tabKind
        }

-- | User-facing kind label for the response JSON.
tabKindLabel :: TabKind -> Text
tabKindLabel (TkSession (SkProvider _)) = "provider"
tabKindLabel (TkSession (SkHarness _))  = "harness"
tabKindLabel (TkRawShell _)             = "raw_shell"

-- ---------------------------------------------------------------------------
-- POST /api/sessions/new — 410 Gone stub (A7)
-- ---------------------------------------------------------------------------

-- | The legacy session-creation endpoint returns 410 Gone with a
-- @Location@ header pointing to the new unified endpoint.
handleNewSessionGone :: (Response -> IO ResponseReceived) -> IO ResponseReceived
handleNewSessionGone respond =
  respond $ responseLBS status410
    [ (hContentType, "application/json")
    , ("Access-Control-Allow-Origin", "*")
    , ("Location", "/api/tabs/new")
    ]
    (Aeson.encode (object
      [ "error" .= ("deprecated" :: Text)
      , "use"   .= ("/api/tabs/new" :: Text)
      ]))

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
                  result <- try @SomeException $ doCompletion env provider model userText transcriptPath
                  case result of
                    Left e -> do
                      _lh_logError (_fe_logger env) $ "Send error: " <> T.pack (show e)
                      respond $ jsonResponse status500 (object ["error" .= ("Completion failed" :: Text)])
                    Right respText ->
                      respond $ jsonResponse status200 (object ["response" .= respText])

-- | Run a completion: load context, send to provider, record to transcript.
doCompletion :: FrontendEnv -> SomeProvider -> ModelId -> Text -> FilePath -> IO Text
doCompletion env provider model userText transcriptPath = do
  -- Open a transcript handle for recording
  th <- mkFileTranscriptHandle (_fe_logger env) transcriptPath
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
