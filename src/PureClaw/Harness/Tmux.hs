-- |
-- == Scope note (post-WU4)
--
-- For NEW code, the canonical shell-quoter lives in
-- 'PureClaw.Internal.ShellQuote'. The local re-exports
-- 'shellEscape' / 'shellEscapeStr' here delegate to it. The
-- double-quote variant 'escapeForShell' and the @sh -c@-based
-- 'stealthShellCommand' remain local because they are specific to
-- the existing Claude Code supervision flow; they will retire when
-- the future TmuxRpc work refactors the harness.
--
-- See @docs\/terminal-backend-abstractions.md@
-- § \"Remote arg quoting\" and § \"Scope of Harness.Tmux migration\".
module PureClaw.Harness.Tmux
  ( -- * tmux availability
    requireTmux
  , findTmux
  , checkTmuxCapabilities
    -- * Session lifecycle
  , startTmuxSession
  , startTmuxSessionStatus
  , TmuxSessionStatus (..)
  , stopTmuxSession
  , listTmuxSessions
    -- * Window management (index-based, legacy)
  , addHarnessWindow
  , stopHarnessWindow
  , renameWindow
  , listSessionWindows
    -- * Window management (name-based, WU1)
  , windowTarget
  , addHarnessWindowNamed
  , stopHarnessWindowNamed
  , renameWindowNamed
    -- * Identity markers (WU1)
  , setWindowMarker
  , setRemainOnExit
  , readMarkers
  , showWindowOption
  , TmuxWindowRow (..)
  , parseMarkerRows
    -- * PID provenance (WU1)
  , harnessPidOf
  , selectHarnessPid
  , parsePsRows
    -- * Pure output helpers (unit-testable)
  , stripAnsi
  , escapeForShell
    -- * I/O (index-based, legacy)
  , sendToWindow
  , captureWindow
  , tmuxDisplay
    -- * I/O (name-based, WU1)
  , sendToWindowNamed
  , captureWindowNamed
    -- * Pure argv builders (WU1, unit-testable)
  , sendKeysNamedArgs
  , pasteBufferNamedArgs
  , captureNamedArgs
  , killWindowNamedArgs
  , renameWindowNamedArgs
  , newWindowNamedArgs
  , setWindowMarkerArgs
  , setRemainOnExitArgs
    -- * Stealth mode
  , stealthShellCommand
    -- * Shell quoting (delegates to 'PureClaw.Internal.ShellQuote')
  , shellEscape
  , shellEscapeStr
    -- * tmux authorization seam (WU3 — sole chokepoint for tmux subprocesses)
  , tmuxProc
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Set (Set)
import Data.Set qualified as Set
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
import PureClaw.Internal.ShellQuote qualified as ShellQuote
import PureClaw.Security.Command qualified as Command

-- | The SOLE chokepoint for constructing a tmux subprocess. Every tmux
-- invocation in PureClaw builds its 'P.ProcessConfig' from an
-- 'Command.AuthorizedCommand' obtained via 'Command.authorizeTmuxCommand'
-- (the manager-owned tmux seam, §8 B1). After this helper has produced the
-- base config, callers apply the appropriate @setStdin@\/@setStdout@\/
-- @setStderr@ wrappers.
--
-- Because 'Command.AuthorizedCommand' has an un-exported value constructor and
-- 'Command.authorizeTmuxCommand' is the only tmux path to one, routing every
-- @tmux@ @P.proc@ through here makes an un-authorized tmux call impossible by
-- construction. Bare @P.proc tmuxBin@ must appear nowhere else.
--
-- TODO(harness-registry phase 2): audit-log tmux seam invocations once a
-- 'LogHandle' is threaded to the call sites (would change exported signatures,
-- out of scope for this additive refactor — see 'Command.authorizeTmuxCommand').
tmuxProc :: Command.AuthorizedCommand -> P.ProcessConfig () () ()
tmuxProc ac =
  P.proc (Command.getCommandProgram ac) (map T.unpack (Command.getCommandArgs ac))

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
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin (map T.pack args))
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

