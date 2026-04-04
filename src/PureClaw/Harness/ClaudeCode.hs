module PureClaw.Harness.ClaudeCode
  ( mkClaudeCodeHarness
  , mkClaudeCodeHarnessWith
  ) where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
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

-- | Session and window names used by the Claude Code harness.
sessionName :: Text
sessionName = "pureclaw"

windowName :: Text
windowName = "claude-code"

-- | Create a Claude Code harness using real system dependencies.
mkClaudeCodeHarness
  :: SecurityPolicy
  -> TranscriptHandle
  -> IO (Either HarnessError HarnessHandle)
mkClaudeCodeHarness =
  mkClaudeCodeHarnessWith
    (Dir.findExecutable "claude")
    requireTmux
    addHarnessWindow
    startTmuxSession

-- | Testable variant with injectable dependencies.
mkClaudeCodeHarnessWith
  :: IO (Maybe FilePath)                                                    -- ^ findExecutable "claude"
  -> IO (Either HarnessError ())                                            -- ^ requireTmux
  -> (Text -> Text -> FilePath -> [Text] -> IO (Either HarnessError ()))    -- ^ addHarnessWindow
  -> (Text -> IO (Either HarnessError ()))                                  -- ^ startTmuxSession
  -> SecurityPolicy
  -> TranscriptHandle
  -> IO (Either HarnessError HarnessHandle)
mkClaudeCodeHarnessWith findClaude checkTmux addWindow startSession policy th =
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
                      -- Step 6: Add harness window
                      windowResult <- addWindow sessionName windowName program []
                      case windowResult of
                        Left err -> pure (Left err)
                        Right () -> do
                          -- Step 7: Wire up the HarnessHandle
                          let handle = HarnessHandle
                                { _hh_send    = transcriptSend th
                                , _hh_receive = transcriptReceive th
                                , _hh_name    = "Claude Code"
                                , _hh_session = sessionName
                                , _hh_status  = checkWindowStatus th
                                , _hh_stop    = stopHarnessWindow sessionName windowName
                                }
                          pure (Right handle)

-- | Pre-authorize: check that the policy would allow "claude" at all.
-- This is a fast pure check before doing any IO (tmux, findExecutable, etc.).
preAuthorize :: SecurityPolicy -> Either CommandError ()
preAuthorize policy = case authorize policy "claude" [] of
  Left err -> Left err
  Right _  -> Right ()

-- | Send input to the Claude Code window with transcript logging.
transcriptSend :: TranscriptHandle -> ByteString -> IO ()
transcriptSend th input = do
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
  sendToWindow sessionName windowName input

-- | Capture output from the Claude Code window with transcript logging.
-- Uses withTranscript to wrap the capture call.
transcriptReceive :: TranscriptHandle -> IO ByteString
transcriptReceive th = do
  let target = sessionName <> ":" <> windowName
  output <- captureWindow target 300
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Response
        , _te_payload       = encodePayload output
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  pure output

-- | Check if the Claude Code tmux window is still running.
-- Uses @tmux list-windows@ to check if the window exists.
checkWindowStatus :: TranscriptHandle -> IO HarnessStatus
checkWindowStatus th = do
  exitCode <- P.runProcess
    $ P.setStdin P.closed
    $ P.setStdout P.nullStream
    $ P.setStderr P.nullStream
    $ P.proc "tmux" ["list-windows", "-t", "pureclaw", "-F", "#{window_name}"]
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
