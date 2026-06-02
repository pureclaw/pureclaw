module PureClaw.Frontend.API
  ( -- * WAI Application
    apiApp
    -- * Environment
  , FrontendEnv (..)
  , StartedHarness (..)
    -- * Harness routing helpers
  , harnessKeyFromKind
  , shouldRouteToHarness
  , resolveHarnessSession
    -- * Stream connection guard (per-origin cap)
  , StreamGuard (..)
  , mkStreamGuard
    -- * Shared helpers
  , isValidSessionId
    -- * List snapshot (used by Stream.hs for WS push)
  , computeListsSnapshot
  , broadcastLists
    -- * Response types (exported for testing)
  , HarnessInfo (..)
  , HarnessActivity (..)
  , SessionInfo (..)
  , toSessionInfo
  , TranscriptEntryInfo (..)
  , toTranscriptEntryInfo
  , AgentInfo (..)
  , ProviderInfo (..)
  , TabSnapshot (..)
    -- * Harness → tab snapshot mapping (WU8, exported for testing)
  , livenessToTabStatus
  , harnessEntriesToTabs
    -- * New tab request/response (exported for testing)
  , NewTabRequest (..)
  , NewTabResponse (..)
  , BranchSpec (..)
  ) where

import Control.Concurrent.STM (TVar, newTVarIO)
import Control.Exception (IOException, SomeException, bracket, bracket_, try)
import Control.Monad (filterM, unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson (Value, ToJSON (..), FromJSON (..), object, (.=), (.:), (.:?))
import Data.Aeson.Types qualified as AesonTypes
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Vector qualified as V
import System.IO (IOMode (..), withFile)
import Data.ByteString.Char8 qualified as BSC
import Data.IORef
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Network.HTTP.Types
import Network.Wai
import System.Directory (doesFileExist, getFileSize, removeDirectoryRecursive, renameFile)
import System.FilePath ((</>), takeDirectory)

import PureClaw.Agent.AgentDef
  ( AgentDef (..)
  , composeAgentPromptWithBootstrap
  , discoverAgents
  , loadAgent
  , unAgentName
  )
import PureClaw.Agent.Context
import PureClaw.Core.Types (MessageSource (..), ModelId (..), SessionId (..), ToolCallId, UserId (..), channelKindToText, unModelId, unSessionId)
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.BroadcastingTranscript (mkBroadcastingFileTranscriptHandle)
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  )
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Tab (TabKind (..))
import PureClaw.Harness.Reconcile (livenessToActivity)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Providers.Class
import PureClaw.Session.Handle
  ( BranchError (..)
  , BranchSeed (..)
  , BranchSpec (..)
  , SessionHandle (..)
  , SetArchivedError (..)
  , SetDescriptionError (..)
  , frozenSystemPrompt
  , lastRequestModel
  , listSessions
  , loadRecentMessages
  , mkSessionHandle
  , resolveBranchSeed
  , setArchived
  , setDescription
  , touchSessionLastActive
  , tryLoad
  )
import PureClaw.Session.Types
import PureClaw.Handles.Transcript
import PureClaw.Tools.Registry (ToolRegistry, executeTool, registryDefinitions)
import PureClaw.Transcript.Provider
import PureClaw.Transcript.Types

-- | Runtime environment for the frontend API.
data FrontendEnv = FrontendEnv
  { _fe_harnesses    :: IORef (Map.Map Text HarnessHandle)
    -- ^ Live harness handles from AgentEnv.
  , _fe_harnessRegistry :: Registry.HarnessRegistry
    -- ^ The durable 'HarnessId' registry — the source of truth for harness
    -- identity and health (design @docs\/harness-registry.md@). ADDITIVE
    -- alongside the legacy '_fe_harnesses' map: the map keys by mutable
    -- window name, whereas the registry keys by a UUID-backed
    -- 'Registry.HarnessId' that survives tmux rename\/move and restart. Shares
    -- the SAME underlying 'TVar' as 'AgentEnv._env_harnessRegistry' so the
    -- frontend and agent observe the same registry.
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
  , _fe_streamGuard  :: Maybe StreamGuard
    -- ^ Optional per-origin WS subscriber counter. The WS endpoint uses
    -- this to enforce '_bc_maxSubsPerOrigin' (DoD D30). 'Nothing' disables
    -- the WS endpoint entirely (it returns 503).
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
  , _fe_startHarness :: HarnessSpec -> TranscriptHandle -> IO (Either HarnessError StartedHarness)
    -- ^ Start a tmux-backed harness process for a frontend-created
    -- AI-Harness session. The dispatcher provides the real implementation
    -- (allocates a tmux window, spawns the harness, registers the handle);
    -- the default stub returns @Left@ to signal "not wired". On success it
    -- returns the harness map key and the tmux coordinates to persist in the
    -- session's @_sm_kind@.
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
  , _fe_registry     :: ToolRegistry
    -- ^ Tool registry whose definitions are sent in the @tools@ field
    -- of every provider completion request the frontend originates
    -- (i.e. @POST \/api\/sessions\/\<id\>\/send@). Without this the
    -- provider receives an empty tools array and cannot make tool calls.
  , _fe_maxToolIterations :: Int
    -- ^ Maximum number of @complete@ → tool-execution → re-@complete@
    -- iterations 'doCompletion' will perform for a single user message
    -- before giving up. Defends against a model that keeps tool-calling
    -- without ever returning final text. Reaching the cap returns a
    -- placeholder response; it does not throw.
  }

-- | Result of successfully starting a harness via '_fe_startHarness'.
data StartedHarness = StartedHarness
  { _shh_key  :: !Text        -- ^ harness map key = canonical <> "-" <> show windowIdx (also the tmux window name)
  , _shh_tmux :: !TmuxConfig  -- ^ coordinates to persist in the session's _sm_kind HarnessSpec._h_backend
  , _shh_id   :: !Registry.HarnessId
    -- ^ The durable 'Registry.HarnessId' generated for the spawned harness and
    -- registered in the 'HarnessRegistry' (WU4). 'createHarnessTab' persists it
    -- into '_sm_kind' (WU7, D7.2) so subsequent sends route by id through the
    -- registry rather than only by the dual-written window name.
  }

-- | The default tmux session name a frontend-spawned harness lands in when the
-- requested 'HarnessSpec' does not specify one (WU7, D7.3).
defaultHarnessSession :: Text
defaultHarnessSession = "pureclaw"

