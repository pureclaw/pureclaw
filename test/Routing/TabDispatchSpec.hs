-- |
-- Module      : Routing.TabDispatchSpec
-- Description : 8b.4 — per-conversation inbound router + flat tab commands.
--
-- Drives 'PureClaw.Routing.TabDispatch.handleInbound' entirely against
-- recording fakes (no live provider / harness / 'PureClaw.Tabs.Exec'), as
-- required by the 8b.4 Definition of Done. Every dependency is an IORef-backed
-- fake so each test can assert the exact calls made and the EXACT design §14
-- copy strings byte-for-byte.
--
-- Coverage map (DoD):
--
--   * @\/new@ reset (rebinds same slot, old ref released, new ensured, cursor
--     follows) + @\/new@-with-no-active-tab-creates-one + no-default copy.
--   * @\/nt@ append+switch + slot-exhaustion copy + no-default copy.
--   * @\/close@ (remove+compact+release) + @--force@ copy + no-target.
--   * @\/tabs@ listing incl. relay-mode line + Dead tombstone shown.
--   * @\/rename@ sanitized + no-target.
--   * @\/relay@ set + no-arg current-mode copy + bad mode.
--   * @\/tab@ opens the wizard (menu emitted, state stored).
--   * Wizard Done (binds+ensures+switches), Cancelled, Reprompt, RunCommand.
--   * @\/N@ Switch (cursor set) + out-of-range copy.
--   * @\/N \<text\>@ Inject (cursor + send).
--   * Default (send to active) + empty-cursor copy + Dead-tombstone deferred
--     warning + drop (assert sendTo NOT called).
--   * ParsedSlashCmd → fallthrough invoked.
module Routing.TabDispatchSpec (spec) where

import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), SessionId (..))
import PureClaw.Handles.Tab (TabError (..), unTabIndex)
import PureClaw.Harness.Registry (HarnessId, parseHarnessId)
import PureClaw.Routing.Config qualified as RConfig
import PureClaw.Routing.TabDispatch
  ( TabDispatchDeps (..)
  , handleInbound
  )
import PureClaw.Tabs
  ( TabRegistry
  , newTabRegistry
  , readTabs
  , registryAppend
  , registrySetStatus
  )
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState
  , RelayMode (..)
  , Tab (..)
  , TabRef (..)
  , TabStatus (..)
  , emptyCursors
  , resolveCursorSlot
  , toList
  )
import PureClaw.Tabs.Wizard (WizardState)

-- ---------------------------------------------------------------------------
-- Fakes harness
-- ---------------------------------------------------------------------------

-- | Recorders + injected behaviour for one 'TabDispatchDeps'.
data Fakes = Fakes
  { f_deps        :: TabDispatchDeps
  , f_emits       :: IORef [(ConversationKey, Text)]
  , f_sends       :: IORef [(TabRef, Text)]
  , f_ensures     :: IORef [TabRef]
  , f_releases    :: IORef [TabRef]
  , f_fallthrough :: IORef [(ConversationKey, Slash.SlashCommand)]
  , f_reg         :: TabRegistry
  , f_cursors     :: IORef CursorState
  , f_wizard      :: IORef (Map ConversationKey WizardState)
  , f_tabsChanged :: IORef Int
    -- ^ Incremented once per call to '_td_onTabsChanged'.
  }

-- | How the injected @newDefaultSession@ behaves.
data DefaultBehaviour
  = MintsRef TabRef        -- ^ Returns @Right ref@.
  | NoDefault              -- ^ Returns @Left "..."@.

-- | How the injected @_td_sendTo@ behaves.
data SendBehaviour
  = SendOk                 -- ^ Always returns @Right ()@.
  | SendErr TabError       -- ^ Always returns @Left err@.

-- | Build a fresh 'Fakes' with the given default-session behaviour and the
-- given wizard candidate lists.
mkFakes
  :: DefaultBehaviour
  -> [(HarnessId, Text)]    -- ^ recent harnesses
  -> [(SessionId, Text)]    -- ^ recent sessions
  -> (HarnessId -> Bool)    -- ^ liveness probe
  -> IO Fakes
