-- |
-- Module      : PureClaw.Routing.TabDispatch
-- Description : Per-conversation inbound router + flat tab commands (8b.4).
--
-- This is the per-conversation routing brain of the Tabs-as-View cutover
-- (GitHub #79; spike §8). 'handleInbound' takes one inbound message tagged
-- with its 'ConversationKey' and routes it against /this/ conversation's
-- cursor and the global 'TabRegistry':
--
--   1. __Wizard interception__ — if the conversation is mid-@\/tab@, its next
--      message is consumed by the wizard ('stepWizard') /before/ the grammar
--      sees it (design §9.2 / §11). A completed pick binds a new tab; a
--      slash-prefixed reply cancels the wizard and re-dispatches that command.
--   2. __Flat tab verbs__ — @\/new@, @\/nt@, @\/close@, @\/tabs@, @\/rename@,
--      @\/relay@, @\/tab@ — recognised directly on the trimmed text (design
--      §7). These are __not__ routed through the legacy @\/tab \<sub\>@
--      grammar.
--   3. __Routing grammar__ — anything else goes through
--      'PureClaw.Routing.Parse.parseInput': @\/N@ switch, @\/N \<text\>@
--      inject, default text to the active tab, or a non-tab slash command
--      handed to '_td_fallthrough'.
--
-- Every effect is injected through 'TabDispatchDeps' (no real provider /
-- harness / Exec), so the whole router is unit-testable with recording fakes
-- and the pinned design §14 copy is asserted byte-for-byte. This module is
-- /additive/ — it is wired into the live loop at 8c, replacing the old
-- @dispatchOne@.
module PureClaw.Routing.TabDispatch
  ( -- * Injected dependencies
    TabDispatchDeps (..)
    -- * The router
  , handleInbound
    -- * Parsed-command entry point
  , runTabCommand
    -- * Production wiring seam
  , mkRunTabCommandSeam
  ) where

import Data.Char qualified as Char
import Data.IORef (IORef, atomicModifyIORef', readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Handles.Channel (ChannelHandle (..), OutgoingMessage (..))
import PureClaw.Handles.Tab
  ( NameError
  , TabError
  , TabIndex
  , mkTabIndex
  , toPublicTabError
  , unPublicTabError
  , unTabIndex
  )
import PureClaw.Harness.Registry (HarnessId)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT
import PureClaw.Core.Types (SessionId)
import PureClaw.Session.Kind
  ( HarnessFlavour (..)
  , HarnessSpec (..)
  , TerminalBackend (..)
  , fixedFlavourLookup
  )
import PureClaw.Tabs
  ( TabRegistry (..)
  , readTabs
  , registryAppend
  , registryLookupSlot
  , registryRemove
  )
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , ForceMode (..)
  , RelayMode (..)
  , Tab (..)
  , TabKindArg (..)
  , TabList
  , TabRef (..)
  , TabSlashCommand (..)
  , TabStatus (..)
  , TabsError (..)
  , clearCursor
  , conversationsOn
  , rebindSlot
  , resolveCursorSlot
  , setCursor
  , toList
  )
import PureClaw.Tabs.Wizard
  ( WizardEnv (..)
  , WizardState
  , WizardStep (..)
  , WizardTarget (..)
  , filterCandidates
  , mkWizardSnapshot
  , renderMenu
  , stepWizard
  )

-- ---------------------------------------------------------------------------
-- Injected dependencies
-- ---------------------------------------------------------------------------

-- | Everything 'handleInbound' needs, injected so the router is testable
-- against fakes (no live provider / harness / 'PureClaw.Tabs.Exec'). The
-- runtime-binding seams ('_td_ensure' \/ '_td_release' \/ '_td_sendTo') are the
-- 'PureClaw.Tabs.Exec' operations partially applied to the live registry at
-- 8c; here they are plain functions a test can record.
data TabDispatchDeps = TabDispatchDeps
  { _td_tabs    :: !TabRegistry
    -- ^ The global ordered tab registry (I1\/I2).
  , _td_cursors :: !(IORef CursorState)
    -- ^ Per-conversation cursors + relay overrides (I3).
  , _td_wizard  :: !(IORef (Map ConversationKey WizardState))
    -- ^ In-flight @\/tab@ wizard state, keyed by conversation (runtime-only).
  , _td_ensure  :: !(TabRef -> IO ())
    -- ^ Start (or ++refcount) the runtime backing a ref.
  , _td_release :: !(TabRef -> IO ())
    -- ^ --refcount; stop the runtime on last release.
  , _td_sendTo  :: !(TabRef -> Text -> IO (Either TabError ()))
    -- ^ Route input text to a ref's runtime.
  , _td_emit    :: !(ConversationKey -> Text -> IO ())
    -- ^ Reply / banner to a conversation's output sink.
  , _td_newDefaultSession :: !(IO (Either Text TabRef))
    -- ^ Create a fresh default-provider session, returning its 'BoundSession'
    --   ref. @'Left' msg@ when no default provider is configured.
  , _td_recentHarnesses :: !(IO [(HarnessId, Text)])
    -- ^ Running harnesses (id + label) for the @\/tab@ wizard menu.
  , _td_recentSessions  :: !(IO [(SessionId, Text)])
    -- ^ Recent sessions (id + label) for the @\/tab@ wizard menu.
  , _td_liveHarness     :: !(HarnessId -> IO Bool)
    -- ^ Liveness probe used by the wizard when a harness pick is resolved.
  , _td_relayDefault    :: !RelayMode
    -- ^ Global default relay mode (shown by @\/tabs@ / @\/relay@).
  , _td_routingConfig   :: !RT.RoutingConfig
    -- ^ Routing config for 'Parse.parseInput' (index bounds etc.).
  , _td_fallthrough     :: !(ConversationKey -> Slash.SlashCommand -> IO ())
    -- ^ Handler for non-tab slash commands (e.g. @\/bg@).
  , _td_onTabsChanged   :: !(IO ())
    -- ^ Callback fired once after each __mutating__ command (@\/nt@, @\/new@,
    -- @\/close@, @\/rename@, wizard bind). NOT fired on read\/switch commands
    -- (@\/tabs@, @\/relay@, @\/N@ switch, default text). Allows callers (e.g.
    -- "PureClaw.CLI.Commands") to rebroadcast\/persist the registry without
    -- creating a dependency from @Routing\/Tabs@ onto @Frontend@.
  , _td_spawnHarness    :: !(HarnessSpec -> IO (Either Text (TabRef, Text)))
    -- ^ Spawn a fresh harness, persist + link its session, and return the new
    -- tab's @('TabRef', label)@ (or a user-facing error). Used by the harness
    -- arm of 'cmdTabNew' (@\/tab new harness@). Wired from
    -- 'PureClaw.Agent.Env._env_startHarness' in "PureClaw.Tabs.Wiring".
  , _td_setSessionDescription :: !(SessionId -> Maybe Text -> IO (Either Text ()))
    -- ^ Set (or clear, with 'Nothing') a session's canonical description — the
    -- cross-process name. Injected so @\/rename@ on a @BoundSession@ tab updates
    -- the session entity (which syncs to every surface) rather than relabelling
    -- a per-process tab field. Wired in "PureClaw.CLI.Commands" per 'ServerMode'
    -- ('ServeFrontend' writes @session.json@ directly + rebroadcasts; the TUI
    -- 'RequireGateway' path PUTs to the running gateway's description endpoint).
  }

-- ---------------------------------------------------------------------------
-- Per-call context
-- ---------------------------------------------------------------------------

-- | The deps + the conversation being served, bundled so every helper takes a
-- single context argument. This keeps each effect call a saturated 2-arg
-- application (e.g. @emit ctx msg@) — passing @deps@ and @convKey@ as two
-- separate arguments at each site leaves an argument-position tick box that
-- HPC reports as un-entered even when the call runs.
data Ctx = Ctx
  { _ctx_deps :: !TabDispatchDeps
  , _ctx_conv :: !ConversationKey
  }

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Route one inbound message for a conversation. See the module haddock for
-- the three-stage order (wizard → flat verbs → routing grammar).
handleInbound :: TabDispatchDeps -> ConversationKey -> Text -> IO ()
handleInbound deps convKey raw = do
  let ctx = Ctx deps convKey
  wiz <- readIORef (_td_wizard deps)
  case Map.lookup convKey wiz of
    Just st -> handleWizardReply ctx st raw
    Nothing -> handleNonWizard ctx raw

-- ---------------------------------------------------------------------------
-- Parsed-command entry point
-- ---------------------------------------------------------------------------

-- | Execute a parsed @\/tab@ command against the shared tab subsystem, with an
-- explicit conversation key (the web path supplies a synthetic key; the
-- TUI\/channel path supplies the real one). Reuses the same helpers the
-- flat-verb handlers use, so every surface produces identical results.
--
-- This is /additive/: it does not change the flat-verb handlers
-- ('cmdClose' \/ 'cmdRename' \/ …) and is not yet wired into the live loop —
-- a later task connects it to @executeSlashCommand@.
runTabCommand :: TabDispatchDeps -> ConversationKey -> TabSlashCommand -> IO ()
runTabCommand deps conv cmd =
  let ctx = Ctx deps conv
      -- The parser guarantees a non-negative decimal index ('parseDecimalIndex'
      -- rejects non-digits), and 'mkTabIndex' only checks the floor (n >= 0), so
      -- the 'Nothing' arm is genuinely unreachable here. (An over-cap index is
      -- NOT rejected at parse time — it resolves to a graceful "no tab" message
      -- at registry-lookup time inside the handlers.) The impossible 'Nothing'
      -- is folded into 'error' per this module's convention.
      idx n = Maybe.fromMaybe
                (impossible "runTabCommand: non-negative parser index unexpectedly rejected")
                (mkTabIndex n)
  in case cmd of
       TabListCmd             -> cmdTabs   ctx
       TabRenameCmd n name    -> doRename  ctx (idx n) name
       TabCloseCmd _ ForceYes -> emit ctx closeForceMsg   -- mirror /close's --force rejection
       TabCloseCmd n ForceNo  -> closeSlot ctx (idx n)
       TabFocusCmd n          -> doSwitch  ctx (idx n)
       TabResumeCmd sid       -> bindNewTab ctx (BoundSession sid) defaultSessionName "attached"
       TabNewCmd mKind mArg   -> cmdTabNew ctx (kindWords mKind ++ argWords mArg)
  where
    -- Reconstruct the @[Text]@ 'cmdTabNew' re-parses: the kind keyword (if any)
    -- followed by the remaining argument words.
    kindWords = maybe [] (\k -> [tabKindArgText k])
    argWords  = maybe [] T.words

-- | Build the '_env_runTabCommand' seam closure: route a parsed @\/tab@ command
-- through 'runTabCommand' over the shared dispatch deps, sending the dispatcher
-- reply to the caller-supplied channel (so the web capture channel receives it),
-- and substituting the web placeholder conversation key when none is supplied.
--
-- This is the named, testable extraction of the inline lambda that
-- "PureClaw.CLI.Commands" assigns to '_env_runTabCommand'. The behaviour is
-- identical: the '_td_emit' field is overridden so the dispatcher's reply goes
-- to @chan@ (the per-request capture channel) instead of the conversation's
-- live sink, and a missing 'ConversationKey' falls back to @placeholderKey@.
mkRunTabCommandSeam
  :: TabDispatchDeps
  -> ConversationKey
     -- ^ placeholder key used when the caller passes 'Nothing' (the web path)
  -> (ChannelHandle -> Maybe ConversationKey -> TabSlashCommand -> IO ())
mkRunTabCommandSeam deps placeholderKey chan mConv =
  runTabCommand
    (deps { _td_emit = \_ t -> _ch_send chan (OutgoingMessage t) })
    (Maybe.fromMaybe placeholderKey mConv)

-- | Render a 'TabKindArg' back to the lowercase keyword 'cmdTabNew' recognises
-- (the inverse of 'PureClaw.Agent.SlashCommands.parseTabKindArg').
tabKindArgText :: TabKindArg -> Text
tabKindArgText TkaAi       = "ai"
tabKindArgText TkaProvider = "provider"
tabKindArgText TkaHarness  = "harness"
tabKindArgText TkaShell    = "shell"
tabKindArgText TkaSsh      = "ssh"
tabKindArgText TkaTmux     = "tmux"

-- ---------------------------------------------------------------------------
-- Stage 1: wizard interception
-- ---------------------------------------------------------------------------

-- | Feed a reply to an in-flight wizard and act on the resulting 'WizardStep'.
handleWizardReply :: Ctx -> WizardState -> Text -> IO ()
handleWizardReply ctx st raw = do
  (mNext, step) <- stepWizard (WizardEnv (_td_liveHarness (_ctx_deps ctx))) st raw
  case step of
    Done target -> do
      clearWizard ctx
      bindWizardTarget ctx target
    Cancelled -> do
      clearWizard ctx
      emit ctx "wizard cancelled"
    RunCommand cmd -> do
      clearWizard ctx
      handleNonWizard ctx cmd
    Reprompt msg -> do
      -- Invalid reply or vanished target: persist the (possibly refreshed)
      -- state and re-show the notice. 'Prompt' is the open-time render and is
      -- never produced by 'stepWizard'; it is folded in here so the match is
      -- total — both carry a notice, both re-prompt.
      setWizard ctx mNext
      emit ctx msg
    Prompt msg -> do
      setWizard ctx mNext
      emit ctx msg

-- | Bind a completed wizard pick to a new tab: append (or switch to an
-- already-bound ref), ensure its runtime, focus the conversation, confirm.
bindWizardTarget :: Ctx -> WizardTarget -> IO ()
bindWizardTarget ctx target =
  bindNewTab ctx ref (targetLabel target) "attached"
  where
    ref = case target of
      AttachHarness h -> BoundHarness h
      ReopenSession s -> BoundSession s

-- | A terse default label for a freshly-attached wizard target.
targetLabel :: WizardTarget -> Text
targetLabel (AttachHarness _) = "harness"
targetLabel (ReopenSession _) = "session"

-- ---------------------------------------------------------------------------
-- Stage 2 + 3: non-wizard dispatch
-- ---------------------------------------------------------------------------

-- | Recognise flat tab verbs on the trimmed text; otherwise fall to the
-- routing grammar.
handleNonWizard :: Ctx -> Text -> IO ()
handleNonWizard ctx raw =
  case T.words trimmed of
    ("/new"    : _)    -> cmdNew    ctx
    ("/nt"     : _)    -> cmdNt     ctx
    ("/close"  : args) -> cmdClose  ctx args
    ("/tabs" : sub@(_:_)) -> handleNonWizard ctx (T.unwords ("/tab" : sub))  -- /tabs <sub> == /tab <sub>
    ["/tabs"]          -> cmdTabs   ctx   -- bare /tabs lists
    ("/rename" : args) -> cmdRename ctx args
    ("/relay"  : args) -> cmdRelay  ctx args
    ("/tab" : "new" : rest)    -> cmdTabNew ctx rest
    ("/tab" : "close" : rest)  -> cmdClose  ctx rest
    ("/tab" : "rename" : rest) -> cmdRename ctx rest
    ("/tab"    : args) -> cmdTab    ctx args
    _                  -> routeGrammar ctx raw
  where
    trimmed = T.strip raw

-- ---------------------------------------------------------------------------
-- /new — reset the active tab
-- ---------------------------------------------------------------------------

-- | @\/new@: reset the conversation's __active__ tab to a fresh default
-- session (same slot). With no active tab, behaves like @\/nt@.
cmdNew :: Ctx -> IO ()
cmdNew ctx = do
  cs <- readIORef (_td_cursors (_ctx_deps ctx))
  tl <- readTabs (_td_tabs (_ctx_deps ctx))
  case resolveCursorSlot (_ctx_conv ctx) cs tl of
    Nothing   -> cmdNt ctx   -- no active tab → create one
    Just slot -> resetActiveTab ctx slot

-- | Reset the tab at @slot@: mint a fresh session, rebind the slot to it
-- (releasing the old ref's runtime, ensuring the new), keep the slot, point
-- the cursor at the new ref, confirm. The previous session persists on disk
-- (I4) — only the tab's binding moves.
resetActiveTab :: Ctx -> TabIndex -> IO ()
resetActiveTab ctx slot = do
  mNew <- _td_newDefaultSession (_ctx_deps ctx)
  case mNew of
    Left msg     -> emit ctx msg
    Right newRef -> do
      -- The slot is present (the caller resolved it from a live cursor) and
      -- @newRef@ is freshly minted, so it is never already bound: 'rebindSlot'
      -- always succeeds and 'registryLookupSlot' is always 'Just' here. The
      -- structurally-impossible branches are folded into 'error' (mirroring
      -- "PureClaw.Routing.Parse"'s 'boundedTabIndex') so the HPC report has no
      -- dead defensive arm to flag.
      mOld <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) slot
      tl   <- readTabs (_td_tabs (_ctx_deps ctx))
      let oldRef = _tab_ref (Maybe.fromMaybe (impossible "resetActiveTab: slot vanished") mOld)
          tl'    = either (impossible "resetActiveTab: fresh ref already bound")
                          id
                          (rebindSlot slot newRef defaultSessionName tl)
      writeTabs ctx tl'
      release ctx oldRef
      ensure ctx newRef
      setCursorTo ctx newRef
      notifyChanged ctx
      emit ctx ("reset tab /" <> slotChar slot)

-- ---------------------------------------------------------------------------
-- /nt — new tab with a fresh default session
-- ---------------------------------------------------------------------------

-- | @\/nt@: create a fresh default session, append a tab at the next slot,
-- ensure its runtime, switch the conversation's cursor to it.
cmdNt :: Ctx -> IO ()
cmdNt ctx = do
  mNew <- _td_newDefaultSession (_ctx_deps ctx)
  case mNew of
    Left msg     -> emit ctx msg
    Right newRef -> bindNewTab ctx newRef defaultSessionName "new tab"

-- ---------------------------------------------------------------------------
-- Shared: append-or-switch a new tab + confirm
-- ---------------------------------------------------------------------------

-- | Append a tab binding @ref@ (label @name@), ensure its runtime, focus the
-- conversation on it, and emit @\<verb\> \/\<slot\>@. If @ref@ is already
-- bound (I2), switch to the existing tab instead of duplicating. Slot
-- exhaustion emits the §14 copy with no state change.
bindNewTab :: Ctx -> TabRef -> Text -> Text -> IO ()
bindNewTab ctx ref name verb = do
  res <- registryAppend (_td_tabs (_ctx_deps ctx)) ref name
  case res of
    Left SlotsFull          -> emit ctx slotsFullMsg
    Left (AlreadyBound cur) -> do
      -- Ref already bound (I2): switch to the existing tab, do not duplicate.
      -- The error payload IS the current slot, so no re-lookup is needed.
      setCursorTo ctx ref
      emit ctx ("switched to /" <> slotChar cur)
    Right slot              -> do
      ensure ctx ref
      setCursorTo ctx ref
      notifyChanged ctx
      emit ctx (verb <> " /" <> slotChar slot)

-- ---------------------------------------------------------------------------
-- /close [N]
-- ---------------------------------------------------------------------------

-- | @\/close [N]@: drop a tab view (never harms ground truth). @--force@ is
-- rejected with the §14 copy; @N@ (or the active tab) is removed + compacted
-- and its runtime released.
cmdClose :: Ctx -> [Text] -> IO ()
cmdClose ctx args = case args of
  ("--force" : _) -> emit ctx closeForceMsg
  (a : _)         -> case slotArg a of
    Just slot -> closeSlot ctx slot
    Nothing   -> emit ctx closeBadArgMsg
  []              -> do
    cs <- readIORef (_td_cursors (_ctx_deps ctx))
    tl <- readTabs (_td_tabs (_ctx_deps ctx))
    case resolveCursorSlot (_ctx_conv ctx) cs tl of
      Just slot -> closeSlot ctx slot
      Nothing   -> emit ctx closeNoTargetMsg

-- | Remove the tab at @slot@ (compacting), release its runtime, and clear the
-- cursors that pointed at it (compaction renumbers others automatically).
closeSlot :: Ctx -> TabIndex -> IO ()
closeSlot ctx slot = do
  mTab <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) slot
  case mTab of
    Nothing  -> emit ctx closeNoTargetMsg
    Just tab -> do
      let ref = _tab_ref tab
      cs <- readIORef (_td_cursors (_ctx_deps ctx))
      registryRemove (_td_tabs (_ctx_deps ctx)) slot
      release ctx ref
      -- Drop every cursor focused on the removed ref (this conversation + any
      -- others sharing the tab); valid cursors survive via TabRef identity.
      mapM_ (modifyCursor ctx . clearCursor) (conversationsOn ref cs)
      notifyChanged ctx
      emit ctx ("closed /" <> slotChar slot)

-- ---------------------------------------------------------------------------
-- /tabs
-- ---------------------------------------------------------------------------

-- | @\/tabs@: list every tab (@\/\<slot\>  \<name\>  \<kind\>  \<status\>@,
-- dead tombstones included) plus a final line naming this conversation's
-- relay mode.
cmdTabs :: Ctx -> IO ()
cmdTabs ctx = do
  tl <- readTabs (_td_tabs (_ctx_deps ctx))
  cs <- readIORef (_td_cursors (_ctx_deps ctx))
  let focused = resolveCursorSlot (_ctx_conv ctx) cs tl
      rows    = map (tabRow focused) (toList tl)
      relay   = relayLine (relayModeFor ctx cs)
  emit ctx (T.intercalate "\n" (rows ++ [relay]))

-- | Render one @\/tabs@ row. The row for @focused@ (this conversation's cursor
-- slot, if any) carries a trailing @(focused)@ marker so the user can see at a
-- glance where plain text will go.
tabRow :: Maybe TabIndex -> Tab -> Text
tabRow focused t =
  "/" <> slotChar (_tab_slot t)
    <> "  " <> _tab_name t
    <> "  " <> kindLabel (_tab_ref t)
    <> "  " <> statusLabel (_tab_status t)
    <> (if focused == Just (_tab_slot t) then "  (focused)" else "")

-- | The trailing relay-mode line shown by @\/tabs@. Phrased as a full sentence
-- so a first-time user understands which tabs' output reaches them without
-- having to learn the @relay@ jargon.
relayLine :: RelayMode -> Text
relayLine FocusedOnly    = "Relay mode: focused — you only see output from this tab."
relayLine ActivityDigest = "Relay mode: activity — this tab in full, plus activity pings from others."
relayLine Firehose       = "Relay mode: all — full output from every tab."

-- ---------------------------------------------------------------------------
-- /rename [N] <name>
-- ---------------------------------------------------------------------------

-- | @\/rename [N] \<name\>@: relabel the tab at @N@ (or the active tab) using
-- 'Parse.sanitizeTabName'.
cmdRename :: Ctx -> [Text] -> IO ()
cmdRename ctx args = case args of
  (a : rest@(_ : _))
    | Just slot <- slotArg a -> doRename ctx slot (T.unwords rest)
  _ -> do
    -- No leading slot arg: rename the active tab to the whole argument blob.
    cs <- readIORef (_td_cursors (_ctx_deps ctx))
    tl <- readTabs (_td_tabs (_ctx_deps ctx))
    case resolveCursorSlot (_ctx_conv ctx) cs tl of
      Just slot -> doRename ctx slot (T.unwords args)
      Nothing   -> emit ctx renameNoTargetMsg

-- | Sanitize @name@ and set the bound entity's canonical name.
--
-- For a @BoundSession@ slot this sets the /session's/ description through the
-- injected '_td_setSessionDescription' seam (the canonical, cross-process name)
-- rather than relabelling the per-process tab field — so a rename syncs to every
-- surface. For a @BoundHarness@ slot, rename is out of scope (the harness has no
-- equivalent canonical name here): emit a clear note and do nothing.
doRename :: Ctx -> TabIndex -> Text -> IO ()
doRename ctx slot name = do
  mTab <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) slot
  case mTab of
    Nothing  -> emit ctx renameNoTargetMsg
    Just tab -> case _tab_ref tab of
      BoundHarness _   -> emit ctx renameHarnessMsg
      BoundSession sid -> case Parse.sanitizeTabName name of
        Left e      -> emit ctx (renameBadNameMsg e)
        Right clean -> do
          res <- _td_setSessionDescription (_ctx_deps ctx) sid (Just clean)
          case res of
            Right () -> emit ctx ("renamed /" <> slotChar slot <> " " <> clean)
            Left err -> emit ctx err

-- ---------------------------------------------------------------------------
-- /relay <mode>
-- ---------------------------------------------------------------------------

-- | @\/relay \<mode\>@: set this conversation's relay mode
-- (@focused@\/@activity@\/@all@). No arg shows the current mode (§14 copy).
cmdRelay :: Ctx -> [Text] -> IO ()
cmdRelay ctx args = case args of
  []      -> do
    cs <- readIORef (_td_cursors (_ctx_deps ctx))
    emit ctx (relayCurrentMsg (relayModeFor ctx cs))
  (a : _) -> case parseRelayMode a of
    Just m  -> do
      modifyCursor ctx (setRelay (_ctx_conv ctx) m)
      emit ctx ("relay mode: " <> relayWord m)
    Nothing -> emit ctx relayBadModeMsg

-- ---------------------------------------------------------------------------
-- /tab — open the attach wizard
-- ---------------------------------------------------------------------------

-- | @\/tab [query]@: snapshot the running harnesses + recent sessions
-- (filtered by @query@), store a 'WizardState' for the conversation, and emit
-- the rendered menu.
cmdTab :: Ctx -> [Text] -> IO ()
cmdTab ctx args = do
  harnesses <- _td_recentHarnesses (_ctx_deps ctx)
  sessions  <- _td_recentSessions (_ctx_deps ctx)
  let query = T.unwords args
      hs    = filterCandidates query harnesses
      ss    = filterCandidates query sessions
      st    = mkWizardSnapshot hs ss
  setWizard ctx (Just st)
  emit ctx (renderMenu st)

-- ---------------------------------------------------------------------------
-- /tab new <kind> — create a tab of the named kind
-- ---------------------------------------------------------------------------

-- | @\/tab new [\<kind\>]@: create a new tab of the requested kind. This is
-- distinct from bare @\/tab@ (the attach wizard) and is dispatched /before/ it,
-- so @\/tab new@ never opens the wizard.
--
-- The default-provider session kinds (@ai@\/@provider@\/bare) mint a fresh
-- session; @harness@ (optionally with an explicit flavour, e.g.
-- @\/tab new harness claude-code@) spawns a real harness via '_td_spawnHarness'
-- (WU-B). The remaining shell-family kinds emit a "not yet supported"
-- placeholder; an unrecognised keyword emits a short usage hint.
cmdTabNew :: Ctx -> [Text] -> IO ()
cmdTabNew ctx rest = case kindKeyword of
  -- bare / "ai" / "provider": mint a default-provider session (mirrors 'cmdNt').
  Nothing         -> mintDefault
  Just "ai"       -> mintDefault
  Just "provider" -> mintDefault
  Just "harness"  -> spawnHarness ctx flavourArgs
  Just "shell"    -> emit ctx (tabNewUnsupportedMsg "shell")
  Just "ssh"      -> emit ctx (tabNewUnsupportedMsg "ssh")
  Just "tmux"     -> emit ctx (tabNewUnsupportedMsg "tmux")
  Just _          -> emit ctx tabNewUsageMsg
  where
    kindKeyword = case rest of
      (k : _) -> Just (T.toLower k)
      []      -> Nothing
    -- Args following the @harness@ keyword (the optional flavour word).
    flavourArgs = drop 1 rest
    mintDefault = do
      mNew <- _td_newDefaultSession (_ctx_deps ctx)
      case mNew of
        Left msg     -> emit ctx msg
        Right newRef -> bindNewTab ctx newRef defaultSessionName "new tab"

-- | @\/tab new harness [\<flavour\>]@: build a default 'HarnessSpec' (flavour
-- from the optional argument, defaulting to @claude-code@; local backend; no
-- cwd\/args\/ids) and spawn it through '_td_spawnHarness'. On success bind the
-- returned 'TabRef' into a new tab; on failure emit the error.
spawnHarness :: Ctx -> [Text] -> IO ()
spawnHarness ctx flavourArgs = do
  result <- _td_spawnHarness (_ctx_deps ctx) spec
  case result of
    Left msg          -> emit ctx msg
    Right (ref, label) -> bindNewTab ctx ref label "new harness"
  where
    flavour = case flavourArgs of
      (f : _) -> fixedFlavourLookup (T.toLower f)
      []      -> HClaudeCode
    spec = HarnessSpec
      { _h_flavour           = flavour
      , _h_backend           = TbLocal
      , _h_cwd               = Nothing
      , _h_args              = []
      , _h_harnessId         = Nothing
      , _h_claudeSessionUuid = Nothing
      , _h_canonicalCwd      = Nothing
      }

-- ---------------------------------------------------------------------------
-- Stage 3: routing grammar
-- ---------------------------------------------------------------------------

-- | Route via 'Parse.parseInput': switch, inject, default text, or non-tab
-- slash command.
routeGrammar :: Ctx -> Text -> IO ()
routeGrammar ctx raw =
  case Parse.parseInput (_td_routingConfig (_ctx_deps ctx)) raw of
    Left _    -> emit ctx parseErrorMsg
    Right pin -> case pin of
      RT.Switch idx         -> doSwitch ctx idx
      RT.Inject idx text    -> doInject ctx idx text
      RT.Default text       -> doDefault ctx text
      RT.ParsedSlashCmd cmd -> _td_fallthrough (_ctx_deps ctx) (_ctx_conv ctx) cmd

-- | @\/N@: focus the tab at slot @N@ (out-of-range → §14 copy).
doSwitch :: Ctx -> TabIndex -> IO ()
doSwitch ctx idx = withSlot ctx idx $ \tab -> do
  setCursorTo ctx (_tab_ref tab)
  emit ctx ("switched to /" <> slotChar idx)

-- | @\/N \<text\>@: focus slot @N@ and route text to it (out-of-range → copy).
doInject :: Ctx -> TabIndex -> Text -> IO ()
doInject ctx idx text = withSlot ctx idx $ \tab -> do
  let ref = _tab_ref tab
  setCursorTo ctx ref
  deliver ctx ref text

-- | Route @text@ to @ref@'s runtime, surfacing a delivery failure as the §14
-- copy. Shared by 'doInject', 'doDefault', and the auto-start path so the
-- send-then-handle-error shape lives in exactly one place.
deliver :: Ctx -> TabRef -> Text -> IO ()
deliver ctx ref text = do
  result <- sendTo ctx ref text
  case result of
    Right () -> pure ()
    Left err -> emit ctx ("couldn't deliver your message — " <> unPublicTabError (toPublicTabError err))

-- | Resolve @idx@ to a present tab or emit the out-of-range §14 copy.
withSlot :: Ctx -> TabIndex -> (Tab -> IO ()) -> IO ()
withSlot ctx idx k = do
  tl   <- readTabs (_td_tabs (_ctx_deps ctx))
  mTab <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) idx
  case mTab of
    Just tab -> k tab
    Nothing  -> emit ctx (outOfRangeMsg idx (length (toList tl)))

