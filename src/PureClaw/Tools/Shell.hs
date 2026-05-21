module PureClaw.Tools.Shell
  ( -- * Tool registration
    shellTool
  , execTool
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

-- | Run a process result through the same output-shaping logic both tools
-- share: stdout + stderr + an "Exit code: N" suffix on failure, with a
-- placeholder for empty output. Returns (text, isError).
shapeResult :: ProcessResult -> (Text, Bool)
shapeResult pr =
  let out      = T.pack (BS8.unpack (_pr_stdout pr))
      err      = T.pack (BS8.unpack (_pr_stderr pr))
      exitInfo = case _pr_exitCode pr of
        ExitSuccess     -> ""
        ExitFailure n   -> "\nExit code: " <> T.pack (show n)
      combined = T.strip (out <> err <> exitInfo)
  in  (if T.null combined then "(no output)" else combined, False)

runAuthorized :: ShellHandle -> ExecOptions -> AuthorizedCommand -> IO (Text, Bool)
runAuthorized sh opts cmd = do
  result <- try @SomeException (_sh_execute sh opts cmd)
  case result of
    Left e   -> pure (T.pack (show e), True)
    Right pr -> pure (shapeResult pr)

-- | Bash-backed shell tool. The @command@ string is handed verbatim to
-- @bash -c@, so the LLM gets full shell semantics: tilde expansion, glob
-- patterns, env-var substitution, pipes, @&&@, redirects, etc.
--
-- Gated by the policy having @shell@ in its allowed-command set
-- (see 'authorizeShell'). Per-basename allowlisting is the @exec@ tool's
-- job — once bash is in the loop, basename checks are not meaningful.
shellTool :: SecurityPolicy -> ShellHandle -> (ToolDefinition, ToolHandler)
shellTool policy sh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "shell"
      , _td_description = T.unlines
          [ "Run a shell command. The string is executed by /bin/bash -c, so"
          , "shell features work: pipes (|), command chaining (&&, ||, ;),"
          , "redirects (>, <), tilde expansion (~), glob patterns (*, ?),"
          , "and environment variable substitution ($VAR)."
          , "Optional: set timeout_ms to limit execution time (returns exit code 124 on timeout)."
          , "Optional: set working_dir to run in a specific directory."
          , "Returns combined stdout+stderr. Non-zero exit appends 'Exit code: N'."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "command" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The shell command line. Passed verbatim to bash -c." :: Text)
                  ]
              , "timeout_ms" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Timeout in milliseconds. Command is killed after this time (default: no timeout)" :: Text)
                  ]
              , "working_dir" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Working directory for the command (default: agent workspace)" :: Text)
                  ]
              ]
          , "required" .= (["command"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseShellInput input of
        Left err -> pure (T.pack err, True)
        Right si
          | T.null (T.strip (_si_command si)) ->
              pure ("Empty command", True)
          | otherwise ->
              case authorizeShell policy (_si_command si) of
                Left (CommandNotAllowed _) ->
                  pure ("shell tool not enabled in security policy (add \"shell\" to allowed_commands, or use the exec tool)", True)
                Left CommandInAutonomyDeny ->
                  pure ("All commands denied by security policy", True)
                Right authorized ->
                  runAuthorized sh (shellExecOpts si) authorized

-- | Argv-style exec tool. Takes an explicit @program@ name and @args@
-- list — no shell interpretation. Every argument reaches the program as
-- a literal string: @~@ is not expanded, @*@ is not globbed, @|@ is not a
-- pipe.
--
-- Authorized against the policy's per-basename allowlist (see 'authorize').
-- This is the tool to expose when a deployment wants to lock the agent
-- down to an explicit set of executables.
execTool :: SecurityPolicy -> ShellHandle -> (ToolDefinition, ToolHandler)
execTool policy sh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "exec"
      , _td_description = T.unlines
          [ "Execute a program with explicit arguments. No shell is involved:"
          , "tilde (~), glob (*), env vars ($VAR), pipes (|), redirects (>),"
          , "and chaining (&&) are NOT interpreted — every arg is a literal."
          , "Use this for tighter security: the policy allowlist gates each"
          , "program by name."
          , "Optional: set timeout_ms to limit execution time (returns exit code 124 on timeout)."
          , "Optional: set working_dir to run in a specific directory."
          , "Returns combined stdout+stderr. Non-zero exit appends 'Exit code: N'."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "program" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Program to execute (e.g. \"ls\", \"git\"). Looked up via PATH." :: Text)
                  ]
              , "args" .= object
                  [ "type"        .= ("array" :: Text)
                  , "items"       .= object [ "type" .= ("string" :: Text) ]
                  , "description" .= ("Arguments as literal strings. No shell expansion." :: Text)
                  ]
              , "timeout_ms" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Timeout in milliseconds. Command is killed after this time (default: no timeout)" :: Text)
                  ]
              , "working_dir" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Working directory for the command (default: agent workspace)" :: Text)
                  ]
              ]
          , "required" .= (["program"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseExecInput input of
        Left err -> pure (T.pack err, True)
        Right ei
          | T.null (T.strip (_ei_program ei)) ->
              pure ("Empty program", True)
          | otherwise ->
              case authorize policy (T.unpack (_ei_program ei)) (_ei_args ei) of
                Left (CommandNotAllowed c) ->
                  pure ("Command not allowed: " <> c, True)
                Left CommandInAutonomyDeny ->
                  pure ("All commands denied by security policy", True)
                Right authorized ->
                  runAuthorized sh (execExecOpts ei) authorized

-- ── Input parsing ─────────────────────────────────────────────────────

data ShellInput = ShellInput
  { _si_command    :: Text
  , _si_timeout    :: Maybe Int
  , _si_workingDir :: Maybe Text
  }

parseShellInput :: Value -> Parser ShellInput
parseShellInput = withObject "ShellInput" $ \o ->
  ShellInput
    <$> o .:  "command"
    <*> o .:? "timeout_ms"
    <*> o .:? "working_dir"

shellExecOpts :: ShellInput -> ExecOptions
shellExecOpts si = ExecOptions
  { _eo_timeout    = _si_timeout si
  , _eo_workingDir = fmap T.unpack (_si_workingDir si)
  }

data ExecInput = ExecInput
  { _ei_program    :: Text
  , _ei_args       :: [Text]
  , _ei_timeout    :: Maybe Int
  , _ei_workingDir :: Maybe Text
  }

parseExecInput :: Value -> Parser ExecInput
parseExecInput = withObject "ExecInput" $ \o ->
  ExecInput
    <$> o .:  "program"
    <*> o .:? "args" .!= []
    <*> o .:? "timeout_ms"
    <*> o .:? "working_dir"

execExecOpts :: ExecInput -> ExecOptions
execExecOpts ei = ExecOptions
  { _eo_timeout    = _ei_timeout ei
  , _eo_workingDir = fmap T.unpack (_ei_workingDir ei)
  }