-- | Shell-escape a 'String' argument. Delegates to the canonical
-- quoter 'PureClaw.Internal.ShellQuote.shellQuoteString'; new code
-- should call that module directly.
shellEscapeStr :: String -> String
shellEscapeStr = ShellQuote.shellQuoteString

-- | Single-quote-wrap a 'Text' for inclusion as a shell argument.
-- Delegates to the canonical quoter
-- 'PureClaw.Internal.ShellQuote.shellQuote'; new code should call
-- that module directly.
shellEscape :: Text -> Text
shellEscape = ShellQuote.shellQuote

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
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     [ "capture-pane", "-t", T.pack target
                     , "-p"
                     , "-S", "-" <> T.pack (show lineCount)
                     ])
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
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     [ "list-windows", "-t", sessionName
                     , "-F", "#{window_index}\t#{window_name}"
                     ])
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

-- ============================================================================
-- WU1: name-based targeting, identity markers, PID provenance, capability check
--
-- These functions are ADDITIVE (orchestrator decision D-ADD-1): the existing
-- index-based functions above are kept unchanged until later work units migrate
-- their callers. New code should prefer the name-based variants — a tmux window
-- name (anchored to a durable @pcl_id marker) is a stabler target than a
-- mutable window index.
-- ============================================================================

-- | Render a tmux target string @\<session\>:\<windowName\>@.
--
-- This is the name-based analogue of the @session:index@ targets the legacy
-- index-based functions build. Pure; the single source of truth for how the
-- name-based ops below address a window.
windowTarget :: Text -> Text -> String
windowTarget sessionName windowName =
  T.unpack sessionName <> ":" <> T.unpack windowName

-- | Parse a non-negative 'Int' from 'Text', returning 'Nothing' on any
-- trailing garbage or empty input.
readIntMaybe :: Text -> Maybe Int
readIntMaybe t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _         -> Nothing

-- ---------------------------------------------------------------------------
-- Pure argv builders (unit-testable; the IO wrappers call straight through)
-- ---------------------------------------------------------------------------

-- | @send-keys@ argv for a small payload, targeting a window by name.
-- Appends @Enter@ to submit the line (mirrors 'sendKeysSmall').
sendKeysNamedArgs :: Text -> Text -> ByteString -> [String]
sendKeysNamedArgs sessionName windowName input =
  ["send-keys", "-t", windowTarget sessionName windowName, BC.unpack input, "Enter"]

-- | @paste-buffer@ argv targeting a window by name (large-payload path).
pasteBufferNamedArgs :: Text -> Text -> [String]
pasteBufferNamedArgs sessionName windowName =
  ["paste-buffer", "-t", windowTarget sessionName windowName]

-- | @capture-pane@ argv targeting a window by name, capturing the last
-- @lineCount@ lines of scrollback as plain text.
captureNamedArgs :: Text -> Text -> Int -> [String]
captureNamedArgs sessionName windowName lineCount =
  [ "capture-pane", "-t", windowTarget sessionName windowName
  , "-p", "-S", "-" <> show lineCount
  ]

-- | @kill-window@ argv targeting a window by name.
killWindowNamedArgs :: Text -> Text -> [String]
killWindowNamedArgs sessionName windowName =
  ["kill-window", "-t", windowTarget sessionName windowName]

-- | @rename-window@ argv: target the window by its current name, rename to the
-- new label.
renameWindowNamedArgs :: Text -> Text -> Text -> [String]
renameWindowNamedArgs sessionName windowName newLabel =
  ["rename-window", "-t", windowTarget sessionName windowName, T.unpack newLabel]

-- | @new-window@ argv creating a named window in a session, optionally honoring
-- a working directory (@-c@). The command string is run in the new window.
newWindowNamedArgs :: Text -> Text -> Maybe FilePath -> String -> [String]
newWindowNamedArgs sessionName windowName mWorkDir cmd =
  ["new-window", "-t", T.unpack sessionName, "-n", T.unpack windowName]
    <> dirArgs
    <> [cmd]
  where
    dirArgs = case mWorkDir of
      Just dir -> ["-c", dir]
      Nothing  -> []

