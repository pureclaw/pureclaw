-- |
-- Module      : PureClaw.Routing.LegacyDispatch
-- Description : Bridge from the legacy single-tab CLI loop into Routing.AutoSpawn.
--
-- The new tabbed-chat dispatcher ('PureClaw.Routing.Dispatcher.runDispatcher')
-- is not yet wired as the production CLI entry point. Users running
-- 'PureClaw.Agent.Loop.runAgentLoop' (the legacy single-tab loop) need
-- @\/tab*@ commands to actually DO something — without this module they
-- hit the @CmdTab _@ fallback in 'executeSlashCommand' which only
-- emits a stub message.
--
-- 'dispatchLegacyTabCmd' is the bridge: it receives a parsed
-- 'TabSlashCommand' and invokes the matching 'PureClaw.Routing.AutoSpawn'
-- handler against the existing 'AgentEnv'. Handler callbacks are wired
-- with the minimum surface needed for legacy mode:
--
--   * 'BannerEmit' — direct @_ch_send@ to the user's channel.
--   * 'PromptRenderer' — built from the channel's streaming flag via
--     'mkDefaultPromptRenderer'.
--   * 'SpawnArgs' map — a fresh empty 'IORef' per dispatch. Legacy mode
--     does not implement the X1 crashed-tab retry UX, so per-call
--     ephemerality is fine.
--   * 'RenumberCallback' — no-op (no DispatcherState to keep in sync).
--   * Sanitize callback — 'PureClaw.Routing.Parse.sanitizeTabName'.
--   * 'TabFactory' — dispatches by 'TabKind' to the real
--     'PureClaw.Tab.Ai.mkTabAi' \/ 'Tab.Harness.mkTabHarness' \/
--     'Tab.Backend.mkTabBackend' factories (all 3-arg variants that
--     take 'AgentEnv').
--
-- @\/tab resume@ requires 'DispatcherState' (session resolver +
-- pending-retry tracking) that legacy mode lacks; this dispatch emits
-- a "not available in legacy mode" message rather than crashing.
--
-- This module sits ABOVE 'PureClaw.Agent.SlashCommands' (for the
-- 'TabSlashCommand' ADT) and ABOVE 'PureClaw.Routing.AutoSpawn' (for
-- the handlers), so it can import both freely. Conversely it must NOT
-- be imported from 'Agent.SlashCommands' (would create a cycle through
-- 'AutoSpawn' which already imports 'SlashCommands').
module PureClaw.Routing.LegacyDispatch
  ( dispatchLegacyTabCmd
  ) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (ForceMode (..), TabSlashCommand (..))
import PureClaw.Handles.Channel (ChannelHandle (..), OutgoingMessage (..))
import PureClaw.Routing.AutoSpawn qualified as AutoSpawn
import PureClaw.Routing.Dispatcher qualified as Dispatcher
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.PromptRenderer (mkDefaultPromptRenderer)


-- | Dispatch a 'TabSlashCommand' from the legacy CLI loop into the
-- 'Routing.AutoSpawn' handler surface.
--
-- All output reaches the user via @_ch_send@; the caller does not need
-- to consume any return value (handlers are 'IO ()').
dispatchLegacyTabCmd :: AgentEnv -> TabSlashCommand -> IO ()
dispatchLegacyTabCmd env tabCmd = do
  let emit     = legacyEmit env
      renderer = mkDefaultPromptRenderer (_env_channel env)
  argsRef <- newIORef (Map.empty :: Map.Map Int AutoSpawn.SpawnArgs)
  case tabCmd of
    TabListCmd ->
      AutoSpawn.handleListTabs env emit
    TabFocusCmd rawIdx ->
      AutoSpawn.handleFocus env emit rawIdx
    TabCloseCmd rawIdx force ->
      AutoSpawn.handleClose env emit argsRef noRenumber rawIdx
                            (force == ForceYes)
    TabRenameCmd rawIdx rawName ->
      AutoSpawn.handleRename env emit Parse.sanitizeTabName rawIdx rawName
    TabNewCmd mKind mArgs ->
      AutoSpawn.handleNew env renderer (Dispatcher.spawnTab env)
                          emit argsRef mKind mArgs
    TabResumeCmd _sid ->
      emit
        "Tab resume requires the tabbed-chat dispatcher\
        \ — not yet wired in the legacy CLI loop."

-- | The 'BannerEmit' callback used by every handler — directly emits via
-- @_ch_send@.
legacyEmit :: AgentEnv -> Text -> IO ()
legacyEmit env text =
  _ch_send (_env_channel env) (OutgoingMessage text)

-- | Renumber callback — no-op for legacy mode. Legacy has no
-- 'DispatcherState', so the pending-retry / spawn-args sidemaps that
-- would otherwise need reindexing don't exist.
noRenumber :: Int -> IO ()
noRenumber _ = pure ()

