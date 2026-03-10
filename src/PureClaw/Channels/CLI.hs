module PureClaw.Channels.CLI
  ( -- * CLI channel
    mkCLIChannelHandle
  ) where

import Control.Exception (bracket_)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO

import PureClaw.Core.Types
import PureClaw.Handles.Channel

-- | Create a channel handle that reads from stdin and writes to stdout.
-- Receive prints a @>@ prompt and reads a line. EOF (Ctrl-D) causes
-- an 'IOError' which the agent loop catches to exit cleanly.
mkCLIChannelHandle :: ChannelHandle
mkCLIChannelHandle = ChannelHandle
  { _ch_receive = do
      putStr "> "
      hFlush stdout
      line <- TIO.getLine
      pure IncomingMessage
        { _im_userId  = UserId "cli-user"
        , _im_content = line
        }
  , _ch_send = \msg -> do
      TIO.putStrLn ""
      TIO.putStrLn (_om_content msg)
      TIO.putStrLn ""
  , _ch_sendError = \err ->
      TIO.hPutStrLn stderr $ "Error: " <> T.pack (show err)
  , _ch_sendChunk = \case
      ChunkText t -> do
        TIO.putStr t
        hFlush stdout
      ChunkDone -> TIO.putStrLn ""
  , _ch_readSecret = bracket_
      (hSetEcho stdin False)
      (hSetEcho stdin True)
      TIO.getLine
  }
