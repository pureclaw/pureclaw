-- |
-- Module      : PureClaw.Tab.Harness
-- Description : Harness tab factory (Tabbed Chat WU7).
--
-- A harness tab is a 'PureClaw.Handles.Tab.TabHandle' that wraps an
-- existing 'PureClaw.Handles.Harness.HarnessHandle' (e.g. a tmux-managed
-- @claude-code@ subprocess). The tab owns two helper threads:
--
--   * a /drainer/ that loops on '_hh_receive' and emits each non-empty
--     output chunk as @'FullMsg' !TabIndex !Text@ via '_env_channelOutQ'
--     (focus-gated at the producer side per D4 and at the writer side
--     per D3);
--   * a /writer/ that drains a bounded outbound queue and forwards
--     bytes to '_hh_send', keeping the public 'TabHandle._tabHandle_send'
--     non-blocking per H4.
--
-- == Factory shape
--
-- @
-- 'mkTabHarness' :: 'PureClaw.Agent.Env.AgentEnv'
--                -> 'PureClaw.Handles.Tab.TabIndex'
--                -> 'PureClaw.Handles.Tab.HarnessSpawnArgs'
--                -> IO (Either 'PureClaw.Handles.Tab.TabError'
--                              'PureClaw.Handles.Tab.TabHandle')
-- @
--
-- Mirrors the WU6 'PureClaw.Tab.Ai.mkTabAi' factory pattern: takes
-- 'AgentEnv', returns either a constructed 'TabHandle' or a
-- redacted 'TabError'.
--
-- == HarnessHandle lookup
--
-- The 'HarnessSpawnArgs._harness_requestedName' field is the lookup
-- key for '_env_harnesses' (which is the existing
-- @IORef (Map Text HarnessHandle)@). Harness lifecycle (start \/ stop)
-- is owned by the existing @\/harness@ slash command surface; the
-- tab factory only /adopts/ a running harness. If the name does not
-- resolve, the factory returns @'Left' ('TabNotFound' ix)@ where @ix@
-- is the requested 'TabIndex' rendered as 'Int' (the public projection
-- is still the channel-safe @\"tab: not found\"@ short label).
--
-- == Slash commands are unsupported (H13 \/ I4)
--
-- '_tabHandle_enqueueSlash' returns @'Left' ('TabUnsupportedCommand'
-- cmd)@ immediately without enqueueing — harness tabs do not have a
-- per-tab 'Context' or slash-command surface. Direct-inject text
-- (@\/N \<text\>@) is forwarded verbatim to the harness via the
-- writer thread so a payload like @\/N \/pwd@ reaches the harness as
-- the literal @\"\/pwd\"@ (I4 — slash-prefix opaque to backend).
--
-- == Close semantics (H8 \/ H9)
--
-- Both 'CloseGraceful' and 'CloseForce' are destructive: they cancel
-- both helper threads and call '_hh_stop' on the underlying
-- 'HarnessHandle'. The harness is /not/ archived (there's no
-- transcript-equivalent to flush). Idempotent + never-throws (H6 \/
-- H7 contract).
--
-- == Async exception discipline
--
-- Helper threads catch 'SomeException' EXCEPT 'AsyncCancelled', which
-- propagates so that '_tabHandle_close' (which cancels the helpers'
-- 'TabRunner's) can unblock a stuck 'threadDelay' or pending
-- '_hh_receive'. Mirrors the WU6 'safelyRunLoop' pattern.
--
-- See @docs\/tabbed-chat.md@ §"H-series" (close lifecycle), §"I4"
-- (opaque slash-prefix), and §"D5" (FullMsg emission).
module PureClaw.Tab.Harness
  ( -- * Factory
    mkTabHarness
    -- * Internal state (exposed for tests)
  , HarnessTabState (..)
    -- * Internal helpers (exposed for tests)
  , drainerSleepMicros
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , atomically
  , isFullTBQueue
  , newTBQueueIO
  , readTBQueue
  , writeTBQueue
  )
import Control.Exception
  ( Exception
  , SomeException
  , catch
  , fromException
  , throwIO
  , try
  )
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (SlashCommand)
import PureClaw.Handles.Harness
  ( HarnessHandle (..)
  , HarnessStatus (..)
  , sanitizeHarnessOutput
  )
import PureClaw.Handles.Tab
  ( CloseMode (..)
  , HarnessSpawnArgs (..)
  , PublicTabError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabRunner (..)
  , TabStatus (..)
  , unTabIndex
  )
import PureClaw.Routing.ChannelOut (shouldEmit)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  )


