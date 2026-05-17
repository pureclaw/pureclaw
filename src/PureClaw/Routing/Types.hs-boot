-- |
-- Module      : PureClaw.Routing.Types (boot)
-- Description : Boot file used to break the AgentEnv ↔ Routing.Types ↔ SlashCommands cycle.
--
-- 'PureClaw.Agent.Env' references 'RoutingConfig', 'OutputSource', and
-- 'ChannelEvent' for the WU3 fields '_env_routingConfig' and
-- '_env_channelOutQ'. The full module 'PureClaw.Routing.Types' imports
-- 'PureClaw.Agent.SlashCommands' (for 'SlashCommand'), which
-- transitively imports 'PureClaw.Agent.Env'. This boot file exports
-- the three types abstractly so the import graph stays acyclic.
--
-- Nothing about these declarations is normative — the source-of-truth
-- definitions live in 'PureClaw.Routing.Types' itself.
module PureClaw.Routing.Types
  ( RoutingConfig
  , OutputSource
  , ChannelEvent
  ) where

data RoutingConfig
data OutputSource
data ChannelEvent
