module PureClaw.Security.Path
  ( -- * Safe path type (constructor intentionally NOT exported)
    SafePath
    -- * Path errors
  , PathError (..)
    -- * Construction (the ONLY way to obtain a SafePath)
  , mkSafePath
    -- * Read-only accessor
  , getSafePath
  ) where

import Data.List (isPrefixOf)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import System.Directory (canonicalizePath, doesPathExist)
import System.FilePath ((</>), isAbsolute, makeRelative, splitDirectories)

import PureClaw.Core.Types (WorkspaceRoot (..))

-- | A filesystem path that has been validated to be within the workspace
-- and not on the blocked list. Constructor is intentionally NOT exported —
-- the only way to obtain a 'SafePath' is through 'mkSafePath'.
newtype SafePath = SafePath FilePath
  deriving stock (Eq, Ord)

instance Show SafePath where
  show (SafePath p) = "SafePath " ++ show p

-- | Errors that can occur during path validation.
data PathError
  = PathEscapesWorkspace FilePath FilePath  -- ^ requested, resolved
  | PathIsBlocked FilePath Text             -- ^ requested, reason
  | PathDoesNotExist FilePath               -- ^ the requested path does not exist
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
  ]

-- | The ONLY way to obtain a 'SafePath'. Canonicalizes the path (following
-- symlinks), verifies it stays within the workspace, checks the blocked list,
-- and verifies the path exists.
mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) requested = do
  canonRoot <- canonicalizePath root
  let raw = if isAbsolute requested then requested else canonRoot </> requested
  -- Security check: reject paths containing ".." components in the
  -- requested path. These could escape the workspace. We check this
  -- BEFORE checking existence to prevent information leakage about
  -- the filesystem outside the workspace.
  if hasParentTraversal requested
    then pure $ Left (PathEscapesWorkspace requested raw)
    else if isAbsolute requested && not (canonRoot `isPrefixOf` raw)
      then pure $ Left (PathEscapesWorkspace requested raw)
      else do
        let relative = makeRelative canonRoot raw
        -- Check blocked paths before checking existence
        if isBlockedPath relative
          then pure $ Left (PathIsBlocked requested "blocked path")
          else do
            exists <- doesPathExist raw
            if not exists
              then pure $ Left (PathDoesNotExist requested)
              else do
                -- Canonicalize to resolve symlinks and verify the real path
                -- is still within the workspace
                canonical <- canonicalizePath raw
                if not (canonRoot `isPrefixOf` canonical)
                  then pure $ Left (PathEscapesWorkspace requested canonical)
                  else pure $ Right (SafePath canonical)

-- | Check if a path contains ".." components that could traverse upward.
hasParentTraversal :: FilePath -> Bool
hasParentTraversal path = ".." `elem` splitDirectories path

-- | Check if a relative path matches any blocked path.
-- Matches on the first path component (e.g. ".env" matches ".env" and ".env/foo").
isBlockedPath :: FilePath -> Bool
isBlockedPath relative =
  let firstComponent = Prelude.takeWhile (\c -> c /= '/' && c /= '\\') relative
  in Set.member firstComponent blockedPaths

-- | Read-only accessor for the underlying file path.
getSafePath :: SafePath -> FilePath
getSafePath (SafePath p) = p
