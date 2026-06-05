-- |
-- Module      : PureClaw.Routing.AutoSpawn
-- Description : Auto-spawn UX, close, resume, rename, crashed handling
--               (Tabbed Chat WU9, A\/L\/X\/B\/S6\/S10 series).
--
-- The user-visible UX surface for tab creation, close, resume, rename,
-- and crashed-tab handling. The dispatcher (WU5) routes parsed slash
-- commands here; this module owns the @\/N@ switch UX (A-series), the
-- close lifecycle on top of the per-kind factory '_tabHandle_close'
-- (L-series), the crashed-tab retry prompt (X-series), and the rename
-- handler (S10).
--
-- == @\/N@ switch UX (A-series, tmux-style packing model)
--
-- 'handleSwitch' implements the simple truth table:
--
--   * tab present → focus + recap (and Crashed observation, X1).
--   * tab missing → emit an error banner; do NOT auto-spawn.
--
-- The previous "auto-spawn on missing /N" behaviour was retired in
-- favour of the tmux packing model: tabs always occupy the lowest
-- slots @\/0..K-1@, so @\/N@ with @N >= K@ is always user error.
--
-- == 'handleDefault' first-run UX (K3)
--
-- The first-run case (no tab focused, registry empty) still
-- implicit-spawns '_rc_defaultKind' at index 0 and forwards the typed
-- text. This is what makes a brand-new user with no tabs able to just
-- type a message and start talking — the K3 first-run path is the only
-- surviving implicit-spawn surface after the tmux packing refactor.
--
-- == @\/tab new@ — always-lowest allocation
--
-- @\/tab new@ no longer accepts a user-supplied index: spawns always
-- land at the lowest free slot via 'Registry.lowestFreeIndex'. The
-- no-kind variant force-prompts the user; the with-kind variant spawns
-- directly.
--
-- == Max-tab cap (S6)
--
-- Every spawn path consults '_rc_maxTabs' BEFORE calling the factory;
-- exceeding the cap surfaces 'TabLimitExceeded' as a dispatcher
-- 'PublicError'. The cap check lives in the dispatcher's 'spawnTabWith'
-- helper (WU5) so AutoSpawn does not duplicate the bookkeeping; we
-- merely surface the redacted error to the user.
--
-- == Crashed UX (X-series)
--
-- Original spawn args are retained per-tab in a @Map Int SpawnArgs@
-- carried by the dispatcher's 'DispatcherState' so the X2\/X3 retry
-- path can replay the exact original args (per design OQ-6: original
-- args, not current defaults).
--
-- See @docs\/tabbed-chat.md@ §"Auto-spawn behavior (A-series)",
-- §"Lifecycle \/ close (L-series)", §"Crashed tab UX (X-series)",
-- §"Dashboard (B-series)", and §"Security (S-series)" S6 \/ S10.
module PureClaw.Routing.AutoSpawn
  ( -- * Spawn-args record (retained per-tab for X2\/X3 retry)
    SpawnArgs (..)
    -- * Banner-emit + spawn-IO injection types
  , BannerEmit
  , SpawnIO
  , RenumberCallback
    -- * Entry points (called by Dispatcher)
  , handleSwitch
  , handleDefault
  , handleNew
  , handleBg
  , handleClose
  , handleFocus
  , handleRename
  , handleResume
  , handleListTabs
    -- * Helpers exported for testing
  , tabKindArgToKind
  , kindKeyword
  , splitArgs
  , recapText
  , rememberArgsForTest
  , missingTabBanner
  , shiftMapKeysAfter
  ) where

import Control.Exception (SomeException, try)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (TabKindArg (..))
import PureClaw.Core.Types (ModelId (..), ProviderId (..), SessionId (..))
import PureClaw.Handles.Tab
  ( CloseMode (..)
  , NameError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabStatus (..)
  , mkTabIndex
  , toPublicTabError
  , unPublicTabError
  , unTabIndex
  , unTabName
  )
import PureClaw.Session.Kind
  ( HarnessFlavour (..)
  , HarnessSpec (..)
  , ProviderSpec (..)
  , SessionKind (..)
  , SshConfig (..)
  , TerminalBackend (..)
  , TmuxConfig (..)
  )
