-- |
-- Module      : PureClaw.Tab.Container
-- Description : Container exec security and argv construction (WU-10).
--
-- Pure helpers for the container backend factory arm:
--
--   * 'containerArgsDenylist' — dangerous container flags that must not
--     appear in user-supplied harness args.
--   * 'checkContainerArgs' — validate args against the denylist.
--   * 'containerEngineBinary' — map 'ContainerEngine' to binary name.
--   * 'flavourToBinary' — map 'HarnessFlavour' to binary name.
--   * 'buildContainerExecArgv' — construct the full exec argv.
--   * 'validateCwd' — pure path-traversal guard for '_h_cwd'.
module PureClaw.Tab.Container
  ( -- * Args denylist
    containerArgsDenylist
  , ContainerArgsError (..)
  , checkContainerArgs
    -- * Argv construction
  , containerEngineBinary
  , flavourToBinary
  , buildContainerExecArgv
    -- * Cwd validation
  , CwdError (..)
  , validateCwd
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Session.Kind
  ( ContainerEngine (..)
  , ContainerSpec (..)
  , HarnessFlavour (..)
  , unContainerTarget
  )


-- ---------------------------------------------------------------------------
-- Args denylist (S9)
-- ---------------------------------------------------------------------------

-- | Container flags that pose a security risk. Any flag in '_h_args'
-- matching one of these strings causes the container factory arm to
-- reject the spawn.
containerArgsDenylist :: [Text]
containerArgsDenylist =
  [ "--privileged"
  , "--cap-add"
  , "--security-opt"
  , "--device"
  , "--pid=host"
  , "--network=host"
  , "--userns=host"
  , "--uts=host"
  , "--ipc=host"
  , "-v"
  , "--volume"
  , "--mount"
  ]

-- | Why container args were rejected.
data ContainerArgsError
  = DeniedFlag !Text
    -- ^ A flag from 'containerArgsDenylist' was found in '_h_args'.
  deriving stock (Show, Eq)

-- | Check a list of user-supplied args against 'containerArgsDenylist'.
-- Returns the first denied flag found, if any.
checkContainerArgs :: [Text] -> Either ContainerArgsError ()
checkContainerArgs args =
  case filter (`elem` containerArgsDenylist) args of
    []    -> Right ()
    (f:_) -> Left (DeniedFlag f)


-- ---------------------------------------------------------------------------
-- Engine binary mapping
-- ---------------------------------------------------------------------------

-- | Map a 'ContainerEngine' to the binary name used in the exec argv.
containerEngineBinary :: ContainerEngine -> Text
containerEngineBinary Docker  = "docker"
containerEngineBinary Podman  = "podman"
containerEngineBinary Kubectl = "kubectl"


-- ---------------------------------------------------------------------------
-- Flavour binary mapping
-- ---------------------------------------------------------------------------

-- | Map a 'HarnessFlavour' to the binary name invoked inside the
-- container. This is the program that appears after the @--@ separator
-- in the container exec argv.
flavourToBinary :: HarnessFlavour -> Text
flavourToBinary HClaudeCode = "claude"
flavourToBinary HCodex      = "codex"
flavourToBinary HOpenCode   = "opencode"
flavourToBinary HHermes     = "hermes"
flavourToBinary HPureClaw   = "pureclaw"
flavourToBinary (HCustom n) = n


-- ---------------------------------------------------------------------------
-- Argv construction (S9)
-- ---------------------------------------------------------------------------

-- | Build the explicit exec argv for a container backend.
--
-- Structure:
-- @[engine_binary, "exec", "-it", target, "--", harness_binary] ++ args@
--
-- The @--@ separator is MANDATORY to prevent argument injection: without
-- it, a malicious target or harness args could be interpreted as flags
-- to the container engine.
buildContainerExecArgv :: ContainerSpec -> HarnessFlavour -> [Text] -> [Text]
buildContainerExecArgv cs flavour harnessArgs =
  [ containerEngineBinary (_cs_engine cs)
  , "exec"
  , "-it"
  , unContainerTarget (_cs_target cs)
  , "--"
  , flavourToBinary flavour
  ] <> harnessArgs


-- ---------------------------------------------------------------------------
-- Cwd validation (S10)
-- ---------------------------------------------------------------------------

-- | Why a cwd path was rejected.
data CwdError
  = CwdPathTraversal
    -- ^ The path contains @..@ components (path traversal).
  deriving stock (Show, Eq)

-- | Pure validation of '_h_cwd'. Rejects paths containing @..@
-- components (which could escape the intended working directory).
-- Returns the validated 'FilePath' when present and valid, or 'Nothing'
-- when no cwd was specified.
--
-- This is a lightweight pure check that catches the most common
-- traversal attack. The full 'mkSafePath' IO validation (which follows
-- symlinks and canonicalises) is performed at spawn time by the factory
-- arm when a 'WorkspaceRoot' is available.
validateCwd :: Maybe Text -> Either CwdError (Maybe FilePath)
validateCwd Nothing  = Right Nothing
validateCwd (Just t) =
  let path = T.unpack t
  in if hasParentTraversal path
       then Left CwdPathTraversal
       else Right (Just path)

-- | Check if a path contains @..@ components that could traverse upward.
hasParentTraversal :: FilePath -> Bool
hasParentTraversal path =
  let components = splitPath path
  in any (== "..") components
  where
    -- Simple split on '/' — sufficient for the pure traversal check.
    splitPath :: FilePath -> [String]
    splitPath = go []
      where
        go acc [] = [reverse acc]
        go acc ('/':rest) = reverse acc : go [] rest
        go acc (c:rest) = go (c:acc) rest
