module PureClaw.Channels.CLI
  ( -- * CLI channel
    mkCLIChannelHandle
  ) where

import Data.Maybe qualified
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Console.Haskeline qualified as HL
import System.Directory (createDirectoryIfMissing)
import System.IO (hFlush, stderr, stdout)

import PureClaw.CLI.Config (getPureclawDir)
import PureClaw.Core.Types
import PureClaw.Handles.Channel

-- | Create a channel handle that uses haskeline for line editing.
-- Provides readline-style input: backspace, arrow keys, up/down history,
-- Ctrl-A/E, etc. History is persisted to @~\/.pureclaw\/history@.
-- Accepts an optional completion function for tab completion of slash commands.
mkCLIChannelHandle :: Maybe (HL.CompletionFunc IO) -> IO ChannelHandle
mkCLIChannelHandle mCompleter = do
  histPath <- haskelineHistoryPath
  let settings = (HL.defaultSettings :: HL.Settings IO)
        { HL.historyFile = Just histPath
        , HL.complete = Data.Maybe.fromMaybe HL.completeFilename mCompleter
        }
  pure ChannelHandle
    { _ch_receive = do
        mLine <- HL.runInputT settings (HL.getInputLine "> ")
        case mLine of
          Nothing   -> ioError (userError "EOF")  -- Ctrl-D: agent loop catches this
          Just line -> pure IncomingMessage
            { _im_userId  = UserId "cli-user"
            , _im_content = T.pack line
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
    , _ch_streaming = True
    , _ch_readSecret = do
        mLine <- HL.runInputT settings (HL.getPassword Nothing "")
        pure (maybe "" T.pack mLine)
    , _ch_prompt = \promptText -> do
        mLine <- HL.runInputT settings (HL.getInputLine (T.unpack promptText))
        pure (maybe "" T.pack mLine)
    , _ch_promptSecret = \promptText -> do
        mLine <- HL.runInputT settings (HL.getPassword Nothing (T.unpack promptText))
        pure (maybe "" T.pack mLine)
    }

-- | Path to the haskeline history file: @~\/.pureclaw\/history@.
-- Creates the directory if it does not exist.
haskelineHistoryPath :: IO FilePath
haskelineHistoryPath = do
  dir <- getPureclawDir
  createDirectoryIfMissing True dir
  pure (dir <> "/history")
