-- |
-- Module      : PureClaw.Routing.Dispatcher
-- Description : The single-threaded routing dispatcher (Tabbed Chat WU5).
--
-- The dispatcher is the one thread that reads from the
-- 'PureClaw.Handles.Channel.ChannelHandle' on the user's side. It
-- classifies every incoming message via 'PureClaw.Routing.Parse.parseInput'
-- and routes it to one of:
--
--   * 'PureClaw.Routing.Types.Switch'         — set '_env_focus' to the named tab
--   * 'PureClaw.Routing.Types.Inject'         — enqueue payload on the named tab's input queue
--   * 'PureClaw.Routing.Types.Default'        — enqueue text on the currently focused tab
--   * 'PureClaw.Routing.Types.ParsedSlashCmd' — handle the slash command (delegated to a hook in WU9\/WU10)
--
-- Per E3 the dispatcher is the only writer of '_env_focus' and runs
-- every routing handler synchronously on its own thread — so there is
-- no TOCTOU between read and write of focused-tab projections.
--
-- == Bootstrapping & cleanup (C4)
--
-- 'runDispatcher' is wrapped in @bracket (newIORef IntMap.empty) cancelAll dispatcherBody@.
-- @cancelAll@ walks '_env_runners' (an @IntMap (IORef (Maybe TabRunner))@,
-- the double-IORef registered by 'spawnTab' BEFORE the fork) and calls
-- '_trun_cancel' on every filled slot. The 'PureClaw.Routing.ChannelOut'
-- writer thread is owned by the same bracket and is cancelled on exit.
--
-- == Async exception discipline
--
-- 'spawnTab' runs under @mask@ so the registry-insert / fork / fill
-- sequence is atomic with respect to async exceptions. 'forkIO' is
-- FORBIDDEN in this module (and downstream tab-related modules): every
-- new thread MUST go through '_env_fork'.
--
-- == Security gates wired here
--
--   * S5 — Crashed tab status is observed by the dispatcher and surfaced
--     to the channel via 'toPublicTabError' (never raw 'TabError' Show).
--   * S7 — per-user spawn-rate token-bucket; exceeding yields a
--     'PublicError' and no spawn.
--   * S8 — the dispatcher reads from '_ch_receive' only; channel-layer
--     allowlist gating is canonical (Signal\/Telegram\/CLI). This module
--     never bypasses the channel.
--
-- == LLM-free invariant (P18)
--
-- Switch \/ Inject \/ ParsedSlashCmd routing NEVER reaches the provider.
-- Only 'PureClaw.Routing.Types.Default' inputs are forwarded to the
-- focused tab's input queue (which may forward to the provider in the
-- AI tab loop case landing in WU6).
--
-- See @docs\/tabbed-chat.md@ §"Dispatcher and Concurrency Model".
module PureClaw.Routing.Dispatcher
  ( -- * Main entry
    runDispatcher
  , runDispatcherWith
    -- * Spawning
  , TabFactory
  , defaultTabFactory
  , spawnTab
  , spawnTabWith
    -- * Cleanup
  , closeAllTabs
    -- * Rate limit (S7)
  , RateLimiter
  , newRateLimiter
  , tryConsumeSpawnToken
    -- * Single-step dispatch (test seam)
  , DispatcherState (..)
  , newDispatcherState
  , dispatchOne
  , dispatchOneWith
    -- * Crash redaction emit (S5)
  , emitCrashedRedacted
    -- * Banner emit (exposed for AutoSpawn handlers)
  , emitDispatcherBanner
    -- * Internal — exposed for tests
  , parseArgsForKind
  ) where

import Control.Concurrent.STM (atomically, writeTBQueue)
import Control.Exception (SomeException, bracket, mask, mask_, onException, try)
import Control.Monad (when)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( NominalDiffTime
  , UTCTime
  , diffUTCTime
  , getCurrentTime
  )
import Data.Foldable (for_)

import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
  ( ForceMode (..)
  , SlashCommand (..)
  , TabSlashCommand (..)
  , getSessionsDir
  )
import PureClaw.Core.Types (ModelId (..), ProviderId (..), SessionId (..), UserId, unSessionId)
import PureClaw.Session.Handle qualified as Session
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Handles.Tab
  ( AiSpawnArgs (..)
  , BackendSpawnArgs (..)
  , CloseMode (..)
  , HarnessSpawnArgs (..)
  , PublicTabError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabRunner (..)
  , TabStatus (..)
  , toPublicTabError
  , unTabIndex
  )
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Session.Kind
  ( ProviderSpec (..)
  , SessionKind (..)
  , TerminalBackend (..)
  )
import PureClaw.Routing.AutoSpawn qualified as AutoSpawn
import PureClaw.Routing.ChannelOut qualified as ChannelOut
import PureClaw.Routing.Onboarding qualified as Onboarding
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.PromptRenderer qualified as Prompt
import PureClaw.Routing.Registry qualified as Registry
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , ParsedInput (..)
  , RoutingConfig (..)
  )
import PureClaw.Tab.Ai qualified as TabAi
import PureClaw.Tab.Backend qualified as TabBackend
import PureClaw.Tab.Harness qualified as TabHarness


-- ---------------------------------------------------------------------------
-- TabFactory test seam
-- ---------------------------------------------------------------------------

-- | Pluggable factory used by 'spawnTabWith'. The default
-- ('defaultTabFactory') dispatches to 'Tab.mkTabAi' \/ 'Tab.mkTabHarness'
-- \/ 'Tab.mkTabBackend' on the supplied 'TabKind'. Tests inject a
-- synthetic factory so they can assert dispatcher behaviour without
-- exercising the (WU6\/WU7\/WU8) factory bodies.
type TabFactory = TabKind -> TabIndex -> [Text] -> IO (Either TabError TabHandle)

