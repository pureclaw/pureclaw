-- |
-- Module      : PureClaw.Tabs (boot)
-- Description : Boot file breaking the AgentEnv ↔ Tabs ↔ Handles.Tab cycle.
--
-- 'PureClaw.Agent.Env' references the abstract 'TabRegistry' handle and its
-- 'newTabRegistry' constructor for the Tabs-as-View 8c.2 field
-- '_env_tabRegistry'. The full module 'PureClaw.Tabs' imports
-- 'PureClaw.Handles.Tab' (for 'TabIndex'), which transitively imports
-- 'PureClaw.Agent.SlashCommands' → 'PureClaw.Routing.Onboarding' →
-- 'PureClaw.Agent.Env'. This boot exports the handle abstractly so the
-- import graph stays acyclic.
--
-- Nothing here is normative — the source-of-truth definitions live in
-- 'PureClaw.Tabs' itself.
module PureClaw.Tabs
  ( TabRegistry
  , newTabRegistry
  ) where

data TabRegistry

newTabRegistry :: IO TabRegistry
