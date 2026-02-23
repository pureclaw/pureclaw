module PureClaw.Tools.Git
  ( -- * Tool registration
    gitTool
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

-- | Create a git tool that executes git subcommands through the security policy.
gitTool :: SecurityPolicy -> ShellHandle -> (ToolDefinition, ToolHandler)
gitTool policy sh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "git"
      , _td_description = "Execute git operations. Supports: status, diff, log, add, commit, branch, checkout, stash."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "subcommand" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The git subcommand and arguments, e.g. \"status\" or \"diff --cached\"" :: Text)
                  ]
              ]
          , "required" .= (["subcommand"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right subcmd -> do
          let args = T.words subcmd
          case authorize policy "git" args of
            Left (CommandNotAllowed _) -> pure ("git is not in the allowed commands list", True)
            Left CommandInAutonomyDeny -> pure ("All commands denied by security policy", True)
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
    parseInput = withObject "GitInput" $ \o -> o .: "subcommand"