-- | The production factory: dispatches by 'TabKind' to the relevant
-- WU6\/WU7\/WU8 factory. Argument parsing for AI \/ Harness \/ Backend
-- spawn arg blobs is shared with 'parseArgsForKind' so the per-kind
-- projection is covered by 'parseArgsForKind' tests alone.
--
-- /WU9 update:/ the body now dispatches to the real
-- 'PureClaw.Tab.Ai.mkTabAi' \/ 'PureClaw.Tab.Harness.mkTabHarness' \/
-- 'PureClaw.Tab.Backend.mkTabBackend' factories — each of which takes
-- an 'AgentEnv' as an additional argument. 'defaultTabFactory' is now
-- a function of 'AgentEnv' that returns a 'TabFactory'; the original
-- 2-arg 'Tab.mkTabAi' stub bodies are kept in 'Handles.Tab' for the
-- H2 type-shape pin but are no longer called from production paths.
defaultTabFactory :: AgentEnv -> TabFactory
defaultTabFactory env kind idx args =
  case parseArgsForKind kind args of
    Left ai             -> TabAi.mkTabAi env idx ai
    Right (Left harn)   -> TabHarness.mkTabHarness env idx harn
    Right (Right back)  -> case kind of
      TkRawShell tb -> TabBackend.mkRawShellTab env idx tb (_backend_args back)
      _             -> TabBackend.mkRawShellTab env idx TbLocal (_backend_args back)

-- | Pure helper that surfaces how 'defaultTabFactory' projects its
-- @[Text]@ arg list onto each per-kind spawn-args record. Exposed for
-- tests; the production 'defaultTabFactory' delegates through this so
-- the args-construction surface is covered without exercising the
-- (WU1-stubbed) factory bottoms.
parseArgsForKind :: TabKind -> [Text] -> Either AiSpawnArgs (Either HarnessSpawnArgs BackendSpawnArgs)
parseArgsForKind kind xs = case kind of
  TkSession (SkProvider _) -> Left  AiSpawnArgs      { _ai_requestedName      = T.unwords xs }
  TkSession (SkHarness _)  -> Right (Left HarnessSpawnArgs { _harness_requestedName = T.unwords xs })
  TkRawShell _             -> Right (Right BackendSpawnArgs
                                { _backend_requestedName = T.unwords xs
                                , _backend_args          = xs
                                })


-- ---------------------------------------------------------------------------
-- Rate limit (S7)
-- ---------------------------------------------------------------------------

-- | Simple per-user token bucket used to defend against close-spawn
-- cycling resource leaks. The bucket holds at most
-- '_rc_spawnRateLimit' tokens; one full bucket refills every minute.
--
-- The representation is intentionally an 'IORef' over a 'Map' rather
-- than 'TVar' — the dispatcher is single-threaded (E3) so STM atomicity
-- is unnecessary, and an 'IORef' keeps the cabal\/test surface small.
data RateLimiter = RateLimiter
  { _rl_buckets :: !(IORef (Map UserId (Double, UTCTime)))
    -- ^ Map from user id to @(tokens, last-refill-time)@. Tokens are
    --   real-valued for fractional refill credit.
  , _rl_capacity :: !Double
    -- ^ Maximum token count (config: '_rc_spawnRateLimit').
  , _rl_refillPerSecond :: !Double
    -- ^ Tokens added per second of elapsed real time. Configured so
    --   one full bucket refills every minute (cap / 60).
  }

-- | Build a fresh rate limiter sized to the supplied
-- '_rc_spawnRateLimit'. The cap doubles as the refill-per-minute, so
-- @cap = 10@ → 10 spawns/minute (≈ one spawn every 6 seconds).
newRateLimiter :: Int -> IO RateLimiter
newRateLimiter cap = do
  ref <- newIORef Map.empty
  let capD = fromIntegral (max 0 cap)
  pure RateLimiter
    { _rl_buckets         = ref
    , _rl_capacity        = capD
    , _rl_refillPerSecond = capD / 60.0
    }

-- | Atomically attempt to consume one spawn token for the given user
-- at the given wall-clock time. Returns 'True' if a token was available
-- (and consumed), 'False' if the bucket was empty.
--
-- An empty 'UserId' (e.g. a fake channel that supplies no sender) is
-- treated as a single global user — every channel layer's allowlist
-- gating is what assigns identity, so the dispatcher does not need to
-- second-guess it.
tryConsumeSpawnToken :: RateLimiter -> UserId -> UTCTime -> IO Bool
tryConsumeSpawnToken rl uid now = atomicModifyIORef' (_rl_buckets rl) $ \m ->
  let (tokens, lastTime) = fromMaybe (_rl_capacity rl, now)
                                     (Map.lookup uid m)
      elapsed :: Double
      elapsed = realToFrac (diffUTCTime now lastTime :: NominalDiffTime)
      refilled = min (_rl_capacity rl)
                     (tokens + elapsed * _rl_refillPerSecond rl)
  in if refilled >= 1.0
       then ( Map.insert uid (refilled - 1.0, now) m
            , True
            )
       else ( Map.insert uid (refilled,        now) m
            , False
            )


-- ---------------------------------------------------------------------------
-- spawnTab
-- ---------------------------------------------------------------------------

-- | Spawn a tab at the lowest free index using the production factory
-- ('defaultTabFactory').
--
-- See 'spawnTabWith' for the parametrised variant used by tests.
spawnTab :: AgentEnv -> TabKind -> [Text] -> IO (Either TabError TabIndex)
spawnTab env = spawnTabWith env (defaultTabFactory env)

