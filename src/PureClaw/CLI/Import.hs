module PureClaw.CLI.Import
  ( -- * JSON5 preprocessing
    stripJson5
    -- * OpenClaw config parsing
  , OpenClawConfig (..)
  , OpenClawAgent (..)
  , OpenClawSignal (..)
  , OpenClawTelegram (..)
  , parseOpenClawConfig
    -- * $include resolution
  , resolveIncludes
    -- * Import execution
  , importOpenClawConfig
  , ImportResult (..)
    -- * Utilities (exported for testing)
  , camelToSnake
  ) where

import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Char qualified as Char
import Data.Maybe (fromMaybe)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import System.Directory qualified as Dir
import System.FilePath ((</>), takeDirectory)

-- ---------------------------------------------------------------------------
-- JSON5 preprocessor
-- ---------------------------------------------------------------------------

-- | Strip JSON5 features (// comments, trailing commas) to produce valid JSON.
-- Handles comments inside strings correctly (does not strip them).
-- Does NOT handle: block comments, hex literals, multiline strings,
-- unquoted keys, or other advanced JSON5 features.
stripJson5 :: Text -> Text
stripJson5 = T.pack . go False . T.unpack
  where
    go :: Bool -> String -> String
    go _ [] = []
    go True ('\\' : c : rest) = '\\' : c : go True rest
    go True ('"' : rest) = '"' : go False rest
    go True (c : rest) = c : go True rest
    go False ('"' : rest) = '"' : go True rest
    go False ('/' : '/' : rest) = go False (dropWhile (/= '\n') rest)
    go False (',' : rest)
      | trailingComma rest = go False rest
    go False (c : rest) = c : go False rest

    trailingComma :: String -> Bool
    trailingComma [] = True
    trailingComma (c : rest)
      | c `elem` (" \t\n\r" :: String) = trailingComma rest
      | c == ']' || c == '}' = True
      | otherwise = False

-- ---------------------------------------------------------------------------
-- OpenClaw config types
-- ---------------------------------------------------------------------------

data OpenClawConfig = OpenClawConfig
  { _oc_defaultModel :: Maybe Text
  , _oc_workspace    :: Maybe Text
  , _oc_agents       :: [OpenClawAgent]
  , _oc_signal       :: Maybe OpenClawSignal
  , _oc_telegram     :: Maybe OpenClawTelegram
  }
  deriving stock (Show, Eq)

data OpenClawAgent = OpenClawAgent
  { _oca_id           :: Text
  , _oca_systemPrompt :: Maybe Text
  , _oca_model        :: Maybe Text
  , _oca_toolProfile  :: Maybe Text
  , _oca_workspace    :: Maybe Text
  }
  deriving stock (Show, Eq)

data OpenClawSignal = OpenClawSignal
  { _ocs_account   :: Maybe Text
  , _ocs_dmPolicy  :: Maybe Text
  , _ocs_allowFrom :: Maybe [Text]
  }
  deriving stock (Show, Eq)

data OpenClawTelegram = OpenClawTelegram
  { _oct_botToken  :: Maybe Text
  , _oct_dmPolicy  :: Maybe Text
  , _oct_allowFrom :: Maybe [Text]
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- OpenClaw config parsing
-- ---------------------------------------------------------------------------

parseOpenClawConfig :: Value -> Either String OpenClawConfig
parseOpenClawConfig = parseEither parseOC

parseOC :: Value -> Parser OpenClawConfig
parseOC = withObject "OpenClawConfig" $ \o -> do
  mAgents <- o .:? "agents"
  defaults <- maybe (pure emptyDefaults) parseDefaults mAgents
  agents <- maybe (pure []) parseAgentList mAgents
  mChannels <- o .:? "channels"
  signal <- maybe (pure Nothing) (withObject "channels" (.:? "signal") >=> traverse parseSignalCfg) mChannels
  telegram <- maybe (pure Nothing) (withObject "channels" (.:? "telegram") >=> traverse parseTelegramCfg) mChannels
  pure OpenClawConfig
    { _oc_defaultModel = fst defaults
    , _oc_workspace    = snd defaults
    , _oc_agents       = agents
    , _oc_signal       = signal
    , _oc_telegram     = telegram
    }

emptyDefaults :: (Maybe Text, Maybe Text)
emptyDefaults = (Nothing, Nothing)

parseDefaults :: Value -> Parser (Maybe Text, Maybe Text)
parseDefaults = withObject "agents" $ \o -> do
  mDefaults <- o .:? "defaults"
  case mDefaults of
    Nothing -> pure emptyDefaults
    Just defVal -> flip (withObject "defaults") defVal $ \d -> do
      mModelVal <- d .:? "model"
      model <- case mModelVal of
        Just (Object m) -> m .:? "primary"
        Just (String s) -> pure (Just s)
        _               -> pure Nothing
      ws <- d .:? "workspace"
      pure (model, ws)

parseAgentList :: Value -> Parser [OpenClawAgent]
parseAgentList = withObject "agents" $ \o -> do
  mList <- o .:? "list"
  case mList of
    Nothing -> pure []
    Just agents -> mapM parseAgentDef agents

parseAgentDef :: Value -> Parser OpenClawAgent
parseAgentDef = withObject "OpenClawAgent" $ \o -> do
  agentId <- o .: "id"
  systemPrompt <- o .:? "systemPrompt"
  mModelVal <- o .:? "model"
  let model = case mModelVal of
        Just (Object m) -> parseMaybe (.: "primary") m
        Just (String s) -> Just s
        _               -> Nothing
  mTools <- o .:? "tools"
  let toolProfile = mTools >>= parseMaybe (withObject "tools" (.: "profile"))
  ws <- o .:? "workspace"
  pure OpenClawAgent
    { _oca_id           = agentId
    , _oca_systemPrompt = systemPrompt
    , _oca_model        = model
    , _oca_toolProfile  = toolProfile
    , _oca_workspace    = ws
    }

parseSignalCfg :: Value -> Parser OpenClawSignal
parseSignalCfg = withObject "signal" $ \o ->
  OpenClawSignal <$> o .:? "account" <*> o .:? "dmPolicy" <*> o .:? "allowFrom"

parseTelegramCfg :: Value -> Parser OpenClawTelegram
parseTelegramCfg = withObject "telegram" $ \o ->
  OpenClawTelegram <$> o .:? "botToken" <*> o .:? "dmPolicy" <*> o .:? "allowFrom"

-- ---------------------------------------------------------------------------
-- $include resolution
-- ---------------------------------------------------------------------------

-- | Resolve $include directives in a JSON Value, up to a max depth.
resolveIncludes :: Int -> FilePath -> Value -> IO Value
resolveIncludes maxDepth baseDir val
  | maxDepth <= 0 = pure val
  | otherwise = case val of
      Object o -> case KM.lookup (Key.fromText "$include") o of
        Just (String path) -> do
          let fullPath = baseDir </> T.unpack path
          included <- loadJson5File fullPath
          case included of
            Left _    -> pure val
            Right inc -> resolveIncludes (maxDepth - 1) (takeDirectory fullPath) inc
        Just (Array paths) -> do
          resolved <- mapM (resolveIncludePath (maxDepth - 1) baseDir) (V.toList paths)
          pure (foldl deepMerge (Object KM.empty) resolved)
        _ -> do
          resolved <- KM.traverseWithKey (\_ v -> resolveIncludes maxDepth baseDir v) o
          pure (Object resolved)
      _ -> pure val

resolveIncludePath :: Int -> FilePath -> Value -> IO Value
resolveIncludePath depth baseDir (String path) = do
  let fullPath = baseDir </> T.unpack path
  loaded <- loadJson5File fullPath
  case loaded of
    Left _    -> pure (Object KM.empty)
    Right inc -> resolveIncludes depth (takeDirectory fullPath) inc
resolveIncludePath _ _ other = pure other

deepMerge :: Value -> Value -> Value
deepMerge (Object a) (Object b) = Object (KM.unionWith deepMerge a b)
deepMerge _ b = b

-- | Load and parse a JSON5 file.
loadJson5File :: FilePath -> IO (Either String Value)
loadJson5File path = do
  result <- try @IOException (TIO.readFile path)
  case result of
    Left err -> pure (Left (show err))
    Right text ->
      let cleaned = stripJson5 text
          bs = TE.encodeUtf8 cleaned
      in pure (eitherDecodeStrict' bs)

-- ---------------------------------------------------------------------------
-- Import execution
-- ---------------------------------------------------------------------------

data ImportResult = ImportResult
  { _ir_configWritten :: Bool
  , _ir_agentsWritten :: [Text]
  , _ir_skippedFields :: [Text]
  , _ir_warnings      :: [Text]
  }
  deriving stock (Show, Eq)

-- | Import an OpenClaw config file into PureClaw's directory structure.
-- Writes to @configDir/config.toml@ and @configDir/agents/*/AGENTS.md@.
importOpenClawConfig :: FilePath -> FilePath -> IO (Either Text ImportResult)
importOpenClawConfig openclawPath configDir = do
  loaded <- loadJson5File openclawPath
  case loaded of
    Left err -> pure (Left ("Failed to parse OpenClaw config: " <> T.pack err))
    Right rawJson -> do
      resolved <- resolveIncludes 3 (takeDirectory openclawPath) rawJson
      case parseOpenClawConfig resolved of
        Left err -> pure (Left ("Failed to extract config fields: " <> T.pack err))
        Right ocConfig -> writeImportedConfig configDir ocConfig

writeImportedConfig :: FilePath -> OpenClawConfig -> IO (Either Text ImportResult)
writeImportedConfig configDir ocConfig = do
  Dir.createDirectoryIfMissing True configDir
  let agentsDir = configDir </> "agents"

  -- Write main config.toml
  let configContent = buildConfigToml ocConfig
  TIO.writeFile (configDir </> "config.toml") configContent

  -- Write agent AGENTS.md files
  agentNames <- mapM (writeAgentFile agentsDir) (_oc_agents ocConfig)

  -- Write default agent if there are defaults
  case (_oc_defaultModel ocConfig, _oc_workspace ocConfig) of
    (Nothing, Nothing) -> pure ()
    _ -> do
      let defaultDir = agentsDir </> "default"
      Dir.createDirectoryIfMissing True defaultDir
      TIO.writeFile (defaultDir </> "AGENTS.md") $ T.unlines
        [ "---"
        , maybe "" ("model: " <>) (_oc_defaultModel ocConfig)
        , maybe "" ("workspace: " <>) (_oc_workspace ocConfig)
        , "---"
        , ""
        , "Default PureClaw agent."
        ]

  pure (Right ImportResult
    { _ir_configWritten = True
    , _ir_agentsWritten = agentNames
    , _ir_skippedFields = []
    , _ir_warnings      = []
    })

buildConfigToml :: OpenClawConfig -> Text
buildConfigToml oc = T.unlines $ concatMap (filter (not . T.null))
  [ maybe [] (\m -> ["model = " <> quoted m]) (_oc_defaultModel oc)
  , case _oc_signal oc of
      Nothing -> []
      Just sig ->
        [ ""
        , "[signal]"
        ] ++ catMaybes
        [ fmap (\a -> "account = " <> quoted a) (_ocs_account sig)
        , fmap (\p -> "dm_policy = " <> quoted (camelToSnake p)) (_ocs_dmPolicy sig)
        , fmap (\af -> "allow_from = " <> fmtList af) (_ocs_allowFrom sig)
        ]
  , case _oc_telegram oc of
      Nothing -> []
      Just tg ->
        [ ""
        , "[telegram]"
        ] ++ catMaybes
        [ fmap (\t -> "bot_token = " <> quoted t) (_oct_botToken tg)
        , fmap (\p -> "dm_policy = " <> quoted (camelToSnake p)) (_oct_dmPolicy tg)
        , fmap (\af -> "allow_from = " <> fmtList af) (_oct_allowFrom tg)
        ]
  ]
  where
    catMaybes = foldr (\x acc -> maybe acc (: acc) x) []

writeAgentFile :: FilePath -> OpenClawAgent -> IO Text
writeAgentFile agentsDir agent = do
  let agentDir = agentsDir </> T.unpack (_oca_id agent)
  Dir.createDirectoryIfMissing True agentDir
  let frontmatterLines = filter (/= "")
        [ maybe "" ("model: " <>) (_oca_model agent)
        , maybe "" ("tool_profile: " <>) (_oca_toolProfile agent)
        , maybe "" ("workspace: " <>) (_oca_workspace agent)
        ]
      hasFrontmatter = not (null frontmatterLines)
      header = if hasFrontmatter
        then ["---"] ++ frontmatterLines ++ ["---", ""]
        else []
      body = fromMaybe "" (_oca_systemPrompt agent)
  TIO.writeFile (agentDir </> "AGENTS.md") (T.unlines (header ++ [body]))
  pure (_oca_id agent)

quoted :: Text -> Text
quoted t = "\"" <> T.replace "\"" "\\\"" t <> "\""

fmtList :: [Text] -> Text
fmtList xs = "[" <> T.intercalate ", " (map quoted xs) <> "]"

camelToSnake :: Text -> Text
camelToSnake = T.concatMap $ \c ->
  if Char.isAsciiUpper c
    then T.pack ['_', Char.toLower c]
    else T.singleton c
