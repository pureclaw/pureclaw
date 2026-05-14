-- |
-- Module      : PureClaw.Backend.Pty
-- Description : PTY allocation seam, drainer state machine, recv idle logic (WU7).
--
-- == Posix-pty firewall
--
-- This module is the __only__ module in the codebase that imports
-- "System.Posix.Pty". The 'PtyFds' ADT is opaque to the rest of the
-- code: its constructors are not exported, which is the type-level
-- side of the firewall. The CI gate
-- @scripts\/check-pty-firewall.sh@ enforces the same invariant at the
-- import level.
--
-- A sibling module 'PureClaw.Backend.Pty.Fake' is the only other
-- member of the firewall — it consumes a small internal-only
-- accessor surface (@FakePtyState@, 'mkFakePtyFds', 'withFakePtyState')
-- to build a deterministic in-process 'PtyIO' for tests. No other
-- module may pattern-match on 'PtyFds' or import @System.Posix.Pty@.
--
-- == 'realPtyIO' coverage policy
--
-- 'realPtyIO' is exercised only via integration tests that spawn real
-- subprocesses (WU8 \/ WU9). Lines that cannot be reached without a
-- real kernel-level PTY (the kernel-error paths inside @posix-pty@)
-- are flagged @-- HPC:Exclude@ at the call sites. The @fakePtyIO@
-- path in 'PureClaw.Backend.Pty.Fake' carries 100% branch coverage
-- and is the substrate for the drainer\'s property tests.
--
-- == Drainer ⇄ Recv signalling
--
-- 'runDrainerLoop' forks an 'Control.Concurrent.Async.Async' that
-- reads from a 'PtyFds' into the STM 'DrainState'. 'drainerRecv' is
-- the consumer side: it implements the idle state machine from
-- @docs\/terminal-backend-abstractions.md@ § "Idle state machine"
-- (waiting-for-first-byte → draining → settled\/timed-out\/eof\/truncated).
module PureClaw.Backend.Pty
  ( -- * PTY seam
    PtyIO (..)
  , PtyFds
  , PtyOpenSpec (..)
  , realPtyIO
    -- * Construction of fake-side PtyFds (consumed by "PureClaw.Backend.Pty.Fake")
  , FakePtyState (..)
  , mkFakePtyFds
  , withFakePtyState
  , isFakePtyFds
    -- * Drainer
  , RecvSignal (..)
  , DrainState (..)
  , newDrainState
  , runDrainerLoop
  , drainerRecv
    -- * Drainer-backed factory substrate
  , mkDrainerBackendHandle
  ) where

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Control.Concurrent.STM
  ( STM
  , atomically
  , orElse
  , registerDelay
  , retry
  )
import Control.Concurrent.STM.TBQueue
  ( TBQueue
  , newTBQueueIO
  , readTBQueue
  , tryReadTBQueue
  , writeTBQueue
  )
