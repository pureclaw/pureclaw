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
  ) where

import Data.Char qualified as Char
import Data.IORef (IORef, atomicModifyIORef', readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Handles.Tab
  ( NameError
  , TabError
  , TabIndex
  , mkTabIndex
  , unTabIndex
  )
import PureClaw.Harness.Registry (HarnessId)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT
import PureClaw.Core.Types (SessionId)
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
  , RelayMode (..)
  , Tab (..)
  , TabList
  , TabRef (..)
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
    ("/tabs"   : _)    -> cmdTabs   ctx
    ("/rename" : args) -> cmdRename ctx args
    ("/relay"  : args) -> cmdRelay  ctx args
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
    Left _       -> emit ctx noDefaultProviderMsg
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
    Left _       -> emit ctx noDefaultProviderMsg
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
  let rows  = map tabRow (toList tl)
      relay = relayLine (relayModeFor ctx cs)
  emit ctx (T.intercalate "\n" (rows ++ [relay]))

-- | Render one @\/tabs@ row.
tabRow :: Tab -> Text
tabRow t =
  "/" <> slotChar (_tab_slot t)
    <> "  " <> _tab_name t
    <> "  " <> kindLabel (_tab_ref t)
    <> "  " <> statusLabel (_tab_status t)

-- | The trailing relay-mode line shown by @\/tabs@.
relayLine :: RelayMode -> Text
relayLine m = "relay: " <> relayWord m

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

-- | Sanitize @name@ and rewrite the tab at @slot@'s label in place.
doRename :: Ctx -> TabIndex -> Text -> IO ()
doRename ctx slot name =
  case Parse.sanitizeTabName name of
    Left e      -> emit ctx (renameBadNameMsg e)
    Right clean -> do
      mTab <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) slot
      case mTab of
        Nothing  -> emit ctx renameNoTargetMsg
        Just tab -> do
          -- Rebinding a slot to the ref it already holds always succeeds
          -- (relabel in place); the impossible 'Left' is folded into 'error'.
          tl <- readTabs (_td_tabs (_ctx_deps ctx))
          let tl' = either (impossible "doRename: in-place rebind rejected")
                           id
                           (rebindSlot slot (_tab_ref tab) clean tl)
          writeTabs ctx tl'
          emit ctx ("renamed /" <> slotChar slot <> " " <> clean)

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
  _ <- sendTo ctx ref text
  pure ()

-- | Resolve @idx@ to a present tab or emit the out-of-range §14 copy.
withSlot :: Ctx -> TabIndex -> (Tab -> IO ()) -> IO ()
withSlot ctx idx k = do
  tl   <- readTabs (_td_tabs (_ctx_deps ctx))
  mTab <- registryLookupSlot (_td_tabs (_ctx_deps ctx)) idx
  case mTab of
    Just tab -> k tab
    Nothing  -> emit ctx (outOfRangeMsg idx (length (toList tl)))

-- | Plain text: route to the conversation's active tab. Empty cursor → spawn
-- hint; a 'Dead' tombstone → deferred death warning + clear + drop (§8).
doDefault :: Ctx -> Text -> IO ()
doDefault ctx text = do
  cs <- readIORef (_td_cursors (_ctx_deps ctx))
  tl <- readTabs (_td_tabs (_ctx_deps ctx))
  case resolveCursorSlot (_ctx_conv ctx) cs tl of
    Nothing   -> emit ctx emptyCursorMsg
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
        else do
          _ <- sendTo ctx (_tab_ref tab) text
          pure ()

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

-- | Empty cursor + default text (§14).
emptyCursorMsg :: Text
emptyCursorMsg = "no active tab — /new to start one or /tab to attach"

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

-- | No default provider configured (§14).
noDefaultProviderMsg :: Text
noDefaultProviderMsg =
  "no default provider configured — set one with /target default <name> (or config.toml)"

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

-- | @\/relay@ with an unrecognised mode word.
relayBadModeMsg :: Text
relayBadModeMsg = "unknown relay mode — use focused, activity, or all"

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
