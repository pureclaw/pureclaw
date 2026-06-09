-- |
-- Module      : PureClaw.Tabs.Exec (boot)
-- Description : Boot file breaking the AgentEnv ↔ Tabs.Exec ↔ Handles.Tab cycle.
--
-- 'PureClaw.Agent.Env' references the abstract 'Exec' registry handle and its
-- 'newExec' constructor for the Tabs-as-View 8c.2 field '_env_exec'. The full
-- module 'PureClaw.Tabs.Exec' imports 'PureClaw.Handles.Tab' (for
-- 'TabError'), which transitively imports 'PureClaw.Agent.SlashCommands' →
-- 'PureClaw.Routing.Onboarding' → 'PureClaw.Agent.Env'. This boot exports the
-- handle abstractly so the import graph stays acyclic.
--
-- Nothing here is normative — the source-of-truth definitions live in
-- 'PureClaw.Tabs.Exec' itself.
module PureClaw.Tabs.Exec
  ( Exec
  , newExec
  ) where

data Exec

newExec :: IO Exec
