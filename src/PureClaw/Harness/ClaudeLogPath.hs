-- | A validated, canonical path to a spawned @claude-code@ harness's on-disk
-- JSONL session-log file. This module is the ONLY way to obtain such a path.
--
-- == Why this exists
--
-- A spawned @claude-code@ harness writes its conversation to a JSONL file under
-- @<base>/projects/<sanitized-cwd>/<uuid>.jsonl@. PureClaw wants an optional,
-- read-only, high-fidelity view of that log (see @docs/harness-jsonl-capture.md@).
-- Reading an attacker-controllable path would be a security hole, so — exactly
-- like 'PureClaw.Security.Path.SafePath' — the value constructor is unexported
-- and the smart constructor enforces filesystem-containment, symlink, and
-- owner\/mode invariants before any caller can read the file (WU5 re-opens it).
--
-- == How the path is located (the WU0 refinement)
--
-- The WU0 Phase-0 spike (@docs/harness-jsonl-capture-spike.md@) established that
-- claude-code derives the project directory name by canonicalizing the cwd and
-- then replacing every non-alphanumeric character with @-@. That rule is an
-- undocumented, version-fragile claude internal. We deliberately do NOT
-- reconstruct it. Instead we exploit the fact that PureClaw mints a
-- /globally-unique/ uuid for every harness: we glob
-- @<base>/projects/*/<uuid>.jsonl@. Because the uuid is unique there is at most
-- one hit. Zero hits is a typed not-found error; more than one hit (which should
-- be impossible) is a typed ambiguity error — we never silently pick one.
--
-- == Security checks (mirror 'SafePath' + a net-new @O_NOFOLLOW@ open)
--
--   1. 'canonicalizePath' the globbed candidate and verify it is contained under
--      the /canonical/ @<base>/projects@ root. A symlink whose target escapes
--      that root is rejected.
--   2. Open the FINAL path component with @O_NOFOLLOW@ ('System.Posix.IO.openFd'
--      with @'PIO.nofollow' = True@). 'System.Posix.Files.getFileStatus' FOLLOWS
--      symlinks, so the existing 'PureClaw.Security.Path.checkModeAndOwner' is
--      insufficient against a symlinked leaf; we do a real @O_NOFOLLOW@ open and
--      @fstat@ the resulting fd. The fd is always closed (bracketed) — this WU
--      only validates; WU5 re-opens the validated path to read.
--   3. Reject if the file owner is not the effective uid, or if the mode is
--      group\/other-writable.
module PureClaw.Harness.ClaudeLogPath
  ( -- * Validated log path (constructor intentionally NOT exported)
    SafeClaudeLogPath
  , getSafeClaudeLogPath
    -- * Base directory (injectable for testability)
  , ClaudeBase
  , mkClaudeBase
  , getClaudeBase
  , resolveClaudeBase
  , chooseBase
    -- * Errors
  , ClaudeLogPathError (..)
    -- * Smart constructor (the ONLY way to obtain a 'SafeClaudeLogPath')
  , mkSafeClaudeLogPath
    -- * Pure owner\/mode predicate (exported for unit testing)
  , ownerModeOk
  ) where

import Control.Exception (IOException)
import Control.Exception qualified as Exc
import Control.Monad qualified as Monad
import Data.List qualified as List
import Data.Text qualified as T
import System.Directory qualified as Dir
import System.Environment qualified as Env
import System.FilePath ((</>))
import System.Posix.Files qualified as PF
import System.Posix.IO qualified as PIO
import System.Posix.Types (FileMode, UserID)
import System.Posix.User qualified as PU

import PureClaw.Harness.ClaudeSession (ClaudeSessionUuid, unClaudeSessionUuid)

--------------------------------------------------------------------------------
-- Types

-- | A filesystem path validated to point at a contained, owner-only
-- @claude-code@ JSONL session log. The value constructor is intentionally NOT
-- exported — the only way to obtain a 'SafeClaudeLogPath' is through
-- 'mkSafeClaudeLogPath'. The 'Show' instance is REDACTED so the concrete path
-- never leaks into general logs (mirrors WU1's 'ClaudeSessionUuid').
newtype SafeClaudeLogPath = SafeClaudeLogPath { getSafeClaudeLogPath :: FilePath }
  deriving stock (Eq, Ord)

-- | Redacted on purpose. See 'SafeClaudeLogPath' haddock. (D2.5)
instance Show SafeClaudeLogPath where
  show _ = "SafeClaudeLogPath <redacted>"

-- | The claude-code config base directory: @CLAUDE_CONFIG_DIR@ if set, else
-- @~/.claude@. Wrapped so the env\/home resolution ('resolveClaudeBase') is a
-- thin IO shell over a value that tests can inject directly via 'mkClaudeBase'
-- (a temp dir), keeping the validation core testable without mutating global
-- process env.
newtype ClaudeBase = ClaudeBase { getClaudeBase :: FilePath }
  deriving stock (Eq, Show)

-- | Wrap a base directory. Exposed so tests can point the smart constructor at
-- a temp dir without touching @CLAUDE_CONFIG_DIR@ or @$HOME@.
mkClaudeBase :: FilePath -> ClaudeBase
mkClaudeBase = ClaudeBase

-- | Resolve the claude-code base directory: @CLAUDE_CONFIG_DIR@ if present and
-- non-empty in the environment, otherwise @~/.claude@ (HOME expanded). This is
-- the only env\/home-touching part; it reads the two IO inputs and defers the
-- decision to the pure 'chooseBase' so the choice logic is unit-testable
-- without mutating process env.
resolveClaudeBase :: IO ClaudeBase
resolveClaudeBase = do
  mEnv <- Env.lookupEnv "CLAUDE_CONFIG_DIR"
  chooseBase mEnv <$> Dir.getHomeDirectory

-- | Pure base-directory choice (exported for unit testing). Use
-- @CLAUDE_CONFIG_DIR@ when it is set AND non-empty; otherwise fall back to
-- @<home>/.claude@. An empty env value is treated as unset (some shells export
-- empty strings).
chooseBase :: Maybe FilePath -> FilePath -> ClaudeBase
chooseBase mEnv home =
  case mEnv of
    Just dir | not (null dir) -> ClaudeBase dir
    _ -> ClaudeBase (home </> ".claude")

-- | Reasons a 'SafeClaudeLogPath' cannot be obtained.
data ClaudeLogPathError
  = -- | No @<base>/projects/*/<uuid>.jsonl@ matched the uuid. Carries the
    -- canonical projects-root that was searched (or the raw root when it did
    -- not exist).
    ClaudeLogNotFound FilePath
  | -- | More than one candidate matched the (supposedly unique) uuid. Carries
    -- every matching path. We never silently pick one.
    ClaudeLogAmbiguous [FilePath]
  | -- | The canonicalized candidate escaped the canonical projects root
    -- (symlink escape). Carries @(canonicalProjectsRoot, canonicalCandidate)@.
    ClaudeLogEscapesRoot FilePath FilePath
  | -- | The @O_NOFOLLOW@-opened file failed the owner\/mode check. Carries
    -- @(path, actualMode masked to 0o777, fileOwner)@.
    ClaudeLogInsecure FilePath FileMode UserID
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- Pure owner/mode predicate (unit-testable in isolation, D2.4)