-- | Spawn a tab at the lowest free index, dispatching to the supplied
-- factory. Wrapping in 'mask' guarantees atomicity of the
-- @register-placeholder \/ build-handle \/ insert-registry \/ fork \/ fill-placeholder@
-- sequence with respect to async exceptions:
--
-- 1. Allocate a placeholder @IORef Nothing :: IORef (Maybe TabRunner)@.
-- 2. Insert the placeholder into '_env_runners' under mask — from this
--    point 'closeAllTabs' will see the slot even if we're interrupted
--    before the fork.
-- 3. Run the factory (which itself does not need to fork the tab loop —
--    it constructs and returns a 'TabHandle' record; the per-tab loop
--    is forked by THIS function via '_env_fork').
-- 4. Insert the resulting 'TabHandle' into '_env_tabs'.
-- 5. Fork the tab loop via '_env_fork' (NOT 'forkIO') and write the
--    returned 'TabRunner' into the placeholder.
--
-- Note on the v1 design: in WU5 the factory body still bottoms (WU1
-- stub) so the real per-tab loop is not started here. WU6\/7\/8 will
-- fill the factory bodies and the loop will run for real. The mask
-- discipline below is correct for the eventual real-factory case and
-- intentionally generic — we do NOT start a separate per-tab loop here
-- because the factory's '_tabHandle_close' is what drives the tab's
-- own internal threading.
spawnTabWith
  :: AgentEnv
  -> TabFactory
  -> TabKind
  -> [Text]
  -> IO (Either TabError TabIndex)
spawnTabWith env factory kind args =
  -- mask: the register-then-build sequence below cannot be interrupted
  -- mid-flight. If an async exception arrives between insert and fork,
  -- 'closeAllTabs' would otherwise leak the in-flight placeholder.
  -- Using 'mask' here matches the design's §"Async exception discipline".
  mask $ \restore -> do
    let rc = _env_routingConfig env
    mIdx <- Registry.lowestFreeIndex (_env_tabs env) (_rc_maxTabs rc)
    case mIdx of
      Nothing  -> pure (Left (TabLimitExceeded (_rc_maxTabs rc)))
      Just idx -> doSpawn restore idx
  where
    doSpawn restore idx = do
      runnerRef <- newIORef Nothing
      -- Register the placeholder BEFORE running the factory. cancelAll
      -- will see this slot (with a Nothing runner — no-op) for the
      -- interval between the insert below and the writeIORef at the
      -- bottom; that's deliberate per the design.
      modifyIORef' (_env_runners env)
                   (IntMap.insert (unTabIndex idx) runnerRef)
      -- Run the (potentially long) factory inside 'restore' so async
      -- exceptions can still arrive at it. On any exception, roll back
      -- the placeholder insert and re-raise.
      mResult <- restore (try @SomeException (factory kind idx args))
                   `onException` rollbackPlaceholder idx
      case mResult of
        Left e        -> rollbackPlaceholder idx >> rethrowOrLeft e
        Right (Left tabErr) -> do
          rollbackPlaceholder idx
          pure (Left tabErr)
        Right (Right th) -> do
          ins <- Registry.insertTab (_env_tabs env) idx th
          case ins of
            Left tabErr -> do
              -- Index race (extremely unlikely under single-threaded
              -- dispatcher invariant E3; still defend so the registry
              -- never gets a double-entry).
              rollbackPlaceholder idx
              pure (Left tabErr)
            Right () ->
              -- The placeholder runner stays 'Nothing' for WU5. The
              -- WU6/7/8 factory bodies will fork the per-tab loop
              -- internally; once they do, the loop's TabRunner can be
              -- written into runnerRef. For WU5 we leave it as
              -- Nothing so cancelAll is a safe no-op for tabs whose
              -- loops were never started.
              pure (Right idx)

    rollbackPlaceholder idx =
      modifyIORef' (_env_runners env)
                   (IntMap.delete (unTabIndex idx))

    rethrowOrLeft :: SomeException -> IO (Either TabError TabIndex)
    rethrowOrLeft _e =
      -- For C3, an exception from the factory must NOT leave any
      -- partially-allocated state. The placeholder was already rolled
      -- back; surface the failure as a generic spawn error rather than
      -- re-raising — the dispatcher caller treats Left as a
      -- 'PublicError' and the underlying 'SomeException' message is
      -- intentionally discarded (S5 redaction principle).
      pure (Left (TabSessionCreateFailed Tab.SessionError))


-- ---------------------------------------------------------------------------
-- closeAllTabs
-- ---------------------------------------------------------------------------

-- | Walk '_env_runners' and cancel every started runner. Tolerant of
-- the WU5-era 'Nothing' placeholders (no-op for those).
--
-- This is the bracket cleanup for 'runDispatcher': it fires on BOTH
-- exception AND graceful exit (e.g. '_ch_receive' returning end-of-
-- stream via a thrown exception). The first-pass cancel is fire-and-
-- forget; we then walk the map again to '_trun_wait' on each.
closeAllTabs :: AgentEnv -> IO ()
closeAllTabs env = do
  m <- readIORef (_env_runners env)
  -- First pass: send cancel to every filled runner. We catch and ignore
  -- exceptions from cancel because tab cleanup must never block the
  -- dispatcher's own bracket cleanup.
  for_ (IntMap.elems m) $ \ref -> do
    mr <- readIORef ref
    case mr of
      Nothing      -> pure ()
      Just runner  -> safeIgnore (_trun_cancel runner)
  -- Second pass: also drive '_tabHandle_close CloseGraceful' on every
  -- registered handle, so per-tab resources (transcript, backend
  -- close, harness stop) are released even when the tab loop never
  -- fully started. '_tabHandle_close' is documented idempotent and
  -- never-throws (H6/H7/H8); we additionally ignore exceptions
  -- defensively.
  tabs <- readIORef (_env_tabs env)
  for_ (IntMap.elems tabs) $ \h ->
    safeIgnore (_tabHandle_close h CloseGraceful)

safeIgnore :: IO () -> IO ()
safeIgnore m = do
  _ <- try @SomeException m
  pure ()


