module PureClaw.Handles.Shell
  ( -- * Process result
    ProcessResult (..)
    -- * Handle type
  , ShellHandle (..)
    -- * Implementations
  , mkShellHandle
  , mkNoOpShellHandle
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import System.Exit
import System.Process.Typed qualified as P

import PureClaw.Handles.Log
import PureClaw.Security.Command

-- | Result of a subprocess execution.
data ProcessResult = ProcessResult
  { _pr_exitCode :: ExitCode
  , _pr_stdout   :: ByteString
  , _pr_stderr   :: ByteString
  }
  deriving stock (Show, Eq)

-- | Subprocess execution capability. Only accepts 'AuthorizedCommand',
-- which is proof that the command passed security policy evaluation.
--
-- The real implementation strips the subprocess environment to prevent
-- secret leakage via inherited environment variables.
newtype ShellHandle = ShellHandle
  { _sh_execute :: AuthorizedCommand -> IO ProcessResult
  }

-- | Minimal safe environment for subprocesses. Provides only PATH so
-- commands can be resolved, but inherits nothing else from the parent.
safeEnv :: [(String, String)]
safeEnv = [("PATH", "/usr/bin:/bin:/usr/local/bin")]

-- | Real shell handle using @typed-process@. Strips the subprocess
-- environment (provides only a minimal PATH) as noted in the architecture.
mkShellHandle :: LogHandle -> ShellHandle
mkShellHandle logger = ShellHandle
  { _sh_execute = \cmd -> do
      let prog = getCommandProgram cmd
          args = map T.unpack (getCommandArgs cmd)
          config = P.setEnv safeEnv
                 $ P.proc prog args
      _lh_logInfo logger $ "Executing: " <> T.pack prog <> " " <> T.unwords (getCommandArgs cmd)
      (exitCode, outLazy, errLazy) <- P.readProcess config
      pure ProcessResult
        { _pr_exitCode = exitCode
        , _pr_stdout   = BL.toStrict outLazy
        , _pr_stderr   = BL.toStrict errLazy
        }
  }

-- | No-op shell handle. Returns success with empty output.
mkNoOpShellHandle :: ShellHandle
mkNoOpShellHandle = ShellHandle
  { _sh_execute = \_ -> pure ProcessResult
      { _pr_exitCode = ExitSuccess
      , _pr_stdout   = ""
      , _pr_stderr   = ""
      }
  }