-- | @set-option -w @pcl_id \<uuid\>@ argv — stamps the durable identity anchor
-- on a window (the re-find hint used by reconcile; see design §3).
setWindowMarkerArgs :: Text -> Text -> Text -> [String]
setWindowMarkerArgs sessionName windowName uuid =
  ["set-option", "-w", "-t", windowTarget sessionName windowName, "@pcl_id", T.unpack uuid]

-- | @set-option -w remain-on-exit on@ argv — required so a dead harness leaves
-- a @pane_dead@ pane in place (observable as @Exited@) instead of the window
-- vanishing (collapsing into @Orphaned@); see spike §11 E3.
setRemainOnExitArgs :: Text -> Text -> [String]
setRemainOnExitArgs sessionName windowName =
  ["set-option", "-w", "-t", windowTarget sessionName windowName, "remain-on-exit", "on"]

-- ---------------------------------------------------------------------------
-- Name-based I/O
-- ---------------------------------------------------------------------------

-- | Send input to a harness window addressed by name.
-- Small input (<= 256 bytes) uses @send-keys@; large input uses
-- @load-buffer@ + @paste-buffer@ (mirrors 'sendToWindow').
sendToWindowNamed :: Text -> Text -> ByteString -> IO ()
sendToWindowNamed sessionName windowName input
  | BC.length input <= 256 = do
      _ <- runTmuxSilent (sendKeysNamedArgs sessionName windowName input)
      pure ()
  | otherwise =
      Temp.withSystemTempFile "pureclaw-tmux-input" $ \tmpPath tmpHandle -> do
        BC.hPut tmpHandle input
        IO.hClose tmpHandle
        _ <- runTmuxSilent ["load-buffer", tmpPath]
        _ <- runTmuxSilent (pasteBufferNamedArgs sessionName windowName)
        _ <- runTmuxSilent ["send-keys", "-t", windowTarget sessionName windowName, "Enter"]
        pure ()

-- | Capture output from a harness window addressed by name, stripping ANSI
-- escape sequences (mirrors 'captureWindow').
captureWindowNamed :: Text -> Text -> Int -> IO ByteString
captureWindowNamed sessionName windowName lineCount = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     (map T.pack (captureNamedArgs sessionName windowName lineCount)))
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitSuccess   -> pure (stripAnsi (LBS.toStrict stdout))
        ExitFailure _ -> pure ""

-- | Kill a harness window addressed by name. Idempotent.
stopHarnessWindowNamed :: Text -> Text -> IO ()
stopHarnessWindowNamed sessionName windowName = do
  _ <- runTmuxSilent (killWindowNamedArgs sessionName windowName)
  pure ()

-- | Rename a harness window addressed by its current name.
renameWindowNamed :: Text -> Text -> Text -> IO ()
renameWindowNamed sessionName windowName newLabel = do
  _ <- runTmuxSilent (renameWindowNamedArgs sessionName windowName newLabel)
  pure ()

-- | Add a harness window addressed by name. If the session was just created
-- and still has its fresh default window 0, reuse it (send the command); else
-- create a new named window. Honors an optional working directory.
--
-- Mirrors 'addHarnessWindow' but targets and names by 'Text' rather than index.
addHarnessWindowNamed :: Text -> Text -> FilePath -> [Text] -> Maybe FilePath -> IO (Either HarnessError ())
addHarnessWindowNamed sessionName windowName binary args mWorkDir = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      let stealthCmd = stealthShellCommand binary args
      fresh <- isFreshDefaultWindow sessionName
      if fresh
        then do
          -- Reuse the session's fresh default window 0: name it, then run.
          renameWindowNamed sessionName "0" windowName
          case mWorkDir of
            Just dir -> do
              _ <- runTmuxSilent
                (sendKeysNamedArgs sessionName windowName (BC.pack ("cd " <> shellEscapeStr dir)))
              pure ()
            Nothing -> pure ()
          _ <- runTmuxSilent (sendKeysNamedArgs sessionName windowName (BC.pack stealthCmd))
          pure (Right ())
        else do
          (exitCode, _stderr) <- runTmux (newWindowNamedArgs sessionName windowName mWorkDir stealthCmd)
          case exitCode of
            ExitSuccess   -> pure (Right ())
            ExitFailure _ -> pure (Right ())