-- ---------------------------------------------------------------------------
-- Dispatcher state (test seam)
-- ---------------------------------------------------------------------------

-- | The pieces of per-run state the dispatcher carries across message
-- cycles. Exposed so 'dispatchOne' can be driven from tests without
-- running 'runDispatcher's infinite loop.
--
-- /WU9 additions:/ '_ds_spawnArgs' records the original
-- @(TabKind, [Text])@ pair for each successful spawn so the X2 \/ X3
-- crashed-tab retry path can replay the exact original arguments
-- (per OQ-6). '_ds_promptRenderer' picks the channel-appropriate
-- spawn-prompt rendering (text on CLI \/ Signal, inline-keyboard
-- friendly on Telegram). '_ds_factory' is the per-kind tab factory
-- the dispatcher will dispatch through for all WU9 spawn paths.
--
-- /WU10 addition:/ '_ds_pendingRetry' records per-user
-- @(TabIndex, SpawnArgs)@ for the most-recently emitted X1 retry
-- prompt. A subsequent \"1\" or \"2\" message from the same user is
-- interpreted as a retry-or-close reply (X1 reply parsing — WU9
-- emitted the prompt but did NOT interpret the reply). The map is
-- single-entry-per-user; a new prompt overrides the previous
-- expectation.
data DispatcherState = DispatcherState
  { _ds_rateLimiter    :: !RateLimiter
    -- ^ Per-chat-user spawn token bucket (S7).
  , _ds_spawnArgs      :: !(IORef (Map Int AutoSpawn.SpawnArgs))
    -- ^ Per-tab original spawn args (kind + arg list) for X2 \/ X3
    -- retry.
  , _ds_promptRenderer :: !Prompt.PromptRenderer
    -- ^ Channel-aware spawn-prompt renderer (A4 \/ A6).
  , _ds_factory        :: !TabFactory
    -- ^ The per-kind factory the dispatcher uses for spawning. Defaults
    -- to 'defaultTabFactory env' for production; tests inject a
    -- synthetic factory via 'newDispatcherState'.
  , _ds_pendingRetry   :: !(IORef (Map UserId (TabIndex, AutoSpawn.SpawnArgs)))
    -- ^ Per-user expectation of an X1 retry reply (WU10). Populated
    -- by the focus path when it observes a 'Crashed' tab; cleared on
    -- reply or on any other intervening user input.
  }

-- | Build a fresh 'DispatcherState' from an 'AgentEnv'.
--
-- The factory argument is retained on the record so WU9's AutoSpawn
-- handlers can drive spawns without re-passing the factory at every
-- call site.
newDispatcherState :: AgentEnv -> TabFactory -> IO DispatcherState
newDispatcherState env factory = do
  rl       <- newRateLimiter (_rc_spawnRateLimit (_env_routingConfig env))
  argsRef  <- newIORef Map.empty
  pendRef  <- newIORef Map.empty
  let renderer = Prompt.mkDefaultPromptRenderer (_env_channel env)
  pure DispatcherState
    { _ds_rateLimiter    = rl
    , _ds_spawnArgs      = argsRef
    , _ds_promptRenderer = renderer
    , _ds_factory        = factory
    , _ds_pendingRetry   = pendRef
    }


-- ---------------------------------------------------------------------------
-- dispatchOne — process a single parsed input
-- ---------------------------------------------------------------------------

-- | Process exactly one incoming message:
--
-- 1. Parse with 'Parse.parseInput'. On 'Left' emit a 'PublicError' to
--    the channel-out queue via 'SrcDispatcher' (no handler invocation,
--    no provider call — P18 preserved).
-- 2. On 'Switch': set '_env_focus'.
-- 3. On 'Inject': enqueue the payload onto tab N's input queue via
--    '_tabHandle_send'.
-- 4. On 'Default': forward to the currently focused tab's input queue
--    (or no-op if no focus — auto-spawn UX lives in WU9).
-- 5. On 'ParsedSlashCmd': for /tab* commands the dispatcher handles
--    spawn\/close\/focus\/etc inline (WU9 will extend); other slash
--    commands are deferred to the focused tab's enqueueSlash (E5\/I5).
--
-- The function is intentionally pure-ish (only IO side effects), so
-- tests can drive it one message at a time with deterministic
-- timestamps.
dispatchOne :: AgentEnv -> DispatcherState -> UserId -> Text -> IO ()
dispatchOne = dispatchOneWith

-- | Like 'dispatchOne' but explicitly named for the test-seam variant
-- — at present they are identical (the 'DispatcherState' record
-- carries every per-run knob WU9 needs); kept as a distinct symbol so
-- future WUs can introduce an even-thinner test-only variant without
-- breaking the public 'dispatchOne' contract.
dispatchOneWith :: AgentEnv -> DispatcherState -> UserId -> Text -> IO ()
dispatchOneWith env ds uid raw = do
  -- WU10 — X1 retry-reply intercept: a bare "1" or "2" from a user with
  -- a pending crashed-tab retry expectation is interpreted as a
  -- retry/close reply. Any other input clears the pending expectation
  -- (so a follow-up retry must be initiated by re-focusing the tab).
  pendingHit <- tryRetryReply env ds uid raw
  if pendingHit
    then pure ()
    else doDispatchOne env ds uid raw

