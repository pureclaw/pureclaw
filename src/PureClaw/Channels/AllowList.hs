module PureClaw.Channels.AllowList
  ( emitAllowListWarning
  , warnIfOpenAllowList
  ) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.IO

import PureClaw.Core.Types
import PureClaw.Handles.Log

-- | When the list is open, write the banner lines to @h@ and emit the WARN
--   log line via the LogHandle. No-op when senders are restricted. @h@ is
--   injectable so tests can capture output to a temp-file Handle.
emitAllowListWarning :: Handle -> LogHandle -> Text -> AllowList a -> IO ()
emitAllowListWarning h lh name al = case allowListWarning name al of
  Nothing -> pure ()
  Just (banner, logMsg) -> do
    mapM_ (TIO.hPutStrLn h) banner
    _lh_logWarn lh logMsg

-- | Convenience for live call sites: banner to stdout (matching the existing
--   @PureClaw 0.1.0@ startup banner), log line to stderr via the LogHandle.
warnIfOpenAllowList :: LogHandle -> Text -> AllowList a -> IO ()
warnIfOpenAllowList = emitAllowListWarning stdout