-- | A session has a \"fresh\" default window when it holds exactly one window
-- still named with tmux's default (a bare numeric index, e.g. @0@). Used to
-- decide whether 'addHarnessWindowNamed' should reuse window 0 or create a new
-- one (spike §11).
isFreshDefaultWindow :: Text -> IO Bool
isFreshDefaultWindow sessionName = do
  windows <- listSessionWindows sessionName
  pure $ case windows of
    [(idx, name)] -> name == T.pack (show idx)
    _             -> False

-- ---------------------------------------------------------------------------
-- Identity markers + server sweep
-- ---------------------------------------------------------------------------

-- | One row of a per-window tmux sweep, carrying the fields the registry needs
-- to identify and assess a harness window.
data TmuxWindowRow = TmuxWindowRow
  { _twr_windowIndex :: !Int          -- ^ @#{window_index}@
  , _twr_windowName  :: !Text         -- ^ @#{window_name}@
  , _twr_pclId       :: !Text         -- ^ @#{@pcl_id}@ (empty if unset)
  , _twr_panePid     :: !(Maybe Int)  -- ^ @#{pane_pid}@ (shell PID)
  , _twr_paneDead    :: !Bool         -- ^ @#{pane_dead}@ (True when the pane process has exited)
  }
  deriving stock (Eq, Show)

-- | The format string used for the 'readMarkers' sweep. Tab-separated so the
-- parser can split tolerantly (window names may contain spaces but not tabs).
markerFormat :: String
markerFormat =
  "#{window_index}\t#{window_name}\t#{@pcl_id}\t#{pane_pid}\t#{pane_dead}"

-- | Set the durable @pcl_id identity marker on a named window.
setWindowMarker :: Text -> Text -> Text -> IO ()
setWindowMarker sessionName windowName uuid = do
  _ <- runTmuxSilent (setWindowMarkerArgs sessionName windowName uuid)
  pure ()

-- | Enable @remain-on-exit@ on a named window (spike §11 E3).
setRemainOnExit :: Text -> Text -> IO ()
setRemainOnExit sessionName windowName = do
  _ <- runTmuxSilent (setRemainOnExitArgs sessionName windowName)
  pure ()

-- | One server sweep of a session: return per-window rows including the
-- @pcl_id marker, the shell PID, and the pane-dead flag. Returns an empty list
-- if the session does not exist or tmux is unavailable.
readMarkers :: Text -> IO [TmuxWindowRow]
readMarkers sessionName = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure []
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     [ "list-windows", "-t", sessionName, "-F", T.pack markerFormat ])
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitFailure _ -> pure []
        ExitSuccess   -> pure (parseMarkerRows (LBS.toStrict stdout))

-- | Parse the tab-separated 'readMarkers' output into 'TmuxWindowRow's.
-- Tolerant: lines with fewer than five fields, or an unparseable window index,
-- are skipped; an unparseable @pane_pid@ yields 'Nothing'; @pane_dead@ is
-- @True@ iff the field is exactly @1@.
parseMarkerRows :: ByteString -> [TmuxWindowRow]
parseMarkerRows bs =
  [ TmuxWindowRow
      { _twr_windowIndex = idx
      , _twr_windowName  = name
      , _twr_pclId       = pclId
      , _twr_panePid     = readIntMaybe panePidT
      , _twr_paneDead    = paneDeadT == "1"
      }
  | line <- BC.lines bs
  , let fields = T.splitOn "\t" (TE.decodeUtf8Lenient line)
  , (idxT : name : pclId : panePidT : paneDeadT : _) <- [fields]
  , Just idx <- [readIntMaybe idxT]
  ]

-- | Read back a single window option value (e.g. @remain-on-exit@) for a named
-- window via @show-options -w -v@. Returns an empty 'Text' on failure.
showWindowOption :: Text -> Text -> Text -> IO Text
showWindowOption sessionName windowName optName = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     [ "show-options", "-w", "-v"
                     , "-t", T.pack (windowTarget sessionName windowName)
                     , optName
                     ])
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitSuccess   -> pure (T.strip (TE.decodeUtf8Lenient (LBS.toStrict stdout)))
        ExitFailure _ -> pure ""