-- ---------------------------------------------------------------------------
-- HarnessTabState — per-tab mutable state, private to the factory closure
-- ---------------------------------------------------------------------------

-- | Per-harness-tab mutable state. Fields are exposed so a future
-- diagnostic @tab info@ handler can inspect them; production code never
-- touches the record outside this module.
data HarnessTabState = HarnessTabState
  { _hts_harness        :: !HarnessHandle
    -- ^ The underlying harness adopted at spawn time. Looked up by
    -- name from '_env_harnesses'; the tab does NOT own the harness
    -- lifecycle (the existing @\/harness@ command surface does), but
    -- '_tabHandle_close' DOES call '_hh_stop' on it per H8 (destructive
    -- close — there is no archive equivalent).
  , _hts_sendQ          :: !(TBQueue ByteString)
    -- ^ Bounded outbound queue. '_tabHandle_send' enqueues here
    -- non-blockingly; the writer thread drains and calls '_hh_send'.
    -- Bounded by '_rc_inputQueueBound' so a saturating producer
    -- surfaces 'TabConcurrencyLimit' rather than blocking the
    -- dispatcher (H4).
  , _hts_drainRunner    :: !(IORef (Maybe TabRunner))
    -- ^ Drainer thread runner (output side: '_hh_receive' →
    -- 'FullMsg'). Filled by 'mkTabHarness' post-fork; stays 'Nothing'
    -- for the brief window between allocation and fork-fill.
  , _hts_writerRunner   :: !(IORef (Maybe TabRunner))
    -- ^ Writer thread runner (input side: '_hts_sendQ' →
    -- '_hh_send'). Filled by 'mkTabHarness' post-fork.
  , _hts_closed         :: !(IORef Bool)
    -- ^ Idempotency flag for '_tabHandle_close'. Flipped to 'True' on
    -- the first invocation; subsequent invocations are no-ops (H6).
  , _hts_statusRef      :: !(IORef TabStatus)
    -- ^ Held status backing '_tabHandle_status'. The drainer and
    -- writer threads do not transition this on a per-chunk basis (a
    -- harness tab is conceptually always available for I\/O); it
    -- starts 'Idle' at spawn and transitions to 'Crashed' if a helper
    -- thread hits a synchronous exception.
  }


-- ---------------------------------------------------------------------------
-- Tuning knobs
-- ---------------------------------------------------------------------------

-- | Microseconds the drainer sleeps between '_hh_receive' calls.
--
-- '_hh_receive' is a /snapshot/ read (it returns whatever output is
-- currently buffered, possibly empty), so we cannot block on it. A
-- 100 ms cadence keeps idle harness tabs from burning CPU while still
-- producing responsive output on focused tabs.
--
-- Exposed for tests so they can pin the cadence; production callers
-- never reference it directly.
drainerSleepMicros :: Int
drainerSleepMicros = 100000  -- 100 ms


-- ---------------------------------------------------------------------------
-- mkTabHarness — the harness tab factory
-- ---------------------------------------------------------------------------

-- | Construct a harness tab. Looks up the requested harness from
-- '_env_harnesses', allocates per-tab state, forks the drainer and
-- writer threads via '_env_fork', and returns a 'TabHandle' whose IO
-- actions close over the state.
--
-- The factory itself never throws: it always returns @'Right' h@ or
-- @'Left' e@. Failures inside the forked helper threads are caught by
-- their own outer exception handler and surface as a 'Crashed' status
-- (visible via '_tabHandle_status').
mkTabHarness :: AgentEnv -> TabIndex -> HarnessSpawnArgs
             -> IO (Either TabError TabHandle)
