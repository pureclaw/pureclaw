module PureClaw.Agent.Env
  ( -- * Agent environment
    AgentEnv (..)
    -- * Accessors
  , envTranscript
    -- * Default helpers (WU3 — Tabbed Chat)
  , defaultEnvFork
    -- * Message target (re-exported from "PureClaw.Core.Types")
  , MessageTarget (..)
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, TVar)
import Control.Monad (void)
import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.Map.Strict (Map)
import Data.Text (Text)

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Core.Types
import PureClaw.Frontend.StreamBroker (StreamBroker)
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import {-# SOURCE #-} PureClaw.Handles.Tab (TabHandle, TabIndex, TabRunner (..))
import PureClaw.Handles.Transcript (TranscriptHandle)
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class
import {-# SOURCE #-} PureClaw.Routing.Types (ChannelEvent, OutputSource, RoutingConfig)
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (SessionHandle (..))
import PureClaw.Tools.Registry

-- | All runtime dependencies for the agent loop, gathered into a single record.
-- This replaces the multi-parameter signature of 'runAgentLoop' and
-- 'executeSlashCommand', making it easy to add new capabilities (e.g.
-- 'VaultHandle') in later work units without touching call sites.
--
-- The Tabbed Chat WU3 (Issue #51) adds seven fields below the original
-- record body: '_env_tabs', '_env_focus', '_env_activeCount',
-- '_env_runners', '_env_channelOutQ', '_env_routingConfig', and
-- '_env_fork'. See @docs\/tabbed-chat.md@ §\"AgentEnv additions\".
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
    -- ^ One-shot callback fired by 'runAgentLoop' after the first
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
  , _env_tabs :: IORef (IntMap TabHandle)
    -- ^ Tab registry — keyed by 'TabIndex'. Mutated by the dispatcher
    -- (WU5) via 'PureClaw.Routing.Registry'. WU3 ships the field empty.
  , _env_focus :: IORef (Maybe TabIndex)
    -- ^ Currently-focused tab. The dispatcher writes this only between
    -- message cycles (E3 invariant). 'Nothing' on first boot, before
    -- any tab has been spawned\/auto-spawned.
  , _env_activeCount :: TVar Int
    -- ^ Number of tabs in 'PureClaw.Handles.Tab.Active' status. Used
    -- by the S9 concurrent-active cap. Mutated atomically by tab
    -- loops (WU6) under STM together with the status transition.
  , _env_runners :: IORef (IntMap (IORef (Maybe TabRunner)))
    -- ^ Per-tab 'TabRunner' placeholders. The dispatcher's spawn path
    -- (WU5) inserts an @IORef Nothing@ under 'mask' BEFORE calling
    -- @_env_fork@, then fills it in once the fork returns — this
    -- guarantees 'closeAllTabs' (the bracket cleanup) sees every fork
    -- that was started, even if interrupted mid-flight.
  , _env_channelOutQ :: TBQueue (OutputSource, ChannelEvent)
    -- ^ Process-wide bounded queue feeding the single channel-out
    -- writer thread (WU4). Capacity is configured by
    -- '_rc_channelOutQBound' at AgentEnv construction time.
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