-- | The pure security predicate factored out of the @O_NOFOLLOW@ open path so
-- it can be unit-tested with synthetic values (you cannot @chown@ to a foreign
-- uid in CI). Accept iff the file is owned by the effective uid AND is not
-- group- or other-writable.
--
-- @ownerModeOk euid mode owner@:
--
--   * @owner == euid@
--   * @mode .&. 0o022 == 0@  (no group-write @0o020@, no other-write @0o002@)
ownerModeOk :: UserID -> FileMode -> UserID -> Bool
ownerModeOk euid mode owner =
  owner == euid && (mode `PF.intersectFileModes` 0o022) == 0

--------------------------------------------------------------------------------
-- Smart constructor

-- | The ONLY way to obtain a 'SafeClaudeLogPath'.
--
-- @mkSafeClaudeLogPath base uuid mExpectedCwd@:
--
--   1. Glob @<base>/projects/*/<uuid>.jsonl@ (D2.2). Zero hits ⇒
--      'ClaudeLogNotFound'; >1 hit ⇒ 'ClaudeLogAmbiguous' (never silently
--      pick).
--   2. 'canonicalizePath' the single hit and verify containment under the
--      canonical projects root (D2.3) ⇒ 'ClaudeLogEscapesRoot' on escape.
--   3. @O_NOFOLLOW@-open the leaf, @fstat@ it, and apply 'ownerModeOk' (D2.4)
--      ⇒ 'ClaudeLogInsecure' on failure. The fd is bracketed (never leaks).
--
-- The optional @mExpectedCwd@ (the persisted canonical spawn-cwd from WU6) is
-- reserved for a future cross-check\/fallback — the PRIMARY derivation is the
-- uuid-glob, which sidesteps reproducing claude's fragile cwd→dirname rule.
mkSafeClaudeLogPath
  :: ClaudeBase
  -> ClaudeSessionUuid
  -> Maybe FilePath
  -- ^ persisted canonical spawn-cwd (cross-check\/fallback; currently unused —
  -- accepted now so the signature is stable for WU6).
  -> IO (Either ClaudeLogPathError SafeClaudeLogPath)
mkSafeClaudeLogPath (ClaudeBase base) uuid _mExpectedCwd = do
  let projectsRoot = base </> "projects"
      fileName = T.unpack (unClaudeSessionUuid uuid) <> ".jsonl"
  rootExists <- Dir.doesDirectoryExist projectsRoot
  if not rootExists
    then pure (Left (ClaudeLogNotFound projectsRoot))
    else do
      hits <- globUuidLogs projectsRoot fileName
      case hits of
        [] -> pure (Left (ClaudeLogNotFound projectsRoot))
        (_ : _ : _) -> pure (Left (ClaudeLogAmbiguous hits))
        [candidate] -> validateCandidate projectsRoot candidate

-- | Find every @<projectsRoot>/<subdir>/<fileName>@ that exists. We use
-- 'listDirectory' + 'doesPathExist' rather than adding a @Glob@ dependency.
-- Subdirectory entries that are not directories are simply skipped (their
-- @</fileName>@ child cannot exist).
globUuidLogs :: FilePath -> FilePath -> IO [FilePath]
globUuidLogs projectsRoot fileName = do
  entries <- Dir.listDirectory projectsRoot
  let candidates = [projectsRoot </> e </> fileName | e <- entries]
  Monad.filterM Dir.doesPathExist candidates

-- | Canonical-containment check (D2.3) followed by the @O_NOFOLLOW@ owner\/mode
-- check (D2.4).
--
-- Two distinct paths are used on purpose:
--
--   * Containment (D2.3) is checked on the CANONICAL candidate (symlinks
--     resolved), so a symlinked project directory or a leaf symlink whose
--     /target/ escapes the projects root is rejected.
--   * The @O_NOFOLLOW@ open (D2.4) is performed on the ORIGINAL (literal,
--     un-canonicalized) candidate leaf. Canonicalizing first would resolve a
--     leaf symlink away before the open, defeating @O_NOFOLLOW@; opening the
--     literal leaf means a symlinked leaf — even one whose target is in-root —
--     fails the open (ELOOP) and is rejected.
--
-- The stored 'SafeClaudeLogPath' carries the CANONICAL path: it is the stable,
-- fully-resolved location WU5 re-opens to read.
validateCandidate
  :: FilePath
  -> FilePath
  -> IO (Either ClaudeLogPathError SafeClaudeLogPath)
validateCandidate projectsRoot candidate = do
  canonRoot <- Dir.canonicalizePath projectsRoot
  canonCandidate <- Dir.canonicalizePath candidate
  if not (isContainedUnder canonRoot canonCandidate)
    then pure (Left (ClaudeLogEscapesRoot canonRoot canonCandidate))
    else checkOwnerModeNoFollow candidate canonCandidate

-- | True iff @child@ is @root@ itself or strictly below it. We compare on
-- 'System.FilePath.splitDirectories'-style component prefixes rather than raw
-- string 'List.isPrefixOf' so that @\/a\/bc@ is NOT considered under @\/a\/b@.
isContainedUnder :: FilePath -> FilePath -> Bool
isContainedUnder root child =
  let rootC = splitNonEmpty root
      childC = splitNonEmpty child
  in rootC `List.isPrefixOf` childC
  where
    splitNonEmpty :: FilePath -> [String]
    splitNonEmpty = filter (not . null) . splitOnSlash
    splitOnSlash :: String -> [String]
    splitOnSlash s = case break (== '/') s of
      (h, []) -> [h]
      (h, _ : t) -> h : splitOnSlash t

-- | Open the LITERAL leaf (@openPath@) with @O_NOFOLLOW@, @fstat@ the fd, apply
-- the pure 'ownerModeOk' predicate, and ALWAYS close the fd (bracket). On
-- success store @canonPath@ (the canonical, fully-resolved location WU5 reads).
--
-- If the literal leaf is a symlink, @O_NOFOLLOW@ makes 'PIO.openFd' fail with
-- @ELOOP@; we surface that (and any other open failure) as 'ClaudeLogInsecure'
-- rather than letting the exception escape, because a symlinked\/unopenable leaf
-- is by definition an insecure candidate.
--
-- 'getFileStatus' (used by the existing 'PureClaw.Security.Path.checkModeAndOwner')
-- FOLLOWS symlinks, so it cannot defeat a symlinked leaf — that is precisely why
-- we re-open the LITERAL leaf with @O_NOFOLLOW@ and @fstat@ the resulting fd.
checkOwnerModeNoFollow
  :: FilePath
  -- ^ literal candidate leaf to open with @O_NOFOLLOW@
  -> FilePath
  -- ^ canonical path to store on success
  -> IO (Either ClaudeLogPathError SafeClaudeLogPath)
checkOwnerModeNoFollow openPath canonPath = do
  euid <- PU.getEffectiveUserID
  let flags = PIO.defaultFileFlags { PIO.nofollow = True }
  opened <- Exc.try (PIO.openFd openPath PIO.ReadOnly flags)
  case opened of
    Left (_ :: IOException) ->
      -- Open failed (e.g. ELOOP because the leaf is a symlink). Treat as
      -- insecure; report a zeroed mode\/owner since we never obtained a status.
      pure (Left (ClaudeLogInsecure canonPath 0 0))
    Right fd ->
      Exc.bracket (pure fd) PIO.closeFd $ \openedFd -> do
        status <- PF.getFdStatus openedFd
        let actualMode = PF.fileMode status `PF.intersectFileModes` 0o777
            owner = PF.fileOwner status
        pure $
          if ownerModeOk euid actualMode owner
            then Right (SafeClaudeLogPath canonPath)
            else Left (ClaudeLogInsecure canonPath actualMode owner)