-- | Plain text: route to the conversation's active tab. No active tab →
-- auto-start a fresh default session and route the text to it (the implicit
-- "just works" session — matches a fresh conversation's pre-Tabs behaviour); a
-- 'Dead' tombstone → deferred death warning + clear + drop (§8).
doDefault :: Ctx -> Text -> IO ()
doDefault ctx text = do
  cs <- readIORef (_td_cursors (_ctx_deps ctx))
  tl <- readTabs (_td_tabs (_ctx_deps ctx))
  case resolveCursorSlot (_ctx_conv ctx) cs tl of
    Nothing   -> autoStartDefault ctx text
    Just slot -> do
      -- 'resolveCursorSlot' returns the slot by resolving the cursor's ref
      -- against the list, so the tab is guaranteed present here; the impossible
      -- absence is folded into 'error' (no dead defensive arm for HPC).
      tab <- Maybe.fromMaybe (impossible "doDefault: resolved slot vanished")
               <$> registryLookupSlot (_td_tabs (_ctx_deps ctx)) slot
      if _tab_status tab == Dead
        then do
          -- §8 deferred death warning: warn, clear the cursor, DROP the text
          -- (never route it into the dead harness).
          emit ctx (deferredDeathMsg (_tab_name tab))
          modifyCursor ctx (clearCursor (_ctx_conv ctx))
        else deliver ctx (_tab_ref tab) text

-- | No active tab + plain text: mint a fresh default session, append a tab for
-- it, focus the conversation on it, and route the text — restoring the implicit
-- "just works" default session. No @new tab \/N@ confirmation is emitted (the
-- user sent a chat message, not @\/nt@); the new tab still becomes visible via
-- 'notifyChanged'. @'Left' msg@ (no provider\/model configured) surfaces the
-- existing setup guidance, exactly like 'cmdNt'.
autoStartDefault :: Ctx -> Text -> IO ()
autoStartDefault ctx text = do
  mNew <- _td_newDefaultSession (_ctx_deps ctx)
  case mNew of
    Left msg     -> emit ctx msg
    Right ref    -> do
      res <- registryAppend (_td_tabs (_ctx_deps ctx)) ref defaultSessionName
      case res of
        -- Slot exhaustion: surface the §14 copy with no state change.
        Left SlotsFull -> emit ctx slotsFullMsg
        -- 'Right' (the freshly-bound slot) and 'Left (AlreadyBound _)' (which is
        -- structurally impossible for a freshly-minted ref) both route the text
        -- to the ref — focus + deliver — rather than crash on the latter.
        _              -> routeToNew ctx ref text

-- | Focus the conversation on a freshly-bound @ref@, ensure its runtime, notify
-- listeners, and route @text@ to it. Shared by the two reachable arms of
-- 'autoStartDefault'.
routeToNew :: Ctx -> TabRef -> Text -> IO ()
routeToNew ctx ref text = do
  ensure ctx ref
  setCursorTo ctx ref
  notifyChanged ctx
  deliver ctx ref text

-- ---------------------------------------------------------------------------
-- Cursor / wizard / registry mutation helpers (all 'Ctx'-saturated)
-- ---------------------------------------------------------------------------

-- | Reply / banner to the served conversation.
emit :: Ctx -> Text -> IO ()
emit ctx = _td_emit (_ctx_deps ctx) (_ctx_conv ctx)

-- | Start (or ++refcount) the runtime backing a ref.
ensure :: Ctx -> TabRef -> IO ()
ensure ctx = _td_ensure (_ctx_deps ctx)

-- | --refcount; stop the runtime on last release.
release :: Ctx -> TabRef -> IO ()
release ctx = _td_release (_ctx_deps ctx)

-- | Route input to a ref's runtime.
sendTo :: Ctx -> TabRef -> Text -> IO (Either TabError ())
sendTo ctx = _td_sendTo (_ctx_deps ctx)

-- | Apply a pure 'CursorState' update to the shared cursor ref.
modifyCursor :: Ctx -> (CursorState -> CursorState) -> IO ()
modifyCursor ctx f =
  atomicModifyIORef' (_td_cursors (_ctx_deps ctx)) (\cs -> (f cs, ()))

-- | Focus the served conversation on a ref.
setCursorTo :: Ctx -> TabRef -> IO ()
setCursorTo ctx ref = modifyCursor ctx (setCursor (_ctx_conv ctx) ref)

-- | Set a conversation's relay-mode override.
setRelay :: ConversationKey -> RelayMode -> CursorState -> CursorState
setRelay k m cs = cs { _cs_relay = Map.insert k m (_cs_relay cs) }

-- | The relay mode for the served conversation, against the global default.
relayModeFor :: Ctx -> CursorState -> RelayMode
relayModeFor ctx cs =
  Map.findWithDefault (_td_relayDefault (_ctx_deps ctx)) (_ctx_conv ctx) (_cs_relay cs)

-- | Store (or clear, with 'Nothing') the served conversation's wizard state.
setWizard :: Ctx -> Maybe WizardState -> IO ()
setWizard ctx mSt =
  atomicModifyIORef' (_td_wizard (_ctx_deps ctx)) $ \m ->
    (maybe (Map.delete k m) (\st -> Map.insert k st m) mSt, ())
  where
    k = _ctx_conv ctx

-- | Drop the served conversation's wizard state.
clearWizard :: Ctx -> IO ()
clearWizard ctx = setWizard ctx Nothing

-- | Fire the injected tabs-changed callback once (called after each mutating
-- registry operation — tab create, close, rename, wizard bind). NOT called on
-- read or cursor-switch operations.
notifyChanged :: Ctx -> IO ()
notifyChanged ctx = _td_onTabsChanged (_ctx_deps ctx)

-- | Overwrite the registry's 'TabList' (used by in-place rebind/rename, which
-- the registry handle has no dedicated op for). The rebinds here run on the
-- dispatcher thread only (single writer), so a snapshot-then-set is race-free
-- in practice.
writeTabs :: Ctx -> TabList -> IO ()
writeTabs ctx tl' =
  case _td_tabs (_ctx_deps ctx) of
    TabRegistry ioref -> writeIORef ioref tl'