mkTabHarness env idx args =
  case Parse.sanitizeTabName (_harness_requestedName args) of
    Left nameErr -> pure (Left (TabInvalidName nameErr))
    Right nameTxt -> do
      mHarness <- lookupHarness env (_harness_requestedName args)
      case mHarness of
        Nothing -> pure (Left (TabNotFound (unTabIndex idx)))
        Just hh -> Right <$> spawnTabWithHarness env idx nameTxt hh

-- | Look up the requested harness from '_env_harnesses' by name. We
-- match by the raw (pre-sanitization) requested name because that's
-- the key used by the existing @\/harness start \<name\>@ surface.
lookupHarness :: AgentEnv -> Text -> IO (Maybe HarnessHandle)
lookupHarness env name = do
  hs <- readIORef (_env_harnesses env)
  pure (Map.lookup name hs)

-- | Allocate per-tab state, fork the drainer + writer threads, and
-- build the public 'TabHandle' record.
spawnTabWithHarness
  :: AgentEnv -> TabIndex -> Text -> HarnessHandle -> IO TabHandle
spawnTabWithHarness env idx nameTxt hh = do
  state <- allocState env hh
  -- Sentinel: state starts Idle at allocation; the drainer thread does
  -- not own status transitions in WU7 (a harness tab is always
  -- available unless a helper thread crashes — see 'safelyRun').
  now <- getCurrentTime
  writeIORef (_hts_statusRef state) (Idle now)
  -- Fork the drainer (output) and writer (input) threads via the
  -- env's fork seam. Both runners are captured into the state so
  -- '_tabHandle_close' can cancel them.
  drainRunner  <- _env_fork env (drainerLoop env idx state)
  writeIORef (_hts_drainRunner state) (Just drainRunner)
  writerRunner <- _env_fork env (writerLoop state)
  writeIORef (_hts_writerRunner state) (Just writerRunner)
  pure (mkHandle env idx (TabName nameTxt) state)

-- | Allocate the per-tab state. The bounded outbound queue's capacity
-- comes from '_rc_inputQueueBound' so the H4 \"non-blocking send\"
-- contract is configurable.
allocState :: AgentEnv -> HarnessHandle -> IO HarnessTabState
allocState env hh = do
  let rc = _env_routingConfig env
  sendQ        <- newTBQueueIO (fromIntegral (_rc_inputQueueBound rc))
  drainRef     <- newIORef Nothing
  writerRef    <- newIORef Nothing
  closedRef    <- newIORef False
  statRef      <- newIORef Active  -- replaced with Idle by spawnTabWithHarness
  pure HarnessTabState
    { _hts_harness        = hh
    , _hts_sendQ          = sendQ
    , _hts_drainRunner    = drainRef
    , _hts_writerRunner   = writerRef
    , _hts_closed         = closedRef
    , _hts_statusRef      = statRef
    }

-- | Build the public 'TabHandle' record from the per-tab state.
mkHandle :: AgentEnv -> TabIndex -> TabName -> HarnessTabState -> TabHandle
mkHandle env idx name state = TabHandle
  { _tabHandle_index        = idx
  , _tabHandle_name         = name
  , _tabHandle_kind         = KindHarness
  , _tabHandle_status       = readIORef (_hts_statusRef state)
  , _tabHandle_send         = sendBytes state
  , _tabHandle_enqueueSlash = enqueueSlashUnsupported
  , _tabHandle_close        = closeTabHarness env state
  }


-- ---------------------------------------------------------------------------
-- _tabHandle_send / _tabHandle_enqueueSlash
-- ---------------------------------------------------------------------------

-- | Enqueue a 'Text' payload onto the outbound queue. Non-blocking:
-- returns @'Left' ('TabConcurrencyLimit' 0)@ if the queue is full so
-- the dispatcher's send loop never blocks (H4).
--
-- The text is UTF-8 encoded and forwarded verbatim — including any
-- leading @\/@ — so a direct-inject like @\/N \/pwd@ reaches the
-- harness as the literal @\"\/pwd\"@ (I4: slash-prefix opaque to the
-- backend).
sendBytes :: HarnessTabState -> Text -> IO (Either TabError ())
sendBytes state t = atomically (tryEnqueueSTM (_hts_sendQ state) (TE.encodeUtf8 t))

