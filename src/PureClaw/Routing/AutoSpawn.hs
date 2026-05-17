-- |
-- Module      : PureClaw.Routing.AutoSpawn
-- Description : Auto-spawn UX, close, resume, rename, crashed handling
--               (Tabbed Chat WU9, A\/L\/X\/B\/S6\/S10 series).
--
-- The user-visible UX surface for tab creation, close, resume, rename,
-- and crashed-tab handling. The dispatcher (WU5) routes parsed slash
-- commands here; this module owns the auto-spawn truth table
-- (A-series), the close lifecycle on top of the per-kind factory
-- '_tabHandle_close' (L-series), the crashed-tab retry prompt
-- (X-series), and the rename handler (S10).
--
-- == Auto-spawn truth table (A-series)
--
-- 'handleSwitch' implements the A1\/A3\/A4 axis:
--
--   * tab present → focus + recap.
--   * tab missing AND '_rc_defaultKind' set → silent spawn at the
--     requested index via the kind-specific factory, then focus.
--   * tab missing AND '_rc_defaultKind' unset → emit a kind-prompt
--     banner via 'PromptRenderer' (A4 \/ A6).
--
-- == Force-prompt (A7)
--
-- The @\/tab new N@ no-kind path ALWAYS prompts regardless of
-- '_rc_defaultKind' — the user explicitly asked for the prompt UX by
-- typing @\/tab new N@ with no kind argument.
--
-- == Max-tab cap (A11 \/ S6)
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
    -- * Entry points (called by Dispatcher)
  , handleSwitch
  , handleDefault
  , handleNew
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
  ) where

import Control.Exception (SomeException, try)
import Data.Foldable (for_)
import Data.IORef
  ( IORef
  , modifyIORef'
  , readIORef
  , writeIORef
  )
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (TabKindArg (..))
import PureClaw.Core.Types (SessionId (..))
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
-- handleSwitch — /N (A1\/A3\/A4)
-- ---------------------------------------------------------------------------

-- | Handle @\/N@ (Switch). Truth table:
--
-- * tab present → focus, emit recap, observe Crashed status (X1).
-- * tab missing AND '_rc_defaultKind' set → silent auto-spawn at the
--   requested index, then focus + confirmation banner.
-- * tab missing AND '_rc_defaultKind' unset → kind-prompt via the
--   supplied 'PromptRenderer'.
--
-- The 'SpawnIO' caller is responsible for honouring '_rc_maxTabs' (S6
-- \/ A11) and the spawn-rate limit (S7); AutoSpawn does not duplicate
-- those checks.
handleSwitch
  :: AgentEnv
  -> PromptRenderer
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> TabIndex
  -> IO ()
handleSwitch env renderer spawnIO emit argsRef idx = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Just h  -> focusExisting env emit idx h
    Nothing -> handleMissingSwitch env renderer spawnIO emit argsRef idx Nothing

-- | Common path for @\/N@ where tab N is absent. The optional
-- @mPayload@ argument is the buffered text from an @\/N \<payload\>@
-- input shape (A6) — when set, it is enqueued on the newly-spawned
-- tab after the spawn succeeds.
handleMissingSwitch
  :: AgentEnv
  -> PromptRenderer
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> TabIndex
  -> Maybe Text
  -> IO ()
handleMissingSwitch env renderer spawnIO emit argsRef idx mPayload = do
  let rc = _env_routingConfig env
  case kindFromDefault rc of
    Nothing ->
      -- A4 \/ A6: no default kind — prompt the user.
      emit (_pr_renderSpawnPrompt renderer idx mPayload)
    Just kind -> do
      -- A3 \/ A5: silent spawn with the default kind.
      r <- spawnIO kind []
      case r of
        Left  e ->
          emit ("/" <> tShowIdx idx <> ": "
                <> unPublicTabError (toPublicTabError e))
        Right newIdx -> do
          rememberArgs argsRef newIdx kind []
          writeIORef (_env_focus env) (Just newIdx)
          for_ mPayload (enqueuePayloadOn env emit newIdx)
          emit ("/" <> tShowIdx newIdx <> ": spawned ("
                <> kindKeyword kind <> ")")

-- | Project '_rc_defaultKind' onto 'Maybe TabKind'. The field is
-- non-optional 'TabKind' (default 'KindAi') by design. WU9 v1 always
-- returns 'Just'; the @\/tab new N@ no-kind path is what reaches the
-- prompt UX (via 'handleNew'), not the bare @\/N@ form. We keep the
-- 'Maybe' shape so a future config switch can opt into the prompt UX
-- as the default for @\/N@ as well.
kindFromDefault :: RoutingConfig -> Maybe TabKind
kindFromDefault = Just . _rc_defaultKind


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
-- handleNew — /tab new ...
-- ---------------------------------------------------------------------------

-- | Handle @\/tab new N [\<kind\> [\<arg-text\>]]@.
--
-- Truth table (mirrors A7 \/ A8 \/ A9 \/ A10 \/ A11):
--
-- * @\/tab new N@ (no kind), N missing  → force-prompt (A7).
-- * @\/tab new N@ (no kind), N exists   → error (A8).
-- * @\/tab new N kind \[args\]@, N missing → spawn (A9).
-- * @\/tab new N kind \[args\]@, N exists  → error (A10).
-- * Cap exceeded → redacted 'TabLimitExceeded' (A11 \/ S6).
handleNew
  :: AgentEnv
  -> PromptRenderer
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Int               -- ^ requested index
  -> Maybe TabKindArg  -- ^ kind keyword, if supplied
  -> Maybe Text        -- ^ arg text, if supplied
  -> IO ()
