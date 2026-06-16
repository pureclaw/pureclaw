module PureClaw.Frontend.API
  ( -- * WAI Application
    apiApp
    -- * Environment
  , FrontendEnv (..)
  , StartedHarness (..)
  , spawnHarnessSession
  , ReleaseTmux (..)
  , productionReleaseTmux
  , productionKillWindow
  , pickLiveMarker
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
    -- Re-exported from "PureClaw.Frontend.TabsView"
  , livenessToTabStatus
  , harnessOriginToText
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
import Data.Aeson (Value, ToJSON (..), FromJSON (..), object, (.=), (.:), (.:?), (.!=))
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

import PureClaw.Tabs (TabRegistry, readTabs, registryAppend, registryRemove)
import PureClaw.Tabs.Types (CursorState, Tab (..), TabRef (..), TabsError (..), toList)
import PureClaw.Tabs.Exec (Exec, release)

import PureClaw.Agent.AgentDef
  ( AgentDef (..)
  , composeAgentPromptWithBootstrap
  , discoverAgents
  , loadAgent
  , unAgentName
  )
import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.Context
import PureClaw.Core.Types (MessageSource (..), ModelId (..), SessionId (..), ToolCallId, UserId (..), channelKindToText, isValidSessionId, unModelId, unSessionId)
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.BroadcastingTranscript (mkBroadcastingFileTranscriptHandle)
import PureClaw.Frontend.TabsView
  ( TabSnapshot (..)
  , livenessToTabStatus
  , harnessOriginToText
  , tabSnapshotsFromRegistry
  )
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  )
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Tab (TabIndex, TabKind (..), unTabIndex)
import PureClaw.Harness.Discovery (DiscoverableWindow, scanDiscoverableIO)
import PureClaw.Harness.Reconcile (livenessToActivity)
import PureClaw.Harness.Tmux qualified as Tmux
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Security.Adoption
  ( AdoptError (..)
  , AdoptedHarness
  , ConsentChannel (..)
  , authorizeAdoption
  )
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
  , _fe_consentChannel :: ConsentChannel
    -- ^ How the run that drives this frontend was launched: the foreground
    -- interactive TUI ('ConsentInteractive'), the gateway-served web UI
    -- ('ConsentWeb'), or a truly unattended run with no human picking a window
    -- ('ConsentHeadless' — bot\/cron\/import\/tests). The @POST \/api\/adopt@
    -- endpoint passes this to 'authorizeAdoption' BEFORE any tmux mutation.
    -- 'ConsentInteractive' and 'ConsentWeb' authorize (the human's New-Tab\/
    -- "Existing Harness" window selection IS the consent); 'ConsentHeadless' is
    -- denied even with a valid consent body (design §8 B2, SEC-1\/FEAS-2). This
    -- is the SOLE remaining adoption gate now that the allow-list was dropped.
    -- Tests default to 'ConsentHeadless' (fail-closed).
  , _fe_adopt        :: AdoptedHarness -> Text -> IO (Either HarnessError (Registry.HarnessId, HarnessHandle))
    -- ^ Adopt an external, discovered tmux window into the registry. The
    -- 'AdoptedHarness' argument is the capability token from 'authorizeAdoption'
    -- (its value constructor is unexported, so this seam is impossible to call
    -- without first passing the consent + allow-list gate — D4.3, type-enforced).
    -- The 'Text' is the window name to adopt; the session rides in the token.
    -- The dispatcher wires the real 'adoptExternalWindow' mechanism (which
    -- stamps @\@pcl_id@, sets the capture baseline to the current scrollback
    -- end, registers an @OriginAdopted@ entry, and links a @session.json@); the
    -- default test stub returns @Left@. The endpoint additionally syncs the
    -- legacy '_fe_harnesses' map on success (D-ADD-2).
  , _fe_releaseTmux  :: ReleaseTmux
    -- ^ The two tmux primitives the @POST \/api\/tabs\/{index}\/release@
    -- endpoint needs, bundled so they can be injected as a single seam (Phase 3
    -- WU5). 'productionReleaseTmux' wires them to the real
    -- 'Tmux.readMarkers'-based live-@\@pcl_id@ lookup and 'Tmux.clearWindowMarker'.
    -- The endpoint re-corroborates the live marker BEFORE issuing any
    -- @set-option@ (SEC-3 anti-spoof): it NEVER calls @_rt_clearMarker@ unless
    -- the live marker still equals THIS entry's id. Tests inject a recording
    -- 'ReleaseTmux' to assert the @set-option -wu@ argv (D5.1) and to prove no
    -- tmux mutation happens on a stale\/uncorroborated entry (D5.2).
  , _fe_killWindow   :: Text -> Text -> IO ()
    -- ^ Kill the tmux window at @(session, windowName)@ — terminates the
    -- harness's claude-code process and the pane's shell. Used ONLY by
    -- @POST \/api\/tabs\/{index}\/destroy@, and ONLY after the handler
    -- re-corroborates (via '_fe_releaseTmux'\'s @_rt_liveMarker@) that the live
    -- @\@pcl_id@ still equals THIS entry's id (SEC-3): we never kill a window we
    -- cannot confirm is ours. Production wires 'Tmux.stopHarnessWindowNamed'
    -- (@kill-window@); the default test stub is a no-op.
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
    -- ^ Maximum number of tabs allowed (A8 enforcement). Enforced against the
    -- live '_fe_tabRegistry' length (WU7) — the registry is the single source
    -- of truth for the open-tab count.
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
  , _fe_agentEnv :: AgentEnv
    -- ^ Shared base env; '_env_channel'/'_env_session' are overridden per
    -- request by the slash-dispatch caller (Task 7). Leave LAZY (no bang):
    -- in CLI.Commands 'env' and 'frontendEnv' are bound in the same recursive
    -- 'let', so this back-edge ties the knot without forcing at construction.
  , _fe_tabRegistry :: TabRegistry
    -- ^ The live first-class tab registry (WU6). 'tabsFromRegistry' reads
    -- this alongside '_fe_harnessRegistry' to project the canonical
    -- @GET \/api\/tabs@ list. Shares the SAME 'TabRegistry' as
    -- 'AgentEnv._env_tabRegistry' so both views observe the same state.
    -- Tests wire a fresh 'newTabRegistry' (empty on construction).
  , _fe_cursors :: IORef CursorState
    -- ^ Per-conversation cursor state (WU6 / WU7). Shared with the agent
    -- loop. Unused in WU6 directly but added now to avoid a second
    -- 'FrontendEnv' churn pass in WU7. Tests wire @newIORef emptyCursors@.
  , _fe_exec :: Exec
    -- ^ Refcounted per-'TabRef' runtime registry (WU6 / WU7). Unused in
    -- WU6 directly but added now to allow WU7's close-path runtime release
    -- without another 'FrontendEnv' churn pass. Tests wire 'newExec'.
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
  , _shh_claudeSessionUuid :: !(Maybe Text)
    -- ^ The canonical @claude-code@ session UUID minted at spawn time and
    -- injected as @--session-id \<uuid\>@ into the spawned @claude@ argv (WU6).
    -- 'createHarnessTab' persists it into the session's
    -- 'PureClaw.Session.Kind._h_claudeSessionUuid' so a restart can re-derive
    -- the JSONL log path. 'Nothing' for non-@claude-code@\/adopted harnesses.
    -- The SAME minted value is injected into the argv AND returned here, so the
    -- persisted uuid is guaranteed to match the one claude-code writes its log
    -- under.
  , _shh_canonicalCwd :: !(Maybe Text)
    -- ^ The canonicalized spawn working directory used for JSONL log-path
    -- derivation (WU6 D6.3). 'createHarnessTab' persists it into
    -- 'PureClaw.Session.Kind._h_canonicalCwd'. 'Nothing' when not a spawned
    -- @claude-code@ harness.
  }