-- ---------------------------------------------------------------------------
-- Session listing + created-vs-existed lifecycle
-- ---------------------------------------------------------------------------

-- | List all tmux session names on the running server. Empty list if tmux is
-- absent or no sessions exist.
listTmuxSessions :: IO [Text]
listTmuxSessions = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure []
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                     ["list-sessions", "-F", "#{session_name}"])
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitFailure _ -> pure []
        ExitSuccess   ->
          pure [ T.strip ln
               | line <- BC.lines (LBS.toStrict stdout)
               , let ln = TE.decodeUtf8Lenient line
               , not (T.null (T.strip ln))
               ]

-- | Whether 'startTmuxSessionStatus' created a new session or found an
-- existing one.
data TmuxSessionStatus
  = TmuxSessionCreated
  | TmuxSessionExisted
  deriving stock (Eq, Show)

-- | Like 'startTmuxSession', but reports whether the session was newly created
-- or already existed. Does NOT change 'startTmuxSession' (D-ADD-1).
startTmuxSessionStatus :: Text -> IO (Either HarnessError TmuxSessionStatus)
startTmuxSessionStatus sessionName = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      exists <- sessionExists sessionName
      if exists
        then pure (Right TmuxSessionExisted)
        else do
          (exitCode, stderr) <- runTmux
            [ "new-session", "-d"
            , "-s", T.unpack sessionName
            , "-x", "300"
            , "-y", "100"
            ]
          case exitCode of
            ExitSuccess   -> pure (Right TmuxSessionCreated)
            ExitFailure c -> pure (Left (HarnessTmuxNotAvailable
              ("tmux new-session failed (exit " <> T.pack (show c) <> "): "
                <> TE.decodeUtf8Lenient stderr)))

-- ---------------------------------------------------------------------------
-- PID provenance
-- ---------------------------------------------------------------------------

-- | Given a pane shell PID and the flavour binary name (the @comm@ to match),
-- find the harness process PID by walking the process subtree rooted at the
-- pane PID and matching @comm@.
--
-- NEVER a global @pgrep@\/@grep@ (spike §11 METHOD: a global match kills
-- unrelated processes). On macOS the wrapper exec-collapses so the binary is a
-- direct child (spike §11 E2); on Linux it may be a grandchild via @sh -c@ —
-- the recursive descent handles both.
--
-- Pure over @(pid, ppid, comm)@ rows; chooses the shallowest matching
-- descendant (BFS) so a direct child wins over a deeper one.
--
-- The @(pid, ppid)@ table is untrusted (parsed from @ps@ output, or in tests
-- from arbitrary fixtures) and may describe a cycle — a self-parent
-- (@pid == ppid@), a mutual cycle, or any longer loop. A visited-set bounds the
-- descent so it is total over arbitrary rows: every PID is enqueued at most
-- once, so the BFS terminates on any cycle and still returns the correct
-- shallowest match (or 'Nothing' when no descendant matches).
selectHarnessPid :: Int -> Text -> [(Int, Int, Text)] -> Maybe Int
selectHarnessPid paneShellPid flavourComm rows =
  bfs (Set.singleton paneShellPid) [paneShellPid]
  where
    -- BFS over the descendant frontier; at each level prefer a comm match.
    -- @visited@ accumulates every PID already enqueued so a cyclic table cannot
    -- re-enqueue a node and loop forever.
    bfs :: Set Int -> [Int] -> Maybe Int
    bfs _       []      = Nothing
    bfs visited parents =
      let kids = [ (pid, comm) | (pid, ppid, comm) <- rows, ppid `elem` parents ]
      in case [ pid | (pid, comm) <- kids, comm == flavourComm ] of
           (p : _) -> Just p
           []      ->
             -- Descend only into children not yet visited; otherwise a cycle
             -- (a ppid pointing back at an ancestor) would loop forever.
             let nextPids = filter (`Set.notMember` visited) (map fst kids)
             in bfs (foldr Set.insert visited nextPids) nextPids