mkFakes defB = mkFakesEx defB SendOk

-- | Extended variant of 'mkFakes' that also controls @_td_sendTo@ behaviour.
mkFakesEx
  :: DefaultBehaviour
  -> SendBehaviour
  -> [(HarnessId, Text)]    -- ^ recent harnesses
  -> [(SessionId, Text)]    -- ^ recent sessions
  -> (HarnessId -> Bool)    -- ^ liveness probe
  -> IO Fakes
mkFakesEx defB sendB harnesses sessions liveFn = do
  emits       <- newIORef []
  sends       <- newIORef []
  ensures     <- newIORef []
  releases    <- newIORef []
  fall        <- newIORef []
  reg         <- newTabRegistry
  cursors     <- newIORef emptyCursors
  wizard      <- newIORef Map.empty
  tabsChanged <- newIORef (0 :: Int)
  let deps = TabDispatchDeps
        { _td_tabs           = reg
        , _td_cursors        = cursors
        , _td_wizard         = wizard
        , _td_ensure         = \r -> modifyIORef' ensures (++ [r])
        , _td_release        = \r -> modifyIORef' releases (++ [r])
        , _td_sendTo         = \r t -> do
            modifyIORef' sends (++ [(r, t)])
            pure $ case sendB of
              SendOk      -> Right ()
              SendErr err -> Left err
        , _td_emit           = \k t -> modifyIORef' emits (++ [(k, t)])
        , _td_newDefaultSession = pure $ case defB of
            MintsRef r -> Right r
            NoDefault  -> Left noDefaultGuidance
        , _td_recentHarnesses = pure harnesses
        , _td_recentSessions  = pure sessions
        , _td_liveHarness     = pure . liveFn
        , _td_relayDefault    = FocusedOnly
        , _td_routingConfig   = RConfig.defaultRoutingConfig
        , _td_fallthrough     = \k c -> modifyIORef' fall (++ [(k, c)])
        , _td_onTabsChanged   = modifyIORef' tabsChanged (+1)
        }
  pure Fakes
    { f_deps        = deps
    , f_emits       = emits
    , f_sends       = sends
    , f_ensures     = ensures
    , f_releases    = releases
    , f_fallthrough = fall
    , f_reg         = reg
    , f_cursors     = cursors
    , f_wizard      = wizard
    , f_tabsChanged = tabsChanged
    }

-- | A simple default-mint 'Fakes' (no wizard candidates, all harnesses live).
simpleFakes :: DefaultBehaviour -> IO Fakes
simpleFakes defB = mkFakes defB [] [] (const True)

-- | Simple fakes where @_td_sendTo@ always returns the given 'TabError'.
simpleFakesWithSendErr :: TabError -> IO Fakes
simpleFakesWithSendErr err =
  mkFakesEx (MintsRef (sess "x")) (SendErr err) [] [] (const True)

-- ---------------------------------------------------------------------------
-- Convenience accessors
-- ---------------------------------------------------------------------------

emitted :: Fakes -> IO [Text]
emitted f = map snd <$> readIORef (f_emits f)

lastEmit :: Fakes -> IO Text
lastEmit f = do
  es <- emitted f
  case reverse es of
    (e : _) -> pure e
    []      -> pure "<no emit>"

sentTexts :: Fakes -> IO [(TabRef, Text)]
sentTexts f = readIORef (f_sends f)

ensured :: Fakes -> IO [TabRef]
ensured f = readIORef (f_ensures f)

released :: Fakes -> IO [TabRef]
released f = readIORef (f_releases f)

falls :: Fakes -> IO [(ConversationKey, Slash.SlashCommand)]
falls f = readIORef (f_fallthrough f)

-- | The slot a conversation's cursor currently resolves to.
cursorSlot :: Fakes -> ConversationKey -> IO (Maybe Int)
cursorSlot f k = do
  cs <- readIORef (f_cursors f)
  tl <- readTabs (f_reg f)
  pure (fmap unTabIndex (resolveCursorSlot k cs tl))