-- ---------------------------------------------------------------------------
-- Small argument parsers
-- ---------------------------------------------------------------------------

-- | Parse a single @[0-9a-z]@ slot argument into a 'TabIndex'.
slotArg :: Text -> Maybe TabIndex
slotArg t = case T.unpack t of
  [c] -> tabIndexChar c >>= mkTabIndex
  _   -> Nothing

-- | The @[0-9a-z]@ → index mapping (digits @0..9@, letters @10..35@).
tabIndexChar :: Char -> Maybe Int
tabIndexChar c
  | Char.isDigit c      = Just (fromEnum c - fromEnum '0')
  | Char.isAsciiLower c = Just (10 + fromEnum c - fromEnum 'a')
  | otherwise           = Nothing

-- | Render a 'TabIndex' back to its single @[0-9a-z]@ display char.
slotChar :: TabIndex -> Text
slotChar ti =
  let n = unTabIndex ti
  in if n < 10
       then T.singleton (toEnum (fromEnum '0' + n))
       else T.singleton (toEnum (fromEnum 'a' + n - 10))

-- | Parse a relay-mode word.
parseRelayMode :: Text -> Maybe RelayMode
parseRelayMode t = case T.toLower t of
  "focused"  -> Just FocusedOnly
  "activity" -> Just ActivityDigest
  "all"      -> Just Firehose
  _          -> Nothing

