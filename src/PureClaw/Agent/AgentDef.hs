module PureClaw.Agent.AgentDef
  ( -- * Agent name (smart constructor)
    AgentName
  , unAgentName
  , mkAgentName
  , AgentNameError (..)
    -- * TOML frontmatter extraction
  , extractFrontmatter
    -- * Agent configuration (TOML frontmatter)
  , AgentConfig (..)
  , defaultAgentConfig
  , parseAgentsMd
  , AgentsMdParseError (..)
    -- * Agent definition
  , AgentDef (..)
    -- * Prompt composition
  , composeAgentPrompt
  , composeAgentPromptWithBootstrap
    -- * Discovery and loading
  , discoverAgents
  , loadAgent
    -- * Workspace validation and setup
  , WorkspaceError (..)
  , validateWorkspace
  , ensureDefaultWorkspace
    -- * Override precedence
  , resolveOverride
  ) where

import Control.Applicative ((<|>))
import Control.Exception qualified as Exc
import Data.Aeson qualified as Aeson
import Data.Char qualified as Char
import Data.Either (rights)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory qualified as Dir
import System.FilePath (isAbsolute, (</>))
import System.Posix.Files qualified as PF
import Toml (TomlCodec, (.=))
import Toml qualified

import PureClaw.Handles.Log (LogHandle (..))

-- | Validated agent name. The data constructor is intentionally NOT exported —
-- the only way to obtain an 'AgentName' is through 'mkAgentName'.
newtype AgentName = AgentName { unAgentName :: Text }
  deriving stock (Eq, Ord, Show)

-- | Reasons a raw 'Text' cannot be promoted to an 'AgentName'.
data AgentNameError
  = AgentNameEmpty
  | AgentNameTooLong
  | AgentNameInvalidChars Text
  | AgentNameLeadingDot
  deriving stock (Eq, Show)

-- | Maximum allowed length for an agent name.
agentNameMaxLength :: Int
agentNameMaxLength = 64

-- | Valid character predicate: ASCII letters, digits, underscore, hyphen.
isValidAgentNameChar :: Char -> Bool
isValidAgentNameChar c =
  Char.isAsciiUpper c
    || Char.isAsciiLower c
    || Char.isDigit c
    || c == '_'
    || c == '-'

-- | Smart constructor. Rejects empty names, names longer than 64 characters,
-- names with a leading dot (hidden), and names containing any character
-- outside @[a-zA-Z0-9_-]@ (which in particular rejects @.@, @/@, and null).
mkAgentName :: Text -> Either AgentNameError AgentName
mkAgentName raw
  | T.null raw = Left AgentNameEmpty
  | T.length raw > agentNameMaxLength = Left AgentNameTooLong
  | T.head raw == '.' && T.all isValidAgentNameChar (T.tail raw) = Left AgentNameLeadingDot
  | not (T.all isValidAgentNameChar raw) = Left (AgentNameInvalidChars raw)
  | otherwise = Right (AgentName raw)

-- | Custom 'Aeson.FromJSON' routes through 'mkAgentName' so that invalid
-- names on disk cannot bypass the smart constructor.
-- | Split a TOML frontmatter fence off the front of a document. Recognizes a
-- leading @---\\n@, a terminating @\\n---\\n@, and returns the inner block as
-- the first component and the body after the closer as the second. If the
-- input does not start with a fence or the fence is not closed, returns
-- @(Nothing, originalInput)@ unchanged.
extractFrontmatter :: Text -> (Maybe Text, Text)
extractFrontmatter input =
  case T.stripPrefix "---\n" input of
    Nothing -> (Nothing, input)
    Just rest ->
      case T.breakOn "\n---\n" rest of
        (_, "") -> (Nothing, input)  -- no closing fence
        (inner, afterBreak) ->
          let body = T.drop (T.length ("\n---\n" :: Text)) afterBreak
          in (Just inner, body)

instance Aeson.FromJSON AgentName where
  parseJSON = Aeson.withText "AgentName" $ \t ->
    case mkAgentName t of
      Right n -> pure n
      Left err -> fail ("invalid AgentName: " ++ show err)

-- | Configuration loaded from the TOML frontmatter of an @AGENTS.md@ file.
-- All fields are optional; unknown fields are ignored by the codec.
data AgentConfig = AgentConfig
  { _ac_model       :: Maybe Text
  , _ac_toolProfile :: Maybe Text
  , _ac_workspace   :: Maybe Text
  } deriving stock (Eq, Show)

-- | An 'AgentConfig' with every field unset.
defaultAgentConfig :: AgentConfig
defaultAgentConfig = AgentConfig Nothing Nothing Nothing

