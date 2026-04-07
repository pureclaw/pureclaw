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
  ) where

import Control.Exception qualified as Exc
import Data.Aeson qualified as Aeson
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory qualified as Dir
import System.FilePath ((</>))
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
