module PureClaw.Channels.CLI
  ( -- * CLI channel
    mkCLIChannelHandle
  ) where

import Control.Exception (bracket, bracket_)
import Data.IORef
import Data.Text (Text)
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
      line <- readUnbufferedLine
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
      readUnbufferedLine
  , _ch_prompt = \promptText -> do
      TIO.putStr promptText
      hFlush stdout
      readUnbufferedLine
  , _ch_promptSecret = \promptText -> do
      TIO.putStr promptText
      hFlush stdout
      bracket_ (hSetEcho stdin False) (hSetEcho stdin True) $ do
        line <- readUnbufferedLine
        TIO.putStrLn ""  -- newline after hidden input
        pure line
  }

-- | Read a line from stdin bypassing the terminal's canonical mode line
-- buffer (which is limited to ~1024 bytes on macOS). Temporarily switches
-- stdin to 'NoBuffering' and reads character-by-character until newline.
readUnbufferedLine :: IO Text
readUnbufferedLine = do
  origBuf <- hGetBuffering stdin
  bracket
    (hSetBuffering stdin NoBuffering)
    (\_ -> hSetBuffering stdin origBuf)
    (\_ -> do
      ref <- newIORef []
      let go = do
            c <- getChar
            if c == '\n'
              then pure ()
              else modifyIORef ref (c :) >> go
      go
      chars <- readIORef ref
      pure (T.pack (reverse chars))
    )