-- | Resolve the tmux session name a harness should be spawned into from the
-- requested 'HarnessSpec' (WU7, the epic's core fix). The session is read from
-- the spec's 'TbTmux' backend '_tc_session' when it is non-empty; otherwise it
-- falls back to 'defaultHarnessSession' (@"pureclaw"@). A non-tmux backend
-- (the frontend's placeholder @local@ request backend) likewise resolves to the
-- default. The WINDOW is auto-assigned by the spawn path (@canonical-\<idx\>@);
-- honoring a caller-specified '_tc_window' for placement is deferred
-- (pureclaw-jlc), so this reads only the session, never the window.
resolveHarnessSession :: HarnessSpec -> Text
resolveHarnessSession spec = case _h_backend spec of
  TbTmux tc
    | not (T.null (_tc_session tc)) -> _tc_session tc
  _                                 -> defaultHarnessSession

-- | The durable routing key for a session kind, if it is a tmux-backed
-- harness. @Just k@ => route this session to a harness; @Nothing@ => provider
-- session.
--
-- WU6 makes this /id-primary with a name fallback/: when the persisted
-- 'HarnessSpec' carries a 'Registry.HarnessId' (the durable anchor), the key
-- is that id's canonical text; otherwise it is the (dual-written) tmux window
-- name — the legacy PR #74 routing key. 'sendToHarness' interprets the key:
-- an id-shaped key resolves through the registry first, falling back to the
-- window name; a name-shaped key goes straight to the legacy name-keyed map.
-- The registry is EMPTY until later work units populate it, so until then this
-- yields the window name and routing stays on the PR #74 path unchanged.
harnessKeyFromKind :: SessionKind -> Maybe Text
harnessKeyFromKind (SkHarness hs) = case _h_backend hs of
  TbTmux tc -> Just (maybe (_tc_window tc) Registry.harnessIdToText (_h_harnessId hs))
  _         -> Nothing
harnessKeyFromKind _ = Nothing

-- | The dual-written tmux window name for a tmux-backed harness session, used
-- as the legacy name-fallback routing key when an id lookup misses (WU6).
-- @Nothing@ for any non-tmux / non-harness kind.
harnessWindowFromKind :: SessionKind -> Maybe Text
harnessWindowFromKind (SkHarness hs) = case _h_backend hs of
  TbTmux tc -> Just (_tc_window tc)
  _         -> Nothing
harnessWindowFromKind _ = Nothing

-- | Routing decision: does this session route to a harness (vs the LLM provider)?
shouldRouteToHarness :: SessionKind -> Bool
shouldRouteToHarness = Maybe.isJust . harnessKeyFromKind

-- | Is a registry entry PID-corroborated? A recorded shell or harness PID is
-- evidence the entry is genuinely ours and not a bare, attacker-writable
-- @\@pcl_id@ marker (design §8 C4 / K2). Routing trust requires this: an
-- uncorroborated entry never receives keystrokes (D6.6).
isPidCorroborated :: Registry.HarnessEntry -> Bool
isPidCorroborated e =
  Maybe.isJust (Registry._he_harnessPid e) || Maybe.isJust (Registry._he_shellPid e)

-- | Per-origin WS subscriber counter. Lives at the same lifetime as the
-- broker (constructed once in @startWithChannel@). The WS handler calls
-- 'tryClaim' on upgrade (rejecting with 503 if the cap is reached) and
-- 'release' on disconnect. Key is the normalized Origin string (see
-- 'normalizeOrigin' in "PureClaw.Frontend.Stream").
data StreamGuard = StreamGuard
  { _streamGuard_perOrigin    :: !(TVar (Map Text Int))
    -- ^ Live count per normalized Origin string.
  , _streamGuard_maxPerOrigin :: !Int
    -- ^ Maximum simultaneous WS subscriptions per origin.
  }

-- | Construct a fresh 'StreamGuard' with the given per-origin cap.
mkStreamGuard :: Int -> IO StreamGuard
mkStreamGuard maxPer = do
  ref <- newTVarIO Map.empty
  pure StreamGuard
    { _streamGuard_perOrigin    = ref
    , _streamGuard_maxPerOrigin = maxPer
    }

-- | Shared session-ID validation used by every endpoint that consumes a
-- caller-supplied session id (HTTP @\/transcript@, @\/send@, @\/prompt@
-- and the WS @focus@ op). Rejects @..@ and @\/@ to foreclose path
-- traversal; rejects the empty string. Behavioural surface is intentionally
-- the same across the HTTP and WS paths so D26's "shared helper" property
-- holds: changing the rule here changes it everywhere.
isValidSessionId :: Text -> Bool
isValidSessionId sid
  | T.null sid = False
  | T.isInfixOf ".." sid = False
  | T.isInfixOf "/" sid = False
  | otherwise = True

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
  { _pi_name         :: Text
  , _pi_isDefault    :: Bool
  , _pi_defaultModel :: Maybe Text
  }
  deriving stock (Show, Eq)

instance ToJSON ProviderInfo where
  toJSON pi_ = object $
    [ "name"      .= _pi_name pi_
    , "isDefault" .= _pi_isDefault pi_
    ] ++ maybe [] (\m -> ["defaultModel" .= m]) (_pi_defaultModel pi_)

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

-- | Map a registry 'Registry.Liveness' to the @TabSnapshot@ status vocabulary
-- (@running|idle|crashed@). This is the MINIMAL Phase-1 mapping: both
-- 'Registry.LivenessExited' and 'Registry.LivenessOrphaned' collapse to
-- @\"crashed\"@ because the tab model has no separate \"exited\"\/\"orphaned\"
-- words yet. The full status vocabulary is Phase 2.
livenessToTabStatus :: Registry.Liveness -> Text
livenessToTabStatus lv = case lv of
  Registry.LivenessIdle     -> "idle"
  Registry.LivenessThinking -> "running"
  Registry.LivenessExited   -> "crashed"
  Registry.LivenessOrphaned -> "crashed"

-- | Project the harness registry's entries onto @TabSnapshot@s for the
-- Active-Tabs list. Phase-1 minimal slice: only harness entries are surfaced
-- (provider\/raw_shell tabs are the Phase-2 full tab model).
--
-- 'HarnessEntry' carries no intrinsic tab index in Phase 1, so the index is a
-- STABLE DISPLAY ORDERING derived by sorting deterministically on
-- @(label, id-text)@ and enumerating from 0. Full tab-index semantics are
-- Phase 2.
harnessEntriesToTabs :: [Registry.HarnessEntry] -> [TabSnapshot]
harnessEntriesToTabs entries =
  zipWith toTab [0 ..] sorted
  where
    sorted =
      List.sortOn
        (\e -> (Registry._he_label e, Registry.harnessIdToText (Registry._he_id e)))
        entries
    toTab :: Int -> Registry.HarnessEntry -> TabSnapshot
    toTab idx e = TabSnapshot
      { _ts_index     = idx
      , _ts_kind      = "harness"
      , _ts_name      = Registry._he_label e
      , _ts_status    = livenessToTabStatus (Registry._he_liveness e)
      , _ts_sessionId = Registry._he_sessionId e
      }

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
  , _si_channel              :: Maybe Text
    -- ^ Communications channel name of the session origin (e.g. "signal",
    -- "telegram", "cli"), derived from the first inbound message's
    -- 'MessageSource'. 'Nothing' when the session has no recorded source.
  , _si_channelUserId        :: Maybe Text
    -- ^ Channel user id of the session origin (phone / UUID / Telegram id).
    -- 'Nothing' when the channel carries no user id (e.g. @pureclaw tui@).
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
    , "channel"             .= _si_channel si
    , "channelUserId"       .= _si_channelUserId si
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

-- | @GET \/api\/harnesses@ — report every harness in the registry with its
-- reconciled liveness. The registry (not the legacy '_fe_harnesses' map) is the
-- source of truth for health (Harness Registry, WU5): the reconcile loop keeps
-- each entry's '_he_liveness' fresh, so the handler reads the cached state
-- rather than performing a live tmux capture per request.
handleHarnesses :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleHarnesses env respond = do
  entries <- Registry.snapshot (_fe_harnessRegistry env)
  let infos = map harnessInfoOfEntry entries
  respond $ jsonResponse status200 infos

-- | Map a registry entry to its JSON-serializable 'HarnessInfo'. The display
-- name is the entry's label (the tmux window name); the activity comes from the
-- reconciled liveness via the same mapping the reconcile loop publishes.
harnessInfoOfEntry :: Registry.HarnessEntry -> HarnessInfo
harnessInfoOfEntry e = HarnessInfo
  { _hi_name     = Registry._he_label e
  , _hi_activity = livenessToActivity (Registry._he_liveness e)
  }

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
        Right () -> do
          broadcastLists env
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

-- ---------------------------------------------------------------------------
-- List snapshots (WS push)
-- ---------------------------------------------------------------------------

-- | Compute the same sidebar payloads (tabs, recent sessions, archived
-- sessions) that the three HTTP endpoints return, pre-serialized as a
-- single JSON 'Value'. The WS handler sends this on connect and the
-- mutation handlers call 'broadcastLists' to push it after every change.
computeListsSnapshot :: FrontendEnv -> IO Aeson.Value
computeListsSnapshot env = do
  let limit   = _fe_recentLimit env
      baseDir = _fe_sessionsDir env
  tabs <- _fe_listTabs env
  -- Recent sessions: exclude archived, exclude active-tab-backed, exclude
  -- empty transcripts, enrich with first-message snippet — same pipeline
  -- as handleRecentSessions.
  allMetas <- listSessions baseDir Nothing (limit * 3)
  let activeTabSids = [s | TabSnapshot { _ts_sessionId = Just s } <- tabs]
      notInTab m    = unSessionId (_sm_id m) `notElem` activeTabSids
      visible       = filter (\m -> not (_sm_archived m) && notInTab m) allMetas
  nonEmpty <- filterM (hasTranscriptEntries baseDir) visible
  let chosen = take limit nonEmpty
  snippets <- traverse (firstMessageSnippet baseDir) chosen
  let recentInfos = zipWith toSessionInfo chosen snippets
  -- Archived: all archived sessions, sorted by lastActive descending
  -- (listSessions already sorts; we just filter).
  archivedMetas <- listSessions baseDir Nothing 1000
  let archivedChosen = filter _sm_archived archivedMetas
  archivedSnippets <- traverse (firstMessageSnippet baseDir) archivedChosen
  let archivedInfos = zipWith toSessionInfo archivedChosen archivedSnippets
  pure $ object
    [ "type"              .= ("lists" :: Text)
    , "tabs"              .= tabs
    , "recentSessions"    .= recentInfos
    , "archivedSessions"  .= archivedInfos
    ]

-- | Compute and broadcast a lists snapshot to all WS subscribers.
-- No-op when the broker is absent (test / legacy paths).
broadcastLists :: FrontendEnv -> IO ()
broadcastLists env = case _fe_broker env of
  Nothing     -> pure ()
  Just broker -> do
    v <- computeListsSnapshot env
    _streamBroker_publish broker (ListsSnapshot v)

-- ---------------------------------------------------------------------------
-- Archive / description
-- ---------------------------------------------------------------------------

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
    Right () -> do
      broadcastLists env
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
        Right () -> do
          broadcastLists env
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
  , _si_channel             = channelKindToText . _ms_channel <$> _sm_source m
  , _si_channelUserId       = _sm_source m >>= fmap unUserId . _ms_userId
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
  -- Reject path traversal (shared helper — D26)
  if not (isValidSessionId sid)
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
data NewTabRequest = NewTabRequest
  { _ntr_kind       :: TabKind
  , _ntr_branchFrom :: Maybe BranchSpec
    -- ^ Optional branch source. When 'Just', the new tab's session is
    -- seeded from a copy of the named source session's transcript prefix
    -- (parsed from the @"branch_from"@ key; absent ⇒ 'Nothing').
  }

instance FromJSON NewTabRequest where
  parseJSON = Aeson.withObject "NewTabRequest" $ \o -> do
    kindObj <- o .: "kind"
    tabKind <- parseTabKind kindObj
    branchFrom <- o .:? "branch_from"
    pure (NewTabRequest tabKind branchFrom)

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
    Right (NewTabRequest tabKind mBranch) ->
      case mBranch of
        Nothing -> do
          -- A8: enforce maxTabs limit
          curCount <- readIORef (_fe_tabCount env)
          if curCount >= _fe_maxTabs env
            then respond $ jsonResponse status409
                   (object ["error" .= ("maximum tab count reached" :: Text)])
            else createTab env tabKind Nothing respond
        Just branchSpec ->
          -- Branch path: validate the request kind and resolve the seed
          -- BEFORE the maxTabs gate / createTab so a failed branch never
          -- consumes a tab slot or creates a directory (D5).
          case tabKind of
            TkSession (SkProvider _) -> do
              seedResult <- resolveBranchSeed (_fe_sessionsDir env) branchSpec
              case seedResult of
                Left err -> respond (branchErrorResponse err)
                Right seed -> do
                  curCount <- readIORef (_fe_tabCount env)
                  if curCount >= _fe_maxTabs env
                    then respond $ jsonResponse status409
                           (object ["error" .= ("maximum tab count reached" :: Text)])
                    else createTab env tabKind (Just seed) respond
            _ ->
              respond $ jsonResponse status400
                (object ["error" .= ("branch target must be a provider session" :: Text)])

-- | Map a 'BranchError' to its HTTP response. Invalid/traversal source id
-- and non-provider sources are client errors (400); a missing source
-- session or a missing entry id are not-found (404).
branchErrorResponse :: BranchError -> Response
branchErrorResponse err = case err of
  BranchInvalidSourceId sid -> jsonResponse status400
    (object ["error" .= ("invalid branch source id: " <> sid)])
  BranchSourceNotProvider -> jsonResponse status400
    (object ["error" .= ("branch source is not a provider session" :: Text)])
  BranchSourceMissing _ -> jsonResponse status404
    (object ["error" .= ("branch source session not found" :: Text)])
  BranchEntryNotFound eid -> jsonResponse status404
    (object ["error" .= ("branch source entry not found: " <> eid)])

-- | Actually create the tab and return a response. With @'Just' seed@ the
-- session is seeded from a branch source (see 'createBranchedSession');
-- with 'Nothing' the behaviour is identical to a fresh New-tab session.
createTab :: FrontendEnv -> TabKind -> Maybe BranchSeed -> (Response -> IO ResponseReceived) -> IO ResponseReceived
createTab env tabKind mSeed respond = do
  -- Read the slot index for the response; the actual bump is deferred for
  -- the harness path so a failed tmux spawn never consumes a slot (the
  -- count has no decrement). Provider / raw-shell paths bump immediately,
  -- preserving their existing behaviour byte-for-byte.
  curCount <- readIORef (_fe_tabCount env)
  case tabKind of
    -- Harness sessions must actually spawn the tmux harness before the tab
    -- is considered created. A branch seed only ever targets a provider
    -- session (handleNewTab rejects non-provider branch targets), so a
    -- seeded harness cannot occur here.
    TkSession sk@(SkHarness spec) ->
      createHarnessTab env tabKind spec sk curCount respond
    TkSession sk -> do
      -- Bump tab count
      writeIORef (_fe_tabCount env) (curCount + 1)
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
          -- recent-sessions UI falls back to the session id. Harness
          -- kinds are handled by 'createHarnessTab' above, so 'sk' here
          -- is always a provider spec.
          agentName = case sk of
            SkProvider ps -> _ps_agent ps
          -- For a branch, inherit _sm_kind / _sm_model / _sm_agent from
          -- the source meta so the branch's sidebar row matches its
          -- parent; otherwise use the request kind + global model.
          (metaKind, metaModel, metaAgent) = case mSeed of
            Just seed ->
              let srcMeta = _bseed_sourceMeta seed
              in ( _sm_kind srcMeta, _sm_model srcMeta, _sm_agent srcMeta )
            Nothing -> (sk, modelText, agentName)
          meta = SessionMeta
            { _sm_id                = sid
            , _sm_agent             = metaAgent
            , _sm_kind              = metaKind
            , _sm_model             = metaModel
            , _sm_channel           = "web"
            , _sm_createdAt         = now
            , _sm_lastActive        = now
            , _sm_bootstrapConsumed = True
            , _sm_archived          = False
            , _sm_description       = Nothing
            , _sm_autoSummary       = Nothing
            , _sm_source            = Nothing
            }
      sh <- mkSessionHandle (_fe_broker env) (_fe_logger env) (_fe_sessionsDir env) meta
      _sh_save sh
      -- For a branch, seed the new transcript with a verbatim copy of the
      -- source prefix (preserving _te_id and order). The frozen system prompt
      -- and last-used model ride in the copied transcript (see
      -- docs/session-branching.md §9), so the fork does NOT copy the source's
      -- custom-prompt.md; it inherits the agent identity via _sm_agent above.
      case mSeed of
        Just seed -> mapM_ (_th_record (_sh_transcript sh)) (_bseed_prefix seed)
        Nothing -> pure ()
      -- Publish the new-session signal to the live stream broker (D18). The
      -- sidebar uses this to render the session row without polling. The
      -- no-broker path is intentional ('Nothing' preserves the legacy
      -- behaviour for one-off scripts and tests). Previously this lived in
      -- the now-410'd POST /api/sessions/new handler; it moved here when
      -- the session-tab unification merged on main.
      case _fe_broker env of
        Just broker ->
          _streamBroker_publish broker
            (ActivityChanged (_sm_id meta) (SaSessionCreated meta))
        Nothing -> pure ()
      broadcastLists env
      respond $ jsonResponse status200 NewTabResponse
        { _ntresp_tabIndex  = curCount
        , _ntresp_sessionId = Just (unSessionId sid)
        , _ntresp_kind      = tabKindLabel tabKind
        }
    TkRawShell _backend -> do
      -- Bump tab count
      writeIORef (_fe_tabCount env) (curCount + 1)
      respond $ jsonResponse status200 NewTabResponse
        { _ntresp_tabIndex  = curCount
        , _ntresp_sessionId = Nothing
        , _ntresp_kind      = tabKindLabel tabKind
        }

-- | Create a harness-backed tab: persist the session, spawn the tmux
-- harness via '_fe_startHarness', and only on success persist the real
-- tmux coordinates into '_sm_kind' and bump the tab count. A failed spawn
-- removes the just-created session directory and leaves the tab count
-- untouched (it has no decrement), so a fallible spawn never strands a
-- session dir or burns a tab slot.
createHarnessTab
  :: FrontendEnv
  -> TabKind        -- ^ original request kind (for the response label)
  -> HarnessSpec    -- ^ requested harness spec (backend replaced on success)
  -> SessionKind    -- ^ the SkHarness kind to seed _sm_kind with
  -> Int            -- ^ current tab count = response slot index
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
createHarnessTab env tabKind spec sk curCount respond = do
  now <- getCurrentTime
  let sid  = newSessionId Nothing now
      meta = SessionMeta
        { _sm_id                = sid
        , _sm_agent             = Nothing
        , _sm_kind              = sk
        , _sm_model             = ""
        , _sm_channel           = "web"
        , _sm_createdAt         = now
        , _sm_lastActive        = now
        , _sm_bootstrapConsumed = True
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        , _sm_source            = Nothing
        }
  sh <- mkSessionHandle (_fe_broker env) (_fe_logger env) (_fe_sessionsDir env) meta
  _sh_save sh
  -- Pass a NON-recording transcript to the harness so it does not
  -- double-record entries: 'handleSend' is the SOLE recorder of harness
  -- Request/Response entries to the session transcript (WU3). Recording
  -- here too would duplicate every fresh-session entry.
  started <- _fe_startHarness env spec mkNoOpTranscriptHandle
  case started of
    Left err -> do
      -- Roll back the session dir created above. A missing dir must not
      -- throw, so swallow IO errors from the cleanup.
      _ <- try @IOException (removeDirectoryRecursive (_sh_dir sh))
      respond $ harnessErrorResponse err
    Right st -> do
      -- Persist the real tmux coordinates AND the durable HarnessId returned by
      -- the spawn (WU7, D7.2). The id is the primary routing anchor (resolved
      -- through the registry by 'harnessKeyFromKind'/'sendToHarness'); the tmux
      -- window/session is dual-written for the name-fallback path. The persisted
      -- '_tc_session' is the resolved session honored by '_fe_startHarness'.
      modifyIORef' (_sh_meta sh) $ \m ->
        m { _sm_kind = SkHarness
              (spec { _h_backend   = TbTmux (_shh_tmux st)
                    , _h_harnessId = Just (_shh_id st)
                    }) }
      _sh_save sh
      -- Read back the post-spawn meta so the live broadcast carries the real
      -- TbTmux backend (the persisted session.json above is already correct;
      -- the original 'meta' still holds the placeholder backend).
      updatedMeta <- readIORef (_sh_meta sh)
      -- Only a successful spawn consumes a tab slot.
      writeIORef (_fe_tabCount env) (curCount + 1)
      case _fe_broker env of
        Just broker ->
          _streamBroker_publish broker
            (ActivityChanged (_sm_id updatedMeta) (SaSessionCreated updatedMeta))
        Nothing -> pure ()
      broadcastLists env
      respond $ jsonResponse status200 NewTabResponse
        { _ntresp_tabIndex  = curCount
        , _ntresp_sessionId = Just (unSessionId sid)
        , _ntresp_kind      = tabKindLabel tabKind
        }

-- | Map a 'HarnessError' to its HTTP response. An authorization failure is
-- a client-side 403; a missing harness binary or unavailable tmux is a
-- 503 (the dependency the server needs is not available right now).
harnessErrorResponse :: HarnessError -> Response
harnessErrorResponse err = case err of
  HarnessNotAuthorized ce -> jsonResponse status403
    (object ["error" .= ("harness not authorized: " <> T.pack (show ce))])
  HarnessBinaryNotFound detail -> jsonResponse status503
    (object ["error" .= ("harness binary not found: " <> detail)])
  HarnessTmuxNotAvailable detail -> jsonResponse status503
    (object ["error" .= ("tmux not available: " <> detail)])

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

-- | Set or replace the custom prompt for a session (WU6, §9.3).
--
-- Enforces the @custom-prompt.md ⊕ agent@ invariant: a session may have a
-- per-session agent /or/ a user-supplied custom prompt, never both. Setting
-- a custom prompt therefore:
--
--   * clears @_sm_agent@ (the custom prompt supersedes the agent);
--   * stores an optionally-provided @name@ in @_sm_description@ (a friendly
--     title), /not/ as the agent;
--   * leaves all other metadata fields untouched.
--
-- __Ordering / atomicity:__ the metadata is read, updated, and written
-- (atomic tmp + rename) /before/ @custom-prompt.md@ is written. If the
-- existing @session.json@ is missing or undecodable, no @custom-prompt.md@
-- is written, so a meta failure can never leave a custom prompt sitting
-- alongside a still-set agent.
handleSetPrompt :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleSetPrompt env sid req respond = do
  if not (isValidSessionId sid)
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
            -- An optionally-provided friendly title, trimmed; an
            -- all-whitespace value is treated as "no description".
            let mDescription = do
                  name <- Map.lookup "name" obj
                  let trimmed = T.strip name
                  if T.null trimmed then Nothing else Just trimmed
            -- Step 1: read + update + atomically rewrite session.json FIRST.
            -- Clear the agent (invariant) and set the description from name.
            metaExists <- doesFileExist metaPath
            if not metaExists
              then respondNotFound respond
              else do
                eBytes <- try (LBS.readFile metaPath) :: IO (Either IOException LBS.ByteString)
                case eBytes of
                  Left e ->
                    respond $ jsonResponse status500
                      (object ["error" .= T.pack (show e)])
                  Right raw -> case Aeson.eitherDecode' raw of
                    Left err ->
                      respond $ jsonResponse status500
                        (object ["error" .= T.pack err])
                    Right meta -> do
                      let updated = (meta :: SessionMeta)
                            { _sm_agent       = Nothing
                            , _sm_description = mDescription
                            }
                          tmpP = metaPath <> ".tmp"
                      LBS.writeFile tmpP (Aeson.encode updated)
                      renameFile tmpP metaPath
                      -- Step 2: only after the meta update succeeds do we
                      -- write the custom prompt file. Now the agent is
                      -- guaranteed cleared, so no contradiction can exist.
                      TIO.writeFile promptPath prompt
                      respond $ jsonResponse status200 (object ["ok" .= True])

-- | Request body for sending a message. The optional @model@ field (WU5,
-- §9.2) lets a client pin the completion to a specific model for this turn;
-- when omitted, 'doCompletion' falls back to the session's most-recent
-- transcript model and then the global model.
data SendRequest = SendRequest
  { _sr_message :: Text
  , _sr_model   :: Maybe Text
  }

instance FromJSON SendRequest where
  parseJSON = Aeson.withObject "SendRequest" $ \o ->
    SendRequest <$> o .: "message" <*> o .:? "model"

-- | Send a user message to a session and get a completion.
handleSend :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleSend env sid req respond = do
  -- Validate session ID (shared helper — D26)
  if not (isValidSessionId sid)
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
            Right (SendRequest userText reqModel) -> do
              -- Branch on the session's kind BEFORE the provider/model guard:
              -- an AI-Harness session must route to its live tmux harness even
              -- on an instance with no LLM provider configured. A failure to
              -- load the meta (missing/malformed) falls through to the
              -- provider path, preserving prior behaviour.
              mMeta <- tryLoad (_fe_sessionsDir env) (T.unpack sid)
              let mKind = _sm_kind <$> mMeta
              case mKind >>= harnessKeyFromKind of
                Just key -> do
                  -- The dual-written tmux window name is the legacy name-fallback
                  -- key; an id-shaped @key@ resolves via the registry first and
                  -- falls back to this name (WU6).
                  let fallbackName = mKind >>= harnessWindowFromKind
                  sendToHarness env sid key fallbackName userText transcriptPath respond
                Nothing -> do
                  mProvider <- readIORef (_fe_provider env)
                  mModel <- readIORef (_fe_model env)
                  case (mProvider, mModel) of
                    (Nothing, _) ->
                      respond $ jsonResponse status503 (object ["error" .= ("No provider configured" :: Text)])
                    (_, Nothing) ->
                      respond $ jsonResponse status503 (object ["error" .= ("No model configured" :: Text)])
                    (Just provider, Just model) -> do
                      result <- try @SomeException $
                        doCompletion env (SessionId sid) provider reqModel model userText transcriptPath
                      case result of
                        Left e -> do
                          _lh_logError (_fe_logger env) $ "Send error: " <> T.pack (show e)
                          respond $ jsonResponse status500 (object ["error" .= ("Completion failed" :: Text)])
                        Right respText ->
                          respond $ jsonResponse status200 (object ["response" .= respText])

-- | Route a user message to a live tmux harness handle (WU3, defect #2).
-- This is the harness analogue of 'doCompletion': it is the SOLE recorder
-- of the harness Request\/Response transcript entries (the harness handle
-- itself is given a no-op transcript so it does not double-record), it
-- broadcasts through the same broadcasting transcript handle 'doCompletion'
-- uses, and it bumps @_sm_lastActive@ and re-broadcasts the lists snapshot
-- on success.
--
-- If no live handle is registered under @key@ (e.g. the harness crashed or
-- was never reconnected after a restart) it returns a clear 503 — never a
-- silent provider completion and never a 500.
--
-- WU6 makes routing /id-primary with a name fallback/. Resolution order:
--
--   1. If @key@ parses as a 'Registry.HarnessId', look it up in the registry:
--
--        * Found AND PID-corroborated AND it has a live handle -> route to that
--          handle (the durable, rename-proof path).
--        * Found AND corroborated but with NO handle (e.g. boot-discovered, not
--          yet attached) -> fall through to the name path.
--        * Found but NOT PID-corroborated -> REFUSE (respond 503, log a
--          refusal, send NO keystrokes). A spoofable @\@pcl_id@ marker on a
--          window with no recorded PID is treated as "not ours" (§8 C4 / D6.6).
--          This case does NOT fall back to the name path.
--        * Not found in the registry -> fall back to the name path (the registry
--          is empty until later work units populate it).
--
--   2. Name path (legacy, PR #74): look the @fallbackName@ (the dual-written
--      tmux window name) up in '_fe_harnesses'. On a match, route; on a miss,
--      respond 503 "not running". When a corroborated registry entry matches
--      this name by label, lazily back-fill its 'Registry.HarnessId' into
--      @session.json@ (D6.5) so subsequent sends route by id.
sendToHarness
  :: FrontendEnv
  -> Text         -- ^ session id
  -> Text         -- ^ routing key (a 'Registry.HarnessId' text, or a window name)
  -> Maybe Text   -- ^ fallback tmux window name (the dual-written legacy key)
  -> Text         -- ^ user message text
  -> FilePath     -- ^ session transcript path
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
sendToHarness env sid key fallbackName userText transcriptPath respond =
  case Registry.parseHarnessId key of
    Just hid -> do
      mEntry <- Registry.lookupById (_fe_harnessRegistry env) hid
      case mEntry of
        Just entry
          | not (isPidCorroborated entry) -> do
              -- D6.6 (§8 C4): a spoofable marker without recorded PID provenance
              -- is NOT ours. Refuse outright — never send keystrokes, never fall
              -- back to the name map for this case.
              _lh_logError (_fe_logger env) $
                "Refusing to route session '" <> sid <> "' to harness id '"
                <> key <> "': registry entry is not PID-corroborated (possible "
                <> "spoofed @pcl_id marker — §8 C4)."
              respond $ jsonResponse status503 (object
                [ "error" .= ("harness id is not PID-corroborated; refusing to route" :: Text) ])
          | Just hh <- Registry._he_handle entry ->
              -- Corroborated, with a live handle: the durable id path. The id
              -- is already durable here, so no back-fill is needed.
              routeViaHandle env sid hh userText transcriptPath (pure ()) respond
          | otherwise ->
              -- Corroborated but no attached handle yet: fall through to name.
              routeViaName env sid fallbackName userText transcriptPath respond
        -- Unknown id: the registry has no entry yet -> legacy name fallback.
        Nothing -> routeViaName env sid fallbackName userText transcriptPath respond
    -- Key is not id-shaped: a legacy window-name key. Route by name directly.
    Nothing -> routeViaName env sid (Just key) userText transcriptPath respond

-- | The legacy name-keyed routing path (PR #74). Looks @mName@ up in
-- '_fe_harnesses'; on a match, routes via that handle (and lazily back-fills a
-- 'Registry.HarnessId' if a corroborated entry matches by label — D6.5); on a
-- miss (or no name available), responds 503 "not running".
routeViaName
  :: FrontendEnv
  -> Text
  -> Maybe Text
  -> Text
  -> FilePath
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
routeViaName env sid mName userText transcriptPath respond = do
  handles <- readIORef (_fe_harnesses env)
  case mName >>= (`Map.lookup` handles) of
    Nothing ->
      respond $ jsonResponse status503
        (object ["error" .= ("harness '" <> Maybe.fromMaybe "?" mName
                              <> "' is not running" :: Text)])
    Just hh ->
      -- D6.5: lazily back-fill the durable id when a corroborated registry
      -- entry matches this window name by label. Best-effort; runs only AFTER
      -- a successful send (post-send, synchronous-but-exception-proof: it runs
      -- synchronously before 'respond' on the success branch — adding only
      -- minor latency — but is itself exception-proof (D6.5c), so it can fail
      -- neither the send the user already received nor the response.)
      routeViaHandle env sid hh userText transcriptPath
        (maybe (pure ()) (backfillHarnessId env sid) mName)
        respond

-- | Route a user message to a resolved 'HarnessHandle': record the
-- Request\/Response transcript entries (sole writer of this session's
-- transcript), broadcast, bump @_sm_lastActive@, and respond. Shared by the
-- id and name resolution paths.
--
-- @postSend@ is a synchronous-but-exception-proof action run ONLY after a
-- successful send (the name path uses it for the D6.5 id back-fill). It runs
-- synchronously before @respond@ on the success branch — so it can add minor
-- latency to a successful response but never delays a failed send; callers MUST
-- make it exception-proof (see 'backfillHarnessId') so it cannot fail the send.
routeViaHandle
  :: FrontendEnv
  -> Text
  -> HarnessHandle
  -> Text
  -> FilePath
  -> IO ()        -- ^ post-send hook (run only on success; must not throw)
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
routeViaHandle env sid hh userText transcriptPath postSend respond = do
  -- 'handleSend' is the sole writer of THIS session's transcript: on the
  -- fresh-create path the harness handle was given a no-op transcript
  -- ('createHarnessTab'), and a restart-discovered handle records to the
  -- CLI's own session transcript (a different file), so recording here never
  -- duplicates an entry in this session transcript. 'bracket' guarantees the
  -- transcript fd is flushed + closed even if '_hh_send'/'_hh_receive' throws
  -- (tmux IO), so a failed send cannot leak a file descriptor.
  result <- try @SomeException $
    bracket
      (mkBroadcastingFileTranscriptHandle
         (_fe_broker env) (SessionId sid) (_fe_logger env) transcriptPath)
      (\th -> _th_flush th >> _th_close th)
      (\th -> do
        -- Record the user message as a Request entry (mirrors 'harnesseSend').
        recordHarnessEntry th Request userText
        _hh_send hh (TE.encodeUtf8 userText)
        raw <- _hh_receive hh
        let resp = sanitizeHarnessOutput (TE.decodeUtf8 raw)
        -- Only record a Response entry when the harness produced output;
        -- a blank reply must not leave an empty/duplicate entry.
        unless (T.null (T.strip resp)) $
          recordHarnessEntry th Response resp
        pure resp)
  case result of
    Left e -> do
      _lh_logError (_fe_logger env) $ "Harness send error: " <> T.pack (show e)
      respond $ jsonResponse status500 (object ["error" .= ("Harness send failed" :: Text)])
    Right resp -> do
      touchSessionLastActive (_fe_sessionsDir env) (SessionId sid)
      broadcastLists env
      -- Synchronous-but-exception-proof post-send hook (e.g. the D6.5 id
      -- back-fill). It runs synchronously here, before 'respond' — so it can add
      -- minor latency — but is exception-proof at the source, so it cannot fail
      -- the send the user is about to receive.
      postSend
      respond $ jsonResponse status200 (object ["response" .= resp])

-- | Lazy migration (D6.5): if a corroborated registry entry's label matches
-- @windowName@, persist its 'Registry.HarnessId' onto the session's
-- 'HarnessSpec' in @session.json@ so subsequent sends route by id. Operates
-- directly on the on-disk meta (read-modify-write with a tmp-file + atomic
-- rename), mirroring the disk-only meta mutators in "PureClaw.Session.Handle".
--
-- Best-effort and exception-proof (D6.5c): a missing\/corrupt @session.json@,
-- an absent\/uncorroborated entry, or an already-id-bearing spec are all silent
-- no-ops, and ANY IO fault in the read-modify-write (a TOCTOU between
-- 'doesFileExist' and 'LBS.readFile', a permission error, a disk-full or
-- cross-device error on write\/'renameFile', or a lazy-read fault surfacing in
-- 'Aeson.decode') is caught, logged, and swallowed. Keeping routing fast must
-- never fail a send the user already received, so this function NEVER throws.
backfillHarnessId :: FrontendEnv -> Text -> Text -> IO ()
backfillHarnessId env sid windowName = do
  result <- try @SomeException go
  case result of
    Left e ->
      _lh_logError (_fe_logger env) $
        "harnessId back-fill failed (non-fatal): " <> T.pack (show e)
    Right () -> pure ()
  where
    go :: IO ()
    go = do
      mEntry <- Registry.lookupByLabel (_fe_harnessRegistry env) windowName
      case mEntry of
        Just entry | isPidCorroborated entry -> do
          let p = _fe_sessionsDir env </> T.unpack sid </> "session.json"
          ok <- doesFileExist p
          when ok $ do
            raw <- LBS.readFile p
            case Aeson.decode raw of
              Just meta -> case _sm_kind meta of
                SkHarness hs
                  | Maybe.isNothing (_h_harnessId hs) -> do
                      let hs'   = hs { _h_harnessId = Just (Registry._he_id entry) }
                          meta' = meta { _sm_kind = SkHarness hs' }
                          -- A back-fill-specific tmp suffix, distinct from the
                          -- @session.json.tmp@ used by 'touchSessionLastActive'
                          -- /'updateSessionMeta', so the post-send back-fill can
                          -- never race that mutator's tmp file on the same dir.
                          tmpP  = p <> ".backfill.tmp"
                      -- tmp-file + rename: a crash mid-write leaves the prior
                      -- session.json intact (same atomicity as 'saveMeta').
                      LBS.writeFile tmpP (Aeson.encode meta')
                      renameFile tmpP p
                _ -> pure ()
              Nothing -> pure ()
        _ -> pure ()

-- | Record a single harness transcript entry, mirroring the field shape of
-- 'harnesseSend'\/'harnessReceive' in "PureClaw.Harness.ClaudeCode".
recordHarnessEntry :: TranscriptHandle -> Direction -> Text -> IO ()
recordHarnessEntry th dir payload = do
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  _th_record th TranscriptEntry
    { _te_id            = entryId
    , _te_timestamp     = now
    , _te_harness       = Just "harness"
    , _te_model         = Nothing
    , _te_direction     = dir
    , _te_payload       = encodePayload (TE.encodeUtf8 payload)
    , _te_durationMs    = Nothing
    , _te_correlationId = entryId
    , _te_metadata      = Map.empty
    }

-- | Run a completion: load context, send to provider, execute any tool
-- calls the model emits, and loop until the model produces a turn with
-- no tool calls (or the iteration cap is hit). The transcript handle is
-- opened via 'mkBroadcastingFileTranscriptHandle' so each iteration's
-- provider-wrapper Request\/Response entries reach the broker (D25) when
-- one is configured on the 'FrontendEnv'.
doCompletion
  :: FrontendEnv
  -> SessionId
  -> SomeProvider
  -> Maybe Text  -- ^ Request-supplied model (WU5, §9.2), if any.
  -> ModelId     -- ^ Global fallback model (the @_fe_model@ IORef value).
  -> Text
  -> FilePath
  -> IO Text
doCompletion env sid provider reqModel fallbackModel userText transcriptPath = do
  -- Open a (possibly broadcasting) transcript handle for recording.
  th <- mkBroadcastingFileTranscriptHandle
          (_fe_broker env) sid (_fe_logger env) transcriptPath
  -- Resolve the per-session model with precedence (§9.2): the request's
  -- explicit model, else the most-recent model recorded in the transcript
  -- (the "rides in the transcript" fallback — read from the structured
  -- '_te_model' column, which 'loadRecentMessages' discards), else the
  -- global '_fe_model' fallback. The chosen 'ModelId' flows into
  -- 'mkTranscriptProvider' below so '_te_model' is recorded automatically.
  -- A blank/whitespace request model (e.g. {"model":""}) is treated as
  -- absent so it falls through to the transcript/global fallback rather
  -- than sending an empty model id to the provider.
  model <- case reqModel of
    Just m | not (T.null (T.strip m)) -> pure (ModelId m)
    _ -> do
      mTranscriptModel <- lastRequestModel th
      pure $ maybe fallbackModel ModelId mTranscriptModel
  -- Load recent messages for context
  history <- loadRecentMessages th 50 100000
  -- The system prompt is FROZEN per session: computed once on the first
  -- turn and thereafter replayed from the transcript unchanged (§9.1).
  -- 'frozenSystemPrompt' reads the last recorded Request's system_prompt:
  --   * Just frozen ⇒ a prior turn exists ⇒ reuse it verbatim (including a
  --     frozen-null, which must stay null — do NOT recompute, do NOT
  --     re-read custom-prompt.md).
  --   * Nothing      ⇒ first turn ⇒ compute with precedence
  --                    custom-prompt.md → per-session agent → global.
  let sessionDir = takeDirectory transcriptPath
  frozen <- frozenSystemPrompt th
  systemPrompt <- case frozen of
    Just p  -> pure p
    Nothing -> computeFirstTurnPrompt env sessionDir
  -- Build context with system prompt and history
  let ctx0 = foldl (flip addMessage) (emptyContext systemPrompt) history
      userMsg = textMessage User userText
      ctx = addMessage userMsg ctx0
      -- Wrap provider with transcript logging
      provider' = mkTranscriptProvider th (unModelId model) Nothing provider
      reg = _fe_registry env
      tools = registryDefinitions reg
      cap = _fe_maxToolIterations env
  -- Publish session-thinking activity events so the FE sidebar / chat
  -- area can show a live indicator while the provider call is in flight.
  -- For harness-backed sessions, the equivalent signal comes from the
  -- 2s tmux probe loop in 'PureClaw.Frontend.ActivityProbe'; provider
  -- sessions don't go through the harness map, so the only place we
  -- can hook this is at the request boundary in 'doCompletion'.
  -- 'bracket_' guarantees the Idle event fires even if 'complete' throws.
  let publishStatus s = case _fe_broker env of
        Just broker -> _streamBroker_publish broker
          (ActivityChanged sid (SaHarnessStatus s))
        Nothing -> pure ()
  result <- bracket_
              (publishStatus HarnessThinking)
              (publishStatus HarnessIdle)
              (runCompletionLoop env provider' model tools reg cap ctx)
  _th_flush th
  _th_close th
  -- Bump the session's on-disk _sm_lastActive so the sidebar "age" pill
  -- reflects this completion. The gateway records through a raw
  -- broadcasting transcript handle, which bypasses the touchLastActive
  -- wrapper that live SessionHandles get, so we update the metadata
  -- explicitly here and re-broadcast the lists snapshot to subscribers.
  touchSessionLastActive (_fe_sessionsDir env) sid
  broadcastLists env
  pure result

-- | Section-character limit used when rendering a per-session agent's
-- system prompt, matching the limit used elsewhere for web/session agent
-- rendering (e.g. the @/agent@ slash command).
agentPromptSectionLimit :: Int
agentPromptSectionLimit = 8000

-- | Compute the system prompt for the FIRST turn of a session (called only
-- when 'frozenSystemPrompt' returns 'Nothing'). Precedence (§9.1):
--
--   1. @custom-prompt.md@ in the session dir (user override), if present.
--   2. The per-session agent (from @session.json@'s @_sm_agent@), rendered
--      with 'composeAgentPromptWithBootstrap' honoring the session's
--      @_sm_bootstrapConsumed@ state. A missing/undiscoverable agent (F7)
--      or an empty/whitespace render (F8) falls through to the global
--      prompt — never a 500.
--   3. The global @_fe_systemPrompt@.
--
-- The computed value is frozen into the transcript automatically because
-- 'doCompletion' records the request that carries it.
computeFirstTurnPrompt :: FrontendEnv -> FilePath -> IO (Maybe Text)
computeFirstTurnPrompt env sessionDir = do
  let customPromptPath = sessionDir </> "custom-prompt.md"
  customExists <- doesFileExist customPromptPath
  if customExists
    then Just <$> TIO.readFile customPromptPath
    else do
      mAgentPrompt <- renderSessionAgentPrompt env sessionDir
      case mAgentPrompt of
        Just p  -> pure (Just p)
        Nothing -> pure (_fe_systemPrompt env)

-- | Render the per-session agent's system prompt, or 'Nothing' if there is
-- no usable agent. Reads the session's @_sm_agent@ inline from
-- @session.json@, looks the agent up under @_fe_agentsDir@, and renders it
-- honoring @_sm_bootstrapConsumed@. Returns 'Nothing' (so the caller falls
-- back to the global prompt) when:
--
--   * @session.json@ is missing or fails to decode;
--   * @_sm_agent@ is 'Nothing';
--   * the named agent is not found under @_fe_agentsDir@ (F7); or
--   * the rendered prompt is empty/whitespace (F8).
renderSessionAgentPrompt :: FrontendEnv -> FilePath -> IO (Maybe Text)
renderSessionAgentPrompt env sessionDir = do
  let metaPath = sessionDir </> "session.json"
  readResult <- try @IOException (LBS.readFile metaPath)
  let raw = either (Left . show) Right readResult
  case raw >>= Aeson.eitherDecode' of
    Left err -> do
      _lh_logWarn (_fe_logger env) $
        "Per-session agent: could not read session.json (" <>
        T.pack metaPath <> "): " <> T.pack err <> " — falling back to global prompt"
      pure Nothing
    Right meta -> case _sm_agent (meta :: SessionMeta) of
      Nothing   -> pure Nothing
      Just name -> do
        mDef <- loadAgent (_fe_agentsDir env) name
        case mDef of
          Nothing -> do
            _lh_logWarn (_fe_logger env) $
              "Per-session agent \"" <> unAgentName name <>
              "\" not found under " <> T.pack (_fe_agentsDir env) <>
              " — falling back to global prompt"
            pure Nothing
          Just def -> do
            rendered <- composeAgentPromptWithBootstrap
                          (_fe_logger env) def agentPromptSectionLimit
                          (_sm_bootstrapConsumed meta)
            if T.null (T.strip rendered)
              then do
                _lh_logWarn (_fe_logger env) $
                  "Per-session agent \"" <> unAgentName name <>
                  "\" rendered an empty prompt — falling back to global prompt"
                pure Nothing
              else pure (Just rendered)

-- | Loop: call the provider, execute any tool_use blocks, append the
-- tool_result message to context, and recurse. Terminates when the
-- model returns a turn without tool calls or when @iters@ reaches zero.
runCompletionLoop
  :: FrontendEnv
  -> SomeProvider
  -> ModelId
  -> [ToolDefinition]
  -> ToolRegistry
  -> Int           -- ^ remaining iterations
  -> Context
  -> IO Text
runCompletionLoop env provider' model tools reg iters ctx
  | iters <= 0 = do
      _lh_logWarn (_fe_logger env)
        "Tool iteration cap reached; returning placeholder response"
      pure "Tool iteration cap reached without a final response."
  | otherwise = do
      let req = CompletionRequest
            { _cr_model        = model
            , _cr_messages     = contextMessages ctx
            , _cr_systemPrompt = contextSystemPrompt ctx
            , _cr_maxTokens    = Just 4096
            , _cr_tools        = tools
            , _cr_toolChoice   = Nothing
            }
      resp <- complete provider' req
      let calls = toolUseCalls resp
          assistantMsg = Message Assistant (_crsp_content resp)
          ctx' = addMessage assistantMsg ctx
      if null calls
        then pure (responseText resp)
        else do
          results <- mapM (executeOneCall env reg) calls
          let ctx'' = addMessage (toolResultMessage results) ctx'
          runCompletionLoop env provider' model tools reg (iters - 1) ctx''

-- | Execute a single tool call against the registry, logging any
-- unknown-tool or error condition.
executeOneCall
  :: FrontendEnv
  -> ToolRegistry
  -> (ToolCallId, Text, Value)
  -> IO (ToolCallId, [ToolResultPart], Bool)
executeOneCall env reg (callId, name, input) = do
  _lh_logInfo (_fe_logger env) $ "Tool call: " <> name
  result <- executeTool reg name input
  case result of
    Nothing -> do
      _lh_logWarn (_fe_logger env) $ "Unknown tool: " <> name
      pure (callId, [TRPText ("Unknown tool: " <> name)], True)
    Just (parts, isErr) -> do
      when isErr $ _lh_logWarn (_fe_logger env)
        ("Tool error in " <> name)
      pure (callId, parts, isErr)

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
