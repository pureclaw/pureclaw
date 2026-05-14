-- |
-- Module      : PureClaw.Internal.FakeClock
-- Description : Deterministic in-process fake clock for tests (WU3).
--
-- A 'FakeClock' is an in-process integer time source measured in
-- milliseconds. It is used by 'PureClaw.Handles.Backend.mkInMemoryBackendHandle'
-- (and, later, by @fakePtyIO@ in WU7) so property tests can advance
-- time without sleeping the test runner.
--
-- The clock starts at @0@. Callers advance it explicitly with
-- 'advanceFakeClock'; there is no automatic wall-clock progression.
--
-- Listeners registered with 'forkClockListener' are invoked
-- synchronously inside 'advanceFakeClock' with the new time. The
-- returned action unregisters the listener (idempotent).
module PureClaw.Internal.FakeClock
  ( FakeClock
  , newFakeClock
  , currentFakeTime
  , advanceFakeClock
  , forkClockListener
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
  ( TVar
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)

-- | Internal listener identifier; increments monotonically.
newtype ListenerId = ListenerId Int
  deriving stock (Eq, Ord)

-- | A deterministic millisecond clock used for tests.
--
-- The constructor is intentionally NOT exported: callers obtain a
-- clock via 'newFakeClock' and observe it via 'currentFakeTime'.
data FakeClock = FakeClock
  { _fc_nowMs     :: !(IORef Int)
  , _fc_listeners :: !(TVar [(ListenerId, Int -> IO ())])
  , _fc_nextId    :: !(IORef Int)
  }

-- | Construct a fresh fake clock starting at @0@.
newFakeClock :: IO FakeClock
newFakeClock = do
  nowRef <- newIORef 0
  ls     <- newTVarIO []
  idRef  <- newIORef 0
  pure FakeClock
    { _fc_nowMs     = nowRef
    , _fc_listeners = ls
    , _fc_nextId    = idRef
    }

-- | The current fake time in milliseconds since the clock was constructed.
currentFakeTime :: FakeClock -> IO Int
currentFakeTime = readIORef . _fc_nowMs

-- | Advance the clock by the given number of milliseconds. Listeners
-- registered via 'forkClockListener' are fired synchronously, in
-- registration order, with the new time.
--
-- Negative deltas are clamped to zero (the clock never goes backwards).
advanceFakeClock :: FakeClock -> Int -> IO ()
advanceFakeClock clock deltaMs = do
  let delta = max 0 deltaMs
  newTime <- atomicModifyIORef' (_fc_nowMs clock) $ \t ->
    let t' = t + delta in (t', t')
  ls <- readTVarIO (_fc_listeners clock)
  mapM_ (\(_, cb) -> cb newTime) ls

-- | Register a listener; returns an action that unregisters it.
--
-- The unregister action is safe to call more than once (subsequent
-- calls are no-ops).
forkClockListener :: FakeClock -> (Int -> IO ()) -> IO (IO ())
forkClockListener clock cb = do
  newId <- atomicModifyIORef' (_fc_nextId clock) $ \n ->
    let n' = n + 1 in (n', ListenerId n)
  atomically $ modifyTVar' (_fc_listeners clock) ((newId, cb) :)
  pure $ atomically $ do
    cur <- readTVar (_fc_listeners clock)
    writeTVar (_fc_listeners clock) (filter ((/= newId) . fst) cur)
