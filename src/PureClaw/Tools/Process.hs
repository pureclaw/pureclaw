module PureClaw.Tools.Process
  ( -- * Tool registration
    processTool
  ) where

import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit

import PureClaw.Handles.Process
import PureClaw.Providers.Class
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Tools.Registry

-- | Create a process tool for background command management.
-- Supports: spawn, list, poll, kill, write_stdin.
processTool :: SecurityPolicy -> ProcessHandle -> (ToolDefinition, ToolHandler)
processTool policy ph = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "process"
      , _td_description = "Manage background processes. Actions: spawn (start a background command), list (show all), poll (check status and output), kill (terminate), write_stdin (send input)."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "action" .= object
                  [ "type" .= ("string" :: Text)
                  , "enum" .= (["spawn", "list", "poll", "kill", "write_stdin"] :: [Text])
                  , "description" .= ("The action to perform" :: Text)
                  ]
              , "command" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The command to run (for spawn)" :: Text)
                  ]
              , "id" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Process ID (for poll, kill, write_stdin)" :: Text)
                  ]
              , "input" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Input to send to stdin (for write_stdin)" :: Text)
                  ]
              ]
          , "required" .= (["action"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseAction input of
        Left err -> pure (T.pack err, True)
        Right action -> dispatch action input

    dispatch :: Text -> Value -> IO (Text, Bool)
    dispatch "spawn" input =
      case parseEither parseSpawn input of
        Left err -> pure (T.pack err, True)
        Right cmd -> doSpawn cmd
    dispatch "list" _ = doList
    dispatch "poll" input =
      case parseEither parseId input of
        Left err -> pure (T.pack err, True)
        Right pid -> doPoll pid
    dispatch "kill" input =
      case parseEither parseId input of
        Left err -> pure (T.pack err, True)
        Right pid -> doKill pid
    dispatch "write_stdin" input =
      case parseEither parseWriteStdin input of
        Left err -> pure (T.pack err, True)
        Right (pid, bytes) -> doWriteStdin pid bytes
    dispatch action _ = pure ("Unknown action: " <> action, True)

    doSpawn :: Text -> IO (Text, Bool)
    doSpawn cmd = do
      let parts = T.words cmd
      case parts of
        [] -> pure ("Empty command", True)
        (prog:args) ->
          case authorize policy (T.unpack prog) args of
            Left (CommandNotAllowed c) ->
              pure ("Command not allowed: " <> c, True)
            Left CommandInAutonomyDeny ->
              pure ("All commands denied by security policy", True)
            Right authorized -> do
              pid <- _ph_spawn ph authorized
              pure ("Started process " <> T.pack (show (unProcessId pid)), False)

    doList :: IO (Text, Bool)
    doList = do
      procs <- _ph_list ph
      if null procs
        then pure ("No background processes", False)
        else pure (formatList procs, False)

    doPoll :: Int -> IO (Text, Bool)
    doPoll pid = do
      status <- _ph_poll ph (ProcessId pid)
      case status of
        Nothing -> pure ("Process " <> T.pack (show pid) <> " not found", True)
        Just (ProcessRunning stdout stderr) ->
          let out = T.pack (BS8.unpack stdout)
              err = T.pack (BS8.unpack stderr)
          in pure ("Status: running\n" <> formatOutput out err, False)
        Just (ProcessDone exitCode stdout stderr) ->
          let out = T.pack (BS8.unpack stdout)
              err = T.pack (BS8.unpack stderr)
              exitInfo = case exitCode of
                ExitSuccess   -> "0"
                ExitFailure n -> T.pack (show n)
          in pure ("Status: done (exit " <> exitInfo <> ")\n" <> formatOutput out err, False)

    doKill :: Int -> IO (Text, Bool)
    doKill pid = do
      ok <- _ph_kill ph (ProcessId pid)
      if ok
        then pure ("Killed process " <> T.pack (show pid), False)
        else pure ("Process " <> T.pack (show pid) <> " not found", True)

    doWriteStdin :: Int -> Text -> IO (Text, Bool)
    doWriteStdin pid input = do
      ok <- _ph_writeStdin ph (ProcessId pid) (BS8.pack (T.unpack input))
      if ok
        then pure ("Sent input to process " <> T.pack (show pid), False)
        else pure ("Process " <> T.pack (show pid) <> " not found or not running", True)

    formatList :: [ProcessInfo] -> Text
    formatList = T.intercalate "\n" . map formatInfo

    formatInfo :: ProcessInfo -> Text
    formatInfo pi' =
      let status = if _pi_running pi'
            then "running"
            else case _pi_exitCode pi' of
              Just ExitSuccess   -> "done (exit 0)"
              Just (ExitFailure n) -> "done (exit " <> T.pack (show n) <> ")"
              Nothing            -> "unknown"
      in "[" <> T.pack (show (unProcessId (_pi_id pi'))) <> "] "
         <> _pi_command pi' <> " — " <> status

    formatOutput :: Text -> Text -> Text
    formatOutput out err =
      let parts = filter (not . T.null)
            [ if T.null out then "" else "stdout:\n" <> out
            , if T.null err then "" else "stderr:\n" <> err
            ]
      in if null parts then "(no output)" else T.intercalate "\n" parts

    parseAction :: Value -> Parser Text
    parseAction = withObject "ProcessInput" $ \o -> o .: "action"

    parseSpawn :: Value -> Parser Text
    parseSpawn = withObject "ProcessSpawnInput" $ \o -> o .: "command"

    parseId :: Value -> Parser Int
    parseId = withObject "ProcessIdInput" $ \o -> o .: "id"

    parseWriteStdin :: Value -> Parser (Int, Text)
    parseWriteStdin = withObject "ProcessWriteStdinInput" $ \o ->
      (,) <$> o .: "id" <*> o .: "input"
