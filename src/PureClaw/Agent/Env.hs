module PureClaw.Agent.Env
  ( -- * Agent environment
    AgentEnv (..)
  ) where

import Data.Text (Text)

import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Security.Vault
import PureClaw.Tools.Registry

-- | All runtime dependencies for the agent loop, gathered into a single record.
-- This replaces the multi-parameter signature of 'runAgentLoop' and
-- 'executeSlashCommand', making it easy to add new capabilities (e.g.
-- 'VaultHandle') in later work units without touching call sites.
data AgentEnv = AgentEnv
  { _env_provider     :: SomeProvider
    -- ^ The LLM provider (wrapped existential, erases the concrete type).
  , _env_model        :: ModelId
    -- ^ The model to use for completions.
  , _env_channel      :: ChannelHandle
    -- ^ The channel to read messages from and write responses to.
  , _env_logger       :: LogHandle
    -- ^ Structured logger for diagnostic output.
  , _env_systemPrompt :: Maybe Text
    -- ^ Optional system prompt prepended to every conversation.
  , _env_registry     :: ToolRegistry
    -- ^ All registered tools available for the agent to call.
  , _env_vault        :: Maybe VaultHandle
    -- ^ Optional secrets vault. 'Nothing' if no vault is configured.
  }
