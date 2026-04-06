module PureClaw.Harness.ClaudeCode
  ( mkClaudeCodeHarness
  , mkClaudeCodeHarnessWith
  , mkDiscoveredClaudeCodeHandle
    -- * Response extraction (exported for testing)
  , extractLastResponse
  , isIdle
  , isResponseMarker
  , isUiBoundary
  ) where

import Control.Concurrent
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
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
import PureClaw.Harness.Tmux
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Transcript.Types

-- | Session name used by the Claude Code harness.
sessionName :: Text
sessionName = "pureclaw"

-- | Create a Claude Code harness using real system dependencies.
-- The 'Int' is the tmux window index (0 for the first harness, 1 for the next, etc.).
mkClaudeCodeHarness
  :: SecurityPolicy
  -> TranscriptHandle
  -> Int
  -> Maybe FilePath   -- ^ optional working directory
  -> [Text]           -- ^ extra CLI arguments (e.g. --dangerously-skip-permissions)
  -> IO (Either HarnessError HarnessHandle)
mkClaudeCodeHarness =
  mkClaudeCodeHarnessWith
    (Dir.findExecutable "claude")
    requireTmux
    addHarnessWindow
    startTmuxSession

-- | Testable variant with injectable dependencies.
mkClaudeCodeHarnessWith
  :: IO (Maybe FilePath)                                                                -- ^ findExecutable "claude"
  -> IO (Either HarnessError ())                                                        -- ^ requireTmux
  -> (Text -> Int -> FilePath -> [Text] -> Maybe FilePath -> IO (Either HarnessError ()))  -- ^ addHarnessWindow
  -> (Text -> IO (Either HarnessError ()))                                              -- ^ startTmuxSession
  -> SecurityPolicy
  -> TranscriptHandle
  -> Int                                                                                -- ^ tmux window index
  -> Maybe FilePath                                                                     -- ^ optional working directory
  -> [Text]                                                                             -- ^ extra CLI arguments
  -> IO (Either HarnessError HarnessHandle)
mkClaudeCodeHarnessWith findClaude checkTmux addWindow startSession policy th windowIdx mWorkDir extraArgs =
  -- Step 1: Pre-check authorization (pure, no IO needed).
  -- This catches Deny autonomy and missing command allowlisting before any IO.
  case preAuthorize policy of
    Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
    Right () -> do
      -- Step 2: Check tmux availability
      tmuxResult <- checkTmux
      case tmuxResult of
        Left err -> pure (Left err)
        Right () -> do
          -- Step 3: Find claude binary
          mClaudePath <- findClaude
          case mClaudePath of
            Nothing -> pure (Left (HarnessBinaryNotFound "claude"))
            Just claudePath -> do
              -- Step 4: Authorize the full command path
              case authorize policy claudePath [] of
                Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
                Right authorizedCmd -> do
                  let program = getCommandProgram authorizedCmd
                  -- Step 5: Start tmux session (idempotent)
                  sessionResult <- startSession sessionName
                  case sessionResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      -- Step 6: Add harness window at the assigned index
                      windowResult <- addWindow sessionName windowIdx program extraArgs mWorkDir
                      case windowResult of
                        Left err -> pure (Left err)
                        Right () -> do
                          -- Step 7: Wire up the HarnessHandle
                          baselineRef <- newIORef BS.empty
                          let handle = HarnessHandle
                                { _hh_send    = harnesseSend th windowIdx baselineRef
                                , _hh_receive = harnessReceive th windowIdx baselineRef
                                , _hh_name    = "Claude Code"
                                , _hh_session = sessionName
                                , _hh_status  = checkWindowStatus th
                                , _hh_stop    = stopHarnessWindow sessionName windowIdx
                                }
                          pure (Right handle)

-- | Pre-authorize: check that the policy would allow "claude" at all.
-- This is a fast pure check before doing any IO (tmux, findExecutable, etc.).
preAuthorize :: SecurityPolicy -> Either CommandError ()
preAuthorize policy = case authorize policy "claude" [] of
  Left err -> Left err
  Right _  -> Right ()

-- | Send input to the Claude Code window and log the request.
harnesseSend :: TranscriptHandle -> Int -> IORef ByteString -> ByteString -> IO ()
harnesseSend th windowIdx _baselineRef input = do
  -- Log the request
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
  sendToWindow sessionName windowIdx input

