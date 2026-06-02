module PureClaw.Harness.ClaudeCode
  ( -- * Construction
    mkClaudeCodeHarness
  , mkClaudeCodeHarnessWith
  , mkDiscoveredClaudeCodeHandle
    -- * Injectable dependencies (D4.2 / D4.3 seam)
  , ClaudeCodeDeps (..)
  , defaultClaudeCodeDeps
    -- * Response extraction (exported for testing)
  , extractLastResponse
  , isIdle
  , isResponseMarker
  , isUiBoundary
  ) where

import Control.Concurrent
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding qualified as TE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import System.Directory qualified as Dir
import System.Exit
import System.Process.Typed qualified as P
import PureClaw.Handles.Harness
import PureClaw.Handles.Transcript
import PureClaw.Harness.Registry (HarnessId, HarnessRegistry)
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Transcript.Types

-- ---------------------------------------------------------------------------
-- Injectable dependencies
-- ---------------------------------------------------------------------------

-- | The injectable tmux\/identity operations a Claude Code harness needs.
--
-- This record is the dependency-injection seam for the spawn-identity sequence
-- (D4.2) and the cached-coordinate, self-healing handle (D4.3): tests supply
-- fakes that record calls and simulate a tmux \"no such window\" so the
-- re-resolve path runs without a real tmux server. The production set is
-- 'defaultClaudeCodeDeps'.
--
-- The name-based I\/O ops report /found/-vs-/not found/ so the handle can
-- re-resolve its coordinate (a renamed\/moved window) by sweeping for its
-- @\@pcl_id@ and retrying once (design §4 \/ K3).
data ClaudeCodeDeps = ClaudeCodeDeps
  { _ccd_newId        :: IO HarnessId
    -- ^ Generate a fresh 'HarnessId' (production: 'Reg.newHarnessId').
  , _ccd_findClaude   :: IO (Maybe FilePath)
    -- ^ Locate the @claude@ binary (production: @findExecutable \"claude\"@).
  , _ccd_checkTmux    :: IO (Either HarnessError ())
    -- ^ Confirm tmux is available (production: 'requireTmux').
  , _ccd_addWindow    :: Text -> Text -> FilePath -> [Text] -> Maybe FilePath -> IO (Either HarnessError ())
    -- ^ Create the harness window: @session windowName binary args workDir@
    --   (production: 'addHarnessWindowNamed').
  , _ccd_startSession :: Text -> IO (Either HarnessError ())
    -- ^ Ensure the tmux session exists (production: 'startTmuxSession').
  , _ccd_setMarker    :: Text -> Text -> Text -> IO ()
    -- ^ Stamp the @\@pcl_id@ marker: @session windowName uuidText@
    --   (production: 'setWindowMarker').
  , _ccd_setRemain    :: Text -> Text -> IO ()
    -- ^ Set @remain-on-exit on@: @session windowName@ (production:
    --   'setRemainOnExit').
  , _ccd_panePidOf    :: Text -> Text -> IO (Maybe Int)
    -- ^ Read the pane shell PID for @session windowName@ from a sweep
    --   (production: derive from 'readMarkers').
  , _ccd_harnessPidOf :: Int -> Text -> IO (Maybe Int)
    -- ^ Derive the harness-process PID from a pane shell PID + flavour comm
    --   (production: 'harnessPidOf').
  , _ccd_sweep        :: Text -> IO [TmuxWindowRow]
    -- ^ One server sweep of a session (production: 'readMarkers'). Used by the
    --   re-resolve path to find a moved window by its @\@pcl_id@.
  , _ccd_sendNamed    :: Text -> Text -> ByteString -> IO Bool
    -- ^ Send input to @session windowName@; 'True' iff the window was found.
  , _ccd_captureNamed :: Text -> Text -> Int -> IO (Maybe ByteString)
    -- ^ Capture from @session windowName@; 'Nothing' iff the window was not
    --   found ('Just' empty is a present-but-blank pane).
  , _ccd_stopNamed    :: Text -> Text -> IO ()
    -- ^ Kill @session windowName@ (production: 'stopHarnessWindowNamed').
  , _ccd_status       :: Text -> Text -> IO HarnessStatus
    -- ^ Check liveness of @session windowName@.
  }

-- | The comm name of the flavour binary used for harness-PID derivation.
claudeComm :: Text
claudeComm = "claude"

-- | Production dependency set: every op wired to the real tmux primitives.
-- All tmux subprocesses flow through the WU3 authorization seam
-- ('authorizeTmuxCommand' \/ 'tmuxProc') — never a bare @P.proc tmux@.
defaultClaudeCodeDeps :: ClaudeCodeDeps
defaultClaudeCodeDeps = ClaudeCodeDeps
  { _ccd_newId        = Reg.newHarnessId
  , _ccd_findClaude   = Dir.findExecutable "claude"
  , _ccd_checkTmux    = requireTmux
  , _ccd_addWindow    = addHarnessWindowNamed
  , _ccd_startSession = startTmuxSession
  , _ccd_setMarker    = setWindowMarker
  , _ccd_setRemain    = setRemainOnExit
  , _ccd_panePidOf    = realPanePidOf
  , _ccd_harnessPidOf = harnessPidOf
  , _ccd_sweep        = readMarkers
  , _ccd_sendNamed    = realSendNamed
  , _ccd_captureNamed = realCaptureNamed
  , _ccd_stopNamed    = stopHarnessWindowNamed
  , _ccd_status       = realStatus
  }

-- | Read the pane shell PID for a window by sweeping the session and matching
-- the window name.
realPanePidOf :: Text -> Text -> IO (Maybe Int)
realPanePidOf session windowName = do
  rows <- readMarkers session
  pure (find ((== windowName) . _twr_windowName) rows >>= _twr_panePid)

-- | Send to a named window through the WU3 tmux seam, reporting whether the
-- window was found. tmux exits non-zero when @-t@ targets a missing window.
realSendNamed :: Text -> Text -> ByteString -> IO Bool
realSendNamed session windowName input = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure False
    Just tmuxBin -> do
      let args = sendKeysNamedArgs session windowName input
          config = P.setStdin P.closed
                 $ P.setStdout P.nullStream
                 $ P.setStderr P.nullStream
                 $ tmuxProc (authorizeTmuxCommand tmuxBin (map T.pack args))
      exitCode <- P.runProcess config
      pure (exitCode == ExitSuccess)

-- | Capture from a named window through the WU3 tmux seam. 'Nothing' signals a
-- missing window (tmux exit non-zero); 'Just' carries the (ANSI-stripped) bytes.
realCaptureNamed :: Text -> Text -> Int -> IO (Maybe ByteString)
realCaptureNamed session windowName lineCount = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure Nothing
    Just tmuxBin -> do
      let args = captureNamedArgs session windowName lineCount
          config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (authorizeTmuxCommand tmuxBin (map T.pack args))
      (exitCode, stdout, _stderr) <- P.readProcess config
      pure $ case exitCode of
        ExitSuccess   -> Just (LBS.toStrict stdout)
        ExitFailure _ -> Nothing

-- | Window-status check by name through the WU3 tmux seam: a present window is
-- 'HarnessRunning'; a missing one is 'HarnessExited'.
realStatus :: Text -> Text -> IO HarnessStatus
realStatus session windowName = do
  mTmux <- findTmux
  case mTmux of
    Nothing -> pure (HarnessExited (ExitFailure 127))
    Just tmuxBin -> do
      exitCode <- P.runProcess
        $ P.setStdin P.closed
        $ P.setStdout P.nullStream
        $ P.setStderr P.nullStream
        $ tmuxProc (authorizeTmuxCommand tmuxBin
            ["list-windows", "-t", T.pack (windowTarget session windowName)
            , "-F", "#{window_name}"])
      pure $ case exitCode of
        ExitSuccess      -> HarnessRunning
        ExitFailure code -> HarnessExited (ExitFailure code)

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a Claude Code harness using the production dependency set.
--
-- On success it has stamped the durable @\@pcl_id@ identity marker, enabled
-- @remain-on-exit@, recorded the shell + harness PIDs, and registered a
-- @Spawned@ 'Reg.HarnessEntry' in the registry. The returned 'HarnessId' lets
-- the caller persist the identity and sync the legacy name-keyed map.
mkClaudeCodeHarness
  :: SecurityPolicy
  -> TranscriptHandle
  -> Text             -- ^ tmux session name (default @"pureclaw"@)
  -> Text             -- ^ tmux window name (display-only, e.g. @claude-code-0@)
  -> Int              -- ^ tmux window index (placement hint for the new window)
  -> Maybe FilePath   -- ^ optional working directory
  -> [Text]           -- ^ extra CLI arguments (e.g. --dangerously-skip-permissions)
  -> HarnessRegistry  -- ^ the durable registry to register the spawned entry into
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
mkClaudeCodeHarness = mkClaudeCodeHarnessWith defaultClaudeCodeDeps

-- | Testable variant with injectable dependencies ('ClaudeCodeDeps').
mkClaudeCodeHarnessWith
  :: ClaudeCodeDeps
  -> SecurityPolicy
  -> TranscriptHandle
  -> Text             -- ^ tmux session name
  -> Text             -- ^ tmux window name
  -> Int              -- ^ tmux window index
  -> Maybe FilePath   -- ^ optional working directory
  -> [Text]           -- ^ extra CLI arguments
  -> HarnessRegistry
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
mkClaudeCodeHarnessWith deps policy th session windowName _windowIdx mWorkDir extraArgs reg =
  -- Step 1: Pre-check authorization (pure, no IO needed).
  case preAuthorize policy of
    Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
    Right () -> do
      -- Step 2: Check tmux availability
      tmuxResult <- _ccd_checkTmux deps
      case tmuxResult of
        Left err -> pure (Left err)
        Right () -> do
          -- Step 3: Find claude binary
          mClaudePath <- _ccd_findClaude deps
          case mClaudePath of
            Nothing -> pure (Left (HarnessBinaryNotFound "claude"))
            Just claudePath ->
              -- Step 4: Authorize the full command path
              case authorize policy claudePath [] of
                Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
                Right authorizedCmd -> do
                  let program = getCommandProgram authorizedCmd
                  -- Step 5: Start tmux session (idempotent)
                  sessionResult <- _ccd_startSession deps session
                  case sessionResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      -- Step 6: Add harness window (named)
                      windowResult <- _ccd_addWindow deps session windowName program extraArgs mWorkDir
                      case windowResult of
                        Left err -> pure (Left err)
                        Right () -> do
                          -- Step 6b: If unsafe mode, auto-confirm the safety prompt
                          when (hasUnsafeFlag extraArgs) $ do
                            threadDelay 2000000  -- 2s for the prompt to appear
                            _ <- _ccd_sendNamed deps session windowName ""
                            pure ()
                          -- Step 7: Establish identity (D4.2).
                          hid <- _ccd_newId deps
                          _ccd_setMarker deps session windowName (Reg.harnessIdToText hid)
                          _ccd_setRemain deps session windowName
                          mShellPid <- _ccd_panePidOf deps session windowName
                          mHarnessPid <- case mShellPid of
                            Just shellPid -> _ccd_harnessPidOf deps shellPid claudeComm
                            Nothing       -> pure Nothing
                          -- Step 8: Wire up the cached-coordinate handle (D4.3).
                          baselineRef <- newIORef BS.empty
                          let handle = HarnessHandle
                                { _hh_send    = harnessSend deps reg hid th baselineRef
                                , _hh_receive = harnessReceive deps reg hid th baselineRef
                                , _hh_name    = "Claude Code"
                                , _hh_session = session
                                , _hh_status  = harnessStatus deps reg hid
                                , _hh_stop    = harnessStop deps reg hid
                                }
                          -- Step 9: Register the Spawned entry (D4.2).
                          let entry = Reg.HarnessEntry
                                { Reg._he_id          = hid
                                , Reg._he_session     = session
                                , Reg._he_windowName  = windowName
                                , Reg._he_shellPid    = mShellPid
                                , Reg._he_harnessPid  = mHarnessPid
                                , Reg._he_origin      = Reg.OriginSpawned
                                , Reg._he_liveness    = Reg.LivenessIdle
                                , Reg._he_extModified = False
                                , Reg._he_stale       = False
                                , Reg._he_sessionId   = Nothing
                                , Reg._he_label       = windowName
                                , Reg._he_orphanedTicks = 0
                                , Reg._he_handle      = Just handle
                                }
                          Reg.insertEntry reg entry
                          pure (Right (hid, handle))

-- | Check whether the extra args include the unsafe/skip-permissions flag.
hasUnsafeFlag :: [Text] -> Bool
hasUnsafeFlag = elem "--dangerously-skip-permissions"

-- | Pre-authorize: check that the policy would allow "claude" at all.
preAuthorize :: SecurityPolicy -> Either CommandError ()
preAuthorize policy = case authorize policy "claude" [] of
  Left err -> Left err
  Right _  -> Right ()

-- ---------------------------------------------------------------------------
-- Cached-coordinate, self-healing handle (D4.3)
-- ---------------------------------------------------------------------------

-- | Read the current cached coordinate @(session, windowName)@ for a harness
-- from its registry entry. The handle does NOT close over a frozen window name
-- (design §4): it reads the live entry on every I\/O so the reconcile loop
-- (WU5) can update the coordinate underneath it.
currentCoord :: HarnessRegistry -> HarnessId -> IO (Maybe (Text, Text))
currentCoord reg hid = do
  mEntry <- Reg.lookupById reg hid
  pure (fmap (\e -> (Reg._he_session e, Reg._he_windowName e)) mEntry)

-- | Re-resolve a harness's window after a tmux \"no such window\": sweep the
-- session, find the row whose @\@pcl_id@ matches this harness's id, update the
-- cached '_he_windowName', and return the new name. 'Nothing' if no marked
-- window matches (the full reconcile loop is WU5; this is the minimal
-- one-shot heal).
reResolve :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> Text -> IO (Maybe Text)
reResolve deps reg hid session = do
  rows <- _ccd_sweep deps session
  let idText = Reg.harnessIdToText hid
  case find ((== idText) . _twr_pclId) rows of
    Nothing  -> pure Nothing
    Just row -> do
      let newName = _twr_windowName row
      mEntry <- Reg.lookupById reg hid
      case mEntry of
        Nothing -> pure ()
        Just e  -> Reg.insertEntry reg e { Reg._he_windowName = newName }
      pure (Just newName)

-- | Send input to the harness, logging the request. Reads the cached coordinate;
-- on a tmux \"no such window\" it re-resolves once by @\@pcl_id@ and retries.
harnessSend :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> TranscriptHandle -> IORef ByteString -> ByteString -> IO ()
harnessSend deps reg hid th _baselineRef input = do
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Request
        , _te_payload       = encodePayload input
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ()  -- entry vanished; nothing to target
    Just (session, windowName) -> do
      found <- _ccd_sendNamed deps session windowName input
      unless found $ do
        mNew <- reResolve deps reg hid session
        case mNew of
          Nothing      -> pure ()  -- could not heal; give up (WU5 owns reconcile)
          Just newName -> do
            _ <- _ccd_sendNamed deps session newName input
            pure ()

-- | Poll the harness window until idle, then capture and extract the last
-- response. Re-resolves the coordinate once on a tmux \"no such window\".
harnessReceive :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> TranscriptHandle -> IORef ByteString -> IO ByteString
harnessReceive deps reg hid th _baselineRef = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ""
    Just (session, windowName0) -> do
      -- Ensure the window is reachable; re-resolve once if not.
      windowName <- do
        probe <- _ccd_captureNamed deps session windowName0 1
        case probe of
          Just _  -> pure windowName0
          Nothing -> do
            mNew <- reResolve deps reg hid session
            pure (fromMaybe windowName0 mNew)
      startTime <- getCurrentTime
      pollUntilIdle session windowName startTime "" (0 :: Int)
      fullCapture <- fromMaybe "" <$> _ccd_captureNamed deps session windowName 0
      let responseText = extractLastResponse fullCapture
      entryId <- UUID.toText <$> UUID.nextRandom
      now <- getCurrentTime
      let entry = TranscriptEntry
            { _te_id            = entryId
            , _te_timestamp     = now
            , _te_harness       = Just "claude-code"
            , _te_model         = Nothing
            , _te_direction     = Response
            , _te_payload       = encodePayload responseText
            , _te_durationMs    = Nothing
            , _te_correlationId = entryId
            , _te_metadata      = Map.empty
            }
      _th_record th entry
      pure responseText
  where
    pollUntilIdle session windowName startTime lastScreen stableCount = do
      threadDelay 500000  -- 500ms
      current <- fromMaybe "" <$> _ccd_captureNamed deps session windowName 300
      now <- getCurrentTime
      let elapsed = diffUTCTime now startTime
          screenText = TE.decodeUtf8Lenient current
      if elapsed > 120
        then pure ()
        else if isIdle screenText
          then if current == lastScreen
            then if stableCount >= 2
              then pure ()
              else pollUntilIdle session windowName startTime current (stableCount + 1)
            else pollUntilIdle session windowName startTime current 0
          else pollUntilIdle session windowName startTime "" 0

-- | Check the harness window status via the cached coordinate.
harnessStatus :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> IO HarnessStatus
harnessStatus deps reg hid = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure (HarnessExited (ExitFailure 127))
    Just (session, windowName) -> _ccd_status deps session windowName

-- | Stop (kill) the harness window via the cached coordinate.
harnessStop :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> IO ()
harnessStop deps reg hid = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ()
    Just (session, windowName) -> _ccd_stopNamed deps session windowName

-- ---------------------------------------------------------------------------
-- Response extraction (pure)
-- ---------------------------------------------------------------------------

-- | Check if Claude Code is idle (showing prompt, not busy).
isIdle :: Text -> Bool
isIdle screen =
  let hasPrompt = T.isInfixOf "\x276F" screen   -- ❯
      isBusy    = T.isInfixOf "\x280B" screen    -- ⠋ (spinner)
                || T.isInfixOf "Thinking" screen
                || T.isInfixOf "Running" screen
  in hasPrompt && not isBusy

-- | Extract the last response block from Claude Code scrollback.
extractLastResponse :: ByteString -> ByteString
extractLastResponse capture =
  let allLines  = map TE.decodeUtf8Lenient (BS.split 0x0A capture)
      markerIdxs = [ i | (i, line) <- zip [0..] allLines
                       , isResponseMarker line ]
  in case markerIdxs of
    [] -> ""  -- no response found
    _  ->
      let startIdx   = last markerIdxs
          response   = takeWhile (not . isUiBoundary)
                     $ drop startIdx allLines
          cleaned    = case response of
            (firstLine : rest) -> stripMarker firstLine : rest
            []                 -> []
      in TE.encodeUtf8 (T.intercalate "\n" cleaned)

-- | Lines starting with ⏺ (U+23FA, BLACK CIRCLE FOR RECORD) are response markers.
isResponseMarker :: Text -> Bool
isResponseMarker line =
  T.isPrefixOf "\x23FA" (T.stripStart line)
  || T.isPrefixOf "\x2B24" (T.stripStart line)  -- ⬤ alternate marker

-- | UI boundaries that terminate response extraction.
isUiBoundary :: Text -> Bool
isUiBoundary line =
  let stripped = T.stripStart line
  in T.isPrefixOf "\x276F" stripped         -- ❯ input prompt
  || T.isPrefixOf "?" stripped
     && T.isInfixOf "shortcut" line         -- "? for shortcuts"
  || T.isInfixOf "\x2580\x2580" line        -- ▀▀ top bar
  || T.isInfixOf "\x2584\x2584" line        -- ▄▄ bottom bar
  || T.isInfixOf "\x2500\x2500\x2500" line  -- ─── horizontal rule

-- | Strip the response marker prefix (⏺ or ⬤) from a line.
stripMarker :: Text -> Text
stripMarker line =
  let stripped = T.stripStart line
  in if T.isPrefixOf "\x23FA" stripped || T.isPrefixOf "\x2B24" stripped
     then T.stripStart (T.drop 1 stripped)
     else line

-- ---------------------------------------------------------------------------
-- Discovered handle
-- ---------------------------------------------------------------------------

-- | Reconstruct a 'HarnessHandle' for an already-running Claude Code window
-- discovered via tmux. Used on startup to recover harness state.
--
-- This is the legacy, registry-less discovery path (the boot reconstruction
-- that builds registry entries is WU5). It targets the window by name directly
-- using the production tmux ops; it does NOT re-resolve (no registry entry to
-- update). The 'Text' session and window name are threaded through (D4.1).
mkDiscoveredClaudeCodeHandle :: TranscriptHandle -> Text -> Text -> IO HarnessHandle
mkDiscoveredClaudeCodeHandle th session windowName =
  pure HarnessHandle
    { _hh_send    = discoveredSend th session windowName
    , _hh_receive = discoveredReceive th session windowName
    , _hh_name    = "Claude Code"
    , _hh_session = session
    , _hh_status  = realStatus session windowName
    , _hh_stop    = stopHarnessWindowNamed session windowName
    }

-- | Send for a discovered (registry-less) handle: log the request, then send by
-- name. No re-resolve (no registry entry to heal).
discoveredSend :: TranscriptHandle -> Text -> Text -> ByteString -> IO ()
discoveredSend th session windowName input = do
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Request
        , _te_payload       = encodePayload input
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  _ <- realSendNamed session windowName input
  pure ()

-- | Receive for a discovered handle: poll until idle, capture, extract, log.
discoveredReceive :: TranscriptHandle -> Text -> Text -> IO ByteString
discoveredReceive th session windowName = do
  startTime <- getCurrentTime
  pollUntilIdle startTime "" (0 :: Int)
  fullCapture <- captureFullScrollbackNamed session windowName
  let responseText = extractLastResponse fullCapture
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Response
        , _te_payload       = encodePayload responseText
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  pure responseText
  where
    pollUntilIdle startTime lastScreen stableCount = do
      threadDelay 500000
      current <- fromMaybe "" <$> realCaptureNamed session windowName 300
      now <- getCurrentTime
      let elapsed = diffUTCTime now startTime
          screenText = TE.decodeUtf8Lenient current
      if elapsed > 120
        then pure ()
        else if isIdle screenText
          then if current == lastScreen
            then if stableCount >= 2
              then pure ()
              else pollUntilIdle startTime current (stableCount + 1)
            else pollUntilIdle startTime current 0
          else pollUntilIdle startTime "" 0

-- | Capture the full scrollback buffer (not just the visible pane) by name,
-- through the WU3 tmux seam. Returns empty on a missing window or tmux absence.
captureFullScrollbackNamed :: Text -> Text -> IO ByteString
captureFullScrollbackNamed session windowName = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (authorizeTmuxCommand tmuxBin
                     [ "capture-pane", "-t", T.pack (windowTarget session windowName)
                     , "-p", "-S", "-", "-E", "-"
                     ])
      (exitCode, stdout, _stderr) <- P.readProcess config
      pure $ case exitCode of
        ExitSuccess   -> LBS.toStrict stdout
        ExitFailure _ -> ""