-- | Main dispatch body, factored out so the X1 retry-reply intercept
-- in 'dispatchOneWith' can short-circuit without nesting.
doDispatchOne :: AgentEnv -> DispatcherState -> UserId -> Text -> IO ()
doDispatchOne env ds uid raw = do
  let rc = _env_routingConfig env
  case Parse.parseInput rc raw of
    Left _err ->
      -- Parser errors carry only bounded primitives; surfacing
      -- TemporaryError "input not recognized" keeps the channel clean
      -- (no constructor leaks).
      emitDispatcherBanner env "input not recognized"

    Right (Switch idx) -> do
      -- tmux packing model: a missing /N is user error (no auto-spawn).
      AutoSpawn.handleSwitch env
        (emitDispatcherBanner env)
        idx
      -- WU10 — X1 expectation capture: if the focused tab is now
      -- Crashed, record the spawn args under the user's pending-retry
      -- map so a subsequent "1"/"2" reply lands somewhere.
      noteCrashedExpectation env ds uid idx

    Right (Inject idx payload) ->
      injectTo env idx payload

    Right (Default text) -> do
      mFocus <- readIORef (_env_focus env)
      case mFocus of
        Nothing  ->
          -- L6 \/ K3: empty focus + Default text → implicit auto-spawn
          -- of '_rc_defaultKind' at the lowest free index, then
          -- forward the text to it.
          AutoSpawn.handleDefault env
            (ratelimitedSpawn env ds uid)
            (emitDispatcherBanner env)
            (_ds_spawnArgs ds)
            text
        Just idx -> injectTo env idx text

    Right (ParsedSlashCmd cmd) ->
      dispatchSlash env ds uid cmd


-- ---------------------------------------------------------------------------
-- X1 retry-reply handling (WU10 fills in the WU9-deferred wiring)
-- ---------------------------------------------------------------------------

-- | Intercept a bare \"1\" or \"2\" reply from a user with a pending
-- retry expectation. Returns 'True' if the input was consumed as a
-- retry reply (and the caller should NOT continue dispatch), 'False'
-- otherwise.
--
-- The pending-retry map is cleared on every non-reply input — sending
-- any other message dismisses the prompt.
tryRetryReply
  :: AgentEnv -> DispatcherState -> UserId -> Text -> IO Bool
tryRetryReply env ds uid raw = do
  let trimmed = T.strip raw
  pending <- readIORef (_ds_pendingRetry ds)
  case Map.lookup uid pending of
    Nothing -> pure False
    Just (idx, sa) -> case trimmed of
      "1" -> do
        clearPendingRetry ds uid
        retryCrashedTab env ds uid idx sa
        pure True
      "2" -> do
        clearPendingRetry ds uid
        closeCrashedTab env idx
        pure True
      _ -> do
        -- Any other input dismisses the prompt — the user moved on.
        clearPendingRetry ds uid
        pure False

-- | Record an X1 retry expectation for the user, if the focused tab
-- is Crashed. No-op for any other status (Active / Idle) so non-crashed
-- focus paths don't leak pending entries.
noteCrashedExpectation
  :: AgentEnv -> DispatcherState -> UserId -> TabIndex -> IO ()
noteCrashedExpectation env ds uid idx = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Nothing -> pure ()
    Just th -> do
      r <- try @SomeException (_tabHandle_status th)
      case r of
        Right (Crashed _) -> do
          argsMap <- readIORef (_ds_spawnArgs ds)
          case Map.lookup (unTabIndex idx) argsMap of
            Just sa ->
              atomicModifyIORef' (_ds_pendingRetry ds)
                (\m -> (Map.insert uid (idx, sa) m, ()))
            Nothing ->
              -- No spawn args recorded — retry would have nothing to
              -- replay. Skip the expectation entry rather than racing
              -- the user into a dead-end "1" reply.
              pure ()
        _ -> pure ()

-- | Retry a crashed tab: close the existing tab handle (idempotent +
-- never-throws) and respawn with the original spawn args (X2 \/ X3).
-- Spawning is rate-limited (S7) as usual.
retryCrashedTab
  :: AgentEnv
  -> DispatcherState
  -> UserId
  -> TabIndex
  -> AutoSpawn.SpawnArgs
  -> IO ()
retryCrashedTab env ds uid idx sa = do
  -- Drive the close on the old (crashed) handle so resources are
  -- released. The handle's _tabHandle_close is documented idempotent.
  mTab <- Registry.lookupTab (_env_tabs env) idx
  for_ mTab $ \th ->
    safeIgnore (_tabHandle_close th CloseGraceful)
  -- Remove the old entry from the registry so spawnTab can re-use
  -- the index.
  _ <- Registry.removeTab (_env_tabs env) idx
  -- Respawn with the original args.
  r <- ratelimitedSpawn env ds uid
         (AutoSpawn._sa_kind sa) (AutoSpawn._sa_args sa)
  case r of
    Left tabErr ->
      emitDispatcherBanner env
        ("/" <> tShowIdx idx <> ": retry failed — "
          <> unPublicTabError (toPublicTabError tabErr))
    Right newIdx -> do
      writeIORef (_env_focus env) (Just newIdx)
      emitDispatcherBanner env
        ("/" <> tShowIdx newIdx <> ": retried")

-- | Close a crashed tab without retrying. The handle's
-- '_tabHandle_close' is invoked (idempotent) and the registry entry
-- is removed so the index is free for re-use.
closeCrashedTab :: AgentEnv -> TabIndex -> IO ()
closeCrashedTab env idx = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  for_ mTab $ \th -> safeIgnore (_tabHandle_close th CloseGraceful)
  _ <- Registry.removeTab (_env_tabs env) idx
  -- If the closed tab was focused, clear focus so the next Default
  -- input either implicit-spawns or routes correctly.
  mFocus <- readIORef (_env_focus env)
  when (mFocus == Just idx) $
    writeIORef (_env_focus env) Nothing
  emitDispatcherBanner env
    ("/" <> tShowIdx idx <> ": closed")

-- | Drop the pending retry entry for the user. Idempotent.
clearPendingRetry :: DispatcherState -> UserId -> IO ()
clearPendingRetry ds uid =
  atomicModifyIORef' (_ds_pendingRetry ds)
    (\m -> (Map.delete uid m, ()))