-- | The user-facing word for a relay mode.
relayWord :: RelayMode -> Text
relayWord FocusedOnly    = "focused"
relayWord ActivityDigest = "activity"
relayWord Firehose       = "all"

-- | The kind label shown in @\/tabs@.
kindLabel :: TabRef -> Text
kindLabel (BoundSession _) = "session"
kindLabel (BoundHarness _) = "harness"

-- | The status label shown in @\/tabs@.
statusLabel :: TabStatus -> Text
statusLabel Live = "live"
statusLabel Dead = "dead"

-- | The default label for a freshly-minted default-provider session tab
-- (@\/new@ \/ @\/nt@). Wizard-bound tabs use 'targetLabel' instead.
defaultSessionName :: Text
defaultSessionName = "session"

-- ---------------------------------------------------------------------------
-- Pinned copy (design §14)
-- ---------------------------------------------------------------------------

-- | @\/N@ out of range (§14). @n@ = current tab count.
outOfRangeMsg :: TabIndex -> Int -> Text
outOfRangeMsg idx n =
  "/" <> slotChar idx <> ": out of range — you have " <> tshow n
    <> " tabs (/0–/" <> lastSlotChar n <> "); /tabs to list"

-- | The high slot char of an @n@-tab list (@n-1@). For @n <= 0@ (an
-- out-of-range switch against an empty list) the high coordinate is @0@. For
-- @n >= 1@, @n-1 >= 0@ so 'mkTabIndex' always succeeds; the impossible
-- 'Nothing' is folded into 'error'.
lastSlotChar :: Int -> Text
lastSlotChar n
  | n <= 0    = "0"
  | otherwise =
      slotChar (Maybe.fromMaybe (impossible "lastSlotChar: negative index")
                                (mkTabIndex (n - 1)))

