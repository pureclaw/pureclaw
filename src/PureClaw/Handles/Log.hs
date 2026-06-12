module PureClaw.Handles.Log
  ( -- * Handle type
    LogHandle (..)
    -- * Log levels
  , LogLevel (..)
  , parseLogLevel
  , shouldLog
    -- * Implementations
  , mkStderrLogHandle
  , mkStderrLogHandleAt
  , mkNoOpLogHandle
  ) where

import Control.Concurrent.MVar
import Data.Char qualified as Char
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

-- | Minimum severity threshold for logging. Constructor order encodes
-- severity, so @LlDebug < LlInfo < LlWarn < LlError@ and filtering is a
-- comparison. Constructors are prefixed to avoid clashing with unqualified
-- names like 'Data.Aeson.Error' at import sites.
data LogLevel = LlDebug | LlInfo | LlWarn | LlError
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | Parse a log level from a CLI string. Case-insensitive; 'Nothing' for
-- anything that is not one of @debug@, @info@, @warn@, @error@.
parseLogLevel :: String -> Maybe LogLevel
parseLogLevel s = case map Char.toLower s of
  "debug" -> Just LlDebug
  "info"  -> Just LlInfo
  "warn"  -> Just LlWarn
  "error" -> Just LlError
  _       -> Nothing

-- | Should a message at the given level be emitted under the configured
-- threshold? True when the message is at least as severe as the threshold.
shouldLog :: LogLevel -> LogLevel -> Bool
shouldLog threshold msgLevel = msgLevel >= threshold

-- | Log to stderr with ISO 8601 timestamps and level prefixes, emitting every
-- level. Equivalent to @'mkStderrLogHandleAt' 'LlInfo'@.
mkStderrLogHandle :: IO LogHandle
mkStderrLogHandle = mkStderrLogHandleAt LlInfo

-- | Like 'mkStderrLogHandle', but only emits messages at or above the given
-- threshold. Below-threshold calls are silent no-ops. Uses an 'MVar' to
-- serialize writes so concurrent threads don't interleave.
mkStderrLogHandleAt :: LogLevel -> IO LogHandle
mkStderrLogHandleAt threshold = do
  lock <- newMVar ()
  let logWithLevel :: LogLevel -> Text -> Text -> IO ()
      logWithLevel msgLevel label msg
        | shouldLog threshold msgLevel = withMVar lock $ \() -> do
            now <- getCurrentTime
            let timestamp = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" now)
            TIO.hPutStrLn stderr $ "[" <> timestamp <> "] [" <> label <> "] " <> msg
        | otherwise = pure ()
  pure LogHandle
    { _lh_logInfo  = logWithLevel LlInfo  "INFO"
    , _lh_logWarn  = logWithLevel LlWarn  "WARN"
    , _lh_logError = logWithLevel LlError "ERROR"
    , _lh_logDebug = logWithLevel LlDebug "DEBUG"
    }

-- | No-op log handle. All operations silently succeed.
mkNoOpLogHandle :: LogHandle
mkNoOpLogHandle = LogHandle
  { _lh_logInfo  = \_ -> pure ()
  , _lh_logWarn  = \_ -> pure ()
  , _lh_logError = \_ -> pure ()
  , _lh_logDebug = \_ -> pure ()
  }