-- | Spawn a tab via the dispatcher's configured factory, consuming
-- one rate-limit token first (S7). Returns 'Left' with a redacted
-- 'TabError' on either:
--
--   * rate-limit denial → 'TabConcurrencyLimit' (the closest
--     semantically-correct redacted shape — the public projection
--     renders as "tab: input queue full" which is acceptable v1
--     coverage); or
--   * factory failure → propagated as-is from 'spawnTabWith'.
--
-- AutoSpawn handlers consume this as their 'SpawnIO' callback so the
-- spawn-rate limit is enforced uniformly across A-series spawn paths.
ratelimitedSpawn
  :: AgentEnv
  -> DispatcherState
  -> UserId
  -> TabKind
  -> [Text]
  -> IO (Either TabError TabIndex)
ratelimitedSpawn env ds uid kind args = do
  now <- getCurrentTime
  ok  <- tryConsumeSpawnToken (_ds_rateLimiter ds) uid now
  if not ok
    then pure (Left (TabConcurrencyLimit 0))
    else spawnTabWith env (_ds_factory ds) kind args


-- | Dispatch a slash command. The @\/tab*@ family is routed to the
-- AutoSpawn handlers; every other slash command is delivered to the
-- focused AI tab via '_tabHandle_enqueueSlash' (WU10 — I5 wiring).
--
-- The focused-tab projection rules:
--
--   * Focused 'KindAi' tab → enqueue 'SlashCmd' on the tab's input queue;
--     the tab loop runs @executeSlashCommand env cmd ctx@ against its
--     per-tab context (E5 single-writer invariant).
--   * Focused non-AI tab → emit a redacted PublicError
--     (\"@\/N\: tab kind does not support this command@\") and do NOT
--     enqueue. The 'TabUnsupportedCommand' is the canonical surface
--     mirroring K5's @\/target@ pattern.
--   * No focus → fall back to the in-dispatcher legacy executor against
--     an empty 'Context'. This preserves single-tab behaviour for
--     channels that have not yet auto-spawned a tab and is also what
--     drives the empty-registry K3 implicit-spawn path through the
--     normal channel flow.
dispatchSlash
  :: AgentEnv -> DispatcherState -> UserId -> SlashCommand -> IO ()
dispatchSlash env ds uid cmd = case cmd of
  CmdTab tabCmd -> dispatchTab env ds uid tabCmd
  -- Onboarding (O1): handled at the dispatcher layer because the
  -- response is a fixed orientation message — it must not depend on a
  -- focused AI tab (a brand-new user has no tabs yet), and it must
  -- not be enqueued into the focused tab's slash queue (which would
  -- be wrong-channel-of-output for a UX greeting). Delegated to
  -- 'Onboarding.handleStart' which emits via @_ch_send@ directly.
  CmdStart      -> Onboarding.handleStart env
  _             -> routeToFocused env ds uid cmd

-- | Route a non-@\/tab*@ slash command to the focused tab via
-- '_tabHandle_enqueueSlash' (WU10 — I5 wiring).
--
-- Returns immediately without blocking on the tab loop's processing.
-- Per E5, the tab loop is the single writer to its per-tab context.
routeToFocused
  :: AgentEnv -> DispatcherState -> UserId -> SlashCommand -> IO ()
routeToFocused env ds uid cmd = do
  -- Consume one rate-limit token (S7) per slash dispatch — exercises the
  -- same gate the pre-WU10 'ratelimitedSlashAck' walked.
  now <- getCurrentTime
  ok  <- tryConsumeSpawnToken (_ds_rateLimiter ds) uid now
  if not ok
    then emitDispatcherBanner env "rate limit: too many recent spawns"
    else do
      mFocus <- readIORef (_env_focus env)
      case mFocus of
        Nothing  -> emitDispatcherBanner env (noFocusBanner cmd)
        Just idx -> enqueueOnFocused env idx cmd

-- | Look up the focused tab and dispatch the slash command per kind.
-- On 'KindAi' the command is enqueued; on any other kind we surface a
-- redacted PublicError without enqueueing (K5 pattern, generalised).
enqueueOnFocused :: AgentEnv -> TabIndex -> SlashCommand -> IO ()
enqueueOnFocused env idx cmd = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Nothing -> emitDispatcherBanner env
                 ("/" <> tShowIdx idx <> ": no such tab")
    Just th -> case _tabHandle_kind th of
      TkSession (SkProvider _) -> do
        r <- safeEnqueueSlash th cmd
        case r of
          Right () -> pure ()
          Left  e  -> emitDispatcherBanner env
                        ("/" <> tShowIdx idx <> ": "
                         <> unPublicTabError (toPublicTabError e))
      _ ->
        -- Non-AI focused tab: per the K5 generalisation, surface a
        -- redacted PublicError and do NOT enqueue.
        emitDispatcherBanner env
          ("/" <> tShowIdx idx
            <> ": tab kind does not support this command")

-- | Banner shown when a non-@\/tab*@ slash command is received but
-- nothing is focused. The cases are too disparate to render a fully
-- contextual message; we emit a short hint to spawn or focus a tab so
-- the slash command can land somewhere.
noFocusBanner :: SlashCommand -> Text
noFocusBanner _ =
  "no focused tab — focus one with /N or spawn one with /tab new <kind>"

-- | Wrap '_tabHandle_enqueueSlash' so any synchronous exception
-- becomes a redacted 'TabConcurrencyLimit' rather than a dispatcher
-- crash. Mirrors 'safeEnqueue' for the 'UserText' path.
safeEnqueueSlash :: TabHandle -> SlashCommand -> IO (Either TabError ())
safeEnqueueSlash th cmd = do
  r <- try @SomeException (_tabHandle_enqueueSlash th cmd)
  pure $ case r of
    Left  _e   -> Left (TabConcurrencyLimit 0)
    Right inner -> inner


