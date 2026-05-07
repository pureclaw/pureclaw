module PureClaw.Handles.Log
  ( -- * Handle type
    LogHandle (..)
    -- * Implementations
  , mkStderrLogHandle
  , mkNoOpLogHandle
  ) where

import Control.Concurrent.MVar
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Text qualified as T
import Data.Time
import System.IO

-- | Logging capability. Functions that only receive a 'LogHandle' cannot
-- shell out, read files, or access the network — they can only log.
data LogHandle = LogHandle
  { _lh_logInfo  :: Text -> IO ()
  , _lh_logWarn  :: Text -> IO ()
  , _lh_logError :: Text -> IO ()
  , _lh_logDebug :: Text -> IO ()
  }

-- | Log to stderr with ISO 8601 timestamps and level prefixes.
-- Uses an 'MVar' to serialize writes so concurrent threads don't interleave.
mkStderrLogHandle :: IO LogHandle
mkStderrLogHandle = do
  lock <- newMVar ()
  let logWithLevel :: Text -> Text -> IO ()
      logWithLevel level msg = withMVar lock $ \() -> do
        now <- getCurrentTime
        let timestamp = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" now)
        TIO.hPutStrLn stderr $ "[" <> timestamp <> "] [" <> level <> "] " <> msg
  pure LogHandle
    { _lh_logInfo  = logWithLevel "INFO"
    , _lh_logWarn  = logWithLevel "WARN"
    , _lh_logError = logWithLevel "ERROR"
    , _lh_logDebug = logWithLevel "DEBUG"
    }

-- | No-op log handle. All operations silently succeed.
mkNoOpLogHandle :: LogHandle
mkNoOpLogHandle = LogHandle
  { _lh_logInfo  = \_ -> pure ()
  , _lh_logWarn  = \_ -> pure ()
  , _lh_logError = \_ -> pure ()
  , _lh_logDebug = \_ -> pure ()
  }