-- | Slot exhaustion at 36 (§14).
slotsFullMsg :: Text
slotsFullMsg = "all 36 tab slots in use — /close one first"

-- | Deferred death warning on next send to a 'Dead' tab (§14).
deferredDeathMsg :: Text -> Text
deferredDeathMsg name =
  "⚠ \"" <> name <> "\" exited while you were away — message not sent; resend when ready"

-- | @--force@ on @\/close@ (§14).
closeForceMsg :: Text
closeForceMsg = "/close has no --force (tabs never destroy sessions or harnesses)"

-- | @\/relay@ with no arg, showing the current mode (§14).
relayCurrentMsg :: RelayMode -> Text
relayCurrentMsg m = "relay mode: " <> relayWord m <> " (focused | activity | all)"

-- | A parse-error note for an unrecognised @\/@ shape.
parseErrorMsg :: Text
parseErrorMsg = "could not parse that — /tabs to list, /help for commands"

-- | @\/close@ with no resolvable target.
closeNoTargetMsg :: Text
closeNoTargetMsg = "no tab to close — /tabs to list"

-- | @\/close@ with an unparseable slot argument.
closeBadArgMsg :: Text
closeBadArgMsg = "close which tab? give a slot like /close 0 (/tabs to list)"

-- | @\/rename@ with no resolvable target.
renameNoTargetMsg :: Text
renameNoTargetMsg = "no tab to rename — /tabs to list"

