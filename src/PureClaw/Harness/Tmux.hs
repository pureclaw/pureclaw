module PureClaw.Harness.Tmux
  ( -- * tmux availability
    requireTmux
  , findTmux
    -- * Session lifecycle
  , startTmuxSession
  , stopTmuxSession
    -- * Window management
  , addHarnessWindow
  , stopHarnessWindow
  , renameWindow
  , listSessionWindows
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
import Data.Text.Encoding qualified as TE
import System.Directory qualified as Dir
import System.Exit
import System.IO qualified as IO
import System.Info qualified as Info
import System.IO.Temp qualified as Temp
import System.Process.Typed qualified as P

import PureClaw.Handles.Harness

-- | Resolve the absolute path to the tmux binary.
-- First checks PATH via 'findExecutable', then tries common system locations.
findTmux :: IO (Maybe FilePath)
findTmux = do
  mPath <- Dir.findExecutable "tmux"
  case mPath of
    Just p  -> pure (Just p)
    Nothing -> findFirstExisting fallbackPaths
  where
    fallbackPaths =
      [ "/opt/homebrew/bin/tmux"
      , "/usr/local/bin/tmux"
      , "/usr/bin/tmux"
      ]
    findFirstExisting [] = pure Nothing
    findFirstExisting (p : ps) = do
      exists <- Dir.doesFileExist p
      if exists then pure (Just p) else findFirstExisting ps

-- | Check if tmux is available on PATH.
requireTmux :: IO (Either HarnessError ())
requireTmux = do
  mPath <- findTmux
  pure $ case mPath of
    Nothing -> Left (HarnessTmuxNotAvailable "tmux not found on PATH or fallback locations")
    Just _  -> Right ()

-- | Run a tmux command, capturing stderr for diagnostics.
-- Returns the exit code and stderr output.
runTmux :: [String] -> IO (ExitCode, ByteString)
runTmux args = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure (ExitFailure 127, "tmux not found")
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.nullStream
                 $ P.setStderr P.byteStringOutput
                 $ P.proc tmuxBin args
      (exitCode, _stdout, stderr) <- P.readProcess config
      pure (exitCode, LBS.toStrict stderr)

-- | Run a tmux command silently. Returns just the exit code.
runTmuxSilent :: [String] -> IO ExitCode
runTmuxSilent args = fst <$> runTmux args

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

-- | Shell-escape a 'String' argument. Convenience wrapper around 'shellEscape'.
shellEscapeStr :: String -> String
shellEscapeStr = T.unpack . shellEscape . T.pack

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
          (exitCode, stderr) <- runTmux
            [ "new-session", "-d"
            , "-s", T.unpack sessionName
            , "-x", "300"
            , "-y", "100"
            ]
          case exitCode of
            ExitSuccess   -> pure (Right ())
            ExitFailure c -> pure (Left (HarnessTmuxNotAvailable
              ("tmux new-session failed (exit " <> T.pack (show c) <> "): "
                <> TE.decodeUtf8Lenient stderr)))

-- | Check if a tmux session with the given name exists.
sessionExists :: Text -> IO Bool
sessionExists sessionName = do
  exitCode <- runTmuxSilent ["has-session", "-t", T.unpack sessionName]
  pure (exitCode == ExitSuccess)

-- | Add a window to a tmux session for a harness at a specific window index.
-- Window 0 reuses the session's default window; higher indices create new windows.
-- Uses stealth mode: env -u TMUX, script -c for fresh PTY.
-- An optional working directory can be specified; for window 0 this sends a @cd@
-- before the command, for higher indices it uses @tmux new-window -c@.
addHarnessWindow :: Text -> Int -> FilePath -> [Text] -> Maybe FilePath -> IO (Either HarnessError ())
addHarnessWindow sessionName windowIdx binary args mWorkDir = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      let stealthCmd = stealthShellCommand binary args
          session = T.unpack sessionName
          target  = session <> ":" <> show windowIdx
      if windowIdx == 0
        then do
          -- Window 0 already exists from session creation — cd then send command
          case mWorkDir of
            Just dir -> do
              _ <- runTmuxSilent ["send-keys", "-t", target, "cd " <> shellEscapeStr dir, "Enter"]
              pure ()
            Nothing  -> pure ()
          _ <- runTmuxSilent ["send-keys", "-t", target, stealthCmd, "Enter"]
          pure (Right ())
        else do
          let baseArgs = [ "new-window", "-t", target ]
              dirArgs  = case mWorkDir of
                           Just dir -> ["-c", dir]
                           Nothing  -> []
          (exitCode, _stderr) <- runTmux (baseArgs <> dirArgs <> [stealthCmd])
          case exitCode of
            ExitSuccess   -> pure (Right ())
            ExitFailure _ -> pure (Right ())

-- | Send input to a harness window by index.
-- Small input (<= 256 bytes) uses send-keys.
-- Large input (> 256 bytes) uses load-buffer + paste-buffer.
sendToWindow :: Text -> Int -> ByteString -> IO ()
sendToWindow sessionName windowIdx input
  | BC.length input <= 256 = sendKeysSmall sessionName windowIdx input
  | otherwise              = sendKeysLarge sessionName windowIdx input

-- | Send small input via tmux send-keys.
sendKeysSmall :: Text -> Int -> ByteString -> IO ()
sendKeysSmall sessionName windowIdx input = do
  let target = T.unpack sessionName <> ":" <> show windowIdx
  _ <- runTmuxSilent ["send-keys", "-t", target, BC.unpack input, "Enter"]
  pure ()

-- | Send large input via tmux load-buffer + paste-buffer.
sendKeysLarge :: Text -> Int -> ByteString -> IO ()
sendKeysLarge sessionName windowIdx input = do
  let target = T.unpack sessionName <> ":" <> show windowIdx
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
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let target = T.unpack sessionName
          config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ P.proc tmuxBin
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

-- | Kill a specific harness window within a session by index.
stopHarnessWindow :: Text -> Int -> IO ()
stopHarnessWindow sessionName windowIdx = do
  let target = T.unpack sessionName <> ":" <> show windowIdx
  _ <- runTmuxSilent ["kill-window", "-t", target]
  pure ()

-- | Rename a window within a session.
renameWindow :: Text -> Int -> Text -> IO ()
renameWindow sessionName windowIdx label = do
  let target = T.unpack sessionName <> ":" <> show windowIdx
  _ <- runTmuxSilent ["rename-window", "-t", target, T.unpack label]
  pure ()

-- | List all windows in a tmux session, returning @(windowIndex, windowName)@ pairs.
-- Returns an empty list if the session does not exist or tmux is unavailable.
listSessionWindows :: Text -> IO [(Int, Text)]
listSessionWindows sessionName = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure []
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ P.proc tmuxBin
                     [ "list-windows", "-t", T.unpack sessionName
                     , "-F", "#{window_index}\t#{window_name}"
                     ]
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitFailure _ -> pure []
        ExitSuccess   -> pure (parseListing (LBS.toStrict stdout))
  where
    parseListing bs =
      [ (idx, name)
      | line <- BC.lines bs
      , let txt = TE.decodeUtf8Lenient line
      , (idxStr, rest) <- [T.break (== '\t') txt]
      , not (T.null rest)
      , let name = T.drop 1 rest  -- drop the tab
      , Just idx <- [readIndex idxStr]
      ]

    readIndex t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing
