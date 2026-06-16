module PureClaw.Agent.Env
  ( -- * Agent environment
    AgentEnv (..)
    -- * Accessors
  , envTranscript
    -- * Default helpers (WU3 — Tabbed Chat)
  , defaultEnvFork
    -- * Default helpers (WU-B — /tab new harness)
  , noStartHarness
    -- * Default helpers (Task B — /tab dispatcher seam)
  , noRunTabCommand
    -- * Tab subsystem bundle (Tabs-as-View 8c.2)
  , TabSubsystem (..)
  , newTabSubsystem
    -- * Message target (re-exported from "PureClaw.Core.Types")
  , MessageTarget (..)
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, newTBQueueIO)
import Control.Monad (void)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Core.Types
import PureClaw.Frontend.StreamBroker (StreamBroker)
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Tab (TabRunner (..))
import PureClaw.Handles.Transcript (TranscriptHandle)
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class
import {-# SOURCE #-} PureClaw.Routing.Types (ChannelEvent, RoutingConfig)
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (SessionHandle (..))
import PureClaw.Session.Kind (HarnessSpec)
import PureClaw.Tabs (TabRegistry, newTabRegistry)
import PureClaw.Tabs.Exec (Exec, newExec)
import {-# SOURCE #-} PureClaw.Tabs.RelayWriter
  ( RelayWriter
  , SinkRegistry
  , newRelayWriter
  , newSinkRegistry
  )
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState
  , TabRef
  , TabSlashCommand
  , emptyCursors
  )
import PureClaw.Tabs.Wizard (WizardState)
import PureClaw.Tools.Registry

-- | All runtime dependencies for the agent loop, gathered into a single record.
-- This bundles every capability the tabbed loop ('runTabbedLoop') and the
-- slash-command handlers need into one record, making it easy to add new
-- capabilities (e.g. 'VaultHandle') without touching call sites.
--
-- The Tabbed Chat WU3 (Issue #51) added the '_env_routingConfig' and
-- '_env_fork' fields; the live tab subsystem (Tabs-as-View #79) is carried by
-- the '_env_tabRegistry' \/ '_env_cursors' \/ '_env_exec' \/ '_env_relayWriter'
-- \/ '_env_sinks' \/ '_env_wizard' \/ '_env_tabOutQ' fields built by
-- 'newTabSubsystem'.
data AgentEnv = AgentEnv
  { _env_provider     :: IORef (Maybe SomeProvider)
    -- ^ The LLM provider. 'Nothing' when no credentials are configured yet.
  , _env_model        :: IORef (Maybe ModelId)
    -- ^ The model to use for completions. 'Nothing' when no model is
    -- configured yet (user must set one via @\/target@ or config file).
    -- Mutable so slash commands like @\/provider@ and @\/target@ can
    -- hot-swap it.
  , _env_channel      :: ChannelHandle
    -- ^ The channel to read messages from and write responses to.
  , _env_logger       :: LogHandle
    -- ^ Structured logger for diagnostic output.
  , _env_systemPrompt :: Maybe Text
    -- ^ Optional system prompt prepended to every conversation.
  , _env_registry     :: ToolRegistry
    -- ^ All registered tools available for the agent to call.
  , _env_vault        :: IORef (Maybe VaultHandle)
    -- ^ Optional secrets vault. 'Nothing' if no vault is configured.
  , _env_pluginHandle :: PluginHandle
    -- ^ Handle for detecting and generating age plugin identities.
  , _env_policy :: SecurityPolicy
    -- ^ Security policy for command authorization. Needed by harness management.
  , _env_harnesses :: IORef (Map Text HarnessHandle)
    -- ^ Running harness handles, keyed by name (e.g. "claude-code").
  , _env_harnessRegistry :: Registry.HarnessRegistry
    -- ^ The durable 'HarnessId' registry — the source of truth for harness
    -- identity and health (design @docs\/harness-registry.md@). This is
    -- ADDITIVE alongside the legacy '_env_harnesses' map: the map keys by
    -- mutable window name, whereas the registry keys by a UUID-backed
    -- 'Registry.HarnessId' that survives tmux rename\/move and restart. The
    -- two coexist during Phase 1; later work units migrate consumers onto the
    -- registry. Shares one underlying 'TVar' with '_fe_harnessRegistry' so
    -- the agent and frontend observe the same registry.
  , _env_target :: IORef MessageTarget
    -- ^ Where incoming user messages are routed. Mutable so @\/target@
    -- can hot-swap the destination.
  , _env_nextWindowIdx :: IORef Int
    -- ^ Monotonically increasing counter for assigning tmux window indices
    -- to new harnesses. Starts at 0.
  , _env_agentDef :: Maybe AgentDef
    -- ^ Currently-selected agent, if any. Populated by the @--agent@ flag
    -- or the @default_agent@ config field. Used by agent-aware slash
    -- commands; 'Nothing' in the backward-compat no-agent path.
  , _env_session :: IORef SessionHandle
    -- ^ Current conversation session. Mutable so @\/session new@ and
    -- @\/session resume@ can swap the active session in place.
  , _env_onFirstStreamDone :: IORef (Maybe (IO ()))
    -- ^ One-shot callback fired by the tabbed loop after the first
    -- 'StreamDone' it observes. The loop atomically consumes the
    -- action (setting the field back to 'Nothing') so a second
    -- 'StreamDone' does not re-fire it. In production this is
    -- populated with @'markBootstrapConsumed' session@ so the agent
    -- marks its bootstrap as consumed exactly once per process start.
  , _env_mcpServers :: IORef (Map Text McpServer)
    -- ^ Connected MCP servers, keyed by user-assigned name.
    -- Mutable so @\/mcp connect@ and @\/mcp disconnect@ can add\/remove
    -- servers at runtime. Tools from these servers are merged into the
    -- effective registry on each completion request.
    --
    -- ---- WU3 (Tabbed Chat #51) additions below this line ----
  , _env_routingConfig :: RoutingConfig
    -- ^ Routing-layer configuration loaded once at process start
    -- (WU3 'PureClaw.Routing.Config'). Immutable for the life of the
    -- process — runtime @\/config@ mutation is v1.5+.
  , _env_fork :: IO () -> IO TabRunner
    -- ^ Test-seam-aware fork primitive. The production default
    -- ('defaultEnvFork') wraps 'Control.Concurrent.Async.async';
    -- tests inject synchronous variants (T4) to make spawn paths
    -- deterministic. Tab loops (WU5\/WU6) MUST use this instead of
    -- 'Control.Concurrent.forkIO'.
  , _env_broker :: Maybe StreamBroker
    -- ^ Optional in-process pub\/sub broker for live transcript
    -- streaming. When 'Just', every transcript write performed via the
    -- session handles owned by this 'AgentEnv' fans out broker events
    -- ('EntryRecorded' and 'ActivityChanged'). 'Nothing' preserves the
    -- legacy no-broker path (tests, one-off scripts, the CLI before
    -- WU3's lifecycle changes land). See "PureClaw.Frontend.StreamBroker"
    -- and "PureClaw.Frontend.BroadcastingTranscript".
    --
    -- ---- Tabs-as-View (GitHub #79) tab subsystem below this line ----
    -- These seven fields are the LIVE tab subsystem the tabbed loop routes
    -- through ('PureClaw.Agent.Loop.runTabbedLoop' + the
    -- 'PureClaw.Routing.TabDispatch' router). They are constructed together
    -- by 'newTabSubsystem'.
  , _env_tabRegistry :: TabRegistry
    -- ^ The ordered first-class tab registry (invariants I1\/I2 —
    -- "PureClaw.Tabs").
  , _env_cursors :: IORef CursorState
    -- ^ Per-conversation tab cursors + relay overrides (invariant I3 —
    -- "PureClaw.Tabs.Types").
  , _env_exec :: Exec
    -- ^ The refcounted per-'TabRef' runtime registry
    -- ("PureClaw.Tabs.Exec"). The real @_ex_startRuntime@ closure that
    -- drives it is built in "PureClaw.Tabs.Wiring".
  , _env_relayWriter :: RelayWriter
    -- ^ The output-side relay writer's burst-dedup state
    -- ("PureClaw.Tabs.RelayWriter"). Drained by the relay-writer thread the
    -- tabbed loop forks.
  , _env_sinks :: SinkRegistry
    -- ^ Conversation -> 'ChannelHandle' output sink registry
    -- ("PureClaw.Tabs.RelayWriter"). The CLI conversation registers its sink
    -- here at loop start.
  , _env_wizard :: IORef (Map ConversationKey WizardState)
    -- ^ In-flight @\/tab@ attach-wizard state, keyed by conversation
    -- ("PureClaw.Tabs.Wizard"). Runtime-only; starts empty.
  , _env_tabOutQ :: TBQueue (TabRef, ChannelEvent)
    -- ^ Ref-tagged tab-output queue: runtimes enqueue @('TabRef',
    -- 'ChannelEvent')@ here; the relay-writer thread drains it through
    -- 'PureClaw.Tabs.RelayWriter.processOutput'.
  , _env_onTabsChanged :: !(IO ())
    -- ^ Callback fired once after each chat-side 'TabRegistry' mutation
    -- (@\/nt@, @\/new@, @\/close@, @\/rename@, wizard bind). Default is
    -- @'pure' ()@. Wired to rebroadcast\/persist the registry in
    -- "PureClaw.CLI.Commands" (WU8). Keeping the callback here prevents
    -- @Routing\/Tabs@ from depending on @Frontend@.
  , _env_startHarness :: !(HarnessSpec -> IO (Either Text (TabRef, Text)))
    -- ^ Dispatcher-reachable seam that spawns a fresh harness, persists its
    -- session, links it into the registry, and returns the new tab's
    -- @('TabRef', label)@ on success (or a user-facing error 'Text'). The
    -- dispatcher's @\/tab new harness@ arm
    -- ("PureClaw.Routing.TabDispatch.cmdTabNew") routes through this. Mirrors
    -- '_env_onTabsChanged': the default ('noStartHarness') is the unwired stub
    -- and the real closure is wired in "PureClaw.CLI.Commands" (WU-B) over
    -- 'PureClaw.Frontend.API.spawnHarnessSession'. Kept here so @Routing\/Tabs@
    -- need not depend on @Frontend@.
  , _env_runTabCommand :: !(ChannelHandle -> Maybe ConversationKey -> TabSlashCommand -> IO ())
    -- ^ Dispatcher-reachable seam that executes a parsed @\/tab@ command
    -- (rename\/close\/list\/new\/focus\/resume) against the shared tab
    -- subsystem. The first argument is the caller's reply 'ChannelHandle':
    -- the web path captures dispatcher output via a scoped /capture/ channel
    -- (NOT '_env_sinks'), so the real wiring overrides @_td_emit@ to send to
    -- THIS channel rather than the conversation's sink. @Just k@ supplies the
    -- current conversation for the conversation-relative bits (focus cursor,
    -- "(focused)" marker, relay, wizard); @Nothing@ (the web path, which has
    -- no 'ConversationKey') falls back to the wired web 'ConversationKey'.
    -- Mirrors '_env_startHarness': the
    -- default ('noRunTabCommand') is the unwired stub; the real closure is
    -- wired in "PureClaw.Tabs.Wiring"\/"PureClaw.CLI.Commands" (Task C) over
    -- the shared @runTabCommand@. Kept here so @Agent.SlashCommands@ (which
    -- defines @executeSlashCommand@) can invoke tab logic without importing
    -- @Routing.TabDispatch@.
  }

-- | Read the active session's transcript handle.
--
-- The transcript lives inside the session directory (@transcript.jsonl@)
-- and is swapped automatically when @\/session new@ or
-- @\/session resume@ replaces the active session. Callers that previously
-- read @_env_transcript@ should use this accessor instead.
envTranscript :: AgentEnv -> IO TranscriptHandle
envTranscript env = _sh_transcript <$> readIORef (_env_session env)

-- | Default '_env_fork' implementation: wraps 'Control.Concurrent.Async.async'
-- so the returned 'TabRunner' cancels and waits via the standard async
-- combinators.
--
-- '_trun_cancel' is 'Control.Concurrent.Async.cancel' (idempotent — safe to
-- call on a finished async). '_trun_wait' is 'Control.Concurrent.Async.wait'
-- with the result discarded (the tab loop body returns @()@). Tests that
-- need deterministic cancel observability should inject the synchronous
-- variant from 'Test.Fake.TabFactory' instead.
defaultEnvFork :: IO () -> IO TabRunner
defaultEnvFork body = do
  a <- Async.async body
  pure TabRunner
    { _trun_cancel = Async.cancel a
    , _trun_wait   = void (Async.wait a)
    }

-- | Default '_env_startHarness' implementation: the unwired stub. Returns a
-- @'Left'@ explaining that harness spawning has not been wired (the seam is
-- only live in "PureClaw.CLI.Commands", where it is replaced by the real
-- closure over 'PureClaw.Frontend.API.spawnHarnessSession'). Tests and any
-- non-CLI construction site default to this.
noStartHarness :: HarnessSpec -> IO (Either Text (TabRef, Text))
noStartHarness _ = pure (Left "harness spawn not wired")

-- | Default '_env_runTabCommand': the unwired stub (no-op). Tests and any
-- non-CLI construction site default to this; the real closure is wired in
-- "PureClaw.Tabs.Wiring"\/"PureClaw.CLI.Commands".
noRunTabCommand :: ChannelHandle -> Maybe ConversationKey -> TabSlashCommand -> IO ()
noRunTabCommand _ _ _ = pure ()

-- ---------------------------------------------------------------------------
-- Tab subsystem bundle (Tabs-as-View 8c.2)
-- ---------------------------------------------------------------------------

-- | The freshly-constructed tab-subsystem state the 8c.2 flip threads into
-- 'AgentEnv'. Built once at the production site (and at any test that drives
-- the tabbed loop) by 'newTabSubsystem'; its fields map one-for-one onto the
-- seven new 'AgentEnv' fields.
data TabSubsystem = TabSubsystem
  { _ts_tabRegistry    :: !TabRegistry
  , _ts_cursors        :: !(IORef CursorState)
  , _ts_exec           :: !Exec
  , _ts_relayWriter    :: !RelayWriter
  , _ts_sinks          :: !SinkRegistry
  , _ts_wizard         :: !(IORef (Map ConversationKey WizardState))
  , _ts_tabOutQ        :: !(TBQueue (TabRef, ChannelEvent))
  , _ts_onTabsChanged  :: !(IO ())
    -- ^ Default @'pure' ()@; overridable at the construction site (e.g.
    -- "PureClaw.CLI.Commands" in WU8) before wiring into 'AgentEnv'.
  }

-- | Allocate a complete, empty tab subsystem: an empty tab registry, empty
-- cursors, an empty runtime registry, a fresh relay writer + sink registry,
-- empty wizard state, and a bounded tab-output queue sized by @outQBound@
-- (the production site reuses @'_rc_channelOutQBound'@). The @_ex_startRuntime@
-- closure that the 'Exec' is driven with is NOT part of this bundle — it is
-- built against the live 'AgentEnv' in "PureClaw.Tabs.Wiring" and passed to
-- @ensure@/@release@ at call time.
newTabSubsystem :: Int -> IO TabSubsystem
newTabSubsystem outQBound = do
  tabRegistry <- newTabRegistry
  cursors     <- newIORef emptyCursors
  exec        <- newExec
  relayWriter <- newRelayWriter
  sinks       <- newSinkRegistry
  wizard      <- newIORef Map.empty
  tabOutQ     <- newTBQueueIO (fromIntegral (max 1 outQBound))
  pure TabSubsystem
    { _ts_tabRegistry   = tabRegistry
    , _ts_cursors       = cursors
    , _ts_exec          = exec
    , _ts_relayWriter   = relayWriter
    , _ts_sinks         = sinks
    , _ts_wizard        = wizard
    , _ts_tabOutQ       = tabOutQ
    , _ts_onTabsChanged = pure ()
    }