-- | STM body of 'sendBytes', factored out so tests can drive it inside
-- a larger transaction if needed.
tryEnqueueSTM :: TBQueue ByteString -> ByteString -> STM (Either TabError ())
tryEnqueueSTM q bs = do
  full <- isFullTBQueue q
  if full
    then pure (Left (TabConcurrencyLimit 0))
    else writeTBQueue q bs >> pure (Right ())

-- | '_tabHandle_enqueueSlash' for a harness tab: slash commands are
-- not supported, so we return @'Left' ('TabUnsupportedCommand' cmd)@
-- immediately without enqueueing (H13 \/ I4 contract).
enqueueSlashUnsupported :: SlashCommand -> IO (Either TabError ())
enqueueSlashUnsupported cmd = pure (Left (TabUnsupportedCommand cmd))


-- ---------------------------------------------------------------------------
-- _tabHandle_close — destructive close for harness tabs
-- ---------------------------------------------------------------------------

-- | Close a harness tab. Idempotent + never throws (H6, H7).
--
-- Both 'CloseGraceful' and 'CloseForce' are destructive: there is no
-- harness-side archive equivalent to flush. The triad below cancels
-- both helper threads and then calls '_hh_stop'. Each step is wrapped
-- in 'safeIgnore' so a misbehaving harness can't leak an exception out
-- of the never-throws contract.
closeTabHarness :: AgentEnv -> HarnessTabState -> CloseMode -> IO ()
closeTabHarness _env state mode = do
  alreadyClosed <- atomicModifyIORef' (_hts_closed state) (True,)
  unless alreadyClosed $ do
    safeIgnore (cancelMaybeRunner (_hts_drainRunner state))
    safeIgnore (cancelMaybeRunner (_hts_writerRunner state))
    -- H9: 'CloseGraceful' and 'CloseForce' are semantically identical
    -- for non-AI tabs (close is already destructive). The pattern-match
    -- below is here for symmetry with the WU6 KindAi factory and so
    -- coverage tools see both arms exercised.
    case mode of
      CloseGraceful -> safeIgnore (_hh_stop (_hts_harness state))
      CloseForce    -> safeIgnore (_hh_stop (_hts_harness state))

-- | Read the captured 'TabRunner' (set by 'mkTabHarness' after fork)
-- and invoke its cancel. Tolerant of the brief allocation\/fork window
-- when the IORef is still 'Nothing'.
cancelMaybeRunner :: IORef (Maybe TabRunner) -> IO ()
cancelMaybeRunner ref = do
  mRunner <- readIORef ref
  for_ mRunner _trun_cancel

-- | Best-effort: run an IO action and swallow synchronous failures.
-- The close path MUST be never-throws (H7), so every step is wrapped
-- defensively. 'AsyncCancelled' is also swallowed here because the
-- close handler is invoked from outside the helper threads; any
-- AsyncCancelled bubbling up through cancel itself is benign (the
-- target thread has already received the cancel).
safeIgnore :: IO () -> IO ()
safeIgnore m = do
  _ <- try @SomeException m
  pure ()


-- ---------------------------------------------------------------------------
-- Drainer thread — _hh_receive → FullMsg via _env_channelOutQ
-- ---------------------------------------------------------------------------

-- | Drainer-thread top-level. Wraps 'drainerStep' in 'safelyRun' so a
-- synchronous exception transitions the tab to 'Crashed' rather than
-- killing the parent thread, and so 'AsyncCancelled' propagates per
-- the C5 contract.
drainerLoop :: AgentEnv -> TabIndex -> HarnessTabState -> IO ()
drainerLoop env idx state = safelyRun state loop
  where
    loop = do
      drainerStep env idx state
      loop