-- ---------------------------------------------------------------------------
-- handleResumeIntoTab — L7 (WU10 fills in the WU9-deferred wiring)
-- ---------------------------------------------------------------------------

-- | Handle @\/tab resume \<id\>@. The parser already validated the
-- 'SessionId' via 'mkSessionId' (P15a). WU10 wires the L7 chain:
--
--   1. 'Session.resolveSessionRef' — resolve the id under
--      @~\/.pureclaw\/sessions@.
--   2. 'Session.resumeSession' — load metadata + open transcript.
--   3. @writeIORef '_env_session'@ — make the resumed session the
--      active one so the spawned tab's factory snapshots it.
--   4. @'spawnTab' env 'KindAi' []@ — create a new KindAi tab via the
--      dispatcher's configured factory (rate-limited per S7).
--
-- On any failure the dispatcher emits a redacted banner and aborts
-- without touching '_env_session' (the previous active session
-- remains).
handleResumeIntoTab
  :: AgentEnv -> DispatcherState -> UserId -> SessionId -> IO ()
handleResumeIntoTab env ds uid sid = do
  sessionsDir <- getSessionsDir
  resolved <- try @SomeException
                (Session.resolveSessionRef sessionsDir (unSessionId sid))
  case resolved of
    Left _e ->
      emitDispatcherBanner env
        ("/tab resume " <> unSessionId sid <> ": resolve failed")
    Right (Left Session.NotFound) ->
      emitDispatcherBanner env
        ("/tab resume " <> unSessionId sid <> ": no such session")
    Right (Left (Session.Ambiguous _matches)) ->
      emitDispatcherBanner env
        ("/tab resume " <> unSessionId sid <> ": ambiguous session id")
    Right (Right realSid) -> do
      handleResolved env ds uid sessionsDir realSid

-- | Common tail of 'handleResumeIntoTab': resume the session, swap it
-- into 'AgentEnv', then spawn a new AI tab. Factored out so the
-- top-level handler stays readable.
handleResolved
  :: AgentEnv
  -> DispatcherState
  -> UserId
  -> FilePath
  -> SessionId
  -> IO ()
handleResolved env ds uid sessionsDir realSid = do
  resumed <- try @SomeException
               (Session.resumeSession (_env_logger env) sessionsDir realSid)
  case resumed of
    Left _e ->
      emitDispatcherBanner env
        ("/tab resume " <> unSessionId realSid <> ": resume failed")
    Right (Left _err) ->
      emitDispatcherBanner env
        ("/tab resume " <> unSessionId realSid <> ": resume failed")
    Right (Right newSession) -> do
      -- L7 design: replace the active session in place so the spawned
      -- tab's factory snapshot picks it up. Prior tabs that already
      -- snapshotted '_env_session' keep their handles (v1 limitation
      -- noted in design's K7 §). The new tab will own the resumed
      -- session.
      writeIORef (_env_session env) newSession
      let resumeKind = TkSession (SkProvider ProviderSpec
                        { _ps_provider = ProviderId "anthropic"
                        , _ps_model    = ModelId "placeholder"
                        , _ps_agent    = Nothing
                        })
      spawnResult <- ratelimitedSpawn env ds uid resumeKind []
      case spawnResult of
        Left tabErr ->
          emitDispatcherBanner env
            ("/tab resume " <> unSessionId realSid <> ": "
              <> unPublicTabError (toPublicTabError tabErr))
        Right newIdx -> do
          -- Set focus to the newly-spawned tab so the user lands on
          -- it immediately.
          writeIORef (_env_focus env) (Just newIdx)
          emitDispatcherBanner env
            ("/tab resume " <> unSessionId realSid <> ": resumed at /"
              <> tShowIdx newIdx)

-- | Dispatch a @\/tab*@ command to the AutoSpawn handlers. Each branch
-- maps a 'TabSlashCommand' constructor to the appropriate handler.
--
-- The @\/tab close N@ branch supplies AutoSpawn with a renumber
-- callback that shifts the dispatcher's side maps ('_ds_pendingRetry'
-- in particular) to match the registry's tmux-style packing.
-- '_ds_spawnArgs' is shifted by AutoSpawn itself since it is passed
-- in directly.
dispatchTab
  :: AgentEnv -> DispatcherState -> UserId -> TabSlashCommand -> IO ()
dispatchTab env ds uid tcmd = case tcmd of
  TabNewCmd mKind mArgs ->
    AutoSpawn.handleNew env
      (_ds_promptRenderer ds)
      (ratelimitedSpawn env ds uid)
      (emitDispatcherBanner env)
      (_ds_spawnArgs ds)
      mKind mArgs

  TabListCmd ->
    AutoSpawn.handleListTabs env (emitDispatcherBanner env)

  TabCloseCmd rawIdx force ->
    AutoSpawn.handleClose env
      (emitDispatcherBanner env)
      (_ds_spawnArgs ds)
      (renumberPendingRetry ds)
      rawIdx
      (force == ForceYes)

  TabFocusCmd rawIdx ->
    AutoSpawn.handleFocus env
      (emitDispatcherBanner env)
      rawIdx

  TabResumeCmd sid ->
    handleResumeIntoTab env ds uid sid

  TabRenameCmd rawIdx newName ->
    AutoSpawn.handleRename env
      (emitDispatcherBanner env)
      Parse.sanitizeTabName
      rawIdx newName

-- | Shift the keys of the per-user pending-retry map so that any
-- pending @(TabIndex, SpawnArgs)@ payload whose tab index was just
-- renumbered down by one stays pointed at the same tab.
--
-- Entries whose @TabIndex@ equals the closed slot are dropped (the
-- referenced tab no longer exists); entries whose index is greater
-- have the index decremented; entries with smaller indices stay put.
renumberPendingRetry :: DispatcherState -> Int -> IO ()
renumberPendingRetry ds closedN =
  atomicModifyIORef' (_ds_pendingRetry ds) $ \m ->
    (Map.mapMaybe (shiftEntry closedN) m, ())
  where
    shiftEntry k (idx, sa) =
      let i = unTabIndex idx
      in if i == k
           then Nothing
           else if i > k
                  then case Tab.mkTabIndex (i - 1) of
                         Just newIdx -> Just (newIdx, sa)
                         Nothing     -> Nothing  -- unreachable: i > k >= 0
                  else Just (idx, sa)


