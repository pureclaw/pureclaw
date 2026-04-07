module PureClaw.Agent.Env
  ( -- * Agent environment
    AgentEnv (..)
    -- * Message target
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
import PureClaw.Handles.Transcript
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle (SessionHandle)
import PureClaw.Tools.Registry

-- | Where incoming user messages are routed.
data MessageTarget
  = TargetProvider          -- ^ Send to the configured LLM provider + model
  | TargetHarness Text      -- ^ Send to a named running harness
  deriving stock (Show, Eq)

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
  , _env_transcript :: IORef (Maybe TranscriptHandle)
    -- ^ Optional transcript handle. When 'Just', the provider is wrapped
    -- with 'mkTranscriptProvider' to log all completions.
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
  , _env_session :: SessionHandle
    -- ^ Current conversation session. In WU1 this is always a no-op
    -- placeholder; WU2 promotes it to a real on-disk session.
  }