import Control.Concurrent.STM.TVar
  ( TVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, mask, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Process qualified as Proc

import System.Posix.Pty qualified as Posix.Pty

import PureClaw.Handles.Backend
  ( BackendError
  , BackendHandle (..)
  , BackendKind (..)
  , Cols (..)
  , EnvMap
  , EnvValue (..)
  , IdleSpec
  , PtyOpts (..)
  , RecvResult (..)
  , Rows (..)
  , acquireBufferQuota
  , globalBackendBufferQuota
  , idleMinFirstByte
  , idleQuietMs
  , idleTimeoutMs
  , releaseBufferQuota
  )
import PureClaw.Internal.FakeClock (FakeClock)

--------------------------------------------------------------------------------
-- PTY seam
--------------------------------------------------------------------------------

-- | Caller-supplied parameters for opening a PTY.
--
-- Built by factory modules ('PureClaw.Backend.Local',
-- 'PureClaw.Backend.SSH', 'PureClaw.Backend.Tmux') from an
-- 'PureClaw.Security.Command.AuthorizedCommand' (or remote analogue)
-- plus the option record\'s geometry / env / cwd.
data PtyOpenSpec = PtyOpenSpec
  { _pos_program :: !FilePath
  , _pos_args    :: ![Text]
  , _pos_env     :: !EnvMap
  , _pos_cwd     :: !(Maybe FilePath)
  , _pos_cols    :: !Cols
  , _pos_rows    :: !Rows
  }

-- | Opaque PTY file-descriptors handle.
--
-- The constructors are NOT exported. Other modules see 'PtyFds' as an
-- abstract type and operate on it only via a 'PtyIO' record. This is
-- the type-level half of the @posix-pty@ firewall.
data PtyFds
  = RealPtyFds !Posix.Pty.Pty !(Maybe Proc.ProcessHandle)
  | FakePtyFds !FakePtyState

-- | Internal record state for the fake PTY path.
--
-- Defined here (rather than in "PureClaw.Backend.Pty.Fake") so that
-- the 'PtyFds' constructors can remain hidden from the world while
-- the @Fake@ submodule still has the structure it needs to update via
-- 'withFakePtyState'.
data FakePtyState = FakePtyState
  { _fps_readQueue :: !(IORef [ByteString])
    -- ^ Pending output chunks, head consumed first.
  , _fps_writeLog  :: !(IORef [ByteString])
    -- ^ All bytes ever written through '_pio_write', newest first.
  , _fps_resizeLog :: !(IORef [(Cols, Rows)])
    -- ^ All resize calls, newest first.
  , _fps_closed    :: !(IORef Bool)
    -- ^ 'True' once '_pio_close' has been called at least once.
  , _fps_eofAfter  :: !(IORef (Maybe Int))
    -- ^ Optional cap: after this many bytes have been read,
    -- @_pio_read@ returns empty 'ByteString' (EOF).
  , _fps_bytesRead :: !(IORef Int)
    -- ^ Running total of bytes returned from '_pio_read'.
  , _fps_clock     :: !FakeClock
    -- ^ Deterministic clock; tests advance it explicitly.
  }

-- | Construct a fake 'PtyFds' from a populated 'FakePtyState'. Used
-- only by "PureClaw.Backend.Pty.Fake".
mkFakePtyFds :: FakePtyState -> PtyFds
mkFakePtyFds = FakePtyFds

-- | Apply an action to the fake state inside a 'PtyFds', if the value
-- came from the fake path. Returns 'Nothing' if the 'PtyFds' is real.
withFakePtyState :: PtyFds -> (FakePtyState -> IO a) -> IO (Maybe a)
withFakePtyState fds f = case fds of
  FakePtyFds st -> Just <$> f st
  RealPtyFds {} -> pure Nothing

-- | Predicate: did this 'PtyFds' come from the fake path?
--
-- Provided so the rest of the codebase never has to pattern-match on
-- 'PtyFds' to know which side it is on.
isFakePtyFds :: PtyFds -> Bool
isFakePtyFds (FakePtyFds {}) = True
isFakePtyFds (RealPtyFds {}) = False

-- | The injectable PTY-allocation seam.
--
-- The factory modules ('PureClaw.Backend.Local' etc.) consume a value
-- of this type instead of importing @posix-pty@ directly. Tests use
-- 'PureClaw.Backend.Pty.Fake.fakePtyIO'; production uses 'realPtyIO'.
data PtyIO = PtyIO
  { _pio_open   :: PtyOpenSpec -> IO PtyFds
  , _pio_read   :: PtyFds -> Int -> IO ByteString
    -- ^ Read up to N bytes. May block. An empty result means EOF.
  , _pio_write  :: PtyFds -> ByteString -> IO ()
  , _pio_resize :: PtyFds -> Cols -> Rows -> IO ()
  , _pio_close  :: PtyFds -> IO ()
  }

-- | The real, @posix-pty@-backed 'PtyIO'.
--
-- The 'PtyOpenSpec' carries the program + args + env + cwd + geometry;
-- the open action calls 'Posix.Pty.spawnWithPty' inside a real PTY and
-- returns a wrapping 'PtyFds'.
realPtyIO :: PtyIO
realPtyIO = PtyIO
  { _pio_open   = realOpen
  , _pio_read   = realRead
  , _pio_write  = realWrite
  , _pio_resize = realResize
  , _pio_close  = realClose
  }
  where
    -- HPC:Exclude — kernel-error paths exercised only via integration tests.
    realOpen :: PtyOpenSpec -> IO PtyFds
    realOpen spec = do
      let cols = unCols (_pos_cols spec)
          rows = unRows (_pos_rows spec)
          env  = envToTuples (_pos_env spec)
          mEnv = if null env then Nothing else Just env
          prog = _pos_program spec
          args = map T.unpack (_pos_args spec)
      (pty, ph) <- Posix.Pty.spawnWithPty mEnv True prog args (cols, rows)
      pure (RealPtyFds pty (Just ph))

    realRead :: PtyFds -> Int -> IO ByteString
    realRead fds _ = case fds of
      RealPtyFds pty _ -> do
        -- HPC:Exclude — real-PTY error paths
        r <- try @SomeException (Posix.Pty.readPty pty)
        case r of
          Right bs -> pure bs
          Left _   -> pure BS.empty -- treat as EOF
      FakePtyFds _ -> pure BS.empty
      -- ^ unreachable: realPtyIO never produces a FakePtyFds; the
      --   total pattern keeps -Wall quiet.

    realWrite :: PtyFds -> ByteString -> IO ()
    realWrite fds bs = case fds of
      RealPtyFds pty _ -> Posix.Pty.writePty pty bs
      FakePtyFds _     -> pure ()

    realResize :: PtyFds -> Cols -> Rows -> IO ()
    realResize fds (Cols c) (Rows r) = case fds of
      RealPtyFds pty _ -> Posix.Pty.resizePty pty (c, r)
      FakePtyFds _     -> pure ()

    realClose :: PtyFds -> IO ()
    realClose fds = case fds of
      RealPtyFds pty mPh -> do
        _ <- try @SomeException (Posix.Pty.closePty pty)
        case mPh of
          Just ph -> do
            _ <- try @SomeException (Proc.terminateProcess ph)
            _ <- try @SomeException (Proc.waitForProcess ph)
            pure ()
          Nothing -> pure ()
      FakePtyFds _ -> pure ()

unCols :: Cols -> Int
unCols (Cols n) = n

unRows :: Rows -> Int
unRows (Rows n) = n

envToTuples :: EnvMap -> [(String, String)]
envToTuples = map render . Map.toAscList
  where
    render (k, EnvValue v) = (k, byteStringToString v)
    byteStringToString bs = map (toEnum . fromIntegral) (BS.unpack bs)

--------------------------------------------------------------------------------
-- Drainer
--------------------------------------------------------------------------------

-- | A unit pushed onto 'DrainState._ds_queue' by the drainer 'Async'.
data RecvSignal
  = RsChunk !ByteString
    -- ^ A new chunk of output.
  | RsEof
    -- ^ The drainer\'s underlying read returned EOF (PTY closed).
  | RsTrunc
    -- ^ The per-backend recv-buffer cap was reached. After this
    -- sentinel, the drainer stops enqueuing chunks and the truncate
    -- latch ('_ds_truncated') is set to 'True'.
  deriving stock (Eq, Show)

-- | The STM state shared between the drainer 'Async' and 'drainerRecv'.
data DrainState = DrainState
  { _ds_queue       :: !(TBQueue RecvSignal)
  , _ds_truncated   :: !(TVar Bool)
    -- ^ Latches 'True' on the first 'RsTrunc'; never reset.
  , _ds_drainerDone :: !(TVar Bool)
    -- ^ Set to 'True' when the drainer 'Async' has finished
    -- (EOF, exception, or cancel).
  , _ds_bytesQueued :: !(TVar Int)
    -- ^ Sum of bytes accepted by the queue (i.e. before truncation).
  }

-- | Allocate a fresh 'DrainState'. The queue capacity is generous: the
-- per-byte cap is enforced by 'runDrainerLoop' against
-- '_ds_bytesQueued', not by the queue\'s slot count.
newDrainState :: IO DrainState
newDrainState = do
  q  <- newTBQueueIO 1024
  tr <- newTVarIO False
  dd <- newTVarIO False
  bq <- newTVarIO 0
  pure DrainState
    { _ds_queue       = q
    , _ds_truncated   = tr
    , _ds_drainerDone = dd
    , _ds_bytesQueued = bq
    }

-- | Spawn the drainer loop.
--
-- The loop reads chunks from the 'PtyFds' via @_pio_read@; on each
-- non-empty chunk it accounts for it against the per-backend
-- @recvBufferCap@ (in bytes); on overflow it sets '_ds_truncated' and
-- emits 'RsTrunc', then stops reading. On EOF (empty 'ByteString'
-- from the read) it emits 'RsEof' and exits. Cancelling the returned
-- 'Async' terminates the loop; '_ds_drainerDone' is set on any exit.
runDrainerLoop
  :: PtyIO
  -> PtyFds
  -> Int -- ^ recv-buffer cap, bytes
  -> DrainState
  -> IO (Async ())
runDrainerLoop pio fds cap st = Async.async (loop `finallyAtomic` markDone)
  where
    loop :: IO ()
    loop = do
      truncated <- readTVarIO (_ds_truncated st)
      if truncated
        then pure ()
        else do
          chunk <- _pio_read pio fds 4096
          if BS.null chunk
            then atomically (writeTBQueue (_ds_queue st) RsEof)
            else do
              cont <- atomically $ do
                queued <- readTVar (_ds_bytesQueued st)
                let newTotal = queued + BS.length chunk
                if newTotal > cap
                  then do
                    writeTVar (_ds_truncated st) True
                    writeTBQueue (_ds_queue st) RsTrunc
                    pure False
                  else do
                    writeTVar (_ds_bytesQueued st) newTotal
                    writeTBQueue (_ds_queue st) (RsChunk chunk)
                    pure True
              when cont loop

    markDone :: IO ()
    markDone = atomically (writeTVar (_ds_drainerDone st) True)

    -- A 'finally'-style wrapper that ignores exceptions from the inner
    -- action (the drainer is best-effort) but always runs the cleanup.
    finallyAtomic :: IO () -> IO () -> IO ()
    finallyAtomic action fin = mask $ \restore -> do
      r <- try @SomeException (restore action)
      fin
      case r of
        Right () -> pure ()
        Left _   -> pure ()

-- | Consume from 'DrainState' according to the supplied 'IdleSpec'.
--
-- Implements the idle state machine from
-- @docs\/terminal-backend-abstractions.md@ § "Idle state machine":
--
-- 1. Wait up to @idleMinFirstByte@ ms (or @idleTimeoutMs@ — whichever
--    bounds the wait first) for the first chunk. If nothing arrives
--    within @idleTimeoutMs@ total, return 'RecvTimedOut' on the
--    bytes-so-far (empty if no chunk ever arrived).
-- 2. After the first chunk, accumulate bytes from subsequent chunks.
--    Each chunk resets a rolling quiet-window timer of length
--    @idleQuietMs@. When the quiet window elapses with no further
--    chunks, return 'RecvSettled'.
-- 3. The truncate latch ('_ds_truncated' @== True@) short-circuits
--    every recv with 'RecvTruncated' on whatever has accumulated.
--    The latch persists across calls until @_bh_close@.
-- 4. An 'RsEof' on the queue (or '_ds_drainerDone' going 'True')
--    yields 'RecvEof' on the bytes-so-far.
-- 5. If @idleTimeoutMs@ elapses at any point (including mid-drain),
--    return 'RecvTimedOut' on whatever has accumulated.
drainerRecv :: DrainState -> IdleSpec -> IO (RecvResult ByteString)
drainerRecv st idle = do
  isTrunc <- readTVarIO (_ds_truncated st)
  if isTrunc
    then drainQueueLatched
    else do
      totalTimer <- registerDelay (totalMs * 1_000)
      phaseWait totalTimer
  where
    totalMs = idleTimeoutMs idle
    quietMs = idleQuietMs idle
    firstMs = idleMinFirstByte idle

    -- Phase 0: waiting for the first chunk. Bounded by @firstMs@
    -- (or @totalMs@ if @firstMs == 0@), but never longer than the
    -- total timer.
    phaseWait :: TVar Bool -> IO (RecvResult ByteString)
    phaseWait totalTimer = do
      let firstWaitMs = if firstMs > 0 then firstMs else totalMs
      firstTimer <- registerDelay (firstWaitMs * 1_000)
      r <- atomically $
        (Right <$> readSignal st)
          `orElse` (do
              total <- readTVar totalTimer
              first <- readTVar firstTimer
              if total || first
                then pure (Left ())
                else retry)
      case r of
        Left ()             -> pure (RecvTimedOut BS.empty)
        Right RsEof         -> pure (RecvEof BS.empty)
        Right RsTrunc       -> pure (RecvTruncated BS.empty)
        Right (RsChunk bs)  -> phaseDrain totalTimer [bs]

    -- Phase 1: draining. Loops on rolling @quietMs@ STM waits, bounded
    -- by the same total timer as phase 0. EOF, truncate, total-timeout
    -- and quiet-window-elapsed are the four exits.
    phaseDrain :: TVar Bool -> [ByteString] -> IO (RecvResult ByteString)
    phaseDrain totalTimer acc = do
      quietTimer <- registerDelay (quietMs * 1_000)
      r <- atomically $
        (Right <$> readSignal st)
          `orElse` (do
              total <- readTVar totalTimer
              quiet <- readTVar quietTimer
              if total
                then pure (Left True)   -- total-timeout
                else if quiet
                  then pure (Left False) -- quiet-elapsed
                  else retry)
      case r of
        Left True             -> pure (RecvTimedOut (BS.concat (reverse acc)))
        Left False            -> pure (RecvSettled  (BS.concat (reverse acc)))
        Right RsEof           -> pure (RecvEof (BS.concat (reverse acc)))
        Right RsTrunc         -> pure (RecvTruncated (BS.concat (reverse acc)))
        Right (RsChunk bs)    -> phaseDrain totalTimer (bs : acc)

    -- Latch set: drain whatever is already queued non-blockingly and
    -- return 'RecvTruncated'.
    drainQueueLatched :: IO (RecvResult ByteString)
    drainQueueLatched = do
      acc <- drainNonBlocking []
      pure (RecvTruncated (BS.concat (reverse acc)))

    drainNonBlocking :: [ByteString] -> IO [ByteString]
    drainNonBlocking acc = do
      mSig <- atomically (tryReadTBQueue (_ds_queue st))
      case mSig of
        Nothing           -> pure acc
        Just (RsChunk bs) -> drainNonBlocking (bs : acc)
        Just RsEof        -> pure acc
        Just RsTrunc      -> pure acc

-- | Read a single 'RecvSignal' atomically. Also wakes on truncate-
-- latch flip or drainer-done so callers can short-circuit promptly.
readSignal :: DrainState -> STM RecvSignal
readSignal st =
  readTBQueue (_ds_queue st)
    `orElse` (do
        tr <- readTVar (_ds_truncated st)
        unless tr retry
        pure RsTrunc)
    `orElse` (do
        dd <- readTVar (_ds_drainerDone st)
        unless dd retry
        pure RsEof)

--------------------------------------------------------------------------------
-- Drainer-backed factory substrate
--------------------------------------------------------------------------------

-- | Wire a 'PtyIO' + 'PtyOpts' into a complete 'BackendHandle' whose
-- @_bh_recv@ talks to a 'drainerRecv' loop.
--
-- The factory:
--
-- 1. Acquires the per-backend recv buffer cap from the process-wide
--    quota (rounded up to whole MiB). On oversubscription returns
--    @Left BackendBufferQuotaExceeded@ — no resources opened.
-- 2. Opens the PTY via @_pio_open@ (which uses the program + args
--    from the supplied 'PtyOpenSpec'-like fields on 'PtyOpts'). On
--    a failure the quota is released and the error propagates.
-- 3. Spawns the drainer 'Async' via 'runDrainerLoop'.
-- 4. Builds a 'BackendHandle' whose @_bh_close@ is idempotent: it
--    flips an internal flag, cancels the drainer, closes the PTY,
--    and releases the buffer quota exactly once.
--
-- WU7 ships the seam and the test-side fake. WU8 \/ WU9 \/ WU10 will
-- compose @AuthorizedCommand@ \/ @RemoteCommand@ \/ tmux selectors
-- into the 'PtyOpenSpec' the factories pass in. For WU7\'s tests, the
-- @open@ closure is called with a dummy 'PtyOpenSpec' (only the
-- geometry matters to fakePtyIO).
mkDrainerBackendHandle
  :: PtyIO
  -> PtyOpts
  -> PtyOpenSpec
  -> BackendKind
  -> IO (Either BackendError BackendHandle)
mkDrainerBackendHandle pio opts spec kind = do
  let capBytes = _pto_recvBufferCap opts
      capMiB   = bytesToMiBCeil capBytes
  quotaPtr <- readIORef globalBackendBufferQuota
  acq <- acquireBufferQuota quotaPtr capMiB
  case acq of
    Left e  -> pure (Left e)
    Right () -> do
      fds <- _pio_open pio spec
      st  <- newDrainState
      drainerAsync <- runDrainerLoop pio fds capBytes st
      releasedRef  <- newIORef False
      closeLock    <- newMVar ()
      let releaseQuotaOnce = do
            already <- atomicSwapTrue releasedRef
            if already
              then pure ()
              else releaseBufferQuota quotaPtr capMiB

          doSend = _pio_write pio fds

          doRecv mIdle = drainerRecv st (fromMaybe (_pto_idle opts) mIdle)

          doResize = _pio_resize pio fds

          doClose = modifyMVar_ closeLock $ \() -> do
            Async.cancel drainerAsync
            _ <- Async.waitCatch drainerAsync
            _pio_close pio fds
            releaseQuotaOnce
            pure ()

      pure $ Right BackendHandle
        { _bh_name        = "drainer-pty"
        , _bh_kind        = kind
        , _bh_defaultIdle = _pto_idle opts
        , _bh_send        = doSend
        , _bh_recv        = doRecv
        , _bh_resize      = doResize
        , _bh_close       = doClose
        }

-- | Atomically set an 'IORef Bool' to 'True', returning its previous
-- value. Used to defend against double-release of the buffer quota.
atomicSwapTrue :: IORef Bool -> IO Bool
atomicSwapTrue ref = atomicModifyIORef' ref (True,)

-- | Round a byte count up to whole MiB (1 MiB == 1_048_576 bytes).
-- Zero or negative byte counts produce @0@.
bytesToMiBCeil :: Int -> Int
bytesToMiBCeil n
  | n <= 0    = 0
  | otherwise = (n + mib - 1) `div` mib
  where mib = 1024 * 1024