-- | IO wrapper around 'selectHarnessPid': gather @(pid, ppid, comm)@ rows via
-- @ps -axo pid=,ppid=,comm=@ and select the harness PID descending from the
-- pane shell PID. Returns 'Nothing' if @ps@ is unavailable or no match is
-- found.
harnessPidOf :: Int -> Text -> IO (Maybe Int)
harnessPidOf paneShellPid flavourComm = do
  let config = P.setStdin P.closed
             $ P.setStdout P.byteStringOutput
             $ P.setStderr P.nullStream
             $ P.proc "ps" ["-axo", "pid=,ppid=,comm="]
  (exitCode, stdout, _stderr) <- P.readProcess config
  case exitCode of
    ExitFailure _ -> pure Nothing
    ExitSuccess   -> pure (selectHarnessPid paneShellPid flavourComm (parsePsRows (LBS.toStrict stdout)))

-- | Parse @ps -axo pid=,ppid=,comm=@ output into @(pid, ppid, comm)@ rows.
-- Each line is whitespace-separated: pid, ppid, then the command (the basename
-- of the executable path; tmux's @comm@ matching uses the basename).
parsePsRows :: ByteString -> [(Int, Int, Text)]
parsePsRows bs =
  [ (pid, ppid, comm)
  | line <- BC.lines bs
  , let ws = T.words (TE.decodeUtf8Lenient line)
  , (pidT : ppidT : rest) <- [ws]
  , not (null rest)
  , let comm = lastSegment (T.unwords rest)
  , Just pid  <- [readIntMaybe pidT]
  , Just ppid <- [readIntMaybe ppidT]
  ]
  where
    -- comm may be a full path on some ps variants; take the basename so it
    -- matches the flavour binary name (e.g. "claude").
    lastSegment = T.takeWhileEnd (/= '/')

-- ---------------------------------------------------------------------------
-- Capability check
-- ---------------------------------------------------------------------------

-- | Confirm the running tmux supports the formats the registry depends on:
-- the @pcl_id user-option and the @#{pane_dead}@ format variable. Probes by
-- asking tmux to expand a format string and checking the output is well-formed
-- (tmux leaves an unknown @#{...}@ literal, or errors, when unsupported).
--
-- Returns @Right ()@ when supported; @Left HarnessTmuxNotAvailable@ (with a
-- diagnostic the caller can warn on and then degrade) otherwise.
checkTmuxCapabilities :: IO (Either HarnessError ())
checkTmuxCapabilities = do
  tmuxCheck <- requireTmux
  case tmuxCheck of
    Left err -> pure (Left err)
    Right () -> do
      mPath <- findTmux
      case mPath of
        Nothing -> pure (Left (HarnessTmuxNotAvailable "tmux not found"))
        Just tmuxBin -> do
          -- Expand a probe format. A capable tmux substitutes #{pane_dead}
          -- with 0/1 and #{@pcl_id} with the (empty) marker, yielding a line
          -- that contains neither a literal "#{" nor "pane_dead".
          let config = P.setStdin P.closed
                     $ P.setStdout P.byteStringOutput
                     $ P.setStderr P.byteStringOutput
                     $ tmuxProc (Command.authorizeTmuxCommand tmuxBin
                         [ "display-message", "-p", "PCLCAP:#{pane_dead}:#{@pcl_id}:" ])
          (exitCode, stdout, _stderr) <- P.readProcess config
          let out = TE.decodeUtf8Lenient (LBS.toStrict stdout)
          case exitCode of
            ExitFailure _ ->
              pure (Left (HarnessTmuxNotAvailable
                "tmux does not support the required @pcl_id/pane_dead formats"))
            ExitSuccess
              | "PCLCAP:" `T.isInfixOf` out
              , not ("#{" `T.isInfixOf` out)
              , not ("pane_dead" `T.isInfixOf` out) ->
                  pure (Right ())
              | otherwise ->
                  pure (Left (HarnessTmuxNotAvailable
                    "tmux does not support the required @pcl_id/pane_dead formats"))