-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

-- | The no-default-provider guidance string returned by the 'NoDefault' fake
-- (mirrors what 'mkNewDefaultSession' returns for the no-provider case).
-- TabDispatch now passes the Left text through directly, so both the fake
-- and the assertions use this constant.
noDefaultGuidance :: Text
noDefaultGuidance =
  "No provider configured. To start chatting, configure your provider with:\n\n"
  <> "  /provider <PROVIDER>\n"

convA :: ConversationKey
convA = (CkCli, ConversationId "cli")

convB :: ConversationKey
convB = (CkCli, ConversationId "other")

sess :: Text -> TabRef
sess t = BoundSession (SessionId t)

harn :: Text -> HarnessId
harn t = case parseHarnessId (pad t) of
  Just h  -> h
  Nothing -> error ("bad uuid fixture: " <> T.unpack t)
  where
    -- Pad a short tag into a valid UUID string deterministically.
    pad s = "00000000-0000-0000-0000-0000000000" <> T.justifyRight 2 '0' s

-- | Append a session tab labelled @name@; return its ref.
appendSession :: Fakes -> Text -> Text -> IO TabRef
appendSession f sid name = do
  let r = sess sid
  _ <- registryAppend (f_reg f) r name
  pure r

-- | Append a harness tab; return its ref.
appendHarness :: Fakes -> HarnessId -> Text -> IO TabRef
appendHarness f hid name = do
  let r = BoundHarness hid
  _ <- registryAppend (f_reg f) r name
  pure r

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  newSpec
  ntSpec
  tabNewSpec
  closeSpec
  tabsSpec
  renameSpec
  relaySpec
  tabWizardOpenSpec
  wizardStepSpec
  switchInjectSpec
  defaultSpec
  fallthroughSpec
  edgeSpec
  onTabsChangedSpec

-- ---------------------------------------------------------------------------
-- /new
-- ---------------------------------------------------------------------------

newSpec :: Spec
newSpec = describe "/new (reset active tab)" $ do
  it "rebinds the active tab's slot: old ref released, new ensured, cursor follows" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    old <- appendSession f "old" "old-tab"
    -- Focus convA on the existing tab via a switch.
    handleInbound (f_deps f) convA "/0"
    -- Now /new resets it.
    handleInbound (f_deps f) convA "/new"
    tl <- readTabs (f_reg f)
    -- still exactly one tab at slot 0, now bound to the fresh session
    map (unTabIndex . _tab_slot) (toList tl) `shouldBe` [0]
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    -- old ref released, fresh ref ensured
    released f `shouldReturn` [old]
    ens <- ensured f
    last ens `shouldBe` sess "fresh"
    -- cursor now resolves to slot 0 (the fresh tab)
    cursorSlot f convA `shouldReturn` Just 0
    lastEmit f `shouldReturn` "reset tab /0"

  it "with NO active tab, creates one (like /nt)" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/new"
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    ensured f `shouldReturn` [sess "fresh"]
    cursorSlot f convA `shouldReturn` Just 0
    lastEmit f `shouldReturn` "new tab /0"

  it "with no default provider, emits the §14 copy" $ do
    f <- simpleFakes NoDefault
    _ <- appendSession f "old" "old-tab"
    handleInbound (f_deps f) convA "/0"      -- focus it
    handleInbound (f_deps f) convA "/new"
    lastEmit f `shouldReturn` noDefaultGuidance
    -- nothing released; the tab is untouched
    released f `shouldReturn` []

-- ---------------------------------------------------------------------------
-- /nt
-- ---------------------------------------------------------------------------

