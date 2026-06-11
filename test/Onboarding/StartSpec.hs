-- |
-- Module      : Onboarding.StartSpec
-- Description : O-series — onboarding (WU11 fills in WU0's red scaffold).
--
-- Flips the WU0-staged 'pending' tests for the O-series Definition-of-
-- Done items from @docs/tabbed-chat.md@ §"Onboarding (O-series)" to
-- real assertions backed by the WU11 production wiring:
--
--   * 'PureClaw.Routing.Onboarding.handleStart' (O1)
--   * 'PureClaw.Routing.Onboarding.helpTabSection'
--     consumed by 'PureClaw.Agent.SlashCommands.executeSlashCommand'
--     on 'CmdHelp' (O2)
--   * 'PureClaw.Routing.Onboarding.botFatherCommandList' (O3)
--   * 'PureClaw.Channels.Telegram.botFatherCommands' /
--     'encodeBotFatherCommands' (O3 — Telegram-side projection)
module Onboarding.StartSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import PureClaw.Agent.Context (emptyContext)
import PureClaw.Agent.Env
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Agent.SlashCommands
  ( SlashCommand (..)
  , executeSlashCommand
  , parseSlashCommand
  )
import PureClaw.Channels.Telegram
  ( botFatherCommands
  , encodeBotFatherCommands
  )
import PureClaw.Handles.Channel
  ( ChannelHandle (..)
  , OutgoingMessage (..)
  , mkNoOpChannelHandle
  )
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Onboarding
  ( botFatherCommandList
  , handleStart
  , helpTabSection
  , onboardingMessage
  )
import PureClaw.Security.Policy (defaultPolicy)
import PureClaw.Security.Vault.Plugin (mkPluginHandle)
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tools.Registry (emptyRegistry)


-- ---------------------------------------------------------------------------
-- spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "O-series \x2014 onboarding (WU11 wires)" $ do

  -- =====================================================================
  -- O1 — /start handler
  -- =====================================================================

  describe "O1: /start (Telegram convention)" $ do

    it "parseSlashCommand \"/start\" returns Just CmdStart \
       \(so the channel-layer parser routes the command into the \
       \onboarding handler)" $ do
      parseSlashCommand "/start" `shouldBe` Just CmdStart
      parseSlashCommand "/START" `shouldBe` Just CmdStart
      parseSlashCommand "  /start  " `shouldBe` Just CmdStart

    it "handleStart emits exactly one message whose body contains the \
       \value prop and all three slash-prefix mentions \
       \(/0, /tab new shell, /tabs); /tab new no longer takes an index \
       \(tmux-packing)" $ do
      sentRef <- newIORef ([] :: [Text])
      env <- mkOnboardingEnv (recordingChannel sentRef)
      handleStart env
      sent <- readIORef sentRef
      case sent of
        [body] -> do
          -- Value prop: the welcome line establishes what PureClaw is.
          T.unpack body `shouldContain` "Tabbed Chat lets you drive"
          -- (a) /0 shortcut for AI
          T.unpack body `shouldContain` "/0"
          -- (b) /tab new shell for shell users (no index — tmux packing)
          T.unpack body `shouldContain` "/tab new shell"
          -- (c) /tabs for dashboard
          T.unpack body `shouldContain` "/tabs"
          -- (d) tmux packing note is mentioned so users know /N does
          -- NOT auto-spawn any more.
          T.unpack body `shouldContain` "tmux"
        other -> expectationFailure $
          "expected exactly one emitted message, got " <> show (length other)

    it "executeSlashCommand env CmdStart emits the same orientation \
       \text via _ch_send (so both the legacy executor and the \
       \dispatcher's CmdStart intercept converge on the same body)" $ do
      sentRef <- newIORef ([] :: [Text])
      env <- mkOnboardingEnv (recordingChannel sentRef)
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdStart ctx
      sent <- readIORef sentRef
      sent `shouldBe` [onboardingMessage]

    it "non-Telegram channels degrade gracefully \x2014 the same \
       \handleStart call emits orientation text via _ch_send on a \
       \no-op channel without raising" $ do
      sentRef <- newIORef ([] :: [Text])
      env <- mkOnboardingEnv (recordingChannel sentRef)
      -- handleStart uses only _ch_send (which every ChannelHandle
      -- implements); no Telegram-specific dependency.
      handleStart env `shouldReturn` ()
      sent <- readIORef sentRef
      length sent `shouldBe` 1

  -- =====================================================================
  -- O2 — /help rendering includes a 'Tab commands' subsection
  -- =====================================================================

  describe "O2: /help rendering" $ do

    it "/help output contains the literal strings 'Tab commands' and \
       \'/tabs'" $ do
      sentRef <- newIORef ([] :: [Text])
      env <- mkOnboardingEnv (recordingChannel sentRef)
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdHelp ctx
      sent <- readIORef sentRef
      case sent of
        [body] -> do
          T.unpack body `shouldContain` "Tab commands"
          T.unpack body `shouldContain` "/tabs"
        other -> expectationFailure $
          "expected exactly one /help message, got " <> show (length other)

    -- The legacy parser's GroupTab specs auto-render as a "Tab:" group
    -- via renderHelpText, BUT Onboarding.helpTabSection is a richer
    -- hand-authored block covering the same vocabulary (plus /N grammar
    -- and tmux-style note). /help must not display BOTH — the
    -- auto-render block is suppressed so the hand-authored one is the
    -- single source.
    it "/help renders the Tab section exactly once (no duplication \
       \between auto-render and helpTabSection)" $ do
      sentRef <- newIORef ([] :: [Text])
      env <- mkOnboardingEnv (recordingChannel sentRef)
      let ctx = emptyContext Nothing
      _ <- executeSlashCommand env CmdHelp ctx
      sent <- readIORef sentRef
      case sent of
        [body] -> do
          -- The auto-render group heading "  Tab:" must not appear —
          -- we suppress it because helpTabSection covers the same
          -- vocabulary with more context.
          T.unpack body `shouldNotContain` "  Tab:\n"
          -- The hand-authored heading "Tab commands" must appear
          -- exactly once.
          let occurrences = T.count "Tab commands" body
          occurrences `shouldBe` 1
        other -> expectationFailure $
          "expected exactly one /help message, got " <> show (length other)

    it "the rendered 'Tab commands' subsection enumerates the Tabbed \
       \Chat verbs: /N, /N <payload>, /tabs, /tab new, /tab close, \
       \/tab focus, /tab resume, /tab rename" $ do
      let body = T.unpack helpTabSection
      body `shouldContain` "Tab commands"
      body `shouldContain` "/N"
      body `shouldContain` "/N <payload>"
      body `shouldContain` "/tabs"
      body `shouldContain` "/tab new"
      body `shouldContain` "/tab close"
      body `shouldContain` "/tab focus"
      body `shouldContain` "/tab resume"
      body `shouldContain` "/tab rename"

  -- =====================================================================
  -- O3 — BotFather command registration list (golden file)
  -- =====================================================================

  describe "O3: BotFather command descriptions" $ do

    it "botFatherCommandList matches the golden enumeration: /0..9 \
       \then /a..z \x2192 'Switch to tab N', then /tab, /tabs, /start \
       \with their canonical descriptions (39 entries total, well \
       \under Telegram's 100-command BotFather cap)" $
      botFatherCommandList `shouldBe` expectedBotFatherCommands

    it "PureClaw.Channels.Telegram.botFatherCommands re-exports the \
       \same list (so the Telegram-side projection cannot drift from \
       \the source of truth)" $
      botFatherCommands `shouldBe` botFatherCommandList

    it "encodeBotFatherCommands produces a JSON payload whose \
       \'commands' array contains one entry per registered command \
       \(with the leading '/' stripped, as Telegram's setMyCommands \
       \API requires)" $ do
      let payload = encodeBotFatherCommands botFatherCommandList
      case Aeson.eitherDecodeStrict payload of
        Left e -> expectationFailure ("decode failed: " <> e)
        Right (Aeson.Object o) -> case KM.lookup "commands" o of
          Just (Aeson.Array v) -> do
            length v `shouldBe` length botFatherCommandList
            -- Spot-check the first (/0), middle (/tab), and last
            -- (/start) entries; the round-trip test above pins the
            -- exhaustive list.
            T.unpack (TE.decodeUtf8 payload)
              `shouldContain` "\"command\":\"0\""
            T.unpack (TE.decodeUtf8 payload)
              `shouldContain` "\"command\":\"tab\""
            T.unpack (TE.decodeUtf8 payload)
              `shouldContain` "\"command\":\"start\""
            -- Make sure no stray leading '/' survived.
            T.unpack (TE.decodeUtf8 payload)
              `shouldNotContain` "\"command\":\"/"
          _ -> expectationFailure "expected 'commands' to be a JSON array"
        Right _ -> expectationFailure "expected JSON object"


-- ---------------------------------------------------------------------------
-- Golden list (mirror of docs/tabbed-chat.md §"Channel autocomplete" + O3)
-- ---------------------------------------------------------------------------

-- | The exhaustive expected BotFather command list, exactly as
-- documented in @docs\/tabbed-chat.md@ §"Onboarding (O-series)" O3
-- (updated to single-char @[0-9a-z]@ index grammar).
-- Authored here as a separate value so the O3 test is verifiably
-- comparing against a string the test author wrote (not a re-derived
-- value coupled to the production code).
expectedBotFatherCommands :: [(Text, Text)]
expectedBotFatherCommands =
  [ ("/0", "Switch to tab N")
  , ("/1", "Switch to tab N")
  , ("/2", "Switch to tab N")
  , ("/3", "Switch to tab N")
  , ("/4", "Switch to tab N")
  , ("/5", "Switch to tab N")
  , ("/6", "Switch to tab N")
  , ("/7", "Switch to tab N")
  , ("/8", "Switch to tab N")
  , ("/9", "Switch to tab N")
  , ("/a", "Switch to tab N")
  , ("/b", "Switch to tab N")
  , ("/c", "Switch to tab N")
  , ("/d", "Switch to tab N")
  , ("/e", "Switch to tab N")
  , ("/f", "Switch to tab N")
  , ("/g", "Switch to tab N")
  , ("/h", "Switch to tab N")
  , ("/i", "Switch to tab N")
  , ("/j", "Switch to tab N")
  , ("/k", "Switch to tab N")
  , ("/l", "Switch to tab N")
  , ("/m", "Switch to tab N")
  , ("/n", "Switch to tab N")
  , ("/o", "Switch to tab N")
  , ("/p", "Switch to tab N")
  , ("/q", "Switch to tab N")
  , ("/r", "Switch to tab N")
  , ("/s", "Switch to tab N")
  , ("/t", "Switch to tab N")
  , ("/u", "Switch to tab N")
  , ("/v", "Switch to tab N")
  , ("/w", "Switch to tab N")
  , ("/x", "Switch to tab N")
  , ("/y", "Switch to tab N")
  , ("/z", "Switch to tab N")
  , ("/tab",   "Tabs: new, list, close, focus, resume, rename")
  , ("/tabs",  "List all tabs")
  , ("/start", "Tabbed Chat \x2014 see /help for tab commands")
  ]


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A 'ChannelHandle' whose @_ch_send@ appends each outgoing message
-- body to the supplied 'IORef'. Order is preserved (newest at the
-- head of the stored list after reverse).
recordingChannel :: IORef [Text] -> ChannelHandle
recordingChannel ref = mkNoOpChannelHandle
  { _ch_send = \(OutgoingMessage t) -> modifyIORef' ref (++ [t])
  }

-- | Minimal 'AgentEnv' for onboarding tests. The factory fills every
-- new (Tabbed Chat) field with a usable value so 'handleStart' and
-- 'executeSlashCommand CmdStart' \/ 'CmdHelp' can run without
-- exception. Production fields not touched by the O-series live as
-- @error \"not exercised\"@ stubs so accidental reads surface loudly.
mkOnboardingEnv :: ChannelHandle -> IO AgentEnv
mkOnboardingEnv ch = do
  providerRef    <- newIORef Nothing
  modelRef       <- newIORef Nothing
  vaultRef       <- newIORef Nothing
  harnessRef     <- newIORef Map.empty
  harnessReg     <- Registry.newRegistry
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef Map.empty
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = ch
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
    , _env_harnesses         = harnessRef
    , _env_harnessRegistry  = harnessReg
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_routingConfig     = defaultRoutingConfig
    , _env_fork              = defaultEnvFork
    , _env_broker              = Nothing
    , _env_tabRegistry = error "8c.2 stub: _env_tabRegistry not exercised in this test"
    , _env_cursors = error "8c.2 stub: _env_cursors not exercised in this test"
    , _env_exec = error "8c.2 stub: _env_exec not exercised in this test"
    , _env_relayWriter = error "8c.2 stub: _env_relayWriter not exercised in this test"
    , _env_sinks = error "8c.2 stub: _env_sinks not exercised in this test"
    , _env_wizard = error "8c.2 stub: _env_wizard not exercised in this test"
    , _env_tabOutQ = error "8c.2 stub: _env_tabOutQ not exercised in this test"
    }

