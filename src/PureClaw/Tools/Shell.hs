module PureClaw.Tools.Shell
  ( -- * Tool registration
    shellTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit

import PureClaw.Handles.Shell
import PureClaw.Providers.Class
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Tools.Registry

-- | Create a shell tool that executes commands through the security policy.
shellTool :: SecurityPolicy -> ShellHandle -> (ToolDefinition, ToolHandler)
shellTool policy sh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "shell"
      , _td_description = "Execute a shell command. The command is validated against the security policy before execution."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "command" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The shell command to execute" :: Text)
                  ]
              ]
          , "required" .= (["command"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input -> do
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right cmd -> do
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
                  result <- try @SomeException (_sh_execute sh authorized)
                  case result of
                    Left e -> pure (T.pack (show e), True)
                    Right pr -> do
                      let out = T.pack (BS8.unpack (_pr_stdout pr))
                          err = T.pack (BS8.unpack (_pr_stderr pr))
                          exitInfo = case _pr_exitCode pr of
                            ExitSuccess -> ""
                            ExitFailure n -> "\nExit code: " <> T.pack (show n)
                          combined = T.strip (out <> err <> exitInfo)
                      pure (if T.null combined then "(no output)" else combined, False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "ShellInput" $ \o -> o .: "command"