import PureClaw.Routing.Dashboard (renderDashboard)
import PureClaw.Routing.PromptRenderer (PromptRenderer (..))
import PureClaw.Routing.Registry qualified as Registry
import PureClaw.Routing.Types (RoutingConfig (..))


-- ---------------------------------------------------------------------------
-- SpawnArgs — retained per-tab for X2\/X3 retry
-- ---------------------------------------------------------------------------

-- | The kind + raw argument list originally supplied to a tab's spawn
-- factory. Retained per-tab so the X2\/X3 crashed-tab retry path can
-- replay the exact args (per design OQ-6).
data SpawnArgs = SpawnArgs
  { _sa_kind :: !TabKind
  , _sa_args :: ![Text]
  }
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- Entry-point injection types — minimised to avoid an import cycle
-- ---------------------------------------------------------------------------

-- | Production-side spawn function injected by the dispatcher into
-- AutoSpawn at call time. Mirrors the dispatcher's @spawnTab@ shape
-- without introducing an import cycle (Dispatcher imports AutoSpawn,
-- not the other way round).
type SpawnIO =
     TabKind
  -> [Text]
  -> IO (Either TabError TabIndex)

-- | Banner emitter — wraps the dispatcher's @emitDispatcherBanner@ so
-- AutoSpawn does not need to import 'Routing.Dispatcher' (which would
-- create a cycle).
type BannerEmit = Text -> IO ()


-- ---------------------------------------------------------------------------
-- handleSwitch — /N (tmux packing model)
-- ---------------------------------------------------------------------------

-- | Handle @\/N@ (Switch). Truth table (tmux packing model):
--
-- * tab present → focus, emit recap, observe Crashed status (X1).
-- * tab missing → emit an error banner ('missingTabBanner'); no
--   auto-spawn.
--
-- The previous "auto-spawn on missing /N" behaviour was retired with
-- the tmux packing refactor: because tabs are always packed in the
-- lowest slots, @\/N@ for any @N@ outside the open range is always
-- user error. The K3 first-run UX (no focus, registry empty, plain
-- text) still implicit-spawns via 'handleDefault'.
handleSwitch
  :: AgentEnv
  -> BannerEmit
  -> TabIndex
  -> IO ()
handleSwitch env emit idx = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Just h  -> focusExisting env emit idx h
    Nothing -> emit (missingTabBanner idx)

-- | Banner emitted when @\/N@ references a tab that does not exist.
--
-- Phrased to nudge the user toward the (always-allocating) @\/tab new@
-- command rather than the old "auto-spawn at the requested index"
-- behaviour, which no longer exists.
missingTabBanner :: TabIndex -> Text
missingTabBanner idx =
  "/" <> tShowIdx idx
    <> ": no such tab — use /tab new to create one"


-- ---------------------------------------------------------------------------
-- handleDefault — Default text input with empty focus (L6 + K3)
-- ---------------------------------------------------------------------------

-- | Handle the case where the channel layer delivered a plain-text
-- 'PureClaw.Routing.Types.Default' input AND '_env_focus' is 'Nothing'
-- (no tab focused).
--
-- L6 \/ K3 specifies: implicitly spawn '_rc_defaultKind' at the lowest
-- free index (typically 0), then enqueue the text on the new tab.
--
-- If the spawn fails (e.g. rate-limit, max-tabs hit), surface the
-- redacted public error via the banner emitter.
handleDefault
  :: AgentEnv
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Text
  -> IO ()
handleDefault env spawnIO emit argsRef text = do
  let rc = _env_routingConfig env
      kind = _rc_defaultKind rc
  r <- spawnIO kind []
  case r of
    Left e ->
      emit ("/0: " <> unPublicTabError (toPublicTabError e))
    Right newIdx -> do
      rememberArgs argsRef newIdx kind []
      writeIORef (_env_focus env) (Just newIdx)
      enqueuePayloadOn env emit newIdx text


