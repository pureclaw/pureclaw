-- |
-- Module      : PureClaw.Tabs.Types (boot)
-- Description : Boot file breaking the AgentEnv ↔ Tabs.Types ↔ Handles.Tab cycle.
--
-- 'PureClaw.Agent.Env' references the abstract 'TabRef' and 'CursorState'
-- handles, the 'ConversationKey' synonym, and 'emptyCursors' for the
-- Tabs-as-View 8c.2 fields. The full module 'PureClaw.Tabs.Types' imports
-- 'PureClaw.Handles.Tab', which transitively imports
-- 'PureClaw.Agent.SlashCommands' → 'PureClaw.Routing.Onboarding' →
-- 'PureClaw.Agent.Env'. This boot exports the abstract types so the import
-- graph stays acyclic.
--
-- Nothing here is normative — the source-of-truth definitions live in
-- 'PureClaw.Tabs.Types' itself.
module PureClaw.Tabs.Types
  ( TabRef
  , CursorState
  , ConversationKey
  , emptyCursors
  ) where

import PureClaw.Core.Types (ChannelKind, ConversationId)

data TabRef

data CursorState

type ConversationKey = (ChannelKind, ConversationId)

emptyCursors :: CursorState
