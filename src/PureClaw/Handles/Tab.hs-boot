-- |
-- Module      : PureClaw.Handles.Tab (boot)
-- Description : Boot file used to break the AgentEnv ↔ Tab ↔ SlashCommands cycle.
--
-- 'PureClaw.Agent.Env' needs the abstract types 'TabHandle', 'TabIndex',
-- and 'TabRunner' to declare the WU3 fields '_env_tabs', '_env_focus',
-- '_env_runners', and '_env_fork'. The full module
-- 'PureClaw.Handles.Tab' imports 'PureClaw.Agent.SlashCommands' (for
-- 'SlashCommand'), which transitively imports 'PureClaw.Agent.Env'.
-- This boot file exports only the three abstract types so the import
-- graph stays acyclic.
--
-- Nothing about these declarations is normative — the source-of-truth
-- definitions live in 'PureClaw.Handles.Tab' itself.
module PureClaw.Handles.Tab
  ( TabHandle
  , TabIndex
  , TabRunner (..)
  ) where

data TabHandle
data TabIndex

data TabRunner = TabRunner
  { _trun_cancel :: IO ()
  , _trun_wait   :: IO ()
  }