ntSpec :: Spec
ntSpec = describe "/nt (new tab)" $ do
  it "appends a fresh session at the next slot, ensures it, switches the cursor" $ do
    f <- simpleFakes (MintsRef (sess "s1"))
    _ <- appendSession f "s0" "first"          -- occupies slot 0
    handleInbound (f_deps f) convA "/nt"
    tl <- readTabs (f_reg f)
    map (unTabIndex . _tab_slot) (toList tl) `shouldBe` [0, 1]
    map _tab_ref (toList tl) `shouldBe` [sess "s0", sess "s1"]
    ensured f `shouldReturn` [sess "s1"]
    cursorSlot f convA `shouldReturn` Just 1
    lastEmit f `shouldReturn` "new tab /1"

  it "at 36 tabs, emits the slot-exhaustion §14 copy with no change" $ do
    f <- simpleFakes (MintsRef (sess "overflow"))
    mapM_ (\n -> appendSession f ("s" <> tshowI n) ("t" <> tshowI n)) [0 .. 35 :: Int]
    handleInbound (f_deps f) convA "/nt"
    lastEmit f `shouldReturn` "all 36 tab slots in use — /close one first"
    tl <- readTabs (f_reg f)
    length (toList tl) `shouldBe` 36
    ensured f `shouldReturn` []

  it "with no default provider, emits the §14 copy" $ do
    f <- simpleFakes NoDefault
    handleInbound (f_deps f) convA "/nt"
    lastEmit f `shouldReturn` noDefaultGuidance

-- ---------------------------------------------------------------------------
-- /tab new <kind>
-- ---------------------------------------------------------------------------

tabNewSpec :: Spec
tabNewSpec = describe "cmdTabNew (/tab new)" $ do
  it "/tab new ai mints a default session, binds a tab, ensures, switches" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new ai"
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    ensured f `shouldReturn` [sess "fresh"]
    cursorSlot f convA `shouldReturn` Just 0
    readIORef (f_tabsChanged f) `shouldReturn` 1
    lastEmit f `shouldReturn` "new tab /0"

  it "/tab new (bare) behaves like /tab new ai" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new"
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    ensured f `shouldReturn` [sess "fresh"]
    cursorSlot f convA `shouldReturn` Just 0
    readIORef (f_tabsChanged f) `shouldReturn` 1
    lastEmit f `shouldReturn` "new tab /0"

  it "/tab new provider behaves like /tab new ai" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new provider"
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    ensured f `shouldReturn` [sess "fresh"]
    cursorSlot f convA `shouldReturn` Just 0
    readIORef (f_tabsChanged f) `shouldReturn` 1
    lastEmit f `shouldReturn` "new tab /0"

  it "is case-insensitive on the kind keyword (AI)" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new AI"
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    lastEmit f `shouldReturn` "new tab /0"

  it "/tab new ai with no default provider emits the no-default guidance, no tab created" $ do
    f <- simpleFakes NoDefault
    handleInbound (f_deps f) convA "/tab new ai"
    lastEmit f `shouldReturn` noDefaultGuidance
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    ensured f `shouldReturn` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "/tab new harness is not yet supported (WU-A placeholder)" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new harness"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not yet supported"
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "/tab new shell is not yet supported" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new shell"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not yet supported"
    out `shouldSatisfy` T.isInfixOf "shell"
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "/tab new ssh is not yet supported" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new ssh"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not yet supported"
    out `shouldSatisfy` T.isInfixOf "ssh"
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "/tab new tmux is not yet supported" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new tmux"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not yet supported"
    out `shouldSatisfy` T.isInfixOf "tmux"
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "/tab new bogusxyz (unknown kind) emits a usage hint, no tab created" $ do
    f <- simpleFakes (MintsRef (sess "fresh"))
    handleInbound (f_deps f) convA "/tab new bogusxyz"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "ai"
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    ensured f `shouldReturn` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "REGRESSION: /tab <query> (no new) still opens the attach wizard" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")]
            [(SessionId "old", "refactor")]
            (const True)
    handleInbound (f_deps f) convA "/tab somequery"
    -- wizard state is stored (the menu path), registry unchanged
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` True
    tl <- readTabs (f_reg f)
    toList tl `shouldBe` []
    readIORef (f_tabsChanged f) `shouldReturn` 0

  it "REGRESSION: bare /tab still opens the attach wizard" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const True)
    handleInbound (f_deps f) convA "/tab"
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` True
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "Attach a tab"