-- | Poll the Claude Code window until idle, then extract the last response.
--
-- Idle = screen contains @❯@ and does not contain busy indicators.
-- Requires 3 consecutive stable captures before returning.
-- After stabilisation, captures full scrollback and extracts the last
-- response block (from the last @⏺@ marker to the next UI boundary).
-- Times out after 120 seconds.
harnessReceive :: TranscriptHandle -> Int -> IORef ByteString -> IO ByteString
harnessReceive th windowIdx _baselineRef = do
  let target = sessionName <> ":" <> T.pack (show windowIdx)
  startTime <- getCurrentTime
  -- Poll until Claude Code is idle and screen is stable
  pollUntilIdle target startTime "" (0 :: Int)
  -- Capture full scrollback and extract the last response
  fullCapture <- captureFullScrollback target
  let responseText = extractLastResponse fullCapture
  -- Log the response
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
    pollUntilIdle target startTime lastScreen stableCount = do
      threadDelay 500000  -- 500ms
      current <- captureWindow target 300
      now <- getCurrentTime
      let elapsed = diffUTCTime now startTime
          screenText = TE.decodeUtf8Lenient current
      if elapsed > 120
        then pure ()  -- timeout — extract whatever we have
        else if isIdle screenText
          then if current == lastScreen
            then if stableCount >= 2  -- 3 consecutive stable captures
              then pure ()
              else pollUntilIdle target startTime current (stableCount + 1)
            else pollUntilIdle target startTime current 0
          else pollUntilIdle target startTime "" 0

-- | Check if Claude Code is idle (showing prompt, not busy).
isIdle :: Text -> Bool
isIdle screen =
  let hasPrompt = T.isInfixOf "\x276F" screen   -- ❯
      isBusy    = T.isInfixOf "\x280B" screen    -- ⠋ (spinner)
                || T.isInfixOf "Thinking" screen
                || T.isInfixOf "Running" screen
  in hasPrompt && not isBusy

-- | Capture the full scrollback buffer (not just the visible pane).
captureFullScrollback :: Text -> IO ByteString
captureFullScrollback target = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ P.proc tmuxBin
                     [ "capture-pane", "-t", T.unpack target
                     , "-p"
                     , "-S", "-"   -- from start of scrollback
                     , "-E", "-"   -- to end of scrollback
                     ]
      (exitCode, stdout, _stderr) <- P.readProcess config
      case exitCode of
        ExitSuccess   -> pure (LBS.toStrict stdout)
        ExitFailure _ -> pure ""

-- | Extract the last response block from Claude Code scrollback.
--
-- Finds the last line starting with @\x23FA@ (⏺ — Claude's response marker),
-- collects lines until a UI boundary is hit.
extractLastResponse :: ByteString -> ByteString
extractLastResponse capture =
  let allLines  = map TE.decodeUtf8Lenient (BS.split 0x0A capture)
      -- Find the index of the last response marker
      markerIdxs = [ i | (i, line) <- zip [0..] allLines
                       , isResponseMarker line ]
  in case markerIdxs of
    [] -> ""  -- no response found
    _  ->
      let startIdx   = last markerIdxs
          response   = takeWhile (not . isUiBoundary)
                     $ drop startIdx allLines
          -- Strip the marker prefix from the first line
          cleaned    = case response of
            (first : rest) -> stripMarker first : rest
            []             -> []
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

-- | Check if the Claude Code tmux window is still running.
-- Uses @tmux list-windows@ to check if the window exists.
checkWindowStatus :: TranscriptHandle -> IO HarnessStatus
checkWindowStatus th = do
  mTmux <- findTmux
  case mTmux of
    Nothing -> pure (HarnessExited (ExitFailure 127))
    Just tmuxBin -> checkWithTmux tmuxBin th

checkWithTmux :: FilePath -> TranscriptHandle -> IO HarnessStatus
checkWithTmux tmuxBin th = do
  exitCode <- P.runProcess
    $ P.setStdin P.closed
    $ P.setStdout P.nullStream
    $ P.setStderr P.nullStream
    $ P.proc tmuxBin ["list-windows", "-t", "pureclaw", "-F", "#{window_name}"]
  case exitCode of
    ExitSuccess -> pure HarnessRunning
    ExitFailure code -> do
      -- Window or session is gone — log the event
      now <- getCurrentTime
      entryId <- UUID.toText <$> UUID.nextRandom
      let entry = TranscriptEntry
            { _te_id            = entryId
            , _te_timestamp     = now
            , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
            , _te_direction     = Response
            , _te_payload       = ""
            , _te_durationMs    = Nothing
            , _te_correlationId = entryId
            , _te_metadata      = Map.fromList
                [ ("event", Aeson.String "harness_exited")
                , ("exit_code", Aeson.toJSON code)
                ]
            }
      _th_record th entry
      pure (HarnessExited (ExitFailure code))

-- | Reconstruct a 'HarnessHandle' for an already-running Claude Code window
-- discovered via tmux. Used on startup to recover harness state.
mkDiscoveredClaudeCodeHandle :: TranscriptHandle -> Int -> IO HarnessHandle
mkDiscoveredClaudeCodeHandle th windowIdx = do
  baselineRef <- newIORef BS.empty
  pure HarnessHandle
    { _hh_send    = harnesseSend th windowIdx baselineRef
    , _hh_receive = harnessReceive th windowIdx baselineRef
    , _hh_name    = "Claude Code"
    , _hh_session = sessionName
    , _hh_status  = checkWindowStatus th
    , _hh_stop    = stopHarnessWindow sessionName windowIdx
    }
