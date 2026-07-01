-- | Process-wide isolation of PureClaw's on-disk storage for the test suite.
--
-- Every PureClaw storage path is derived from 'System.Directory.getHomeDirectory',
-- which on POSIX reads @$HOME@. By pointing @$HOME@ (and the related XDG /
-- claude-code / temp variables) at a throwaway directory under @\/tmp@ before
-- any spec runs, the entire suite is kept out of the developer's real
-- @~\/.pureclaw@ store. The @\/tmp@ location makes it obvious the data is
-- disposable.
--
-- This blankets every test, including ones that do not opt into the per-spec
-- @withTempHome@ helper. Per-spec helpers still work: they simply redirect
-- @$HOME@ again within their own scope.
module Support.Isolation
  ( withIsolatedHome
  , setupIsolatedHome
  ) where

import Control.Exception (finally)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Environment (setEnv)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory)

-- | Run an action with a fully isolated PureClaw home under @\/tmp@, removing
-- the directory tree afterwards (even if the action throws — e.g. hspec's
-- @ExitFailure@ on a failing test).
withIsolatedHome :: IO a -> IO a
withIsolatedHome action = do
  -- Line-buffer the suite's stdout/stderr: if a spec hangs, the output already
  -- emitted (the describe/test it reached) is flushed instead of being lost in
  -- block buffering when piped — making a hang diagnosable in CI and locally.
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  root <- setupIsolatedHome
  action `finally` removeDirectoryRecursive root

-- | Create a fresh isolated storage root under @\/tmp@ and redirect every
-- environment variable PureClaw uses to derive storage paths into it.
-- Returns the root directory so callers can clean it up.
setupIsolatedHome :: IO FilePath
setupIsolatedHome = do
  -- Force the root under /tmp explicitly. (On macOS the system temp dir is
  -- under /var/folders, so we cannot rely on createTempDirectory's default.)
  root <- createTempDirectory "/tmp" "pureclaw-test"
  let home = root </> "home"
      tmp  = root </> "tmp"
  createDirectoryIfMissing True home
  createDirectoryIfMissing True tmp
  -- HOME drives getHomeDirectory -> getPureclawDir, config loading, history,
  -- agents, vault, tab state, and the ~/.claude harness-log fallback.
  setEnv "HOME" home
  -- XDG vars in case any dependency consults them instead of HOME.
  setEnv "XDG_CONFIG_HOME" (home </> ".config")
  setEnv "XDG_DATA_HOME" (home </> ".local" </> "share")
  setEnv "XDG_CACHE_HOME" (home </> ".cache")
  setEnv "XDG_STATE_HOME" (home </> ".local" </> "state")
  -- Explicitly relocate claude-code harness logs (honours CLAUDE_CONFIG_DIR).
  setEnv "CLAUDE_CONFIG_DIR" (home </> ".claude")
  -- Point TMPDIR into the same root so withSystemTempDirectory-based fixtures
  -- (which respect TMPDIR) also land under our disposable /tmp tree.
  setEnv "TMPDIR" tmp
  pure root