-- ---------------------------------------------------------------------------
-- handleBg — /bg <prompt> (issue #52)
-- ---------------------------------------------------------------------------

-- | Handle @\/bg \<prompt\>@: spawn a fresh AI tab that runs the prompt
-- in the background and pushes its final response to the channel on
-- completion (the completion push itself lives in 'PureClaw.Tab.Ai',
-- gated on the tab's '_ats_background' flag — see issue #52 WU2).
--
-- Unlike 'handleDefault' \/ 'handleNew', @\/bg@:
--
--   * uses a FIXED AI 'TabKind' ('TkSession' ('SkProvider'
--     'placeholderProviderSpec')) rather than '_rc_defaultKind' — @\/bg@
--     is AI-prompt semantics by design, and the recorded kind makes the
--     X1 crash-retry path (which respins via the normal factory) replay
--     a valid AI tab; and
--   * deliberately does NOT write '_env_focus' — a background spawn must
--     never steal the user's focus.
--
-- The background flag itself is injected by the dispatcher's bg-aware
-- 'SpawnIO' (see 'PureClaw.Routing.Dispatcher.ratelimitedSpawnBg'); this
-- handler stays decoupled from 'PureClaw.Tab.Ai'.
handleBg
  :: AgentEnv
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Text
  -> IO ()
handleBg env spawnIO emit argsRef prompt = do
  let kind = TkSession (SkProvider placeholderProviderSpec)
  r <- spawnIO kind []
  case r of
    Left e ->
      emit ("/bg: " <> unPublicTabError (toPublicTabError e))
    Right newIdx -> do
      rememberArgs argsRef newIdx kind []
      enqueuePayloadOn env emit newIdx prompt
      emit ("/bg: running in tab /" <> tShowIdx newIdx)


-- ---------------------------------------------------------------------------
-- handleNew — /tab new [<kind> [<args>]]
-- ---------------------------------------------------------------------------

-- | Handle @\/tab new [\<kind\> [\<arg-text\>]]@ (tmux packing model).
--
-- Truth table:
--
-- * @\/tab new@ (no kind)            → force-prompt at the next free
--   slot.
-- * @\/tab new \<kind\> [\<args\>]@  → spawn at the lowest free slot
--   via 'SpawnIO' (the dispatcher's rate-limited factory), focus it,
--   and emit a confirmation banner.
-- * Spawn failure (rate-limit, cap, factory failure, etc.) → redacted
--   'PublicError' banner.
--
-- The previous "user picks the slot" behaviour is gone: new tabs are
-- always allocated at the lowest free index (matches tmux
-- @renumber-windows on@ semantics). The slot for the force-prompt
-- banner is determined by 'Registry.lowestFreeIndex' so the prompt
-- text shows the user where the spawn would land.
handleNew
  :: AgentEnv
  -> PromptRenderer
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Maybe TabKindArg  -- ^ kind keyword, if supplied
  -> Maybe Text        -- ^ arg text, if supplied
  -> IO ()
handleNew env renderer spawnIO emit argsRef mKind mArgs = do
  let rc = _env_routingConfig env
  case mKind of
    Nothing -> do
      -- Force-prompt: surface the index where the spawn would land so
      -- the prompt UX has a target to render. If the cap is full, we
      -- emit a redacted PublicError instead of a prompt for a slot
      -- that doesn't exist.
      mFree <- Registry.lowestFreeIndex (_env_tabs env) (_rc_maxTabs rc)
      case mFree of
        Nothing ->
          emit ("/tab new: "
                <> unPublicTabError
                     (toPublicTabError (TabLimitExceeded (_rc_maxTabs rc))))
        Just idx ->
          emit (_pr_renderSpawnPrompt renderer idx Nothing)
    Just kindArg -> do
      let kind = tabKindArgToKind kindArg
          args = splitArgs mArgs
      r <- spawnIO kind args
      case r of
        Left e ->
          -- We don't have a known target index at this point — the
          -- spawn never assigned one. Emit a generic /tab new banner.
          emit ("/tab new: "
                <> unPublicTabError (toPublicTabError e))
        Right newIdx -> do
          rememberArgs argsRef newIdx kind args
          writeIORef (_env_focus env) (Just newIdx)
          emit ("/" <> tShowIdx newIdx <> ": spawned ("
                <> kindKeyword kind <> ")")


-- ---------------------------------------------------------------------------
-- handleClose — /tab close N [--force] (tmux-style renumber)
-- ---------------------------------------------------------------------------

-- | The post-close renumber callback. The dispatcher passes in a
-- closure that shifts its side-maps (spawn-args, pending-retry, etc.)
-- down by one starting at @closedIdx + 1@. AutoSpawn calls this AFTER
-- it has driven the registry-side renumber so the side maps stay in
-- sync with the registry's view of slot ownership.
type RenumberCallback = Int -> IO ()

-- | Handle @\/tab close N [--force]@ with tmux-style packing.
--
-- Truth table:
--
-- * N missing  → 'TabNotFound' (L5).
-- * N present  → '_tabHandle_close' (graceful or force);
--   remove the registry entry; shift every remaining tab at index
--   @\> N@ down by one (tmux @renumber-windows on@ model); drop the
--   SpawnArgs entry for @N@ then shift remaining SpawnArgs keys;
--   reconcile '_env_focus' (was N → cleared; was \> N → decremented).
--
-- The renumber pass is done under a single 'atomicModifyIORef'' for
-- '_env_tabs' and '_env_runners' so a concurrent reader (the
-- dispatcher is the only writer per E3) always observes a consistent
-- contiguous slot layout. The 'RenumberCallback' lets the caller
-- (Dispatcher) apply the same shift to side maps that AutoSpawn does
-- not own.
--
-- The 'TabHandle._tabHandle_index' field of any remaining handle is
-- /not/ rewritten — it reflects the creation index and is treated as
-- advisory after a renumber. The authoritative current slot is the
-- registry key.
handleClose
  :: AgentEnv
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> RenumberCallback  -- ^ side-map shift (dispatcher passes the
                       --   callback that shifts pendingRetry etc.)
  -> Int               -- ^ requested index
  -> Bool              -- ^ True = --force
  -> IO ()
handleClose env emit argsRef renumber rawIdx force =
  case mkTabIndex rawIdx of
    Nothing  ->
      emit ("/" <> T.pack (show rawIdx) <> ": tab: invalid index")
    Just idx -> do
      removed <- Registry.removeTab (_env_tabs env) idx
      case removed of
        Nothing -> emit ("/" <> tShowIdx idx <> ": "
                          <> unPublicTabError
                               (toPublicTabError (TabNotFound rawIdx)))
        Just h  -> do
          safeIgnore (_tabHandle_close h closeMode)
          -- tmux packing: shift every remaining tab > closedIdx down
          -- by one so the registry stays contiguous starting at 0.
          let closedN = unTabIndex idx
          atomicModifyIORef' (_env_tabs env) $ \m ->
            (Registry.packAfterRemove closedN m, ())
          atomicModifyIORef' (_env_runners env) $ \m ->
            (Registry.packAfterRemove closedN m, ())
          -- Side-map shifts: drop the spawn-args for the closed slot,
          -- then shift remaining keys down. The dispatcher's
          -- 'RenumberCallback' handles its own pending-retry map and
          -- any other dispatcher-owned side state.
          atomicModifyIORef' argsRef $ \m ->
            ( shiftMapKeysAfter closedN (Map.delete closedN m), () )
          renumber closedN
          -- Reconcile focus: closed tab → Nothing; tabs above → -1.
          updateFocusOnClose env idx
          emit ("/" <> tShowIdx idx <> ": closed")
  where
    closeMode = if force then CloseForce else CloseGraceful

-- | After a close (with tmux-style renumber), reconcile '_env_focus':
--
--   * focused tab was the closed one → clear focus (the dispatcher's
--     K3 implicit-spawn path will pick up the next 'Default' input);
--   * focused tab was strictly greater than the closed one →
--     decrement the focus index by one (it just got renumbered);
--   * focused tab was strictly less than the closed one → unchanged.
updateFocusOnClose :: AgentEnv -> TabIndex -> IO ()
updateFocusOnClose env closedIdx = do
  mFocus <- readIORef (_env_focus env)
  case mFocus of
    Nothing -> pure ()
    Just f
      | f == closedIdx ->
          writeIORef (_env_focus env) Nothing
      | unTabIndex f > unTabIndex closedIdx ->
          -- The focused tab was renumbered down by one.
          writeIORef (_env_focus env) (mkTabIndex (unTabIndex f - 1))
      | otherwise -> pure ()

-- | Shift the keys of a 'Data.Map.Strict.Map' (Int-keyed) down by one
-- for every key strictly greater than @k@. Mirrors
-- 'Registry.packAfterRemove' for 'IntMap' but works on the generic
-- 'Map' that the dispatcher uses for spawn-args and pending-retry side
-- state.
shiftMapKeysAfter :: Int -> Map Int v -> Map Int v
shiftMapKeysAfter k = Map.foldlWithKey'
  (\acc i v ->
     if i > k
       then Map.insert (i - 1) v acc
       else Map.insert i v acc)
  Map.empty


-- ---------------------------------------------------------------------------
-- handleFocus — /tab focus N (functional alias of /N)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab focus N@. Functional alias of @\/N@; delegates to
-- 'handleSwitch'.
handleFocus
  :: AgentEnv
  -> BannerEmit
  -> Int     -- ^ requested index
  -> IO ()
handleFocus env emit rawIdx =
  case mkTabIndex rawIdx of
    Nothing  ->
      emit ("/" <> T.pack (show rawIdx) <> ": tab: invalid index")
    Just idx ->
      handleSwitch env emit idx


-- ---------------------------------------------------------------------------
-- handleRename — /tab rename N <name> (S10)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab rename N \<name\>@. The user-supplied name passes
-- through the caller-supplied sanitizer (typically
-- 'PureClaw.Routing.Parse.sanitizeTabName'); on success the new name
-- is announced; on failure a redacted public error is emitted.
--
-- /WU9 scope note:/ rename in v1 is observable-only at the registry
-- level — the new name is reported back to the user; persisting the
-- renamed label requires mutating the 'TabHandle' record (currently
-- sealed). For v1 we surface the rename intent and the sanitization
-- outcome; the in-place name swap lands in a v1.5 refinement that
-- replaces the 'TabHandle' field with a mutable 'IORef TabName'.
handleRename
  :: AgentEnv
  -> BannerEmit
  -> (Text -> Either NameError Text)  -- ^ sanitizer
  -> Int       -- ^ requested index
  -> Text      -- ^ requested new name (raw)
  -> IO ()
handleRename env emit sanitize rawIdx rawName =
  case mkTabIndex rawIdx of
    Nothing  ->
      emit ("/" <> T.pack (show rawIdx) <> ": tab: invalid index")
    Just idx -> do
      mTab <- Registry.lookupTab (_env_tabs env) idx
      case mTab of
        Nothing ->
          emit ("/" <> tShowIdx idx <> ": "
                <> unPublicTabError
                     (toPublicTabError (TabNotFound rawIdx)))
        Just h -> case sanitize rawName of
          Left  nameErr ->
            emit ("/" <> tShowIdx idx <> ": "
                  <> unPublicTabError
                       (toPublicTabError (TabInvalidName nameErr)))
          Right safeName -> do
            let oldName = unTabName (_tabHandle_name h)
                redactedSuffix =
                  if safeName == rawName
                    then ""
                    else " (redacted host/path fragment)"
            emit ("Renamed /" <> tShowIdx idx <> " "
                   <> oldName <> " to \"" <> safeName <> "\""
                   <> redactedSuffix)


-- ---------------------------------------------------------------------------
-- handleResume — /tab resume <session-id> (L7)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab resume \<session-id\>@.
--
-- The parser has already validated the session id via
-- 'PureClaw.Routing.Parse.mkSessionId' (S3 \/ P15a) — the dispatcher
-- only reaches here with a 'SessionId' value the validator accepted.
--
-- /WU9 scope note:/ the full resume-into-a-tab pipeline requires
-- threading 'PureClaw.Session.Handle.resolveSessionRef' and
-- 'PureClaw.Session.Handle.resumeSession' through the spawn factory —
-- work that the WU10 'PureClaw.Agent.Loop' refactor will do properly.
-- For WU9 we emit a redacted-but-actionable banner so the user sees
-- feedback; the production wiring lands when WU10 integrates the
-- Tab.Ai factory with the existing session machinery.
handleResume
  :: AgentEnv
  -> BannerEmit
  -> SessionId
  -> IO ()
handleResume _env emit sid =
  emit ("/tab resume " <> sidText sid
         <> ": resume-into-tab wiring lands in WU10")
  where
    sidText :: SessionId -> Text
    sidText (SessionId t) = t


-- ---------------------------------------------------------------------------
-- handleListTabs — /tab list (B-series)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab list@ (and the @\/tabs@ alias). Renders the
-- dashboard via 'PureClaw.Routing.Dashboard.renderDashboard' and emits
-- the result as a single 'BannerLine'.
handleListTabs :: AgentEnv -> BannerEmit -> IO ()
handleListTabs env emit = do
  body <- renderDashboard env
  emit body


-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | Focus an existing tab + emit the recap and (when applicable) the
-- Crashed banner.
focusExisting :: AgentEnv -> BannerEmit -> TabIndex -> TabHandle -> IO ()
focusExisting env emit idx h = do
  writeIORef (_env_focus env) (Just idx)
  st <- safeStatus h
  case st of
    Just (Crashed pe) ->
      -- X1: surface Crashed status as a one-line PublicError + retry
      -- \/ close prompt.
      emit ("/" <> tShowIdx idx <> " crashed: "
             <> unPublicTabError pe
             <> " — [1] retry [2] close")
    _ -> do
      let recap = recapText (_env_routingConfig env) idx
      emit ("/" <> tShowIdx idx <> ": focused")
      if T.null recap then pure () else emit recap

-- | Construct the (WU9-minimal) recap banner. WU10's
-- 'PureClaw.Agent.Loop' refactor will replace this with a transcript
-- replay; for v1 we surface the per-tab recap budget so the user
-- knows what the budget would have been.
recapText :: RoutingConfig -> TabIndex -> Text
recapText rc idx =
  let n     = _rc_switchRecap rc
      nTxt  = T.pack (show n)
  in if n <= 0
       then ""
       else "(recap: last " <> nTxt <> " messages from /"
              <> tShowIdx idx <> ")"

-- | Enqueue a payload on a tab via '_tabHandle_send', surfacing send
-- failures as a redacted dispatcher banner.
enqueuePayloadOn :: AgentEnv -> BannerEmit -> TabIndex -> Text -> IO ()
enqueuePayloadOn env emit idx payload = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Nothing ->
      emit ("/" <> tShowIdx idx <> ": "
            <> unPublicTabError
                 (toPublicTabError (TabNotFound (unTabIndex idx))))
    Just h -> do
      result <- safeEnqueue h payload
      case result of
        Right ()  -> pure ()
        Left  e   -> emit ("/" <> tShowIdx idx <> ": "
                           <> unPublicTabError (toPublicTabError e))

-- | Tolerant '_tabHandle_send' wrapper: any synchronous exception
-- collapses to a redacted 'TabConcurrencyLimit'.
safeEnqueue :: TabHandle -> Text -> IO (Either TabError ())
safeEnqueue h payload = do
  r <- try @SomeException (_tabHandle_send h payload)
  pure $ case r of
    Left  _e    -> Left (TabConcurrencyLimit 0)
    Right inner -> inner

-- | Read '_tabHandle_status' tolerantly. A buggy factory could throw;
-- in that case we collapse the result to 'Nothing' (treated as
-- "unknown status" — no Crashed banner emitted).
safeStatus :: TabHandle -> IO (Maybe TabStatus)
safeStatus h = do
  r <- try @SomeException (_tabHandle_status h)
  pure $ case r of
    Left _  -> Nothing
    Right s -> Just s

-- | Best-effort: run an IO action and swallow synchronous failures.
safeIgnore :: IO () -> IO ()
safeIgnore m = do
  _ <- try @SomeException m
  pure ()

-- | Convert a parser-level 'TabKindArg' to the canonical 'TabKind'.
--
-- The payload in the resulting 'TabKind' is a /placeholder/ — the real
-- configuration (provider, model, harness flavour, SSH host, etc.) is
-- constructed by the per-kind factory from its spawn-args, not from
-- the 'TabKind' value. The 'TabKind' here is used only for dispatch.
tabKindArgToKind :: TabKindArg -> TabKind
tabKindArgToKind k = case k of
  TkaAi       -> TkSession (SkProvider placeholderProviderSpec)
  TkaProvider -> TkSession (SkProvider placeholderProviderSpec)
  TkaHarness  -> TkSession (SkHarness placeholderHarnessSpec)
  TkaShell    -> TkRawShell TbLocal
  TkaSsh      -> TkRawShell (TbSsh placeholderSshConfig)
  TkaTmux     -> TkRawShell (TbTmux placeholderTmuxConfig)

-- | Project a 'TabKind' to its short keyword (mirrors
-- 'PureClaw.Routing.Config.tabKindCodec').
kindKeyword :: TabKind -> Text
kindKeyword k = case k of
  TkSession (SkProvider _)   -> "ai"
  TkSession (SkHarness _)    -> "harness"
  TkRawShell TbLocal         -> "shell"
  TkRawShell (TbSsh _)       -> "ssh"
  TkRawShell (TbTmux _)      -> "tmux"
  TkRawShell (TbContainer _) -> "container"

-- | Placeholder 'ProviderSpec' used when 'tabKindArgToKind' produces
-- a 'TkSession (SkProvider _)'. The factory ignores this payload;
-- the real provider\/model comes from 'AgentEnv' and spawn-args.
placeholderProviderSpec :: ProviderSpec
placeholderProviderSpec = ProviderSpec
  { _ps_provider = ProviderId "anthropic"
  , _ps_model    = ModelId "placeholder"
  , _ps_agent    = Nothing
  }

-- | Placeholder 'HarnessSpec' used when 'tabKindArgToKind' produces
-- a 'TkSession (SkHarness _)'. The factory ignores this payload.
placeholderHarnessSpec :: HarnessSpec
placeholderHarnessSpec = HarnessSpec
  { _h_flavour   = HClaudeCode
  , _h_backend   = TbLocal
  , _h_cwd       = Nothing
  , _h_args      = []
  , _h_harnessId = Nothing
  , _h_claudeSessionUuid = Nothing
  , _h_canonicalCwd      = Nothing
  }

-- | Placeholder 'SshConfig' used when 'tabKindArgToKind' produces
-- 'TkRawShell (TbSsh _)'. The factory ignores this payload.
placeholderSshConfig :: SshConfig
placeholderSshConfig = SshConfig
  { _sc_user = "placeholder"
  , _sc_host = "placeholder"
  , _sc_port = Nothing
  }

-- | Placeholder 'TmuxConfig' used when 'tabKindArgToKind' produces
-- 'TkRawShell (TbTmux _)'. The factory ignores this payload.
placeholderTmuxConfig :: TmuxConfig
placeholderTmuxConfig = TmuxConfig
  { _tc_session = "placeholder"
  , _tc_window  = "placeholder"
  , _tc_pane    = Nothing
  }

-- | Split the @[args-text]@ field (a single 'Text' parsed greedily
-- after the kind keyword) into a list of arguments by whitespace.
splitArgs :: Maybe Text -> [Text]
splitArgs Nothing  = []
splitArgs (Just t) = T.words t

-- | Format a 'TabIndex' as the user-facing decimal string.
tShowIdx :: TabIndex -> Text
tShowIdx = T.pack . show . unTabIndex

-- | Record the spawn args for a given tab so X2\/X3 retry can replay.
rememberArgs :: IORef (Map Int SpawnArgs) -> TabIndex -> TabKind -> [Text] -> IO ()
rememberArgs ref idx kind args =
  modifyIORef' ref
    (Map.insert (unTabIndex idx) SpawnArgs { _sa_kind = kind, _sa_args = args })

-- | Public alias of 'rememberArgs' exposed for tests that want to seed
-- a spawn-args map without going through the full dispatchOne path.
-- Production code should never call this directly; the public
-- 'handleNew' \/ 'handleDefault' paths invoke 'rememberArgs' internally
-- on every successful spawn.
rememberArgsForTest :: IORef (Map Int SpawnArgs) -> TabIndex -> TabKind -> [Text] -> IO ()
rememberArgsForTest = rememberArgs
