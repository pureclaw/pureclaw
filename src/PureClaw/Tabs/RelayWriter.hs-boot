-- |
-- Module      : PureClaw.Tabs.RelayWriter (boot)
-- Description : Boot file breaking the AgentEnv ↔ RelayWriter ↔ Routing.Types cycle.
--
-- 'PureClaw.Agent.Env' references the opaque 'RelayWriter' and
-- 'SinkRegistry' handles (and their @newX@ constructors) for the
-- Tabs-as-View 8c.2 fields '_env_relayWriter' and '_env_sinks'. The full
-- module 'PureClaw.Tabs.RelayWriter' imports 'PureClaw.Routing.Types', which
-- transitively imports 'PureClaw.Agent.SlashCommands' →
-- 'PureClaw.Routing.Onboarding' → 'PureClaw.Agent.Env'. This boot file
-- exports the two handle types abstractly (plus their constructors) so the
-- import graph stays acyclic.
--
-- Nothing here is normative — the source-of-truth definitions live in
-- 'PureClaw.Tabs.RelayWriter' itself.
module PureClaw.Tabs.RelayWriter
  ( SinkRegistry
  , RelayWriter
  , newSinkRegistry
  , newRelayWriter
  ) where

data SinkRegistry
data RelayWriter

newSinkRegistry :: IO SinkRegistry
newRelayWriter :: IO RelayWriter
