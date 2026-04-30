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
  , importOpenClawDir
  , ImportResult (..)
  , DirImportResult (..)
    -- * CLI options
  , ImportOptions (..)
  , resolveImportOptions
    -- * Utilities (exported for testing)
  , camelToSnake
  , mapThinkingDefault
  , computeMaxTurns
  ) where

import Control.Exception (IOException, try)
import Control.Monad ((>=>), when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import System.Directory qualified as Dir
import System.FilePath ((</>), takeDirectory, takeExtension)

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
      | Just rest' <- skipTrailingComma rest = go False rest'
    go False (c : rest) = c : go False rest

    -- | If this comma is trailing (only whitespace/comments before ] or }),
    -- return the remaining string starting at the closing bracket.
    skipTrailingComma :: String -> Maybe String
    skipTrailingComma [] = Just []
    skipTrailingComma ('/' : '/' : rest) =
      skipTrailingComma (dropWhile (/= '\n') rest)
    skipTrailingComma (c : rest)
      | c `elem` (" \t\n\r" :: String) = skipTrailingComma rest
      | c == ']' || c == '}' = Just (c : rest)
      | otherwise = Nothing

-- ---------------------------------------------------------------------------
-- OpenClaw config types
-- ---------------------------------------------------------------------------

data OpenClawConfig = OpenClawConfig
  { _oc_defaultModel    :: Maybe Text
  , _oc_workspace       :: Maybe Text
  , _oc_agents          :: [OpenClawAgent]
  , _oc_signal          :: Maybe OpenClawSignal
  , _oc_telegram        :: Maybe OpenClawTelegram
  , _oc_thinkingDefault :: Maybe Text
  , _oc_timeoutSeconds  :: Maybe Int
  , _oc_userTimezone    :: Maybe Text
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
  defaults <- maybe (pure emptyParsedDefaults) parseDefaults mAgents
  agents <- maybe (pure []) parseAgentList mAgents
  mChannels <- o .:? "channels"
  signal <- maybe (pure Nothing) (withObject "channels" (.:? "signal") >=> traverse parseSignalCfg) mChannels
  telegram <- maybe (pure Nothing) (withObject "channels" (.:? "telegram") >=> traverse parseTelegramCfg) mChannels
  pure OpenClawConfig
    { _oc_defaultModel    = _pd_model defaults
    , _oc_workspace       = _pd_workspace defaults
    , _oc_agents          = agents
    , _oc_signal          = signal
    , _oc_telegram        = telegram
    , _oc_thinkingDefault = _pd_thinkingDefault defaults
    , _oc_timeoutSeconds  = _pd_timeoutSeconds defaults
    , _oc_userTimezone    = _pd_userTimezone defaults
    }

data ParsedDefaults = ParsedDefaults
  { _pd_model           :: Maybe Text
  , _pd_workspace       :: Maybe Text
  , _pd_thinkingDefault :: Maybe Text
  , _pd_timeoutSeconds  :: Maybe Int
  , _pd_userTimezone    :: Maybe Text
  }

emptyParsedDefaults :: ParsedDefaults
emptyParsedDefaults = ParsedDefaults Nothing Nothing Nothing Nothing Nothing

parseDefaults :: Value -> Parser ParsedDefaults
parseDefaults = withObject "agents" $ \o -> do
  mDefaults <- o .:? "defaults"
  case mDefaults of
    Nothing -> pure emptyParsedDefaults
    Just defVal -> flip (withObject "defaults") defVal $ \d -> do
      mModelVal <- d .:? "model"
      model <- case mModelVal of
        Just (Object m) -> m .:? "primary"
        Just (String s) -> pure (Just s)
        _               -> pure Nothing
      ws <- d .:? "workspace"
      thinking <- d .:? "thinkingDefault"
      timeout <- d .:? "timeoutSeconds"
      tz <- d .:? "userTimezone"
      pure ParsedDefaults
        { _pd_model           = model
        , _pd_workspace       = ws
        , _pd_thinkingDefault = thinking
        , _pd_timeoutSeconds  = timeout
        , _pd_userTimezone    = tz
        }

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
  , maybe [] (\t -> ["reasoning_effort = " <> quoted (mapThinkingDefault t)]) (_oc_thinkingDefault oc)
  , maybe [] (\s -> ["max_turns = " <> T.pack (show (computeMaxTurns s))]) (_oc_timeoutSeconds oc)
  , maybe [] (\tz -> ["timezone = " <> quoted tz]) (_oc_userTimezone oc)
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

-- | Map OpenClaw thinkingDefault to PureClaw reasoning_effort.
-- "always"/"high" → "high"; "auto"/"medium" → "medium"; everything else → "low"
mapThinkingDefault :: Text -> Text
mapThinkingDefault t = case T.toLower t of
  "always" -> "high"
  "high"   -> "high"
  "auto"   -> "medium"
  "medium" -> "medium"
  _        -> "low"  -- off, low, none, minimal

-- | Convert OpenClaw timeoutSeconds to max_turns (seconds / 10, clamped to [1, 200]).
computeMaxTurns :: Int -> Int
computeMaxTurns secs = min 200 (max 1 (secs `div` 10))

-- ---------------------------------------------------------------------------
-- CLI options for import command
-- ---------------------------------------------------------------------------

-- | Options for the import command.
data ImportOptions = ImportOptions
  { _io_from :: Maybe FilePath
  , _io_to   :: Maybe FilePath
  }
  deriving stock (Show, Eq)

-- | Resolve import options: handle backward compat with a single positional arg.
-- If a positional arg is given:
--   - If it's a directory, use as --from
--   - If it's a .json file, use dirname as --from
-- Defaults: --from = ~/.openclaw, --to = ~/.pureclaw
resolveImportOptions :: ImportOptions -> Maybe FilePath -> IO (FilePath, FilePath)
resolveImportOptions opts mPositional = do
  home <- Dir.getHomeDirectory
  let defaultFrom = home </> ".openclaw"
      defaultTo   = home </> ".pureclaw"
  fromDir <- case mPositional of
    Just pos -> do
      isDir <- Dir.doesDirectoryExist pos
      if isDir
        then pure pos
        else if takeExtension pos == ".json"
          then pure (takeDirectory pos)
          else pure pos  -- let it fail later with a clear error
    Nothing -> pure (fromMaybe defaultFrom (_io_from opts))
  let toDir = fromMaybe defaultTo (_io_to opts)
  pure (fromDir, toDir)

-- ---------------------------------------------------------------------------
-- Full directory import
-- ---------------------------------------------------------------------------

-- | Result of a full OpenClaw directory import.
data DirImportResult = DirImportResult
  { _dir_configResult   :: ImportResult
  , _dir_credentialsOk  :: Bool
  , _dir_deviceId       :: Maybe Text
  , _dir_workspacePath  :: Maybe FilePath
  , _dir_extraWorkspaces :: [FilePath]
  , _dir_cronSkipped    :: Bool
  , _dir_modelsImported :: Bool
  , _dir_warnings       :: [Text]
  }
  deriving stock (Show, Eq)

-- | Import a full OpenClaw state directory into PureClaw.
importOpenClawDir :: FilePath -> FilePath -> IO (Either Text DirImportResult)
importOpenClawDir fromDir toDir = do
  -- 1. Import openclaw.json → config.toml (existing logic)
  let configPath = fromDir </> "openclaw.json"
  configExists <- Dir.doesFileExist configPath
  if not configExists
    then pure (Left $ "No openclaw.json found in " <> T.pack fromDir)
    else do
      let configDir = toDir </> "config"
      configResult <- importOpenClawConfig configPath configDir
      case configResult of
        Left err -> pure (Left err)
        Right ir -> do
          (addWarning, getWarnings) <- newWarnings

          -- 2. Import auth-profiles.json → credentials.json
          credOk <- importAuthProfiles fromDir toDir addWarning

          -- 3. Import device.json → extract deviceId
          mDeviceId <- importDeviceIdentity fromDir addWarning

          -- 4. Copy workspace files → toDir/workspace/
          let srcWorkspace = fromDir </> "workspace"
          wsExists <- Dir.doesDirectoryExist srcWorkspace
          mWorkspace <- if wsExists
            then do
              let destWorkspace = toDir </> "workspace"
              copyWorkspaceFiles srcWorkspace destWorkspace addWarning
              pure (Just destWorkspace)
            else pure Nothing

          -- 5. Find extra workspace-* directories
          extraWs <- findExtraWorkspaces fromDir

          -- 6. Check for cron jobs
          cronExists <- Dir.doesFileExist (fromDir </> "cron" </> "jobs.json")

          -- 7. Import models.json
          modelsOk <- importModels fromDir toDir addWarning

          -- 8. Append workspace/identity sections to config.toml
          appendConfigSections configDir mWorkspace mDeviceId extraWs

          ws <- getWarnings

          pure (Right DirImportResult
            { _dir_configResult   = ir
            , _dir_credentialsOk  = credOk
            , _dir_deviceId       = mDeviceId
            , _dir_workspacePath  = mWorkspace
            , _dir_extraWorkspaces = extraWs
            , _dir_cronSkipped    = cronExists
            , _dir_modelsImported = modelsOk
            , _dir_warnings       = ws
            })

newWarnings :: IO (Text -> IO (), IO [Text])
newWarnings = do
  ref <- newIORef []
  let addW w = modifyIORef' ref (w :)
      getW   = reverse <$> readIORef ref
  pure (addW, getW)

-- | Import auth-profiles.json → credentials.json
importAuthProfiles :: FilePath -> FilePath -> (Text -> IO ()) -> IO Bool
importAuthProfiles fromDir toDir addWarning = do
  let authPath = fromDir </> "agents" </> "main" </> "agent" </> "auth-profiles.json"
  loaded <- loadJson5File authPath
  case loaded of
    Left _ -> do
      addWarning "auth-profiles.json not found — no credentials imported"
      pure False
    Right val -> do
      let mProfiles = parseMaybe (withObject "auth" (.: "profiles")) val
      case mProfiles of
        Nothing -> do
          addWarning "auth-profiles.json has no profiles field"
          pure False
        Just (Object profiles) -> do
          let creds = KM.foldrWithKey extractCred [] profiles
          if null creds
            then do
              addWarning "No API tokens found in auth-profiles.json"
              pure False
            else do
              Dir.createDirectoryIfMissing True toDir
              let credsJson = object (map (uncurry (.=)) creds)
              LBS.writeFile (toDir </> "credentials.json") (encode credsJson)
              pure True
        _ -> do
          addWarning "auth-profiles.json profiles field is not an object"
          pure False
  where
    extractCred _key val acc =
      case parseMaybe parseProfile val of
        Just (provider, token) -> (Key.fromText provider, String token) : acc
        Nothing -> acc

    parseProfile = withObject "profile" $ \o -> do
      provider <- o .: "provider"
      token <- o .: "token"
      pure (provider :: Text, token :: Text)

-- | Import device.json → extract deviceId
importDeviceIdentity :: FilePath -> (Text -> IO ()) -> IO (Maybe Text)
importDeviceIdentity fromDir addWarning = do
  let devicePath = fromDir </> "identity" </> "device.json"
  loaded <- loadJson5File devicePath
  case loaded of
    Left _ -> do
      addWarning "identity/device.json not found — no device ID imported"
      pure Nothing
    Right val ->
      case parseMaybe (withObject "device" (.: "deviceId")) val of
        Just did -> pure (Just did)
        Nothing -> do
          addWarning "identity/device.json has no deviceId field"
          pure Nothing

-- | Find extra workspace-* directories
findExtraWorkspaces :: FilePath -> IO [FilePath]
findExtraWorkspaces fromDir = do
  entries <- try @IOException (Dir.listDirectory fromDir)
  case entries of
    Left _  -> pure []
    Right es -> do
      let candidates = filter ("workspace-" `T.isPrefixOf`) (map T.pack es)
      dirs <- filterM (\e -> Dir.doesDirectoryExist (fromDir </> T.unpack e)) candidates
      pure (map (\d -> fromDir </> T.unpack d) dirs)
  where
    filterM _ []     = pure []
    filterM p (x:xs) = do
      b <- p x
      rest <- filterM p xs
      if b then pure (x : rest) else pure rest

-- | Import models.json → models.json in toDir
importModels :: FilePath -> FilePath -> (Text -> IO ()) -> IO Bool
importModels fromDir toDir addWarning = do
  let modelsPath = fromDir </> "agents" </> "main" </> "agent" </> "models.json"
  loaded <- loadJson5File modelsPath
  case loaded of
    Left _ -> do
      addWarning "agents/main/agent/models.json not found — no model overrides imported"
      pure False
    Right val -> do
      Dir.createDirectoryIfMissing True toDir
      LBS.writeFile (toDir </> "models.json") (encode val)
      pure True

-- | The workspace files that are copied during import.
-- These are the key files that define agent identity, context, and memory.
workspaceFiles :: [FilePath]
workspaceFiles = ["SOUL.md", "AGENTS.md", "MEMORY.md", "USER.md"]

-- | Copy workspace files from the OpenClaw workspace to the PureClaw workspace.
-- Only copies files that exist; missing files are silently skipped.
-- IO failures on individual files are reported as warnings (not fatal).
copyWorkspaceFiles :: FilePath -> FilePath -> (Text -> IO ()) -> IO ()
copyWorkspaceFiles srcDir destDir addWarning = do
  Dir.createDirectoryIfMissing True destDir
  mapM_ copyIfExists workspaceFiles
  where
    copyIfExists name = do
      let src  = srcDir </> name
          dest = destDir </> name
      exists <- Dir.doesFileExist src
      when exists $ do
        result <- try @IOException (Dir.copyFile src dest)
        case result of
          Right () -> pure ()
          Left err -> addWarning ("Failed to copy " <> T.pack name <> ": " <> T.pack (show err))

-- | Append workspace and identity sections to config.toml
appendConfigSections :: FilePath -> Maybe FilePath -> Maybe Text -> [FilePath] -> IO ()
appendConfigSections configDir mWorkspace mDeviceId extraWs = do
  let configPath = configDir </> "config.toml"
  exists <- Dir.doesFileExist configPath
  if not exists
    then pure ()
    else do
      existing <- TIO.readFile configPath
      let sections = T.unlines $ concat
            [ case mWorkspace of
                Nothing -> []
                Just ws ->
                  [ ""
                  , "[workspace]"
                  , "path = " <> quoted (T.pack ws)
                  ]
            , case mDeviceId of
                Nothing  -> []
                Just did ->
                  [ ""
                  , "[identity]"
                  , "device_id = " <> quoted did
                  ]
            , if null extraWs then []
              else
                [ ""
                , "# Additional OpenClaw workspaces found:"
                ] ++ map (\ws -> "# workspace: " <> T.pack ws) extraWs
            ]
      TIO.writeFile configPath (existing <> sections)