agentConfigCodec :: TomlCodec AgentConfig
agentConfigCodec = AgentConfig
  <$> Toml.dioptional (Toml.text "model")        .= _ac_model
  <*> Toml.dioptional (Toml.text "tool_profile") .= _ac_toolProfile
  <*> Toml.dioptional (Toml.text "workspace")    .= _ac_workspace

-- | Errors that may occur while parsing an @AGENTS.md@ document.
newtype AgentsMdParseError
  = AgentsMdTomlError Text
  deriving stock (Eq, Show)

-- | Parse an @AGENTS.md@ document: extract the optional TOML frontmatter,
-- decode it as an 'AgentConfig', and return the remaining body. A document
-- with no frontmatter yields 'defaultAgentConfig' and the whole input as the
-- body.
parseAgentsMd :: Text -> Either AgentsMdParseError (AgentConfig, Text)
parseAgentsMd input =
  case extractFrontmatter input of
    (Nothing, body) -> Right (defaultAgentConfig, body)
    (Just "", body) -> Right (defaultAgentConfig, body)
    (Just toml, body) ->
      case Toml.decode agentConfigCodec toml of
        Left errs -> Left (AgentsMdTomlError (Toml.prettyTomlDecodeErrors errs))
        Right cfg -> Right (cfg, body)

-- | A discovered and loaded agent: its validated name, the on-disk directory
-- that holds its bootstrap files, and its parsed @AGENTS.md@ frontmatter
-- (falling back to 'defaultAgentConfig' when no frontmatter is present).
data AgentDef = AgentDef
  { _ad_name   :: AgentName
  , _ad_dir    :: FilePath
  , _ad_config :: AgentConfig
  } deriving stock (Eq, Show)

-- | Bootstrap file types, in the order they should be injected into the
-- system prompt.
data SectionKind = SoulK | UserK | AgentsK | MemoryK | IdentityK | ToolsK | BootstrapK
  deriving stock (Eq, Show)

sectionFileName :: SectionKind -> FilePath
sectionFileName SoulK      = "SOUL.md"
sectionFileName UserK      = "USER.md"
sectionFileName AgentsK    = "AGENTS.md"
sectionFileName MemoryK    = "MEMORY.md"
sectionFileName IdentityK  = "IDENTITY.md"
sectionFileName ToolsK     = "TOOLS.md"
sectionFileName BootstrapK = "BOOTSTRAP.md"

sectionMarker :: SectionKind -> Text
sectionMarker SoulK      = "--- SOUL ---"
sectionMarker UserK      = "--- USER ---"
sectionMarker AgentsK    = "--- AGENTS ---"
sectionMarker MemoryK    = "--- MEMORY ---"
sectionMarker IdentityK  = "--- IDENTITY ---"
sectionMarker ToolsK     = "--- TOOLS ---"
sectionMarker BootstrapK = "--- BOOTSTRAP ---"

-- | Maximum raw file size we will read. Anything larger is rejected with a
-- log warning and skipped.
maxBootstrapFileBytes :: Integer
maxBootstrapFileBytes = 1024 * 1024

-- | Truncate a section body to @limit@ characters, appending the exact
-- truncation marker. Strings at or under the limit are returned as-is.
truncateSection :: Int -> Text -> Text
truncateSection limit txt
  | T.length txt <= limit = txt
  | otherwise =
      T.take limit txt
        <> "\n[...truncated at " <> T.pack (show limit) <> " chars...]"

-- | Read a single bootstrap section file, applying size/empty/truncation
-- rules. Returns 'Nothing' when the file is missing, empty (including
-- whitespace-only), or rejected as oversized.
readSection :: LogHandle -> FilePath -> SectionKind -> Int -> IO (Maybe Text)
readSection lg dir kind limit = do
  let path = dir </> sectionFileName kind
  exists <- Dir.doesFileExist path
  if not exists
    then pure Nothing
    else do
      size <- Dir.getFileSize path
      if size > maxBootstrapFileBytes
        then do
          _lh_logWarn lg $
            "Skipping oversized bootstrap file (>" <> T.pack (show maxBootstrapFileBytes) <>
            " bytes): " <> T.pack path
          pure Nothing
        else do
          raw <- Exc.try (TIO.readFile path) :: IO (Either Exc.IOException Text)
          case raw of
            Left e -> do
              _lh_logWarn lg $
                "Failed to read bootstrap file " <> T.pack path <> ": " <> T.pack (show e)
              pure Nothing
            Right txt ->
              let contents = case kind of
                    AgentsK -> case parseAgentsMd txt of
                      Right (_, body) -> body
                      Left _ -> txt
                    _ -> txt
                  trimmed = T.dropWhileEnd Char.isSpace contents
              in if T.null (T.strip trimmed)
                   then pure Nothing
                   else pure (Just (truncateSection limit trimmed))