-- ---------------------------------------------------------------------------
-- /close
-- ---------------------------------------------------------------------------

closeSpec :: Spec
closeSpec = describe "/close" $ do
  it "removes the slot, compacts, and releases the ref" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    r1 <- appendSession f "s1" "b"
    _ <- appendSession f "s2" "c"
    handleInbound (f_deps f) convA "/close 1"
    tl <- readTabs (f_reg f)
    -- s2 shifted down to slot 1
    map _tab_ref (toList tl) `shouldBe` [sess "s0", sess "s2"]
    released f `shouldReturn` [r1]
    lastEmit f `shouldReturn` "closed /1"

  it "with no arg closes the active tab and clears its cursor" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    r0 <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"          -- focus slot 0
    handleInbound (f_deps f) convA "/close"
    released f `shouldReturn` [r0]
    cursorSlot f convA `shouldReturn` Nothing
    lastEmit f `shouldReturn` "closed /0"

  it "rejects --force with the §14 copy (no removal)" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/close --force"
    lastEmit f `shouldReturn`
      "/close has no --force (tabs never destroy sessions or harnesses)"
    tl <- readTabs (f_reg f)
    length (toList tl) `shouldBe` 1
    released f `shouldReturn` []

  it "with no target emits a helpful note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/close"
    lastEmit f `shouldReturn` "no tab to close — /tabs to list"

-- ---------------------------------------------------------------------------
-- /tabs
-- ---------------------------------------------------------------------------

tabsSpec :: Spec
tabsSpec = describe "/tabs" $ do
  it "lists each tab with slot/name/kind/status plus the relay-mode line" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "alpha"
    _ <- appendHarness f (harn "1") "beta"
    handleInbound (f_deps f) convA "/tabs"
    out <- lastEmit f
    let ls = T.lines out
    ls `shouldBe`
      [ "/0  alpha  session  live"
      , "/1  beta  harness  live"
      , "relay: focused"
      ]

  it "shows a Dead tombstone" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    r0 <- appendHarness f (harn "1") "ghost"
    registrySetStatus (f_reg f) r0 Dead
    handleInbound (f_deps f) convA "/tabs"
    out <- lastEmit f
    T.lines out `shouldBe`
      [ "/0  ghost  harness  dead"
      , "relay: focused"
      ]

-- ---------------------------------------------------------------------------
-- /rename
-- ---------------------------------------------------------------------------

renameSpec :: Spec
renameSpec = describe "/rename" $ do
  it "relabels a tab by slot, sanitizing the name" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "old"
    handleInbound (f_deps f) convA "/rename 0 new-name"
    tl <- readTabs (f_reg f)
    map _tab_name (toList tl) `shouldBe` ["new-name"]
    lastEmit f `shouldReturn` "renamed /0 new-name"

  it "renames the active tab when no slot is given" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "old"
    handleInbound (f_deps f) convA "/0"
    handleInbound (f_deps f) convA "/rename shiny"
    tl <- readTabs (f_reg f)
    map _tab_name (toList tl) `shouldBe` ["shiny"]

  it "with no active tab and no slot, emits a no-target note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/rename whatever"
    lastEmit f `shouldReturn` "no tab to rename — /tabs to list"

-- ---------------------------------------------------------------------------
-- /relay
-- ---------------------------------------------------------------------------

relaySpec :: Spec
relaySpec = describe "/relay" $ do
  it "sets this conversation's relay mode" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/relay all"
    lastEmit f `shouldReturn` "relay mode: all"
    -- and it now sticks for the /tabs relay line
    handleInbound (f_deps f) convA "/tabs"
    out <- lastEmit f
    last (T.lines out) `shouldBe` "relay: all"

  it "with no arg shows the current mode (§14 copy)" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/relay activity"   -- set first
    handleInbound (f_deps f) convA "/relay"
    lastEmit f `shouldReturn` "relay mode: activity (focused | activity | all)"

  it "default mode is focused when never set" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/relay"
    lastEmit f `shouldReturn` "relay mode: focused (focused | activity | all)"

  it "rejects an unknown mode" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/relay sideways"
    lastEmit f `shouldReturn` "unknown relay mode — use focused, activity, or all"

