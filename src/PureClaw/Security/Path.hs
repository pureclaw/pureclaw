module PureClaw.Security.Path
  ( -- * Safe path type (constructor intentionally NOT exported)
    SafePath
    -- * Path errors
  , PathError (..)
    -- * Construction (the ONLY way to obtain a SafePath)
  , mkSafePath
    -- * Read-only accessor
  , getSafePath
    -- * Path roots (exported configuration values)
  , KeysRoot (..)
  , RuntimeRoot (..)
    -- * Identity-key paths (constructor intentionally NOT exported)
  , SafeKeyPath
  , mkSafeKeyPath
  , getSafeKeyPath
    -- * Runtime paths (constructor intentionally NOT exported)
  , SafeRuntimePath
  , mkSafeRuntimePath
  , getSafeRuntimePath
    -- * Setup helpers
  , ensureKeysRoot
  , ensureRuntimeRoot
  ) where

import Data.List
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import System.Directory
import System.FilePath
import System.Posix.Files qualified as PF
import System.Posix.Types (FileMode)
import System.Posix.User qualified as PU

import PureClaw.Core.Types

-- | A filesystem path that has been validated to be within the workspace
-- and not on the blocked list. Constructor is intentionally NOT exported —
-- the only way to obtain a 'SafePath' is through 'mkSafePath'.
newtype SafePath = SafePath { getSafePath :: FilePath }
  deriving stock (Eq, Ord)

instance Show SafePath where
  show sp = "SafePath " ++ show (getSafePath sp)

-- | Errors that can occur during path validation.
data PathError
  = PathEscapesWorkspace FilePath FilePath
    -- ^ requested, resolved
  | PathIsBlocked FilePath Text
    -- ^ requested, reason
  | PathDoesNotExist FilePath
    -- ^ the requested path does not exist
  | PathInsecureMode FilePath FileMode FileMode
    -- ^ path, actual mode (masked to 0o777), expected mode (masked to 0o777)
  deriving stock (Show, Eq)

-- | Paths that must never be readable or writable, regardless of workspace.
-- Checked against the first component of the relative path within the workspace.
blockedPaths :: Set String
blockedPaths = Set.fromList
  [ ".env"
  , ".env.local"
  , ".env.production"
  , ".ssh"
  , ".gnupg"
  , ".netrc"
  , ".pureclaw"  -- protects vault and config from agent file tools
  ]

-- | The ONLY way to obtain a 'SafePath'. Canonicalizes the path (following
-- symlinks), verifies it stays within the workspace, checks the blocked list,
-- and verifies the path exists.
--
-- Checks run in order, each as an early return:
--  1. Reject @..@ traversal (prevents workspace escape)
--  2. Reject absolute paths outside workspace
--  3. Reject blocked paths (@.env@, @.ssh@, etc.)
--  4. Reject non-existent paths
--  5. Reject symlinks that resolve outside workspace
mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) requested = do
  canonRoot <- canonicalizePath root
  let raw = if isAbsolute requested then requested else canonRoot </> requested
      relative = makeRelative canonRoot raw
  -- Pure checks first (no IO, no filesystem access)
  let pureCheck
        | hasParentTraversal requested = Just (PathEscapesWorkspace requested raw)
        | isAbsolute requested && not (canonRoot `isPrefixOf` raw) = Just (PathEscapesWorkspace requested raw)
        | isBlockedPath relative = Just (PathIsBlocked requested "blocked path")
        | otherwise = Nothing
  case pureCheck of
    Just err -> pure (Left err)
    Nothing -> do
      exists <- doesPathExist raw
      if not exists
        then pure $ Left (PathDoesNotExist requested)
        else do
          -- Canonicalize resolves symlinks — a symlink inside the workspace
          -- could point outside it, so we re-check containment.
          canonical <- canonicalizePath raw
          pure $ if canonRoot `isPrefixOf` canonical
            then Right (SafePath canonical)
            else Left (PathEscapesWorkspace requested canonical)

-- | Check if a path contains ".." components that could traverse upward.
hasParentTraversal :: FilePath -> Bool
hasParentTraversal path = ".." `elem` splitDirectories path

-- | Check if a relative path matches any blocked path.
-- Matches on the first path component (e.g. ".env" matches ".env" and ".env/foo").
isBlockedPath :: FilePath -> Bool
isBlockedPath relative =
  let firstComponent = Prelude.takeWhile (\c -> c /= '/' && c /= '\\') relative
  in Set.member firstComponent blockedPaths

--------------------------------------------------------------------------------
-- Identity & runtime path roots

-- | Root directory where ssh identity keys live. Project-controlled,
-- created mode 0700 at startup. Exported as a configuration value.
newtype KeysRoot = KeysRoot FilePath
  deriving stock (Eq, Show)

-- | Root directory where short-lived sockets and @known_hosts@ live.
-- Project-controlled, created mode 0700 at startup. Exported as a
-- configuration value.
newtype RuntimeRoot = RuntimeRoot FilePath
  deriving stock (Eq, Show)

-- | A filesystem path validated to live under a 'KeysRoot'. Constructor is
-- intentionally NOT exported — the only way to obtain a 'SafeKeyPath' is
-- through 'mkSafeKeyPath'. The 'Show' instance is redacted to prevent
-- accidental leakage of key paths via logs or error messages.
newtype SafeKeyPath = SafeKeyPath { getSafeKeyPath :: FilePath }
  deriving stock (Eq, Ord)

-- | Redacted on purpose. See 'SafeKeyPath' haddock.
instance Show SafeKeyPath where
  show _ = "SafeKeyPath <redacted>"