-- | @\/rename@ whose name failed sanitization.
renameBadNameMsg :: NameError -> Text
renameBadNameMsg e = "invalid tab name (" <> tshow e <> ")"

-- | @\/rename@ targeting a harness tab — out of scope (rename sets a session's
-- canonical description; a harness has no equivalent canonical name here).
renameHarnessMsg :: Text
renameHarnessMsg = "rename applies to session tabs only"

-- | @\/relay@ with an unrecognised mode word.
relayBadModeMsg :: Text
relayBadModeMsg = "unknown relay mode — use focused, activity, or all"

-- | @\/tab new \<kind\>@ for a kind that is recognised but not yet wired
-- (shell\/ssh\/tmux; harness landed in WU-B).
tabNewUnsupportedMsg :: Text -> Text
tabNewUnsupportedMsg kind = "/tab new " <> kind <> " is not yet supported"

-- | @\/tab new \<kind\>@ for an unrecognised kind keyword — a short usage hint.
tabNewUsageMsg :: Text
tabNewUsageMsg = "unknown tab kind — use ai, harness, shell, ssh, or tmux"

-- ---------------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------------

-- | 'Show' a value as 'Text'.
tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Marker for a structurally-impossible branch (an invariant the surrounding
-- logic has already established). Folded into 'error' via 'Maybe.fromMaybe' /
-- 'either' so the case is dispatched in uninstrumented library code, leaving
-- no dead defensive alternative for the HPC report to flag — the same
-- convention "PureClaw.Routing.Parse" uses for 'boundedTabIndex'.
impossible :: String -> a
impossible msg = error ("PureClaw.Routing.TabDispatch: " <> msg)