-- | Enqueue text on a specific tab's input queue. Looks up the tab in
-- the registry; emits a dispatcher PublicError if the tab is missing
-- or if its input queue is full ('TabConcurrencyLimit'). Never raises.
injectTo :: AgentEnv -> TabIndex -> Text -> IO ()
injectTo env idx payload = do
  mTab <- Registry.lookupTab (_env_tabs env) idx
  case mTab of
    Nothing  -> emitDispatcherBanner env
                  ("/" <> tShowIdx idx <> ": no such tab")
    Just th  -> do
      result <- safeEnqueue th payload
      case result of
        Right ()  -> pure ()
        Left e    -> emitDispatcherBanner env
                       ("/" <> tShowIdx idx <> ": "
                        <> unPublicTabError (toPublicTabError e))


-- | Wrap '_tabHandle_send' so any synchronous exception becomes a
-- redacted 'TabConcurrencyLimit' rather than a dispatcher crash. The
-- field is documented to return Left on overflow, but defending
-- against a misbehaving non-WU5 implementation is cheap.
safeEnqueue :: TabHandle -> Text -> IO (Either TabError ())
safeEnqueue th payload = do
  r <- try @SomeException (_tabHandle_send th payload)
  pure $ case r of
    Left _e        -> Left (TabConcurrencyLimit 0)
    Right inner    -> inner


-- ---------------------------------------------------------------------------
-- Crash redaction (S5)
-- ---------------------------------------------------------------------------

-- | Emit the S5 crashed-tab banner. The banner text uses the public
-- projection from 'PureClaw.Handles.Tab.toPublicTabError' and contains
-- no raw 'TabError' payload — neither host strings, paths, nor ssh
-- stderr fragments.
--
-- Exposed so tests can directly assert on the redacted wording without
-- driving a full crashed-tab spawn. The WU9 AutoSpawn handler emits
-- the same banner shape (extended with the @\"— [1] retry [2] close\"@
-- prompt suffix) via its own 'focusExisting' helper.
emitCrashedRedacted :: AgentEnv -> TabIndex -> PublicTabError -> IO ()
emitCrashedRedacted env idx (PublicTabError pe) =
  emitDispatcherBanner env
    ("/" <> tShowIdx idx <> " crashed: " <> pe)


-- ---------------------------------------------------------------------------
-- Banner-emit helper
-- ---------------------------------------------------------------------------

-- | Enqueue a single dispatcher-sourced 'BannerLine' onto
-- '_env_channelOutQ'. Uses bounded STM writes; will block if the
-- channel-out queue is full (rare — capacity is 1024 by default).
emitDispatcherBanner :: AgentEnv -> Text -> IO ()
emitDispatcherBanner env txt =
  atomically $ writeTBQueue
    (_env_channelOutQ env)
    (SrcDispatcher, BannerLine txt)

-- | Format a TabIndex as the user-facing decimal string.
tShowIdx :: TabIndex -> Text
tShowIdx = T.pack . show . unTabIndex


-- ---------------------------------------------------------------------------
-- runDispatcher
-- ---------------------------------------------------------------------------

-- | Run the dispatcher forever, using the default per-kind factory.
--
-- Wraps everything in 'bracket' so a crash inside the loop or a
-- graceful end-of-stream from '_ch_receive' triggers 'closeAllTabs'
-- and tears down the channel-out writer.
runDispatcher :: AgentEnv -> IO ()
runDispatcher env = runDispatcherWith env (defaultTabFactory env)

-- | Run the dispatcher forever with a caller-supplied factory.
--
-- Tests use this to inject 'TabFactory' stubs without touching the
-- WU1 stub-bottomed production factories.
runDispatcherWith :: AgentEnv -> TabFactory -> IO ()
runDispatcherWith env factory =
  -- The outer bracket guarantees:
  --   * the channel-out writer thread is started under mask_ so it
  --     cannot be lost to an async exception;
  --   * 'closeAllTabs' fires on BOTH exception and graceful exit
  --     (per C4).
  bracket
    (acquire env factory)
    (release env)
    (loop env)
  where
    loop e (ds, _outR) = do
      msg <- _ch_receive (_env_channel e)
      dispatchOne e ds (_im_userId msg) (_im_content msg)
      loop e (ds, _outR)

-- | The 'bracket' acquire: starts the channel-out writer, builds the
-- dispatcher state. Uses 'mask_' to ensure the writer-thread runner is
-- captured into a field accessible to 'release'.
acquire :: AgentEnv -> TabFactory -> IO (DispatcherState, TabRunner)
acquire env factory = mask_ $ do
  ds   <- newDispatcherState env factory
  outR <- ChannelOut.startChannelOut env
  pure (ds, outR)

-- | The 'bracket' release: cancel the channel-out writer thread, then
-- run 'closeAllTabs' to drive per-tab cleanup. Both steps are
-- exception-tolerant (per the cleanup contract).
release :: AgentEnv -> (DispatcherState, TabRunner) -> IO ()
release env (_ds, outR) = do
  safeIgnore (_trun_cancel outR)
  closeAllTabs env
  -- Drain a debug log line so an explicit shutdown is observable in
  -- the logs. The logger is documented total in mkNoOpLogHandle, but
  -- we wrap defensively.
  safeIgnore (_lh_logDebug (_env_logger env) "dispatcher: closeAll complete")