-- ---------------------------------------------------------------------------
-- /tab (open wizard)
-- ---------------------------------------------------------------------------

tabWizardOpenSpec :: Spec
tabWizardOpenSpec = describe "/tab (open wizard)" $ do
  it "snapshots candidates, stores wizard state, and emits the menu" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")]
            [(SessionId "old", "refactor")]
            (const True)
    handleInbound (f_deps f) convA "/tab"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "Attach a tab"
    out `shouldSatisfy` T.isInfixOf "cancel"
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` True

  it "filters candidates by a query argument" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude"), (harn "2", "side:codex")]
            []
            (const True)
    handleInbound (f_deps f) convA "/tab codex"
    out <- lastEmit f
    -- only the codex harness shows up; the claude one is filtered out
    out `shouldSatisfy` T.isInfixOf (renderHarnessId (harn "2"))
    out `shouldNotSatisfy` T.isInfixOf (renderHarnessId (harn "1"))

-- ---------------------------------------------------------------------------
-- Wizard stepping
-- ---------------------------------------------------------------------------

wizardStepSpec :: Spec
wizardStepSpec = describe "wizard reply handling" $ do
  it "Done binds a new tab, ensures it, switches the cursor, clears wizard" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const True)
    handleInbound (f_deps f) convA "/tab"        -- open
    handleInbound (f_deps f) convA "1"           -- pick harness #1
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [BoundHarness (harn "1")]
    ensured f `shouldReturn` [BoundHarness (harn "1")]
    cursorSlot f convA `shouldReturn` Just 0
    lastEmit f `shouldReturn` "attached /0"
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` False

  it "Done on an already-bound ref switches instead of duplicating" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const True)
    _ <- appendHarness f (harn "1") "already"      -- harness #1 already a tab
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "1"
    tl <- readTabs (f_reg f)
    length (toList tl) `shouldBe` 1                 -- no duplicate
    cursorSlot f convA `shouldReturn` Just 0
    lastEmit f `shouldReturn` "switched to /0"

  it "Cancelled clears the wizard and emits" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const True)
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "0"             -- cancel
    lastEmit f `shouldReturn` "wizard cancelled"
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` False

  it "Reprompt keeps the wizard open and emits a notice" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const True)
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "zzz"           -- invalid reply
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` True           -- still open
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not a valid choice"

  it "Reprompt on a vanished harness refreshes the list (still open)" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [(harn "1", "work:claude")] [] (const False)  -- harness dead
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "1"             -- pick the dead harness
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` True
    lastEmit f `shouldReturn` "that target is gone — list refreshed"

  it "RunCommand cancels and re-dispatches the slash command" $ do
    f <- mkFakes (MintsRef (sess "fresh"))
            [(harn "1", "work:claude")] [] (const True)
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "/nt"           -- slash reply cancels + runs
    wiz <- readIORef (f_wizard f)
    Map.member convA wiz `shouldBe` False
    -- /nt actually ran: a fresh tab exists, ensured, cursor set
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [sess "fresh"]
    lastEmit f `shouldReturn` "new tab /0"

-- ---------------------------------------------------------------------------
-- Switch / Inject (routing grammar)
-- ---------------------------------------------------------------------------

switchInjectSpec :: Spec
switchInjectSpec = describe "/N switch and inject" $ do
  it "/N sets the cursor to that tab" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    _ <- appendSession f "s1" "b"
    handleInbound (f_deps f) convA "/1"
    cursorSlot f convA `shouldReturn` Just 1
    lastEmit f `shouldReturn` "switched to /1"

  it "/N out of range emits the §14 copy" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    _ <- appendSession f "s1" "b"
    _ <- appendSession f "s2" "c"
    handleInbound (f_deps f) convA "/5"
    lastEmit f `shouldReturn`
      "/5: out of range — you have 3 tabs (/0–/2); /tabs to list"

  it "/N <text> sets the cursor AND routes the text to that tab" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    r1 <- appendSession f "s1" "b"
    handleInbound (f_deps f) convA "/1 hello there"
    cursorSlot f convA `shouldReturn` Just 1
    sentTexts f `shouldReturn` [(r1, "hello there")]

  it "/N <text> out of range emits the copy and sends nothing" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/4 hi"
    lastEmit f `shouldReturn`
      "/4: out of range — you have 1 tabs (/0–/0); /tabs to list"
    sentTexts f `shouldReturn` []

  it "/N <text> when sendTo returns TabConcurrencyLimit, emits a banner" $ do
    f <- simpleFakesWithSendErr (TabConcurrencyLimit 0)
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0 hello"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "input queue full"

-- ---------------------------------------------------------------------------
-- Default text
-- ---------------------------------------------------------------------------

defaultSpec :: Spec
defaultSpec = describe "default text" $ do
  it "routes to the active tab" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    r0 <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"
    handleInbound (f_deps f) convA "just chatting"
    sentTexts f `shouldReturn` [(r0, "just chatting")]

  it "with no active tab emits the empty-cursor §14 copy" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "hello"
    lastEmit f `shouldReturn` "no active tab — /new to start one or /tab to attach"
    sentTexts f `shouldReturn` []

  it "on a Dead tombstone: deferred warning, clear, DROP (no send)" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    r0 <- appendHarness f (harn "1") "claude-code"
    handleInbound (f_deps f) convA "/0"            -- focus it
    registrySetStatus (f_reg f) r0 Dead            -- harness dies
    handleInbound (f_deps f) convA "ping"
    lastEmit f `shouldReturn`
      "⚠ \"claude-code\" exited while you were away — message not sent; resend when ready"
    sentTexts f `shouldReturn` []                  -- message dropped
    cursorSlot f convA `shouldReturn` Nothing      -- cursor cleared

  it "when sendTo returns TabConcurrencyLimit, emits a banner (queue full)" $ do
    f <- simpleFakesWithSendErr (TabConcurrencyLimit 0)
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"
    handleInbound (f_deps f) convA "hello"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "input queue full"

  it "when sendTo returns TabNotFound, emits a banner (not found)" $ do
    f <- simpleFakesWithSendErr (TabNotFound 0)
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"
    handleInbound (f_deps f) convA "hello"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "not found"

-- ---------------------------------------------------------------------------
-- Fallthrough (non-tab slash command)
-- ---------------------------------------------------------------------------

fallthroughSpec :: Spec
fallthroughSpec = describe "ParsedSlashCmd fallthrough" $
  it "hands a non-tab slash command (/bg) to _td_fallthrough" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convB "/bg do a thing"
    fs <- falls f
    map fst fs `shouldBe` [convB]
    map snd fs `shouldBe` [Slash.CmdBg "do a thing"]

-- ---------------------------------------------------------------------------
-- Edge cases (coverage of the less-trodden arms)
-- ---------------------------------------------------------------------------

edgeSpec :: Spec
edgeSpec = describe "edge cases" $ do
  it "/relay focused is accepted (round-trips through the parser)" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/relay focused"
    lastEmit f `shouldReturn` "relay mode: focused"

  it "/close with a multi-char arg emits the bad-arg note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/close zz"
    lastEmit f `shouldReturn`
      "close which tab? give a slot like /close 0 (/tabs to list)"

  it "/close with a single non-slot char emits the bad-arg note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/close !"
    lastEmit f `shouldReturn`
      "close which tab? give a slot like /close 0 (/tabs to list)"

  it "/N switch against an empty tab list reports a 0-tab range" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/5"
    lastEmit f `shouldReturn`
      "/5: out of range — you have 0 tabs (/0–/0); /tabs to list"

  it "/close of an absent (but well-formed) slot emits the no-target note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/close 5"   -- slot 5 has no tab
    lastEmit f `shouldReturn` "no tab to close — /tabs to list"

  it "/rename with a name that fails sanitization is rejected" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/rename 0 \ESC[31mevil"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "invalid tab name"

  it "/rename of an absent slot emits the no-target note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/rename 7 nope"
    lastEmit f `shouldReturn` "no tab to rename — /tabs to list"

  it "an unparseable /slash shape emits the parse-error note" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    handleInbound (f_deps f) convA "/12"     -- multi-char index: malformed
    lastEmit f `shouldReturn`
      "could not parse that — /tabs to list, /help for commands"

  it "high slots render as letters (/a) across switch, close and listing" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    -- Fill 11 tabs so slot 10 exists and renders as 'a'.
    mapM_ (\n -> appendSession f ("s" <> tshowI n) ("t" <> tshowI n)) [0 .. 10 :: Int]
    handleInbound (f_deps f) convA "/a"            -- switch to slot 10
    cursorSlot f convA `shouldReturn` Just 10
    lastEmit f `shouldReturn` "switched to /a"
    -- /tabs renders the slot-10 row with an 'a' coordinate
    handleInbound (f_deps f) convA "/tabs"
    out <- lastEmit f
    out `shouldSatisfy` T.isInfixOf "/a  t10"
    -- close it by its letter coordinate
    handleInbound (f_deps f) convA "/close a"
    lastEmit f `shouldReturn` "closed /a"

  it "wizard Done on a session pick reopens that session" $ do
    f <- mkFakes (MintsRef (sess "x"))
            [] [(SessionId "past", "vault work")] (const True)
    handleInbound (f_deps f) convA "/tab"
    handleInbound (f_deps f) convA "1"            -- pick the only candidate (a session)
    tl <- readTabs (f_reg f)
    map _tab_ref (toList tl) `shouldBe` [BoundSession (SessionId "past")]
    map _tab_name (toList tl) `shouldBe` ["session"]
    ensured f `shouldReturn` [BoundSession (SessionId "past")]
    lastEmit f `shouldReturn` "attached /0"

  it "a closed tab's cursor on another conversation is cleared by compaction" $ do
    -- convA and convB both focus slot 0; convB closes it. The removed ref's
    -- cursor is dropped for every conversation that pointed at it (I3), so
    -- convA's next default text falls back to the empty-cursor hint.
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"
    handleInbound (f_deps f) convB "/0"
    handleInbound (f_deps f) convB "/close"        -- removes slot 0
    cursorSlot f convA `shouldReturn` Nothing
    handleInbound (f_deps f) convA "stranded"
    lastEmit f `shouldReturn` "no active tab — /new to start one or /tab to attach"
    sentTexts f `shouldReturn` []

-- ---------------------------------------------------------------------------
-- _td_onTabsChanged notify seam
-- ---------------------------------------------------------------------------

onTabsChangedSpec :: Spec
onTabsChangedSpec = describe "_td_onTabsChanged" $ do
  it "fires once on /nt" $ do
    f <- simpleFakes (MintsRef (sess "s1"))
    handleInbound (f_deps f) convA "/nt"
    readIORef (f_tabsChanged f) `shouldReturn` 1

  it "fires once on /close" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/0"   -- focus (cursor switch, not a mutation)
    handleInbound (f_deps f) convA "/close"
    readIORef (f_tabsChanged f) `shouldReturn` 1

  it "does NOT fire on a non-mutating command (/tabs)" $ do
    f <- simpleFakes (MintsRef (sess "x"))
    _ <- appendSession f "s0" "a"
    handleInbound (f_deps f) convA "/tabs"
    readIORef (f_tabsChanged f) `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Render a 'HarnessId' the way the engine-level wizard menu shows it (the
-- raw 'Show' of the id), for substring assertions.
renderHarnessId :: HarnessId -> Text
renderHarnessId = T.pack . show

tshowI :: Int -> Text
tshowI = T.pack . show