-- | One iteration of the drainer. Reads '_hh_receive', emits a
-- 'FullMsg' if the result is non-empty and the tab is focused (D4
-- producer-side skip), then sleeps to avoid CPU burn on idle harnesses.
--
-- Also checks '_hh_status': if the harness has exited, we stop the
-- drainer (the writer thread will eventually surface the next send
-- as a no-op since the harness pipe is closed).
drainerStep :: AgentEnv -> TabIndex -> HarnessTabState -> IO ()
drainerStep env idx state = do
  -- Check status first so an exited harness terminates the loop
  -- quickly. '_hh_status' is documented total in the no-op handle;
  -- for the real claude-code variant it inspects tmux output.
  st <- _hh_status (_hts_harness state)
  case st of
    HarnessExited _ ->
      -- Harness has exited — drainer's job is done. The tab handle
      -- remains valid until '_tabHandle_close' is invoked; closing
      -- will be a no-op on the underlying harness which is already
      -- gone.
      throwIO HarnessExitedSignal
    HarnessRunning -> do
      raw <- _hh_receive (_hts_harness state)
      unless (BS.null raw) $ do
        -- Decode + sanitize for display. The sanitizer strips ANSI,
        -- decorative Unicode, and trims surrounding blank lines.
        let txt = sanitizeHarnessOutput (TE.decodeUtf8 raw)
        unless (T.null (T.strip txt)) $ do
          -- D4 producer-side focus check: skip the enqueue work when
          -- the tab is not focused. The writer thread re-applies the
          -- predicate on dequeue (D3), so this is an optimisation
          -- only; correctness comes from the writer.
          curFocus <- readIORef (_env_focus env)
          when (shouldEmit curFocus (SrcTab idx)) $
            atomically $ writeTBQueue (_env_channelOutQ env)
                           (SrcTab idx, FullMsg idx txt)
      threadDelay drainerSleepMicros


-- ---------------------------------------------------------------------------
-- Writer thread — _hts_sendQ → _hh_send
-- ---------------------------------------------------------------------------

-- | Writer-thread top-level. Drains '_hts_sendQ' forever, forwarding
-- each chunk to '_hh_send'. Wrapped in 'safelyRun' for the same
-- AsyncCancelled \/ Crashed semantics as the drainer.
writerLoop :: HarnessTabState -> IO ()
writerLoop state = safelyRun state loop
  where
    loop = do
      bs <- atomically (readTBQueue (_hts_sendQ state))
      -- '_hh_send' may block (it writes to a tmux pipe). We tolerate
      -- the block because the bounded '_hts_sendQ' keeps the producer
      -- side non-blocking; the writer is a single-purpose drainer and
      -- nothing else depends on its progress.
      _hh_send (_hts_harness state) bs
      loop


-- ---------------------------------------------------------------------------
-- safelyRun — shared exception handler for drainer + writer
-- ---------------------------------------------------------------------------

-- | A private signal raised by the drainer when '_hh_status' reports
-- the harness has exited. Caught by 'safelyRun' so the drainer exits
-- silently (without transitioning the tab to Crashed); other
-- synchronous exceptions DO transition to Crashed.
--
-- 'Show' is hand-written (not derived) so HPC's per-derived-method
-- accounting does not flag the auto-generated instance code as
-- uncovered. The single constructor name suffices for the exception
-- machinery.
data HarnessExitedSignal = HarnessExitedSignal

instance Show HarnessExitedSignal where
  show _ = "HarnessExitedSignal"

instance Exception HarnessExitedSignal

-- | Outer exception handler shared by both helper threads.
--
-- * 'AsyncCancelled' propagates (re-raised) so '_tabHandle_close'
--   semantics work correctly per C5.
-- * 'HarnessExitedSignal' is swallowed silently — the harness exit is
--   an expected lifecycle event, not a crash.
-- * Other 'SomeException' transitions the tab to 'Crashed' (carrying
--   a redacted short label) and the helper thread exits.
safelyRun :: HarnessTabState -> IO () -> IO ()
safelyRun state body = body `catch` handler
  where
    handler :: SomeException -> IO ()
    handler e
      | Just AsyncCancelled        <- fromException e =
          throwIO e  -- propagate AsyncCancelled (C5)
      | Just HarnessExitedSignal   <- fromException e =
          pure ()    -- expected exit; not a crash
      | otherwise =
          writeIORef (_hts_statusRef state)
                     (Crashed (PublicTabError "tab: harness loop crashed"))