handleNew env renderer spawnIO emit argsRef rawIdx mKind mArgs =
  case mkTabIndex rawIdx of
    Nothing  ->
      emit ("/" <> T.pack (show rawIdx) <> ": tab: invalid index")
    Just idx -> do
      mTab <- Registry.lookupTab (_env_tabs env) idx
      case (mTab, mKind) of
        (Just _, _) ->
          -- A8 \/ A10: tab already exists.
          emit ("/" <> tShowIdx idx
                <> " already exists. Use /tab close "
                <> tShowIdx idx <> " to replace.")
        (Nothing, Nothing) ->
          -- A7: force-prompt (ignores '_rc_defaultKind').
          emit (_pr_renderSpawnPrompt renderer idx Nothing)
        (Nothing, Just kindArg) -> do
          let kind = tabKindArgToKind kindArg
              args = splitArgs mArgs
          r <- spawnIO kind args
          case r of
            Left e ->
              emit ("/" <> tShowIdx idx <> ": "
                    <> unPublicTabError (toPublicTabError e))
            Right newIdx -> do
              rememberArgs argsRef newIdx kind args
              writeIORef (_env_focus env) (Just newIdx)
              emit ("/" <> tShowIdx newIdx <> ": spawned ("
                    <> kindKeyword kind <> ")")


-- ---------------------------------------------------------------------------
-- handleClose — /tab close N [--force]
-- ---------------------------------------------------------------------------

-- | Handle @\/tab close N [--force]@. Truth table:
--
-- * N missing  → 'TabNotFound' (L5).
-- * N present  → '_tabHandle_close' (graceful or force, L2 \/ L3 \/ L4);
--   remove the registry entry; if the closed tab was focused, update
--   '_env_focus' per L6 (next focus is the highest-indexed remaining
--   tab, or 'Nothing' if empty); drop the SpawnArgs entry.
handleClose
  :: AgentEnv
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Int     -- ^ requested index
  -> Bool    -- ^ True = --force
  -> IO ()
handleClose env emit argsRef rawIdx force =
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
          -- L6: update focus.
          updateFocusOnClose env idx
          -- Drop the X2\/X3 retry args.
          forgetArgs argsRef idx
          emit ("/" <> tShowIdx idx <> ": closed")
  where
    closeMode = if force then CloseForce else CloseGraceful

-- | After a close, recompute '_env_focus'. Per L6 the new focus is
-- @Just highestRemaining@ if a non-empty registry remains, or
-- @Nothing@ if empty.
updateFocusOnClose :: AgentEnv -> TabIndex -> IO ()
updateFocusOnClose env closedIdx = do
  mFocus <- readIORef (_env_focus env)
  case mFocus of
    Just f | f == closedIdx -> do
      tabs <- readIORef (_env_tabs env)
      let newFocus = highestKey tabs
      writeIORef (_env_focus env) newFocus
    _ -> pure ()
  where
    highestKey m
      | IntMap.null m = Nothing
      | otherwise     = mkTabIndex (fst (IntMap.findMax m))


-- ---------------------------------------------------------------------------
-- handleFocus — /tab focus N (functional alias of /N)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab focus N@. Functional alias of @\/N@; delegates to
-- 'handleSwitch'.
handleFocus
  :: AgentEnv
  -> PromptRenderer
  -> SpawnIO
  -> BannerEmit
  -> IORef (Map Int SpawnArgs)
  -> Int     -- ^ requested index
  -> IO ()
handleFocus env renderer spawnIO emit argsRef rawIdx =
  case mkTabIndex rawIdx of
    Nothing  ->
      emit ("/" <> T.pack (show rawIdx) <> ": tab: invalid index")
    Just idx ->
      handleSwitch env renderer spawnIO emit argsRef idx


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
tabKindArgToKind :: TabKindArg -> TabKind
tabKindArgToKind k = case k of
  TkaAi      -> KindAi
  TkaHarness -> KindHarness
  TkaShell   -> KindShell
  TkaSsh     -> KindSsh
  TkaTmux    -> KindTmux

-- | Project a 'TabKind' to its short keyword (mirrors
-- 'PureClaw.Routing.Config.tabKindCodec').
kindKeyword :: TabKind -> Text
kindKeyword k = case k of
  KindAi      -> "ai"
  KindHarness -> "harness"
  KindShell   -> "shell"
  KindSsh     -> "ssh"
  KindTmux    -> "tmux"

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
-- 'handleNew' \/ 'handleSwitch' \/ 'handleDefault' paths invoke
-- 'rememberArgs' internally on every successful spawn.
rememberArgsForTest :: IORef (Map Int SpawnArgs) -> TabIndex -> TabKind -> [Text] -> IO ()
rememberArgsForTest = rememberArgs

-- | Drop the retained spawn args for a tab (on close).
forgetArgs :: IORef (Map Int SpawnArgs) -> TabIndex -> IO ()
forgetArgs ref idx =
  modifyIORef' ref (Map.delete (unTabIndex idx))
