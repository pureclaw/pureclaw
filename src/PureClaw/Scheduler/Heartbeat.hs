module PureClaw.Scheduler.Heartbeat
  ( -- * Heartbeat configuration
    HeartbeatConfig (..)
  , defaultHeartbeatConfig
    -- * Heartbeat runner
  , HeartbeatState (..)
  , mkHeartbeatState
  , runHeartbeat
  , stopHeartbeat
  , isHeartbeatRunning
    -- * Single tick (for testing)
  , heartbeatTick
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time

import PureClaw.Handles.Log

-- | Configuration for the heartbeat scheduler.
data HeartbeatConfig = HeartbeatConfig
  { _hb_intervalSeconds :: Int
  , _hb_name            :: Text
  }
  deriving stock (Show, Eq)

-- | Default heartbeat: every 60 seconds.
defaultHeartbeatConfig :: HeartbeatConfig
defaultHeartbeatConfig = HeartbeatConfig
  { _hb_intervalSeconds = 60
  , _hb_name            = "heartbeat"
  }

-- | Mutable heartbeat state.
data HeartbeatState = HeartbeatState
  { _hbs_config    :: HeartbeatConfig
  , _hbs_running   :: TVar Bool
  , _hbs_lastTick  :: TVar (Maybe UTCTime)
  , _hbs_tickCount :: TVar Int
  }

-- | Create a fresh heartbeat state.
mkHeartbeatState :: HeartbeatConfig -> IO HeartbeatState
mkHeartbeatState config = HeartbeatState config
  <$> newTVarIO False
  <*> newTVarIO Nothing
  <*> newTVarIO 0

-- | Run the heartbeat loop in a new thread. The provided action is
-- called on each tick. Returns the thread ID. Use 'stopHeartbeat' to
-- stop the loop.
runHeartbeat :: HeartbeatState -> LogHandle -> IO () -> IO ThreadId
runHeartbeat hbs lh action = do
  atomically $ writeTVar (_hbs_running hbs) True
  _lh_logInfo lh $ "Heartbeat started: " <> _hb_name (_hbs_config hbs)
  forkIO $ heartbeatLoop hbs lh action

-- | Stop the heartbeat loop.
stopHeartbeat :: HeartbeatState -> IO ()
stopHeartbeat hbs = atomically $ writeTVar (_hbs_running hbs) False

-- | Check if the heartbeat is running.
isHeartbeatRunning :: HeartbeatState -> IO Bool
isHeartbeatRunning hbs = readTVarIO (_hbs_running hbs)

-- | Execute a single heartbeat tick. Updates last tick time and count.
-- Returns 'True' if the action completed successfully.
heartbeatTick :: HeartbeatState -> LogHandle -> IO () -> IO Bool
heartbeatTick hbs lh action = do
  now <- getCurrentTime
  result <- try action
  case result of
    Left (e :: SomeException) -> do
      _lh_logError lh $ "Heartbeat tick failed: " <> T.pack (show e)
      pure False
    Right () -> do
      atomically $ do
        writeTVar (_hbs_lastTick hbs) (Just now)
        modifyTVar' (_hbs_tickCount hbs) (+ 1)
      pure True

-- Internal: the heartbeat loop.
heartbeatLoop :: HeartbeatState -> LogHandle -> IO () -> IO ()
heartbeatLoop hbs lh action = do
  running <- readTVarIO (_hbs_running hbs)
  if running
    then do
      _ <- heartbeatTick hbs lh action
      threadDelay (intervalMicros hbs)
      heartbeatLoop hbs lh action
    else
      _lh_logInfo lh $ "Heartbeat stopped: " <> _hb_name (_hbs_config hbs)

-- Internal: convert interval seconds to microseconds.
intervalMicros :: HeartbeatState -> Int
intervalMicros hbs = _hb_intervalSeconds (_hbs_config hbs) * 1000000