-- | The two tmux primitives the Release endpoint (Phase 3 WU5) needs, bundled
-- as one injectable seam so the security-critical /corroborate-before-mutate/
-- ordering lives in the handler (not hidden behind the seam) while still being
-- fully testable.
--
-- @_rt_liveMarker session window@ re-reads the LIVE @\@pcl_id@ of the window at
-- the entry's cached @(session, window)@ coordinate, returning 'Nothing' when
-- the window is gone or carries no (non-empty) marker. @_rt_clearMarker session
-- window@ unsets @\@pcl_id@ (@set-option -wu@) — it is invoked ONLY after the
-- handler confirms the live marker still equals THIS entry's id (SEC-3), and it
-- NEVER kills the window.
data ReleaseTmux = ReleaseTmux
  { _rt_liveMarker  :: Text -> Text -> IO (Maybe Text)
  , _rt_clearMarker :: Text -> Text -> IO ()
  , _rt_renameWindow :: Text -> Text -> Text -> IO ()
    -- ^ @session currentName newName@: rename the released window so its tmux
    -- title shows PureClaw has detached. Invoked ONLY on the corroborated
    -- branch (right after '_rt_clearMarker'), so we only retitle a window we
    -- just confirmed is ours; like clear, it NEVER kills the window.
  }

-- | The new tmux window title applied when PureClaw releases a harness — the
-- original (PureClaw-managed) name with a @\" (released)\"@ suffix so the user
-- can see at a glance that PureClaw is no longer attached.
releasedWindowName :: Text -> Text
releasedWindowName current = current <> " (released)"

-- | The production 'ReleaseTmux': the live-marker lookup is a 'Tmux.readMarkers'
-- sweep of the session filtered to the target window (returning its non-empty
-- @\@pcl_id@), and the clear is 'Tmux.clearWindowMarker' (@set-option -wu@).
-- Both route through the authorized tmux seam ('Tmux.tmuxProc').
productionReleaseTmux :: ReleaseTmux
productionReleaseTmux = ReleaseTmux
  { _rt_liveMarker  = \session window ->
      pickLiveMarker window <$> Tmux.readMarkers session
  , _rt_clearMarker = Tmux.clearWindowMarker
  , _rt_renameWindow = Tmux.renameWindowNamed
  }

-- | The production '_fe_killWindow': 'Tmux.stopHarnessWindowNamed', which issues
-- @kill-window -t session:window@ through the authorized tmux seam. Terminates
-- the harness's claude-code process and the pane shell. Invoked by Destroy ONLY
-- after the handler re-corroborates the window is ours (SEC-3).
productionKillWindow :: Text -> Text -> IO ()
productionKillWindow = Tmux.stopHarnessWindowNamed

-- | Pure core of the production live-@\@pcl_id@ lookup: from a session's
-- 'Tmux.readMarkers' sweep, return the non-empty @\@pcl_id@ of the row whose
-- window name matches @window@, or 'Nothing' when the window is absent or its
-- marker is empty\/unset. Empty markers are treated as \"no marker\" so an
-- unmarked\/cleared window never spuriously corroborates.
pickLiveMarker :: Text -> [Tmux.TmuxWindowRow] -> Maybe Text
pickLiveMarker window rows =
  Maybe.listToMaybe
    [ Tmux._twr_pclId r
    | r <- rows
    , Tmux._twr_windowName r == window
    , not (T.null (Tmux._twr_pclId r))
    ]

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

-- | Project the harness registry's entries onto @TabSnapshot@s for the
-- Active-Tabs list. Phase-1 minimal slice: only harness entries are surfaced
-- (provider\/raw_shell tabs are the Phase-2 full tab model).
--
-- 'HarnessEntry' carries no intrinsic tab index in Phase 1, so the index is a
-- STABLE DISPLAY ORDERING derived by sorting deterministically on
-- @(label, id-text)@ and enumerating from 0. Full tab-index semantics are
-- Phase 2.
-- | The canonical display ordering of harness entries: sort deterministically
-- on @(label, id-text)@. This is the SINGLE source of the index→entry mapping —
-- both 'harnessEntriesToTabs' (which enumerates this list to assign
-- '_ts_index') and 'tabIndexToEntry' (which resolves an action's display index
-- back to an entry) consume it, so a @POST \/api\/tabs\/{n}\/...@ action always
-- targets exactly the row @GET \/api\/tabs@ shows at index @n@.
sortedHarnessEntries :: [Registry.HarnessEntry] -> [Registry.HarnessEntry]
sortedHarnessEntries =
  List.sortOn
    (\e -> (Registry._he_label e, Registry.harnessIdToText (Registry._he_id e)))

