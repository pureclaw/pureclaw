{-# LANGUAGE PatternSynonyms #-}
-- |
-- Module      : Routing.LegacyDispatchSpec
-- Description : Tests for the legacy-CLI bridge that dispatches CmdTab into Routing.AutoSpawn.
--
-- The new tabbed-chat dispatcher (Routing.Dispatcher.runDispatcher) is
-- not yet wired as the production CLI entry-point; Agent.Loop.runAgentLoop
-- is the legacy single-tab loop, and users running the CLI today reach
-- it. Without a bridge, /tab* commands parse correctly (since 529229e)
-- but hit a stub message ("Tab commands require the tabbed-chat
-- dispatcher").
--
-- Routing.LegacyDispatch.dispatchLegacyTabCmd is the bridge: it takes
-- an AgentEnv + a TabSlashCommand and invokes the appropriate
-- Routing.AutoSpawn handler so the legacy CLI sees real output.
module Routing.LegacyDispatchSpec (spec) where

import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
  ( ForceMode (..)
  , TabKindArg (..)
  , TabSlashCommand (..)
  )
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Tab
  ( TabHandle (..)
  , TabIndex
  , TabName (..)
  , TabStatus (..)
  , mkTabIndex
  , pattern KindAi
  )
import PureClaw.MCP (McpServer)
import PureClaw.Security.Policy (defaultPolicy)
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin (mkPluginHandle)
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.LegacyDispatch (dispatchLegacyTabCmd)
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle
  ( FakeChannel
  , FakeChannelEvent (..)
  , drainEvents
  , fakeChannelHandle
  , newFakeChannel
  )


-- ---------------------------------------------------------------------------
-- Test scaffolding
-- ---------------------------------------------------------------------------

mkTestEnvWithChannel :: FakeChannel -> IO AgentEnv
mkTestEnvWithChannel fch = do
  providerRef    <- newIORef Nothing
  modelRef       <- newIORef Nothing
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef (Map.empty :: Map Text McpServer)
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef (Nothing :: Maybe TabIndex)
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO 1024
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = fakeChannelHandle fch
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
    , _env_harnesses         = harnessRef
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing :: Maybe AgentDef
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_tabs              = tabsRef
    , _env_focus             = focusRef
    , _env_activeCount       = activeCountTv
    , _env_runners           = runnersRef
    , _env_channelOutQ       = channelOutQ
    , _env_routingConfig     = defaultRoutingConfig
    , _env_fork              = defaultEnvFork
    }

-- | Build a synthetic AI 'TabHandle' that records its `_tabHandle_send`
-- calls and `_tabHandle_close` invocations. Lets the dispatch tests
-- assert on registry state without requiring the real Tab.Ai factory.
mkSyntheticAiTab :: TabIndex -> Text -> IO TabHandle
mkSyntheticAiTab idx nm = do
  pure TabHandle
    { _tabHandle_index        = idx
    , _tabHandle_name         = TabName nm
    , _tabHandle_kind         = KindAi
    , _tabHandle_status       = pure Active
    , _tabHandle_send         = \_ -> pure (Right ())
    , _tabHandle_enqueueSlash = \_ -> pure (Right ())
    , _tabHandle_close        = \_ -> pure ()
    }

-- | Extract all OutgoingMessage text from drained channel events.
drainSentText :: FakeChannel -> IO [Text]
drainSentText fch = do
  evs <- drainEvents fch
  pure [ t | (_, FceSend (OutgoingMessage t)) <- evs ]

-- | True if any drained outbound message contains the substring.
sentMessageContains :: FakeChannel -> Text -> IO Bool
sentMessageContains fch needle = do
  msgs <- drainSentText fch
  pure (any (needle `T.isInfixOf`) msgs)

-- | Convenience: TabIndex via mkTabIndex with no error handling
-- (test inputs are always valid).
ti :: Int -> TabIndex
ti n = case mkTabIndex n of
  Just i  -> i
  Nothing -> error ("ti: " <> show n <> " is not a valid TabIndex")


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Routing.LegacyDispatch.dispatchLegacyTabCmd" $ do

    -- /tabs and /tab list both produce a dashboard. With an empty
    -- registry, the dashboard's B1 message is shown.
    it "TabListCmd on empty registry emits the empty-dashboard banner" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env TabListCmd
      ok <- sentMessageContains fch "No tabs open"
      ok `shouldBe` True

    -- The empty-dashboard banner must NOT mention the obsolete
    -- "/tab new N <kind>" syntax (tmux model — user doesn't pick a
    -- slot) and must NOT advertise "/N" as a way to create tabs (/N
    -- on missing tab errors; it's not a spawn shortcut).
    it "empty-dashboard banner uses the tmux-model /tab new <kind> syntax" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env TabListCmd
      msgs <- drainSentText fch
      let joined = T.unwords msgs
      -- Positive: mention the correct syntax
      ("/tab new <kind>" `T.isInfixOf` joined) `shouldBe` True
      -- Negative: must NOT contain stale "/tab new N" guidance
      ("/tab new N" `T.isInfixOf` joined) `shouldBe` False

    it "TabListCmd with one tab lists it" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      handle <- mkSyntheticAiTab (ti 0) "test-tab"
      atomicModifyIORef' (_env_tabs env)
        (\m -> (IntMap.insert 0 handle m, ()))
      dispatchLegacyTabCmd env TabListCmd
      msgs <- drainSentText fch
      -- Dashboard should mention /0 (the tab) somewhere
      any ("/0" `T.isInfixOf`) msgs `shouldBe` True

    -- /tab focus 0 with no tab → error banner (NOT auto-spawn)
    it "TabFocusCmd 0 on empty registry emits no-such-tab banner" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabFocusCmd 0)
      ok <- sentMessageContains fch "no such tab"
      ok `shouldBe` True

    it "TabFocusCmd 0 with tab 0 present sets focus" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      handle <- mkSyntheticAiTab (ti 0) "first"
      atomicModifyIORef' (_env_tabs env)
        (\m -> (IntMap.insert 0 handle m, ()))
      dispatchLegacyTabCmd env (TabFocusCmd 0)
      newFocus <- readIORef (_env_focus env)
      newFocus `shouldBe` Just (ti 0)

    -- /tab close N renumbers; behaviour identical to AutoSpawn.handleClose
    it "TabCloseCmd on missing tab emits a tab-not-found banner" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabCloseCmd 5 ForceNo)
      ok <- sentMessageContains fch "tab: not found"
      ok `shouldBe` True

    -- /tab new — with no kind, emits the force-prompt; with a kind, the
    -- dispatch tries to spawn. We assert against the easier case: bare
    -- /tab new emits a prompt (so the user knows what to do next).
    it "TabNewCmd Nothing Nothing emits a kind prompt" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabNewCmd Nothing Nothing)
      msgs <- drainSentText fch
      -- The prompt should mention some kind keyword for the user
      -- to pick from (ai, shell, harness, ssh, tmux). We assert
      -- "ai" appears since that's the most universal first choice.
      any (\m -> "ai" `T.isInfixOf` T.toLower m) msgs `shouldBe` True

    -- /tab new <kind> kicks the spawn pipeline. In the legacy bridge,
    -- factories require AgentEnv with all wiring; we can at minimum
    -- assert that *something* gets emitted (no silent ignore) and the
    -- channel state has changed.
    it "TabNewCmd with KindAi emits an outcome message" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabNewCmd (Just TkaAi) Nothing)
      msgs <- drainSentText fch
      length msgs `shouldSatisfy` (>= 1)

    -- /tab rename with missing tab is a no-op-style error (the rename
    -- handler currently announces sanitization but doesn't mutate the
    -- name; the WU10 deferral). We just assert the channel sees
    -- *something* so the user gets feedback rather than silent acceptance.
    it "TabRenameCmd on missing tab emits feedback" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabRenameCmd 0 "new-name")
      msgs <- drainSentText fch
      length msgs `shouldSatisfy` (>= 1)

    -- /tab resume — full wiring requires DispatcherState; the legacy
    -- bridge degrades gracefully with a "not available in legacy mode"
    -- message rather than crashing.
    it "TabResumeCmd emits a not-supported message in legacy mode" $ do
      fch <- newFakeChannel
      env <- mkTestEnvWithChannel fch
      dispatchLegacyTabCmd env (TabResumeCmd (SessionId "some-valid-id"))
      msgs <- drainSentText fch
      length msgs `shouldSatisfy` (>= 1)