-- | A filesystem path validated to live under a 'RuntimeRoot'. Constructor
-- is intentionally NOT exported — the only way to obtain a
-- 'SafeRuntimePath' is through 'mkSafeRuntimePath'. The 'Show' instance
-- is redacted to prevent accidental leakage.
newtype SafeRuntimePath = SafeRuntimePath { getSafeRuntimePath :: FilePath }
  deriving stock (Eq, Ord)

-- | Redacted on purpose. See 'SafeRuntimePath' haddock.
instance Show SafeRuntimePath where
  show _ = "SafeRuntimePath <redacted>"

-- | The ONLY way to obtain a 'SafeKeyPath'.
--
-- Validation rules (match the rigor of 'mkSafePath'):
--
--  1. Reject @..@ traversal in the requested path.
--  2. Canonicalize the keys root; reject if the root directory does not exist.
--  3. Canonicalize the requested file (when it already exists) and verify
--     the result is under the canonicalized keys root. This catches
--     symlinks that point outside the root.
--  4. When the file already exists, @fstat@ it and verify
--     @mode `intersectFileModes` 0o777 == 0o400@ and
--     @owner == geteuid()@; surface 'PathInsecureMode' otherwise.
--
-- Note: a 'SafeKeyPath' for a file that does not yet exist is permitted —
-- it is the caller's responsibility (typically the ssh-key-write path) to
-- create the file with mode 0400. Re-validating after write is the
-- caller's job.
mkSafeKeyPath :: KeysRoot -> FilePath -> IO (Either PathError SafeKeyPath)
mkSafeKeyPath (KeysRoot root) requested =
  validateUnderRoot root requested SafeKeyPath (Just (0o400, expectedKeyMode))
  where
    expectedKeyMode :: FileMode
    expectedKeyMode = 0o400

-- | The ONLY way to obtain a 'SafeRuntimePath'.
--
-- Same validation rules as 'mkSafeKeyPath' except no mode/owner check on
-- the file — sockets are typically created by ssh itself and known_hosts
-- mode is enforced elsewhere.
mkSafeRuntimePath :: RuntimeRoot -> FilePath -> IO (Either PathError SafeRuntimePath)
mkSafeRuntimePath (RuntimeRoot root) requested =
  validateUnderRoot root requested SafeRuntimePath Nothing

-- | Shared validation pipeline for 'mkSafeKeyPath' and 'mkSafeRuntimePath'.
-- Takes a wrapping constructor and an optional @(expectedMode, expectedMode)@
-- pair. The pair carries the expected mode twice because the same value is
-- both the value reported in 'PathInsecureMode' (the "expected" field) and
-- the value we compare against — having a single source kept the call sites
-- intentional.
validateUnderRoot
  :: FilePath
  -> FilePath
  -> (FilePath -> a)
  -> Maybe (FileMode, FileMode)
  -> IO (Either PathError a)
validateUnderRoot root requested wrap mModeCheck = do
  if hasParentTraversal requested
    then pure $ Left (PathEscapesWorkspace requested requested)
    else do
      rootExists <- doesDirectoryExist root
      if not rootExists
        then pure $ Left (PathDoesNotExist root)
        else do
          canonRoot <- canonicalizePath root
          let raw = if isAbsolute requested
                      then requested
                      else canonRoot </> requested
          fileExists <- doesPathExist raw
          if fileExists
            then do
              canonical <- canonicalizePath raw
              if canonRoot `isPrefixOf` canonical
                then case mModeCheck of
                       Nothing -> pure $ Right (wrap canonical)
                       Just (expected, _) -> checkModeAndOwner canonical expected wrap
                else pure $ Left (PathEscapesWorkspace requested canonical)
            else
              -- File does not exist yet (e.g. ssh has not written the key).
              -- Verify the *requested* location resolves under the root.
              if canonRoot `isPrefixOf` raw
                then pure $ Right (wrap raw)
                else pure $ Left (PathEscapesWorkspace requested raw)

-- | Verify the file's mode (masked to the standard permission bits) and
-- effective-uid owner match the expected mode. Returns 'PathInsecureMode'
-- on mismatch.
checkModeAndOwner
  :: FilePath
  -> FileMode
  -> (FilePath -> a)
  -> IO (Either PathError a)
checkModeAndOwner canonical expectedMode wrap = do
  status <- PF.getFileStatus canonical
  let actualMode = PF.fileMode status `PF.intersectFileModes` 0o777
      ownerUid   = PF.fileOwner status
  euid <- PU.getEffectiveUserID
  if actualMode == expectedMode && ownerUid == euid
    then pure $ Right (wrap canonical)
    else pure $ Left (PathInsecureMode canonical actualMode expectedMode)

-- | Create the keys-root directory if missing (mode 0700) and return a
-- 'KeysRoot' wrapping it. Idempotent — if the directory already exists, the
-- mode is re-applied. Callers wire this into agent startup before any
-- 'mkSafeKeyPath' call.
ensureKeysRoot :: FilePath -> IO KeysRoot
ensureKeysRoot dir = do
  createDirectoryIfMissing True dir
  PF.setFileMode dir 0o700
  pure (KeysRoot dir)

-- | Create the runtime-root directory if missing (mode 0700) and return a
-- 'RuntimeRoot' wrapping it. Idempotent. Callers wire this into agent
-- startup before any 'mkSafeRuntimePath' call.
ensureRuntimeRoot :: FilePath -> IO RuntimeRoot
ensureRuntimeRoot dir = do
  createDirectoryIfMissing True dir
  PF.setFileMode dir 0o700
  pure (RuntimeRoot dir)