-- | Compose a system prompt from an agent's bootstrap files. Files are read
-- in the fixed injection order (SOUL, USER, AGENTS, MEMORY, IDENTITY, TOOLS,
-- BOOTSTRAP), missing or empty (including whitespace-only) files are
-- skipped, oversized files (>1MB) are rejected with a log warning, and any
-- section exceeding @limit@ characters is truncated with the exact marker
-- @"\\n[...truncated at \<limit\> chars...]"@.
--
-- For @AGENTS.md@, only the body after the TOML frontmatter fence is
-- injected (the frontmatter itself lives in '_ad_config').
composeAgentPrompt :: LogHandle -> AgentDef -> Int -> IO Text
composeAgentPrompt lg def limit =
  composeAgentPromptWithBootstrap lg def limit False

-- | Like 'composeAgentPrompt', but when @bootstrapConsumed@ is 'True' the
-- @BOOTSTRAP.md@ section is skipped entirely (used after the first
-- @StreamDone@ in a session).
composeAgentPromptWithBootstrap :: LogHandle -> AgentDef -> Int -> Bool -> IO Text
composeAgentPromptWithBootstrap lg def limit bootstrapConsumed = do
  let kinds =
        [ SoulK, UserK, AgentsK, MemoryK, IdentityK, ToolsK ]
        <> [ BootstrapK | not bootstrapConsumed ]
  sections <- mapM (\k -> readSection lg (_ad_dir def) k limit) kinds
  let rendered = [ sectionMarker k <> "\n" <> body
                 | (k, Just body) <- zip kinds sections
                 ]
  pure (T.intercalate "\n\n" rendered)

-- | Enumerate agent directories under @parent@. Subdirectories whose name
-- is not a valid 'AgentName' are skipped with a log warning. A missing
-- parent directory returns the empty list (no error).
discoverAgents :: LogHandle -> FilePath -> IO [AgentDef]
discoverAgents lg parent = do
  exists <- Dir.doesDirectoryExist parent
  if not exists
    then pure []
    else do
      entries <- Dir.listDirectory parent
      results <- mapM tryOne entries
      pure (rights results)
  where
    tryOne entry = do
      let full = parent </> entry
      isDir <- Dir.doesDirectoryExist full
      if not isDir
        then pure (Left ())
        else case mkAgentName (T.pack entry) of
          Left err -> do
            _lh_logWarn lg $
              "Skipping invalid agent directory name " <> T.pack (show entry) <>
              ": " <> T.pack (show err)
            pure (Left ())
          Right name -> do
            cfg <- loadAgentConfig full
            pure (Right AgentDef { _ad_name = name, _ad_dir = full, _ad_config = cfg })

-- | Load an agent by validated name from @parent@. Returns 'Nothing' if the
-- corresponding directory does not exist.
loadAgent :: FilePath -> AgentName -> IO (Maybe AgentDef)
loadAgent parent name = do
  let dir = parent </> T.unpack (unAgentName name)
  exists <- Dir.doesDirectoryExist dir
  if not exists
    then pure Nothing
    else do
      cfg <- loadAgentConfig dir
      pure (Just AgentDef { _ad_name = name, _ad_dir = dir, _ad_config = cfg })

-- | Read and parse the @AGENTS.md@ frontmatter inside an agent directory.
-- If the file is missing or fails to parse, returns 'defaultAgentConfig'.
loadAgentConfig :: FilePath -> IO AgentConfig
loadAgentConfig dir = do
  let path = dir </> "AGENTS.md"
  exists <- Dir.doesFileExist path
  if not exists
    then pure defaultAgentConfig
    else do
      raw <- Exc.try (TIO.readFile path) :: IO (Either Exc.IOException Text)
      case raw of
        Left _ -> pure defaultAgentConfig
        Right txt -> case parseAgentsMd txt of
          Right (cfg, _) -> pure cfg
          Left _ -> pure defaultAgentConfig

-- | Validation error for an agent workspace path.
data WorkspaceError
  = WorkspaceNotAbsolute Text
  | WorkspaceDoesNotExist FilePath
  | WorkspaceDenied FilePath Text  -- ^ denied canonical path + reason
  deriving stock (Show, Eq)