-- | Resolve a display tab index to the 'TabRegistry' slot occupying it (WU7).
-- This replaces the old '/api/tabs' position-against-'sortedHarnessEntries'
-- aliasing: now that provider AND harness tabs interleave in one ordered
-- 'TabList', a tab-action endpoint must target the registry slot whose
-- '_tab_slot' display index equals @idx@, NOT the n-th harness entry.
--
-- Returns @Just (slot, ref)@ — the validated 'TabIndex' and the bound 'TabRef'
-- — for the tab at display index @idx@, or 'Nothing' when no tab occupies it.
-- The slot is read back from the matched 'Tab' (so callers pass it straight to
-- 'registryRemove'\/'release' without re-validating the raw 'Int').
resolveRegistrySlot :: FrontendEnv -> Int -> IO (Maybe (TabIndex, TabRef))
resolveRegistrySlot env idx = do
  tabs <- toList <$> readTabs (_fe_tabRegistry env)
  pure $ case [ t | t <- tabs, unTabIndex (_tab_slot t) == idx ] of
    (t : _) -> Just (_tab_slot t, _tab_ref t)
    []      -> Nothing

harnessEntriesToTabs :: [Registry.HarnessEntry] -> [TabSnapshot]
harnessEntriesToTabs entries =
  zipWith toTab [0 ..] (sortedHarnessEntries entries)
  where
    toTab :: Int -> Registry.HarnessEntry -> TabSnapshot
    toTab idx e = TabSnapshot
      { _ts_index         = idx
      , _ts_kind          = "harness"
      , _ts_name          = Registry._he_label e
      , _ts_status        = livenessToTabStatus (Registry._he_liveness e)
      , _ts_sessionId     = Registry._he_sessionId e
      , _ts_extModified   = Registry._he_extModified e
      , _ts_stale         = Registry._he_stale e
      , _ts_origin        = harnessOriginToText (Registry._he_origin e)
      , _ts_attachCommand =
          Just ("tmux attach -t " <> Registry._he_session e
                  <> ":" <> Registry._he_windowName e)
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
    ("POST", ["api", "tabs", tidx, "dismiss"]) ->
      handleDismissTab env tidx respond
    ("POST", ["api", "tabs", tidx, "release"]) ->
      handleReleaseTab env tidx req respond
    ("POST", ["api", "tabs", tidx, "destroy"]) ->
      handleDestroyTab env tidx req respond
    ("POST", ["api", "tabs", tidx, "acknowledge"]) ->
      handleAcknowledgeTab env tidx respond
    ("POST", ["api", "tabs", _tidx, "restart"]) ->
      handleRestartTab respond
    ("POST", ["api", "tabs", "new"]) ->
      handleNewTab env req respond
    ("POST", ["api", "discovery", "scan"]) ->
      handleDiscoveryScan env respond
    ("POST", ["api", "adopt"]) ->
      handleAdopt env req respond
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

-- | Build the live tab list from the backend 'TabRegistry' enriched with
-- 'Registry.HarnessEntry' data for harness-backed tabs (WU6). This is the
-- canonical source of the @GET \/api\/tabs@ response: 'tabSnapshotsFromRegistry'
-- does the pure projection; we read both registries here so the function is
-- pure and testable without IO.
--
-- The 'harnOf' lookup function finds a 'Registry.HarnessEntry' by its
-- 'Registry.HarnessId' using a linear scan of the current registry snapshot
-- (the registry is small in practice).
tabsFromRegistry :: FrontendEnv -> IO [TabSnapshot]
tabsFromRegistry env = do
  tl      <- readTabs (_fe_tabRegistry env)
  entries <- Registry.snapshot (_fe_harnessRegistry env)
  let harnOf hid = List.find ((== hid) . Registry._he_id) entries
  pure (tabSnapshotsFromRegistry tl harnOf)

-- | Return all currently open tabs as a JSON array.
handleListTabs :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleListTabs env respond = do
  tabs <- tabsFromRegistry env
  respond $ jsonResponse status200 tabs

-- | On-demand discovery of adoptable (PureClaw-unmarked) tmux windows
-- (Phase 3, WU2). The scan LISTS ALL tmux sessions and is METADATA-ONLY — it
-- never captures a pane (design @docs\/harness-registry.md@ §8 B2\/C1). The
-- adoption allow-list was dropped: consent gates adoption (a separate action,
-- WU4), not discovery. Discovered candidates are transient (not registry
-- entries).
handleDiscoveryScan :: FrontendEnv -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleDiscoveryScan _env respond = do
  candidates <- scanDiscoverableIO
  respond $ jsonResponse status200 (candidates :: [DiscoverableWindow])

-- | Request body for @POST \/api\/adopt@. A discovered candidate has NO tab
-- index (it is not a registry entry yet), so it is addressed by
-- @session@ + @window@ — the "resolve a 'DiscoverableWindow' target" shape. The
-- @consent_confirmed@ flag is the browser dialog's confirmation; the endpoint
-- requires it @== true@ (a 400 otherwise) AND independently requires an
-- interactive consent CHANNEL via 'authorizeAdoption' (a 403 otherwise) — a
-- client cannot bypass the channel check by sending @consent_confirmed:true@.
data AdoptRequest = AdoptRequest
  { _ar_session          :: !Text
  , _ar_window           :: !Text
  , _ar_consentConfirmed :: !Bool
  }

instance FromJSON AdoptRequest where
  parseJSON = Aeson.withObject "AdoptRequest" $ \o ->
    AdoptRequest
      <$> o .: "session"
      <*> o .: "window"
      <*> o .:? "consent_confirmed" .!= False

-- | @POST \/api\/adopt@ — adopt an external (discovered, UNMARKED) tmux window
-- into the registry (Phase 3, WU4). SECURITY-CRITICAL ordering (SEC-1):
-- 'authorizeAdoption' runs BEFORE any tmux mutation, so a denied request stamps
-- NO @\@pcl_id@ and creates NO registry entry.
--
-- Steps:
--
--   1. Decode the body; require @consent_confirmed == true@ (else @400@).
--   2. 'authorizeAdoption' (_fe_consentChannel) session:
--
--        * @Left AdoptNoConsentChannel@ → @403@ (a headless\/gateway\/import run
--          has no human at the confirm dialog — fail-closed, the SOLE remaining
--          denial; denies even a @consent_confirmed:true@ body).
--        * @Right token@ → run '_fe_adopt' with the token. On success @200@; on
--          a tmux\/adopt failure @500@.
--
-- On a successful adopt the legacy '_fe_harnesses' map is synced (D-ADD-2) so
-- name-keyed routing keeps working until the session.json id is consulted.
handleAdopt :: FrontendEnv -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleAdopt env req respond = do
  body <- consumeBody req
  case Aeson.eitherDecode body of
    Left err ->
      respond $ jsonResponse status400
        (object ["error" .= ("Invalid JSON: " <> T.pack err)])
    Right ar
      | not (_ar_consentConfirmed ar) ->
          respond $ jsonResponse status400
            (object ["error" .= ("adoption requires consent_confirmed: true" :: Text)])
      | otherwise ->
          -- SEC-1: the gate runs BEFORE any tmux mutation. On Left we respond
          -- and NEVER call '_fe_adopt', so nothing is stamped/registered.
          case authorizeAdoption (_fe_consentChannel env) (_ar_session ar) of
            Left AdoptNoConsentChannel ->
              respond $ jsonResponse status403
                (object ["error" .= ("adoption requires an interactive consent channel" :: Text)])
            Right token -> do
              result <- _fe_adopt env token (_ar_window ar)
              case result of
                Left err ->
                  respond $ harnessErrorResponse err
                Right (hid, hh) -> do
                  -- D-ADD-2: sync the legacy name-keyed map so name-fallback
                  -- routing reaches the adopted handle immediately.
                  modifyIORef' (_fe_harnesses env) (Map.insert (_ar_window ar) hh)
                  -- Surface the PureClaw session id created for this harness (it
                  -- lives on the registry entry's '_he_sessionId') so the web
                  -- "Existing Harness" composer can drop the user into the
                  -- conversation and send a first message right after adopting.
                  -- 'Nothing' -> null.
                  mEntry <- Registry.lookupById (_fe_harnessRegistry env) hid
                  broadcastLists env
                  respond $ jsonResponse status200
                    (object
                      [ "adopted"     .= True
                      , "harness_id"  .= Registry.harnessIdToText hid
                      , "session"     .= _ar_session ar
                      , "window"      .= _ar_window ar
                      , "session_id"  .= (mEntry >>= Registry._he_sessionId)
                      ])

-- | @POST \/api\/tabs\/{index}\/close@ — close a tab of ANY kind (WU7). The
-- display index is resolved against the first-class 'TabRegistry' slot
-- ('resolveRegistrySlot'), NOT against the harness-entry ordering, so it targets
-- exactly the row @GET \/api\/tabs@ shows at that index even once provider and
-- harness tabs interleave. On a non-numeric index responds @400@; on a slot with
-- no tab responds @404@.
--
-- Close removes the tab from the registry and tears down its binding, but —
-- unlike Destroy — NEVER kills a tmux window:
--
--   * 'BoundSession' (provider\/raw-shell) → 'release' the per-ref runtime via
--     '_fe_exec' (decrements the refcount; stops the runtime on the last hold),
--     then drop the tab.
--   * 'BoundHarness' → deregister the harness from the legacy '_fe_harnesses'
--     map and the harness registry and drop the tab, but leave the tmux window
--     + process running (PureClaw simply stops surfacing it as a tab). The
--     backing @session.json@\/transcript are retained.
handleCloseTab :: FrontendEnv -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleCloseTab env tidxText respond =
  case reads (T.unpack tidxText) :: [(Int, String)] of
    [(idx, "")] -> do
      mResolved <- resolveRegistrySlot env idx
      case mResolved of
        Nothing ->
          respond $ jsonResponse status404
            (object ["error" .= ("No tab at index " <> tidxText)])
        Just (slot, ref) -> do
          case ref of
            BoundSession _ ->
              -- Stop the runtime backing this session ref (refcounted; the last
              -- release tears it down). Harmless if no runtime was ever ensured.
              release (_fe_exec env) ref
            BoundHarness hid -> do
              -- Drop the harness binding from both legacy + durable stores, but
              -- DO NOT kill the window (Close never kills — that is Destroy).
              mEntry <- Registry.lookupById (_fe_harnessRegistry env) hid
              Maybe.maybe (pure ())
                (modifyIORef' (_fe_harnesses env) . Map.delete . Registry._he_label)
                mEntry
              Registry.deleteEntry (_fe_harnessRegistry env) hid
          registryRemove (_fe_tabRegistry env) slot
          broadcastLists env
          respond $ jsonResponse status200 (object ["closed" .= True])
    _ ->
      respond $ jsonResponse status400 (object ["error" .= ("Invalid tab index" :: Text)])

-- | Parse a display tab index, resolve it against the CURRENT 'TabRegistry'
-- slot ('resolveRegistrySlot'), and run a HARNESS-ONLY action with the bound
-- 'Registry.HarnessEntry' (WU7). The resolution moved from harness-entry
-- position to registry slot: now that provider and harness tabs interleave in
-- one ordered list, a @POST \/api\/tabs\/{n}\/...@ action targets exactly the
-- row @GET \/api\/tabs@ shows at index @n@.
--
-- Responses:
--
--   * non-numeric index → @400@ \"Invalid tab index\";
--   * no tab at the slot → @404@ \"No tab at index n\";
--   * the slot binds a 'BoundSession' (a provider\/raw-shell tab) → @400@
--     \"not a harness tab\" (Dismiss\/Release\/Destroy\/Acknowledge are
--     harness-only — a session tab is removed via Close, not these);
--   * the slot binds a 'BoundHarness' whose entry has vanished from the
--     harness registry → @404@ \"No tab at index n\";
--   * otherwise runs @act@ with the resolved 'Registry.HarnessEntry' (the
--     existing teardown bodies are unchanged — only the resolution differs).
withResolvedTab
  :: FrontendEnv
  -> Text
  -> (Response -> IO ResponseReceived)
  -> (TabIndex -> Registry.HarnessEntry -> IO ResponseReceived)
  -> IO ResponseReceived
withResolvedTab env tidxText respond act =
  case reads (T.unpack tidxText) :: [(Int, String)] of
    [(idx, "")] -> do
      mResolved <- resolveRegistrySlot env idx
      case mResolved of
        Nothing ->
          respond $ jsonResponse status404
            (object ["error" .= ("No tab at index " <> tidxText)])
        Just (_, BoundSession _) ->
          respond $ jsonResponse status400
            (object ["error" .= ("not a harness tab" :: Text)])
        Just (slot, BoundHarness hid) -> do
          mEntry <- Registry.lookupById (_fe_harnessRegistry env) hid
          case mEntry of
            Just e  -> act slot e
            Nothing ->
              respond $ jsonResponse status404
                (object ["error" .= ("No tab at index " <> tidxText)])
    _ ->
      respond $ jsonResponse status400 (object ["error" .= ("Invalid tab index" :: Text)])

-- | @POST \/api\/tabs\/{index}\/dismiss@ — user-initiated removal of an
-- Exited\/Orphaned row. Removes the entry from BOTH the registry and the legacy
-- '_fe_harnesses' map, but NEVER touches @session.json@ — so the session
-- reappears in Recent Sessions (design §7 \"appears in exactly one section\").
-- Acts on both stores directly (the registry and legacy map both live on
-- 'FrontendEnv'), so no extra callback is needed.
handleDismissTab :: FrontendEnv -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleDismissTab env tidxText respond =
  withResolvedTab env tidxText respond $ \slot e -> do
    Registry.deleteEntry (_fe_harnessRegistry env) (Registry._he_id e)
    modifyIORef' (_fe_harnesses env) (Map.delete (Registry._he_label e))
    -- Remove the tab from the first-class registry too (WU7) so the dismissed
    -- harness no longer projects a dangling row into GET /api/tabs.
    registryRemove (_fe_tabRegistry env) slot
    broadcastLists env
    respond $ jsonResponse status200 (object ["dismissed" .= True])

-- | Request body for @POST \/api\/tabs\/{index}\/release@. The @purge@ flag is
-- ACCEPTED but RESERVED for the Phase-3 MVP: transcript\/@session.json@ are
-- retained regardless (design §8 C2). It is decoded so a future release can
-- honor it without a wire-format change; today it is a documented no-op.
data ReleaseRequest = ReleaseRequest
  { _rr_purge :: !Bool
  }

instance FromJSON ReleaseRequest where
  parseJSON = Aeson.withObject "ReleaseRequest" $ \o ->
    ReleaseRequest <$> o .:? "purge" .!= False

-- | @POST \/api\/tabs\/{index}\/release@ — release an ADOPTED harness: stop
-- managing it and REMOVE PureClaw's @\@pcl_id@ marker, but NEVER kill the
-- window and RETAIN its transcript\/@session.json@ (design §6, §8 C2). Distinct
-- from Dismiss (which removes a dead row with no tmux op) and from Close (which
-- never kills either): Release issues a @set-option -wu@ on a LIVE window — but
-- ONLY after re-corroborating it is still ours (SEC-3 anti-spoof).
--
-- SECURITY-CRITICAL ordering — re-corroboration runs BEFORE any tmux mutation:
--
--   1. Resolve the display index → entry (shared 'tabIndexToEntry' resolver).
--   2. Release applies to a harness of ANY origin (Spawned, Adopted, or
--      Discovered) — the safety control is the corroboration in step 3, not the
--      origin. PureClaw stops managing the window and hands it back.
--   3. Re-read the LIVE @\@pcl_id@ of the entry's @(session, windowName)@ via
--      the injected seam and compare to @harnessIdToText (_he_id entry)@:
--
--        * MATCH → 'Tmux.clearWindowMarker' (@set-option -wu@) + retitle the
--          window via 'Tmux.renameWindowNamed' to @\"… (released)\"@, then
--          deregister from the registry AND the legacy '_fe_harnesses' map;
--          respond @200 {"released":true}@. The window is NOT killed.
--        * MISMATCH \/ window gone (the cached coord now points at a different
--          \/absent window — the PID-reuse\/replacement case) → deregister from
--          BOTH stores WITHOUT issuing ANY tmux @set-option@\/mutation, and log
--          a refusal; respond @200 {"released":true,"note":...}@. The invariant:
--          NEVER @set-option -wu@ a window we cannot confirm is ours.
--
-- The @purge@ body flag is accepted but RESERVED (documented no-op; retention
-- only — design §8 C2).
handleReleaseTab
  :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleReleaseTab env tidxText req respond = do
  body <- consumeBody req
  -- The body is optional; an empty/garbage body decodes to the default
  -- (purge = False). The purge flag is reserved regardless, so we never fail the
  -- request on a bad body.
  let reservedPurge = case Aeson.eitherDecode body of
        Right rr -> _rr_purge rr
        Left _   -> False
  -- RESERVED (Phase-3 MVP = retention only, design §8 C2): accepted but a
  -- documented no-op. We log when it is requested so the intent is auditable,
  -- but we do NOT purge/delete the transcript or session.json.
  when reservedPurge $
    _lh_logInfo (_fe_logger env)
      "release: purge requested but RESERVED (Phase-3 MVP retains transcript/session.json)"
  -- Release applies to ANY harness (spawned OR adopted): PureClaw stops managing
  -- it but leaves the tmux window + processes running. The corroborate-before-
  -- mutate gate inside 'releaseHarnessEntry' is the safety control, not the
  -- origin.
  withResolvedTab env tidxText respond $ \slot e -> releaseHarnessEntry env slot e respond

-- | The corroborate-then-act core of Release, for a harness of ANY origin.
-- Re-reads the live @\@pcl_id@ BEFORE any mutation (SEC-3) and branches:
-- corroborated → unmark + retitle the window \"… (released)\" + deregister;
-- stale → deregister only (no tmux op) + warn. Either way the entry leaves both
-- stores, the window survives, and the transcript\/@session.json@ are retained
-- (C2).
releaseHarnessEntry
  :: FrontendEnv -> TabIndex -> Registry.HarnessEntry -> (Response -> IO ResponseReceived) -> IO ResponseReceived
releaseHarnessEntry env slot e respond = do
  let session  = Registry._he_session e
      window   = Registry._he_windowName e
      expected = Registry.harnessIdToText (Registry._he_id e)
      rt       = _fe_releaseTmux env
  liveMarker <- _rt_liveMarker rt session window
  if liveMarker == Just expected
    then do
      -- Corroborated: the live window still carries THIS entry's marker, so it
      -- is safe to mutate it. Unmark it (@pcl_id), then retitle it so the user
      -- can see PureClaw has detached. Neither op kills the window. The window
      -- name is PureClaw-managed (spawn: @claude-code-N@; adopt: @adopted-…@),
      -- so it is dot-free and the @session:name@ rename target is unambiguous.
      _rt_clearMarker rt session window
      _rt_renameWindow rt session window (releasedWindowName window)
      deregister env slot e
      broadcastLists env
      respond $ jsonResponse status200 (object ["released" .= True])
    else do
      -- Stale/uncorroborated: the cached coord no longer points at our window
      -- (mismatched marker or window gone — PID-reuse/replacement). We refuse to
      -- `set-option -wu` a window we can't confirm is ours; deregister WITHOUT
      -- any tmux mutation and log the refusal.
      _lh_logWarn (_fe_logger env) $
        "release: window " <> session <> ":" <> window
          <> " no longer corroborated (live @pcl_id="
          <> Maybe.fromMaybe "<none>" liveMarker
          <> ", expected " <> expected
          <> "); deregistering WITHOUT unmarking"
      deregister env slot e
      broadcastLists env
      respond $ jsonResponse status200
        (object
          [ "released" .= True
          , "note"     .= ("window no longer corroborated; deregistered without unmarking" :: Text)
          ])

-- | Remove an entry from the harness registry, the legacy '_fe_harnesses' map,
-- AND the first-class 'TabRegistry' at @slot@ (WU7 — so a released\/destroyed
-- harness no longer projects a dangling tab row). Shared by both Release
-- branches and Destroy. Mirrors Dismiss's deregistration; NEVER touches
-- @session.json@\/the transcript (retention — design §8 C2).
deregister :: FrontendEnv -> TabIndex -> Registry.HarnessEntry -> IO ()
deregister env slot e = do
  Registry.deleteEntry (_fe_harnessRegistry env) (Registry._he_id e)
  modifyIORef' (_fe_harnesses env) (Map.delete (Registry._he_label e))
  registryRemove (_fe_tabRegistry env) slot

-- | Request body for @POST \/api\/tabs\/{index}\/destroy@. @confirm_adopted@
-- must be @true@ to destroy an 'Registry.OriginAdopted' harness — killing a
-- window PureClaw did not create breaks the "release never kills" contract, so
-- the server fail-closes unless the caller explicitly confirms. Defaults to
-- 'False' (and on a missing/garbage body), so an unconfirmed adopted destroy is
-- always rejected.
newtype DestroyRequest = DestroyRequest
  { _dr_confirmAdopted :: Bool
  }

instance FromJSON DestroyRequest where
  parseJSON = Aeson.withObject "DestroyRequest" $ \o ->
    DestroyRequest <$> o .:? "confirm_adopted" .!= False

-- | @POST \/api\/tabs\/{index}\/destroy@ — terminate a harness: kill its tmux
-- window (claude-code + the pane shell), ARCHIVE its session (transcript
-- retained — design: destroy is reversible at the data layer), and deregister
-- it from BOTH the registry and the legacy '_fe_harnesses' map. Distinct from
-- Release (never kills), Dismiss (no tmux op, session stays in Recent), and
-- Close.
--
-- Two guards:
--
--   * ADOPTED gate (server-enforced, not UI-trusted): an 'OriginAdopted' entry
--     is rejected with @409@ and NO mutation unless the body carries
--     @confirm_adopted: true@. Spawned\/Discovered entries (our own windows)
--     destroy without confirmation.
--   * SEC-3 corroborate-before-kill: the kill ('_fe_killWindow') fires ONLY
--     when the live @\@pcl_id@ at the entry's cached @(session, window)@ still
--     equals THIS entry's id. On a mismatch\/missing marker (window replaced or
--     gone) we deregister + archive WITHOUT killing and log a refusal — we
--     never kill a window we cannot confirm is ours.
handleDestroyTab
  :: FrontendEnv -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleDestroyTab env tidxText req respond = do
  body <- consumeBody req
  let confirmAdopted = case Aeson.eitherDecode body of
        Right dr -> _dr_confirmAdopted dr
        Left _   -> False
  withResolvedTab env tidxText respond $ \slot e ->
    case Registry._he_origin e of
      Registry.OriginAdopted | not confirmAdopted ->
        -- Server-side enforcement of the kill-adopted confirmation: the UI gate
        -- is not trusted. No tmux op, no deregistration.
        respond $ jsonResponse status409
          (object ["error" .= ("adopted harness requires confirm_adopted" :: Text)])
      _ -> destroyHarnessEntry env slot e respond

-- | The corroborate-then-kill core of Destroy, for an entry already cleared by
-- the adopted gate. Re-reads the live @\@pcl_id@ BEFORE killing (SEC-3); kills
-- only when corroborated, otherwise logs a refusal and skips the kill. Either
-- way the session is archived (transcript retained) and the entry leaves both
-- stores.
destroyHarnessEntry
  :: FrontendEnv -> TabIndex -> Registry.HarnessEntry -> (Response -> IO ResponseReceived) -> IO ResponseReceived
destroyHarnessEntry env slot e respond = do
  let session  = Registry._he_session e
      window   = Registry._he_windowName e
      expected = Registry.harnessIdToText (Registry._he_id e)
  liveMarker <- _rt_liveMarker (_fe_releaseTmux env) session window
  killed <-
    if liveMarker == Just expected
      then do
        -- Corroborated: the live window still carries THIS entry's marker, so
        -- it is safe to kill.
        _fe_killWindow env session window
        pure True
      else do
        _lh_logWarn (_fe_logger env) $
          "destroy: window " <> session <> ":" <> window
            <> " no longer corroborated (live @pcl_id="
            <> Maybe.fromMaybe "<none>" liveMarker
            <> ", expected " <> expected
            <> "); deregistering WITHOUT killing"
        pure False
  -- Archive the backing session (retain the transcript) if session-backed. A
  -- missing/unparseable session is non-fatal: the window kill + deregistration
  -- still stand, so we log and continue rather than fail the request.
  case Registry._he_sessionId e of
    Just sid -> do
      archiveResult <- setArchived (_fe_sessionsDir env) (SessionId sid) True
      case archiveResult of
        Right () -> pure ()
        Left err -> _lh_logWarn (_fe_logger env) $
          "destroy: could not archive session " <> sid <> ": " <> T.pack (show err)
    Nothing -> pure ()
  deregister env slot e
  broadcastLists env
  respond $ jsonResponse status200 $ object $
    ("destroyed" .= True)
      : [ "note" .= ("window no longer corroborated; deregistered without killing" :: Text)
        | not killed ]

-- | @POST \/api\/tabs\/{index}\/acknowledge@ — clear the out-of-band
-- '_he_extModified' flag (the §7 ⚠ \"edited\" pill). Uses 'Registry.modifyEntry'
-- (a single-STM read-modify-write) so the clear cannot race the reconcile
-- loop's 'mergeReconcile'.
handleAcknowledgeTab :: FrontendEnv -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleAcknowledgeTab env tidxText respond =
  withResolvedTab env tidxText respond $ \_slot e -> do
    Registry.modifyEntry (_fe_harnessRegistry env) (Registry._he_id e)
      (\x -> x { Registry._he_extModified = False })
    broadcastLists env
    respond $ jsonResponse status200 (object ["acknowledged" .= True])

-- | @POST \/api\/tabs\/{index}\/restart@ — RESERVED. The Restart affordance is
-- a label only in Phase 2 (design §2\/§7: auto-restart is a non-goal here);
-- the implementation is deferred, so the endpoint exists but returns @501@.
handleRestartTab :: (Response -> IO ResponseReceived) -> IO ResponseReceived
handleRestartTab respond =
  respond $ jsonResponse status501
    (object ["error" .= ("restart not yet implemented" :: Text)])

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
  tabs <- tabsFromRegistry env
      -- Only NON-harness tabs (provider / raw-shell, shown under "Active Tabs")
      -- dedupe their session out of "Recent Sessions". A harness tab keeps its
      -- controls entry under "Running Harnesses" AND, intentionally, its backing
      -- session is also listed under "Recent Sessions" so the user can jump
      -- straight to the conversation — so harness-kind tabs are NOT counted here.
  let activeTabSids = [s | TabSnapshot { _ts_sessionId = Just s, _ts_kind = k } <- tabs, k /= "harness"]
      -- A running harness's backing session is kept in "Recent Sessions" even
      -- with an EMPTY transcript: it is the user's clickable entry point into the
      -- harness conversation (the harness tab itself shows controls, not a chat).
      -- Otherwise a freshly-adopted harness — whose transcript is empty until its
      -- first turn — is unreachable/unchattable in the UI.
      harnessSids   = [s | TabSnapshot { _ts_sessionId = Just s, _ts_kind = "harness" } <- tabs]
      isHarnessSession m = unSessionId (_sm_id m) `elem` harnessSids
      notInTab m    = unSessionId (_sm_id m) `notElem` activeTabSids
      visible       = filter (\m -> not (_sm_archived m) && notInTab m) metas
  nonEmpty <- filterM (\m -> if isHarnessSession m then pure True
                                                   else hasTranscriptEntries baseDir m) visible
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
  -- Exclude sessions that are bound to a non-harness tab: a tab binding
  -- wins over the archived flag (WU6 — the session is open and active).
  tabs <- tabsFromRegistry env
  let activeTabSids = [s | TabSnapshot { _ts_sessionId = Just s, _ts_kind = k } <- tabs, k /= "harness"]
      archived = filter (\m -> _sm_archived m && unSessionId (_sm_id m) `notElem` activeTabSids) metas
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
  tabs <- tabsFromRegistry env
  -- Recent sessions: exclude archived, exclude active-tab-backed, exclude
  -- empty transcripts, enrich with first-message snippet — same pipeline
  -- as handleRecentSessions.
  allMetas <- listSessions baseDir Nothing (limit * 3)
      -- Only NON-harness tabs (provider / raw-shell, shown under "Active Tabs")
      -- dedupe their session out of "Recent Sessions". A harness tab keeps its
      -- controls entry under "Running Harnesses" AND, intentionally, its backing
      -- session is also listed under "Recent Sessions" so the user can jump
      -- straight to the conversation — so harness-kind tabs are NOT counted here.
  let activeTabSids = [s | TabSnapshot { _ts_sessionId = Just s, _ts_kind = k } <- tabs, k /= "harness"]
      -- Keep a running harness's (possibly empty-transcript) session in recents —
      -- it is the clickable entry point to the harness conversation. See
      -- 'handleRecentSessions' for the rationale.
      harnessSids   = [s | TabSnapshot { _ts_sessionId = Just s, _ts_kind = "harness" } <- tabs]
      isHarnessSession m = unSessionId (_sm_id m) `elem` harnessSids
      notInTab m    = unSessionId (_sm_id m) `notElem` activeTabSids
      visible       = filter (\m -> not (_sm_archived m) && notInTab m) allMetas
  nonEmpty <- filterM (\m -> if isHarnessSession m then pure True
                                                   else hasTranscriptEntries baseDir m) visible
  let chosen = take limit nonEmpty
  snippets <- traverse (firstMessageSnippet baseDir) chosen
  let recentInfos = zipWith toSessionInfo chosen snippets
  -- Archived: all archived sessions, sorted by lastActive descending
  -- (listSessions already sorts; we just filter).
  -- Exclude sessions that are bound to a non-harness tab: tab binding wins
  -- over the archived flag (WU6 — the session is open and active in a tab).
  archivedMetas <- listSessions baseDir Nothing 1000
  let archivedChosen = filter
        (\m -> _sm_archived m && unSessionId (_sm_id m) `notElem` activeTabSids)
        archivedMetas
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
    -- | The full, verbatim on-disk transcript line ('encodeEntryRaw') —
    -- all 9 '_te_*' fields incl. '_te_metadata'. Per the everything-visible
    -- principle, "View raw JSON" shows this byte-faithful line; the other
    -- (projected) fields are kept only so the frontend can /build/ messages.
  , _tei_raw       :: Text
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
    , "raw"       .= _tei_raw e
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
  , _tei_raw       = encodeEntryRaw e
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

-- | The current open-tab count: the length of the live 'TabRegistry' (WU7 —
-- the registry is the single source of truth, replacing the dropped
-- '_fe_tabCount' counter).
currentTabCount :: FrontendEnv -> IO Int
currentTabCount env = length . toList <$> readTabs (_fe_tabRegistry env)

-- | True when the registry is at (or above) the '_fe_maxTabs' cap, so a new
-- tab cannot be created (A8).
atTabCap :: FrontendEnv -> IO Bool
atTabCap env = (>= _fe_maxTabs env) <$> currentTabCount env

-- | Handle POST /api/tabs/new.
--
-- Creates a new tab (session-backed or raw shell), enforces the maxTabs
-- limit (A8) against the live 'TabRegistry' length, and returns a JSON
-- response with the tab index, session ID (if any), and kind description.
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
          -- A8: enforce maxTabs limit (registry length vs _fe_maxTabs).
          capped <- atTabCap env
          if capped
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
                  capped <- atTabCap env
                  if capped
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
createTab env tabKind mSeed respond =
  case tabKind of
    -- Harness sessions must actually spawn the tmux harness before the tab
    -- is considered created. A branch seed only ever targets a provider
    -- session (handleNewTab rejects non-provider branch targets), so a
    -- seeded harness cannot occur here.
    TkSession sk@(SkHarness spec) ->
      createHarnessTab env tabKind spec sk respond
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
      -- Bind the session into the first-class TabRegistry (WU7). The returned
      -- slot is the tab's display index in the response. A label of the agent
      -- name (else the session id) drives the sidebar title. The cap was
      -- pre-checked in 'handleNewTab'; 'registryAppend' re-checks defensively
      -- and a 'SlotsFull' (a lost race against a concurrent create) maps to the
      -- same cap 409.
      let tabName = maybe (unSessionId sid) unAgentName metaAgent
      appended <- registryAppend (_fe_tabRegistry env) (BoundSession sid) tabName
      case appended of
        Left SlotsFull ->
          respond $ jsonResponse status409
            (object ["error" .= ("maximum tab count reached" :: Text)])
        Left (AlreadyBound slot) ->
          -- A fresh session id is never already bound; treat the impossible
          -- collision as success at the existing slot rather than failing.
          finishProviderTab env meta sid slot tabKind respond
        Right slot ->
          finishProviderTab env meta sid slot tabKind respond
    TkRawShell _backend ->
      -- Raw-shell tabs are not yet bound into the first-class TabRegistry
      -- (deferred): they carry no 'TabRef' (no SessionId/HarnessId). Report a
      -- slot index of the current registry length so the response shape is
      -- preserved; no registry mutation occurs.
      do
        slotIdx <- currentTabCount env
        respond $ jsonResponse status200 NewTabResponse
          { _ntresp_tabIndex  = slotIdx
          , _ntresp_sessionId = Nothing
          , _ntresp_kind      = tabKindLabel tabKind
          }

-- | Finish a provider tab create after the session was bound into the
-- 'TabRegistry': publish the new-session broker signal, broadcast the lists
-- snapshot, and respond with the bound slot as the tab index (WU7).
finishProviderTab
  :: FrontendEnv -> SessionMeta -> SessionId -> TabIndex -> TabKind
  -> (Response -> IO ResponseReceived) -> IO ResponseReceived
finishProviderTab env meta sid slot tabKind respond = do
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
    { _ntresp_tabIndex  = unTabIndex slot
    , _ntresp_sessionId = Just (unSessionId sid)
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
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
createHarnessTab env tabKind spec sk respond = do
  spawned <- spawnHarnessSession env spec sk
  case spawned of
    Left err -> respond $ harnessErrorResponse err
    Right (sid, hid, updatedMeta, key) -> do
      -- Bind the harness into the first-class TabRegistry (WU7) — only a
      -- successful spawn consumes a tab slot. The returned slot is the tab's
      -- display index in the response; the label is the spawn's window key.
      -- 'SlotsFull' here (a lost race against a concurrent create after the
      -- pre-check in 'handleNewTab') maps to the cap 409; the harness window is
      -- already up, but the tab cannot be surfaced, so report the cap.
      appended <- registryAppend (_fe_tabRegistry env) (BoundHarness hid) key
      case appended of
        Left SlotsFull ->
          respond $ jsonResponse status409
            (object ["error" .= ("maximum tab count reached" :: Text)])
        Left (AlreadyBound slot) ->
          finishHarnessTab env updatedMeta sid slot tabKind respond
        Right slot ->
          finishHarnessTab env updatedMeta sid slot tabKind respond

-- | The reusable spawn+persist+link core extracted from 'createHarnessTab'
-- (WU-B). Creates a fresh harness-backed session, spawns the tmux harness via
-- '_fe_startHarness', and — only on success — persists the real 'TbTmux'
-- coordinates + durable ids into '_sm_kind' and links the registry entry back
-- to the session. A failed spawn rolls back the just-created session directory
-- and returns 'Left', so a fallible spawn never strands a session dir.
--
-- Returns the new session id, its durable 'Registry.HarnessId', the post-spawn
-- 'SessionMeta' (carrying the real 'TbTmux' backend for live broadcast), and
-- the harness key (@_shh_key@ — the tmux window name, used as the tab label).
-- This is the seam both the web 'createHarnessTab' endpoint and the TUI
-- @\/tab new harness@ dispatcher route through (via
-- 'PureClaw.Agent.Env._env_startHarness').
spawnHarnessSession
  :: FrontendEnv
  -> HarnessSpec    -- ^ requested harness spec (backend replaced on success)
  -> SessionKind    -- ^ the SkHarness kind to seed _sm_kind with
  -> IO (Either HarnessError (SessionId, Registry.HarnessId, SessionMeta, Text))
spawnHarnessSession env spec sk = do
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
      pure (Left err)
    Right st -> do
      -- Persist the real tmux coordinates AND the durable HarnessId returned by
      -- the spawn (WU7, D7.2). The id is the primary routing anchor (resolved
      -- through the registry by 'harnessKeyFromKind'/'sendToHarness'); the tmux
      -- window/session is dual-written for the name-fallback path. The persisted
      -- '_tc_session' is the resolved session honored by '_fe_startHarness'.
      modifyIORef' (_sh_meta sh) $ \m ->
        m { _sm_kind = SkHarness
              (spec { _h_backend           = TbTmux (_shh_tmux st)
                    , _h_harnessId         = Just (_shh_id st)
                    , _h_claudeSessionUuid = _shh_claudeSessionUuid st
                    , _h_canonicalCwd      = _shh_canonicalCwd st
                    }) }
      _sh_save sh
      -- Link the freshly-spawned harness's registry entry back to THIS session.
      -- The low-level spawn (startHarnessByName) inserts the entry with
      -- '_he_sessionId = Nothing' because it has no session of its own; only this
      -- orchestrator knows both the 'HarnessId' and the 'sid'. Without the link
      -- the tab's session_id is null and the right pane shows "No session
      -- associated yet" (the adopt path already links via '_he_sessionId'). Set
      -- it before any broadcast so the live lists snapshot already carries it.
      Registry.modifyEntry (_fe_harnessRegistry env) (_shh_id st)
        (\e -> e { Registry._he_sessionId = Just (unSessionId sid) })
      -- Read back the post-spawn meta so the live broadcast carries the real
      -- TbTmux backend (the persisted session.json above is already correct;
      -- the original 'meta' still holds the placeholder backend).
      updatedMeta <- readIORef (_sh_meta sh)
      pure (Right (sid, _shh_id st, updatedMeta, _shh_key st))

-- | Finish a harness tab create after the harness id was bound into the
-- 'TabRegistry': publish the post-spawn meta to the broker (carrying the real
-- TbTmux backend), broadcast the lists snapshot, and respond with the bound
-- slot as the tab index (WU7).
finishHarnessTab
  :: FrontendEnv -> SessionMeta -> SessionId -> TabIndex -> TabKind
  -> (Response -> IO ResponseReceived) -> IO ResponseReceived
finishHarnessTab env updatedMeta sid slot tabKind respond = do
  case _fe_broker env of
    Just broker ->
      _streamBroker_publish broker
        (ActivityChanged (_sm_id updatedMeta) (SaSessionCreated updatedMeta))
    Nothing -> pure ()
  broadcastLists env
  respond $ jsonResponse status200 NewTabResponse
    { _ntresp_tabIndex  = unTabIndex slot
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
