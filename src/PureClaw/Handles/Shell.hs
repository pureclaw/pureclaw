module PureClaw.Handles.Shell
  ( -- * Process result
    ProcessResult (..)
    -- * Execution options
  , ExecOptions (..)
  , defaultExecOptions
    -- * Handle type
  , ShellHandle (..)
    -- * Implementations
  , mkShellHandle
  , mkNoOpShellHandle
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit
import System.Process.Typed qualified as P
import System.Timeout qualified as Timeout

import PureClaw.Handles.Log
import PureClaw.Security.Command

-- | Result of a subprocess execution.
data ProcessResult = ProcessResult
  { _pr_exitCode :: ExitCode
  , _pr_stdout   :: ByteString
  , _pr_stderr   :: ByteString
  }
  deriving stock (Show, Eq)

-- | Options controlling how a command is executed. Designed to be
-- extended as new backends (Docker, SSH, etc.) are added — each
-- backend interprets the fields it supports and ignores the rest.
data ExecOptions = ExecOptions
  { _eo_timeout    :: Maybe Int
    -- ^ Timeout in milliseconds. 'Nothing' means no timeout.
  , _eo_workingDir :: Maybe FilePath
    -- ^ Working directory for the subprocess. 'Nothing' uses the
    -- agent's current directory.
  }
  deriving stock (Show, Eq)

-- | Default execution options: no timeout, inherit working directory.
defaultExecOptions :: ExecOptions
defaultExecOptions = ExecOptions
  { _eo_timeout    = Nothing
  , _eo_workingDir = Nothing
  }

-- | Subprocess execution capability. Only accepts 'AuthorizedCommand',
-- which is proof that the command passed security policy evaluation.
--
-- The real implementation strips the subprocess environment to prevent
-- secret leakage via inherited environment variables.
--
-- Backends (local, Docker, SSH, etc.) provide different implementations
-- of this record. All backends receive 'ExecOptions' and interpret the
-- fields they support.
newtype ShellHandle = ShellHandle
  { _sh_execute :: ExecOptions -> AuthorizedCommand -> IO ProcessResult
  }

-- | Minimal safe environment for subprocesses. Provides only PATH so
-- commands can be resolved, but inherits nothing else from the parent.
safeEnv :: [(String, String)]
safeEnv = [("PATH", "/usr/bin:/bin:/usr/local/bin")]

-- | Real shell handle using @typed-process@. Strips the subprocess
-- environment (provides only a minimal PATH) as noted in the architecture.
mkShellHandle :: LogHandle -> ShellHandle
mkShellHandle logger = ShellHandle
  { _sh_execute = \opts cmd -> do
      let prog = getCommandProgram cmd
          args = map T.unpack (getCommandArgs cmd)
          config = maybe id (\d -> P.setWorkingDir d) (_eo_workingDir opts)
                 $ P.setEnv safeEnv
                 $ P.proc prog args
      _lh_logInfo logger $ "Executing: " <> T.pack prog <> " " <> T.unwords (getCommandArgs cmd)
      let run = do
            (exitCode, outLazy, errLazy) <- P.readProcess config
            pure ProcessResult
              { _pr_exitCode = exitCode
              , _pr_stdout   = BL.toStrict outLazy
              , _pr_stderr   = BL.toStrict errLazy
              }
      case _eo_timeout opts of
        Nothing -> run
        Just ms -> do
          result <- Timeout.timeout (ms * 1000) run
          case result of
            Just r  -> pure r
            Nothing -> pure ProcessResult
              { _pr_exitCode = ExitFailure 124
              , _pr_stdout   = ""
              , _pr_stderr   = TE.encodeUtf8 ("Command timed out after " <> T.pack (show ms) <> "ms")
              }
  }

-- | No-op shell handle. Returns success with empty output.
mkNoOpShellHandle :: ShellHandle
mkNoOpShellHandle = ShellHandle
  { _sh_execute = \_ _ -> pure ProcessResult
      { _pr_exitCode = ExitSuccess
      , _pr_stdout   = ""
      , _pr_stderr   = ""
      }
  }
