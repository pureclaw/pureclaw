module PureClaw.Harness.Tmux
  ( -- * tmux availability
    requireTmux
    -- * Session lifecycle
  , startTmuxSession
  , stopTmuxSession
    -- * Window management
  , addHarnessWindow
  , stopHarnessWindow
    -- * I/O
  , sendToWindow
  , captureWindow
  , tmuxDisplay
    -- * Stealth mode
  , stealthShellCommand
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory qualified as Dir
import System.Exit
import System.IO qualified as IO
import System.Info qualified as Info
import System.IO.Temp qualified as Temp
import System.Process.Typed qualified as P

import PureClaw.Handles.Harness

-- | Run a tmux command silently (no stdin, stdout/stderr to /dev/null).
-- Returns the exit code.
runTmuxSilent :: [String] -> IO ExitCode
runTmuxSilent args =
  P.runProcess
    $ P.setStdin P.closed
    $ P.setStdout P.nullStream
    $ P.setStderr P.nullStream
    $ P.proc "tmux" args

-- | Check if tmux is available on PATH.
requireTmux :: IO (Either HarnessError ())
requireTmux = do
  mPath <- Dir.findExecutable "tmux"
  pure $ case mPath of
    Nothing -> Left HarnessTmuxNotAvailable
    Just _  -> Right ()

-- | Build a stealth shell command string for launching a binary in tmux.
-- Strips TMUX env vars and wraps with script(1) for a fresh PTY.
--
-- macOS: @script -q \/dev\/null command args...@
-- Linux: @script -qc \"command args...\" \/dev\/null@
stealthShellCommand :: FilePath -> [Text] -> String
stealthShellCommand binary args =
  let argStr = unwords (map (T.unpack . shellEscape) args)
      fullCmd = binary <> if null args then "" else " " <> argStr
      scriptWrapped
        | Info.os == "darwin" =
            "script -q /dev/null " <> fullCmd
        | otherwise =
            "script -qc \"" <> escapeForShell fullCmd <> "\" /dev/null"
  in "env -u TMUX -u TMUX_PANE TERM=xterm-256color " <> scriptWrapped

-- | Escape a string for embedding inside double quotes in a shell command.
escapeForShell :: String -> String
escapeForShell = concatMap go
  where
    go '"'  = "\\\""
    go '\\' = "\\\\"
    go '$'  = "\\$"
    go '`'  = "\\`"
    go c    = [c]

-- | Simple shell escaping for individual arguments.
-- Wraps in single quotes and escapes embedded single quotes.
shellEscape :: Text -> Text
shellEscape t
  | T.null t = "''"
  | T.all isSafe t = t
  | otherwise = "'" <> T.replace "'" "'\\''" t <> "'"
  where
    isSafe c = c `elem` (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "-_./=:@")

-- | Start a tmux session with the given name if not already running.
-- Creates a detached session with 300x100 dimensions.
startTmuxSession :: Text -> IO (Either HarnessError ())
startTmuxSession sessionName = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      exists <- sessionExists sessionName
      if exists
        then pure (Right ())
        else do
          exitCode <- runTmuxSilent
            [ "new-session", "-d"
            , "-s", T.unpack sessionName
            , "-x", "300"
            , "-y", "100"
            ]
          case exitCode of
            ExitSuccess   -> pure (Right ())
            ExitFailure _ -> pure (Left HarnessTmuxNotAvailable)

-- | Check if a tmux session with the given name exists.
sessionExists :: Text -> IO Bool
sessionExists sessionName = do
  exitCode <- runTmuxSilent ["has-session", "-t", T.unpack sessionName]
  pure (exitCode == ExitSuccess)

-- | Add a window to a tmux session for a harness.
-- Uses stealth mode: env -u TMUX, script -c for fresh PTY.
addHarnessWindow :: Text -> Text -> FilePath -> [Text] -> IO (Either HarnessError ())
addHarnessWindow sessionName windowName binary args = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      let stealthCmd = stealthShellCommand binary args
      exitCode <- runTmuxSilent
        [ "new-window"
        , "-t", T.unpack sessionName
        , "-n", T.unpack windowName
        , stealthCmd
        ]
      case exitCode of
        ExitSuccess   -> pure (Right ())
        ExitFailure _ -> pure (Left HarnessTmuxNotAvailable)

-- | Send input to a harness window.
-- Small input (<= 256 bytes) uses send-keys.
-- Large input (> 256 bytes) uses load-buffer + paste-buffer.
sendToWindow :: Text -> Text -> ByteString -> IO ()
sendToWindow sessionName windowName input
  | BC.length input <= 256 = sendKeysSmall sessionName windowName input
  | otherwise              = sendKeysLarge sessionName windowName input

-- | Send small input via tmux send-keys.
sendKeysSmall :: Text -> Text -> ByteString -> IO ()
sendKeysSmall sessionName windowName input = do
  let target = T.unpack sessionName <> ":" <> T.unpack windowName
  _ <- runTmuxSilent ["send-keys", "-t", target, BC.unpack input, "Enter"]
  pure ()

-- | Send large input via tmux load-buffer + paste-buffer.
sendKeysLarge :: Text -> Text -> ByteString -> IO ()
sendKeysLarge sessionName windowName input = do
  let target = T.unpack sessionName <> ":" <> T.unpack windowName
  Temp.withSystemTempFile "pureclaw-tmux-input" $ \tmpPath tmpHandle -> do
    BC.hPut tmpHandle input
    IO.hClose tmpHandle
    _ <- runTmuxSilent ["load-buffer", tmpPath]
    _ <- runTmuxSilent ["paste-buffer", "-t", target]
    _ <- runTmuxSilent ["send-keys", "-t", target, "Enter"]
    pure ()

-- | Capture output from a harness window (scrollback, last N lines).
-- Strips ANSI escape sequences from the captured output.
captureWindow :: Text -> Int -> IO ByteString
captureWindow sessionName lineCount = do
  let target = T.unpack sessionName
      config = P.setStdin P.closed
             $ P.setStdout P.byteStringOutput
             $ P.setStderr P.nullStream
             $ P.proc "tmux"
                 [ "capture-pane", "-t", target
                 , "-p"
                 , "-S", "-" <> show lineCount
                 ]
  (exitCode, stdout, _stderr) <- P.readProcess config
  case exitCode of
    ExitSuccess   -> pure (stripAnsi (LBS.toStrict stdout))
    ExitFailure _ -> pure ""

-- | Strip ANSI escape sequences from a ByteString.
-- Matches ESC [ ... (letter or @) sequences.
stripAnsi :: ByteString -> ByteString
stripAnsi = go
  where
    go input
      | BC.null input = BC.empty
      | otherwise =
          let (before, rest) = BC.break (== '\ESC') input
          in if BC.null rest
             then before
             else before <> skipEsc (BC.drop 1 rest)
    skipEsc input
      | BC.null input = BC.empty
      | BC.head input == '[' = skipCsi (BC.drop 1 input)
      | otherwise = go (BC.drop 1 input)
    skipCsi input
      | BC.null input = BC.empty
      | let c = BC.head input
      , c >= '@' && c <= '~' = go (BC.drop 1 input)
      | otherwise = skipCsi (BC.drop 1 input)

-- | Display text in a harness window (for tee-style mirroring).
-- Uses send-keys to echo the text.
tmuxDisplay :: Text -> ByteString -> IO ()
tmuxDisplay sessionName content = do
  let target = T.unpack sessionName
  _ <- runTmuxSilent ["send-keys", "-t", target, BC.unpack content, ""]
  pure ()

-- | Kill the entire tmux session. Idempotent -- does not fail if session
-- does not exist.
stopTmuxSession :: Text -> IO ()
stopTmuxSession sessionName = do
  _ <- runTmuxSilent ["kill-session", "-t", T.unpack sessionName]
  pure ()

-- | Kill a specific harness window within a session.
stopHarnessWindow :: Text -> Text -> IO ()
stopHarnessWindow sessionName windowName = do
  let target = T.unpack sessionName <> ":" <> T.unpack windowName
  _ <- runTmuxSilent ["kill-window", "-t", target]
  pure ()
