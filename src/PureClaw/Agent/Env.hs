module PureClaw.Agent.Env
  ( -- * Agent environment
    AgentEnv (..)
    -- * Accessors
  , envTranscript
    -- * Message target (re-exported from "PureClaw.Core.Types")
  , MessageTarget (..)
  ) where

import Data.IORef
import Data.Map.Strict (Map)
import Data.Text (Text)

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript (TranscriptHandle)
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (SessionHandle (..))
import PureClaw.Tools.Registry

-- | All runtime dependencies for the agent loop, gathered into a single record.
-- This replaces the multi-parameter signature of 'runAgentLoop' and
-- 'executeSlashCommand', making it easy to add new capabilities (e.g.
-- 'VaultHandle') in later work units without touching call sites.
data AgentEnv = AgentEnv
  { _env_provider     :: IORef (Maybe SomeProvider)
    -- ^ The LLM provider. 'Nothing' when no credentials are configured yet.
  , _env_model        :: IORef ModelId
    -- ^ The model to use for completions. Mutable so slash commands
    -- like @\/provider@ and @\/target@ can hot-swap it.
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
  }

-- | Read the active session's transcript handle.
--
-- The transcript lives inside the session directory (@transcript.jsonl@)
-- and is swapped automatically when @\/session new@ or
-- @\/session resume@ replaces the active session. Callers that previously
-- read @_env_transcript@ should use this accessor instead.
envTranscript :: AgentEnv -> IO TranscriptHandle
envTranscript env = _sh_transcript <$> readIORef (_env_session env)