-- | Absolute system directories that must never be used as a workspace.
-- Checked as equality or prefix (@base <> "/"@ prefix) against the
-- canonicalized input.
deniedAbsoluteRoots :: [FilePath]
deniedAbsoluteRoots =
  [ "/", "/etc", "/usr", "/bin", "/sbin", "/var", "/sys", "/proc", "/dev" ]

-- | Home-relative segments that must never be used as a workspace. The
-- effective denied path is @homeDir </> segment@.
deniedHomeSegments :: [FilePath]
deniedHomeSegments =
  [ ".ssh", ".gnupg", ".aws", ".config", ".pureclaw" ]

-- | @isUnderPath base target@ is 'True' iff @target@ equals @base@ or is
-- inside @base@. Both arguments are expected to already be canonicalized.
isUnderPath :: FilePath -> FilePath -> Bool
isUnderPath base target =
  target == base
    || (base /= "/" && (base <> "/") `isPrefixOf` target)

-- | Expand a leading tilde in a raw workspace path against a supplied home dir.
expandTilde :: FilePath -> Text -> FilePath
expandTilde home raw
  | raw == "~" = home
  | Just rest <- T.stripPrefix "~/" raw = home </> T.unpack rest
  | otherwise = T.unpack raw

-- | Validate a user-supplied workspace path. Tilde-expands with the supplied
-- home dir, requires the path to be absolute, requires the directory to
-- exist, canonicalizes (resolving symlinks), then checks it against the
-- denylist of system and home-relative paths.
validateWorkspace :: FilePath -> Text -> IO (Either WorkspaceError FilePath)
validateWorkspace homeDir raw = do
  let expanded = expandTilde homeDir raw
  if not (isAbsolute expanded)
    then pure (Left (WorkspaceNotAbsolute raw))
    else do
      exists <- Dir.doesDirectoryExist expanded
      if not exists
        then pure (Left (WorkspaceDoesNotExist expanded))
        else do
          canonical <- Dir.canonicalizePath expanded
          reason <- checkDenylist homeDir canonical
          case reason of
            Just r -> pure (Left (WorkspaceDenied canonical r))
            Nothing -> pure (Right canonical)

-- | Check a canonicalized path against the denylist. Returns 'Just' a
-- human-readable reason if denied, 'Nothing' otherwise. Denylist entries
-- are themselves canonicalized (when they exist) so that e.g. macOS's
-- @/etc -> /private/etc@ symlink is handled correctly.
checkDenylist :: FilePath -> FilePath -> IO (Maybe Text)
checkDenylist homeDir canonical = do
  absHits <- mapM canonicalizeIfExists deniedAbsoluteRoots
  let absMatch =
        [ orig
        | (orig, canon) <- zip deniedAbsoluteRoots absHits
        , isUnderPath canon canonical
        ]
  case absMatch of
    (hit : _) -> pure (Just ("is inside system directory " <> T.pack hit))
    [] -> do
      homeCanons <- mapM (canonicalizeIfExists . (homeDir </>)) deniedHomeSegments
      let homeMatch =
            [ seg
            | (seg, canon) <- zip deniedHomeSegments homeCanons
            , isUnderPath canon canonical
            ]
      case homeMatch of
        (seg : _) -> pure (Just ("is inside sensitive home directory ~/" <> T.pack seg))
        [] -> pure Nothing

-- | Canonicalize a path if it exists; otherwise return it unchanged. Used
-- to normalize denylist entries so symlinks like @/etc -> /private/etc@
-- resolve to the same canonical form as user-supplied paths.
canonicalizeIfExists :: FilePath -> IO FilePath
canonicalizeIfExists p = do
  exists <- Dir.doesDirectoryExist p
  if exists then Dir.canonicalizePath p else pure p

-- | Ensure the default workspace directory for an agent exists with
-- @0o700@ permissions. Creates parent directories as needed. Idempotent.
-- The workspace path is @\<pureclawDir\>/agents/\<name\>/workspace/@.
ensureDefaultWorkspace :: FilePath -> AgentName -> IO FilePath
ensureDefaultWorkspace pureclawDir name = do
  let workspaceDir =
        pureclawDir </> "agents" </> T.unpack (unAgentName name) </> "workspace"
  Dir.createDirectoryIfMissing True workspaceDir
  PF.setFileMode workspaceDir PF.ownerModes
  pure workspaceDir

-- | Resolve a config value using precedence: CLI > frontmatter > config >
-- default. Returns the first non-'Nothing' argument.
resolveOverride :: Maybe a -> Maybe a -> Maybe a -> Maybe a -> Maybe a
resolveOverride cli fm cfg def = cli <|> fm <|> cfg <|> def
