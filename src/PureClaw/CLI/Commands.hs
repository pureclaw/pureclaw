module PureClaw.CLI.Commands
  ( -- * Entry point
    runCLI
    -- * Command types (exported for testing)
  , Command (..)
  , ChatOptions (..)
  , chatOptionsParser
    -- * Enums (exported for testing)
  , ProviderType (..)
  , MemoryBackend (..)
    -- * Policy (exported for testing)
  , buildPolicy
  ) where

import Control.Exception (IOException, bracket_, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist)

import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO
import System.Process.Typed qualified as P

import PureClaw.Auth.AnthropicOAuth
import PureClaw.CLI.Config

import PureClaw.Agent.Env
import PureClaw.Agent.Identity
import PureClaw.Agent.Loop
import PureClaw.Handles.Transcript
import PureClaw.Channels.CLI
import PureClaw.Channels.Signal
import PureClaw.CLI.Import
  ( ImportOptions (..)
  , DirImportResult (..)
  , ImportResult (..)
  , importOpenClawDir
  , resolveImportOptions
  )
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.File
import PureClaw.Handles.Log
import PureClaw.Handles.Memory
import PureClaw.Handles.Network
import PureClaw.Handles.Shell
import PureClaw.Memory.Markdown
import PureClaw.Memory.SQLite
import PureClaw.Providers.Anthropic
import PureClaw.Providers.Class
import PureClaw.Providers.Ollama
import PureClaw.Providers.OpenAI
import PureClaw.Providers.OpenRouter
import PureClaw.Security.Policy
import PureClaw.Security.Secrets
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Passphrase
import PureClaw.Security.Vault.Plugin
import PureClaw.Tools.FileRead
import PureClaw.Tools.FileWrite
import PureClaw.Tools.Git
import PureClaw.Tools.HttpRequest
import PureClaw.Tools.Memory
import PureClaw.Tools.Registry
import PureClaw.Tools.Shell

-- | Supported LLM providers.
data ProviderType
  = Anthropic
  | OpenAI
  | OpenRouter
  | Ollama
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | Supported memory backends.
data MemoryBackend
  = NoMemory
  | SQLiteMemory
  | MarkdownMemory
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | CLI chat options.
-- Fields with defaults use 'Maybe' so config file values can fill in omitted flags.
data ChatOptions = ChatOptions
  { _co_model         :: Maybe String
  , _co_apiKey        :: Maybe String
  , _co_system        :: Maybe String
  , _co_provider      :: Maybe ProviderType
  , _co_allowCommands :: [String]
  , _co_autonomy      :: Maybe AutonomyLevel
  , _co_channel       :: Maybe String
  , _co_memory        :: Maybe MemoryBackend
  , _co_soul          :: Maybe String
  , _co_config        :: Maybe FilePath
  , _co_noVault       :: Bool
  , _co_oauth         :: Bool
  }
  deriving stock (Show, Eq)

-- | Parser for chat options.
chatOptionsParser :: Parser ChatOptions
chatOptionsParser = ChatOptions
  <$> optional (strOption
      ( long "model"
     <> short 'm'
     <> help "Model to use (default: claude-sonnet-4-20250514)"
      ))
  <*> optional (strOption
      ( long "api-key"
     <> help "API key (default: from config file or env var for chosen provider)"
      ))
  <*> optional (strOption
      ( long "system"
     <> short 's'
     <> help "System prompt (overrides SOUL.md)"
      ))
  <*> optional (option parseProviderType
      ( long "provider"
     <> short 'p'
     <> help "LLM provider: anthropic, openai, openrouter, ollama (default: anthropic)"
      ))
  <*> many (strOption
      ( long "allow"
     <> short 'a'
     <> help "Allow a shell command (repeatable, e.g. --allow git --allow ls)"
      ))
  <*> optional (option parseAutonomyLevel
      ( long "autonomy"
     <> help "Autonomy level: full, supervised, deny (default: deny with no --allow, full with --allow)"
      ))
  <*> optional (strOption
      ( long "channel"
     <> help "Chat channel: cli, signal, telegram (default: cli)"
      ))
  <*> optional (option parseMemoryBackend
      ( long "memory"
     <> help "Memory backend: none, sqlite, markdown (default: none)"
      ))
  <*> optional (strOption
      ( long "soul"
     <> help "Path to SOUL.md identity file (default: ./SOUL.md if it exists)"
      ))
  <*> optional (strOption
      ( long "config"
     <> short 'c'
     <> help "Path to config file (default: ~/.pureclaw/config.toml or ~/.config/pureclaw/config.toml)"
      ))
  <*> switch
      ( long "no-vault"
     <> help "Disable vault even if configured in config file"
      )
  <*> switch
      ( long "oauth"
     <> help "Authenticate with Anthropic via OAuth (opens browser). Tokens are cached in the vault."
      )

-- | Parse a provider type from a CLI string.
parseProviderType :: ReadM ProviderType
parseProviderType = eitherReader $ \s -> case s of
  "anthropic"  -> Right Anthropic
  "openai"     -> Right OpenAI
  "openrouter" -> Right OpenRouter
  "ollama"     -> Right Ollama
  _            -> Left $ "Unknown provider: " <> s <> ". Choose: anthropic, openai, openrouter, ollama"

-- | Display a provider type as a CLI string.
providerToText :: ProviderType -> String
providerToText Anthropic  = "anthropic"
providerToText OpenAI     = "openai"
providerToText OpenRouter = "openrouter"
providerToText Ollama     = "ollama"

-- | Parse a memory backend from a CLI string.
parseMemoryBackend :: ReadM MemoryBackend
parseMemoryBackend = eitherReader $ \s -> case s of
  "none"     -> Right NoMemory
  "sqlite"   -> Right SQLiteMemory
  "markdown" -> Right MarkdownMemory
  _          -> Left $ "Unknown memory backend: " <> s <> ". Choose: none, sqlite, markdown"

-- | Display a memory backend as a CLI string.
memoryToText :: MemoryBackend -> String
memoryToText NoMemory       = "none"
memoryToText SQLiteMemory   = "sqlite"
memoryToText MarkdownMemory = "markdown"

-- | Top-level CLI command.
data Command
  = CmdTui ChatOptions       -- ^ Interactive terminal UI (always CLI channel)
  | CmdGateway ChatOptions   -- ^ Gateway mode (channel from config/flags)
  | CmdImport ImportOptions (Maybe FilePath)  -- ^ Import an OpenClaw state directory
  deriving stock (Show, Eq)

-- | Full CLI parser with subcommands.
cliParserInfo :: ParserInfo Command
cliParserInfo = info (commandParser <**> helper)
  ( fullDesc
 <> progDesc "Haskell-native AI agent runtime"
 <> header "pureclaw — Haskell-native AI agent runtime"
  )

-- | Parser for the top-level command.
-- @pureclaw tui@ — interactive terminal
-- @pureclaw gateway run@ — channel-aware agent
-- No subcommand defaults to @tui@ for backward compatibility.
commandParser :: Parser Command
commandParser = subparser
    ( command "tui" (info (CmdTui <$> chatOptionsParser <**> helper)
        (progDesc "Interactive terminal chat UI"))
   <> command "gateway" (info (subparser
        (command "run" (info (CmdGateway <$> chatOptionsParser <**> helper)
          (progDesc "Run the the PureClaw gateway")))
        <**> helper)
        (progDesc "PureClaw Gateway"))
   <> command "import" (info (importParser <**> helper)
        (progDesc "Import an OpenClaw state directory"))
    )
  <|> (CmdTui <$> chatOptionsParser)  -- default to tui when no subcommand

-- | Parser for the import subcommand.
importParser :: Parser Command
importParser = CmdImport
  <$> (ImportOptions
    <$> optional (strOption
        ( long "from"
       <> help "Source OpenClaw state directory (default: ~/.openclaw)"
        ))
    <*> optional (strOption
        ( long "to"
       <> help "Destination PureClaw state directory (default: ~/.pureclaw)"
        )))
  <*> optional (argument str (metavar "PATH" <> help "Path to OpenClaw dir or config file (backward compat)"))

-- | Main CLI entry point.
runCLI :: IO ()
runCLI = do
  cmd <- execParser cliParserInfo
  case cmd of
    CmdTui opts     -> runChat opts { _co_channel = Just "cli" }
    CmdGateway opts -> runChat opts
    CmdImport opts mPos -> runImport opts mPos

-- | Import an OpenClaw state directory.
runImport :: ImportOptions -> Maybe FilePath -> IO ()
runImport opts mPositional = do
  (fromDir, toDir) <- resolveImportOptions opts mPositional
  putStrLn $ "Importing OpenClaw state from: " <> fromDir
  putStrLn $ "Writing to: " <> toDir
  result <- importOpenClawDir fromDir toDir
  case result of
    Left err -> do
      putStrLn $ "Error: " <> T.unpack err
      exitFailure
    Right dir -> do
      let ir = _dir_configResult dir
          configDir = toDir </> "config"
      putStrLn ""
      putStrLn "Import complete!"
      putStrLn ""
      putStrLn "  Imported:"
      putStrLn $ "    Config:       " <> configDir </> "config.toml"
      case _ir_agentsWritten ir of
        [] -> pure ()
        agents -> do
          putStrLn $ "    Agents:       " <> T.unpack (T.intercalate ", " agents)
          mapM_ (\a -> putStrLn $ "                  " <> configDir </> "agents" </> T.unpack a </> "AGENTS.md") agents
      when (_dir_credentialsOk dir)
        $ putStrLn $ "    Credentials:  " <> toDir </> "credentials.json"
      case _dir_deviceId dir of
        Just did -> putStrLn $ "    Device ID:    " <> T.unpack did
        Nothing  -> pure ()
      case _dir_workspacePath dir of
        Just ws -> putStrLn $ "    Workspace:    " <> ws <> " (referenced in config)"
        Nothing -> pure ()
      when (_dir_modelsImported dir)
        $ putStrLn $ "    Models:       " <> toDir </> "models.json"

      -- Skipped items
      let skipped =
            [("Cron jobs", "PureClaw cron format not yet supported") | _dir_cronSkipped dir]
      if null skipped
        then pure ()
        else do
          putStrLn ""
          putStrLn "  Skipped:"
          mapM_ (\(item, reason) -> putStrLn $ "    " <> item <> ": " <> reason) skipped

      -- Extra workspaces
      case _dir_extraWorkspaces dir of
        [] -> pure ()
        ws -> do
          putStrLn ""
          putStrLn "  Additional workspaces found (noted in config comments):"
          mapM_ (\w -> putStrLn $ "    " <> w) ws

      -- Warnings
      let allWarnings = _ir_warnings ir <> _dir_warnings dir
      case allWarnings of
        [] -> pure ()
        ws -> do
          putStrLn ""
          putStrLn "  Warnings:"
          mapM_ (\w -> putStrLn $ "    " <> T.unpack w) ws

      putStrLn ""
      putStrLn "Next steps:"
      putStrLn "  1. Review the imported config and agent files"
      if _dir_credentialsOk dir
        then putStrLn "  2. Move credentials.json secrets into the PureClaw vault: /vault setup"
        else putStrLn "  2. Configure your API key: pureclaw tui --api-key <key>"
      putStrLn "  3. Run: pureclaw tui"

-- | Run an interactive chat session.
runChat :: ChatOptions -> IO ()
runChat opts = do
  let logger = mkStderrLogHandle

  -- Load config file: --config flag overrides default search locations
  configResult <- maybe loadConfigDiag loadFileConfigDiag (_co_config opts)
  let fileCfg = configFileConfig configResult

  -- Log config loading result
  case configResult of
    ConfigLoaded path _ ->
      _lh_logInfo logger $ "Config: " <> T.pack path
    ConfigParseError path err -> do
      _lh_logWarn logger $ "Config file has errors: " <> T.pack path
      _lh_logWarn logger err
      _lh_logWarn logger "Using default configuration."
    ConfigFileNotFound path ->
      _lh_logWarn logger $ "Config file not found: " <> T.pack path
    ConfigNotFound _paths ->
      _lh_logInfo logger "No config file found"

  -- Resolve effective values: CLI flag > config file > default
  let effectiveProvider = fromMaybe Anthropic  (_co_provider opts <|> parseProviderMaybe (_fc_provider fileCfg))
      effectiveModel    = fromMaybe "claude-sonnet-4-20250514" (_co_model opts <|> fmap T.unpack (_fc_model fileCfg))
      effectiveMemory   = fromMaybe NoMemory    (_co_memory opts <|> parseMemoryMaybe (_fc_memory fileCfg))
      effectiveApiKey   = _co_apiKey opts <|> fmap T.unpack (_fc_apiKey fileCfg)
      effectiveSystem   = _co_system opts <|> fmap T.unpack (_fc_system fileCfg)
      effectiveAllow    = _co_allowCommands opts <> maybe [] (map T.unpack) (_fc_allow fileCfg)
      effectiveAutonomy = _co_autonomy opts
                      <|> parseAutonomyMaybe (_fc_autonomy fileCfg)

  -- Vault (opened before provider so API keys can be fetched from vault)
  vaultOpt <- resolveVault fileCfg (_co_noVault opts) logger

  -- Provider (may be Nothing if no credentials are configured yet)
  manager <- HTTP.newTlsManager
  mProvider <- if effectiveProvider == Anthropic && _co_oauth opts
    then Just <$> resolveAnthropicOAuth vaultOpt manager
    else resolveProvider effectiveProvider effectiveApiKey vaultOpt manager

  -- Model
  let model = ModelId (T.pack effectiveModel)

  -- System prompt: effective --system flag > SOUL.md > nothing
  sysPrompt <- case effectiveSystem of
    Just s  -> pure (Just (T.pack s))
    Nothing -> do
      let soulPath = fromMaybe "SOUL.md" (_co_soul opts)
      ident <- loadIdentity soulPath
      if ident == defaultIdentity
        then pure Nothing
        else pure (Just (identitySystemPrompt ident))

  -- Security policy
  let policy = buildPolicy effectiveAutonomy effectiveAllow

  -- Handles
  let workspace = WorkspaceRoot "."
      sh        = mkShellHandle logger
      fh        = mkFileHandle workspace
      nh        = mkNetworkHandle manager
  mh <- resolveMemory effectiveMemory

  -- Tool registry
  let registry = buildRegistry policy sh workspace fh mh nh

  hSetBuffering stdout LineBuffering
  case mProvider of
    Just _  -> _lh_logInfo logger $ "Provider: " <> T.pack (providerToText effectiveProvider)
    Nothing -> _lh_logInfo logger
      "No providers configured \x2014 use /provider to get started"
  _lh_logInfo logger $ "Model: " <> T.pack effectiveModel
  _lh_logInfo logger $ "Memory: " <> T.pack (memoryToText effectiveMemory)
  case (_sp_allowedCommands policy, _sp_autonomy policy) of
    (AllowAll, Full) -> do
      _lh_logInfo logger "Commands: allow all (unrestricted mode)"
      _lh_logInfo logger
        "\x26a0\xfe0f  Running in unrestricted mode \x2014 the agent can execute any command without approval."
    (_, Deny) ->
      _lh_logInfo logger "Commands: none (deny all)"
    (AllowList s, _) | Set.null s ->
      _lh_logInfo logger "Commands: none (deny all)"
    _ ->
      _lh_logInfo logger $ "Commands: " <> T.intercalate ", " (map T.pack effectiveAllow)

  -- Channel selection: CLI flag > config file > default (cli)
  let effectiveChannel = fromMaybe "cli"
        (_co_channel opts <|> fmap T.unpack (_fc_defaultChannel fileCfg))

  let startWithChannel :: ChannelHandle -> IO ()
      startWithChannel channel = do
        putStrLn "PureClaw 0.1.0 \x2014 Haskell-native AI agent runtime"
        case effectiveChannel of
          "cli" -> putStrLn "Type your message and press Enter. Ctrl-D to exit."
          _     -> putStrLn $ "Channel: " <> effectiveChannel
        putStrLn ""
        -- Create transcript handle
        pureclawDir <- getPureclawDir
        let transcriptDir = pureclawDir </> "transcripts"
        createDirectoryIfMissing True transcriptDir
        timestamp <- getCurrentTime
        let transcriptFile = transcriptDir
              </> formatTime defaultTimeLocale "%Y%m%d-%H%M%S" timestamp
                  <> "-" <> effectiveChannel <> ".jsonl"
        th <- mkFileTranscriptHandle logger transcriptFile
        transcriptRef <- newIORef (Just th)
        harnessRef  <- newIORef Map.empty
        vaultRef    <- newIORef vaultOpt
        providerRef <- newIORef mProvider
        modelRef    <- newIORef model
        let env = AgentEnv
              { _env_provider     = providerRef
              , _env_model        = modelRef
              , _env_channel      = channel
              , _env_logger       = logger
              , _env_systemPrompt = sysPrompt
              , _env_registry     = registry
              , _env_vault        = vaultRef
              , _env_pluginHandle = mkPluginHandle
              , _env_transcript   = transcriptRef
              , _env_policy       = policy
              , _env_harnesses    = harnessRef
              }
        runAgentLoop env

  case effectiveChannel of
    "signal" -> do
      let sigCfg = resolveSignalConfig fileCfg
      -- Check that signal-cli is installed
      signalCliResult <- try @IOException $
        P.readProcess (P.proc "signal-cli" ["--version"])
      case signalCliResult of
        Left _ -> do
          _lh_logWarn logger "signal-cli is not installed or not in PATH."
          _lh_logWarn logger "Install it from: https://github.com/AsamK/signal-cli"
          _lh_logWarn logger "  brew install signal-cli    (macOS)"
          _lh_logWarn logger "  nix-env -i signal-cli      (NixOS)"
          _lh_logWarn logger "Falling back to CLI channel."
          mkCLIChannelHandle >>= startWithChannel
        Right _ -> do
          _lh_logInfo logger $ "Signal account: " <> _sc_account sigCfg
          transport <- mkSignalCliTransport (_sc_account sigCfg) logger
          withSignalChannel sigCfg transport logger startWithChannel
    "cli" ->
      mkCLIChannelHandle >>= startWithChannel
    other -> do
      _lh_logWarn logger $ "Unknown channel: " <> T.pack other <> ". Using CLI."
      mkCLIChannelHandle >>= startWithChannel

-- | Parse a provider type from a text value (used for config file).
parseProviderMaybe :: Maybe T.Text -> Maybe ProviderType
parseProviderMaybe Nothing  = Nothing
parseProviderMaybe (Just t) = case T.unpack t of
  "anthropic"  -> Just Anthropic
  "openai"     -> Just OpenAI
  "openrouter" -> Just OpenRouter
  "ollama"     -> Just Ollama
  _            -> Nothing

-- | Parse an autonomy level from a CLI string.
parseAutonomyLevel :: ReadM AutonomyLevel
parseAutonomyLevel = eitherReader $ \s -> case s of
  "full"       -> Right Full
  "supervised" -> Right Supervised
  "deny"       -> Right Deny
  _            -> Left $ "Unknown autonomy level: " <> s <> ". Choose: full, supervised, deny"

-- | Parse an autonomy level from a text value (used for config file).
parseAutonomyMaybe :: Maybe T.Text -> Maybe AutonomyLevel
parseAutonomyMaybe Nothing  = Nothing
parseAutonomyMaybe (Just t) = case t of
  "full"       -> Just Full
  "supervised" -> Just Supervised
  "deny"       -> Just Deny
  _            -> Nothing

-- | Parse a memory backend from a text value (used for config file).
parseMemoryMaybe :: Maybe T.Text -> Maybe MemoryBackend
parseMemoryMaybe Nothing  = Nothing
parseMemoryMaybe (Just t) = case T.unpack t of
  "none"     -> Just NoMemory
  "sqlite"   -> Just SQLiteMemory
  "markdown" -> Just MarkdownMemory
  _          -> Nothing

-- | Build the tool registry with all available tools.
buildRegistry :: SecurityPolicy -> ShellHandle -> WorkspaceRoot -> FileHandle -> MemoryHandle -> NetworkHandle -> ToolRegistry
buildRegistry policy sh workspace fh mh nh =
  let reg = uncurry registerTool
  in reg (shellTool policy sh)
   $ reg (fileReadTool workspace fh)
   $ reg (fileWriteTool workspace fh)
   $ reg (gitTool policy sh)
   $ reg (memoryStoreTool mh)
   $ reg (memoryRecallTool mh)
   $ reg (httpRequestTool AllowAll nh)
     emptyRegistry

-- | Build a security policy from optional autonomy level and allowed commands.
--
-- Behavior:
--   * @Just Full@ + empty allow list → 'AllowAll' + 'Full' (unrestricted mode)
--   * @Just Full@ + allow list → 'AllowList' of those commands + 'Full'
--   * @Just Supervised@ + allow list → 'AllowList' + 'Supervised'
--   * @Just Deny@ → 'defaultPolicy' ('Deny', empty 'AllowList')
--   * @Nothing@ + empty allow list → 'defaultPolicy' (backward compat)
--   * @Nothing@ + allow list → 'Full' + 'AllowList' (backward compat)
buildPolicy :: Maybe AutonomyLevel -> [String] -> SecurityPolicy
buildPolicy (Just Deny) _ = defaultPolicy
buildPolicy (Just level) [] = SecurityPolicy
  { _sp_allowedCommands = AllowAll
  , _sp_autonomy = level
  }
buildPolicy (Just level) cmds =
  let cmdNames = Set.fromList (map (CommandName . T.pack) cmds)
  in SecurityPolicy
    { _sp_allowedCommands = AllowList cmdNames
    , _sp_autonomy = level
    }
buildPolicy Nothing [] = defaultPolicy
buildPolicy Nothing cmds =
  let cmdNames = Set.fromList (map (CommandName . T.pack) cmds)
  in SecurityPolicy
    { _sp_allowedCommands = AllowList cmdNames
    , _sp_autonomy = Full
    }

-- | Resolve the LLM provider from the provider type.
-- Checks CLI flag first, then the vault for the API key.
-- Returns 'Nothing' if no credentials are available (the agent loop
-- will still start, allowing the user to configure credentials via
-- slash commands like /vault setup).
resolveProvider :: ProviderType -> Maybe String -> Maybe VaultHandle -> HTTP.Manager -> IO (Maybe SomeProvider)
resolveProvider Anthropic keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "ANTHROPIC_API_KEY" vaultOpt
  case mApiKey of
    Just k  -> pure (Just (MkProvider (mkAnthropicProvider manager k)))
    Nothing -> do
      -- Fall back to cached OAuth tokens in the vault
      cachedBs <- tryVaultLookup vaultOpt oauthVaultKey
      case cachedBs >>= eitherToMaybe . deserializeTokens of
        Nothing -> pure Nothing
        Just tokens -> do
          let cfg = defaultOAuthConfig
          now <- getCurrentTime
          t <- if _oat_expiresAt tokens <= now
            then do
              putStrLn "OAuth access token expired \x2014 refreshing..."
              newT <- refreshOAuthToken cfg manager (_oat_refreshToken tokens)
              saveOAuthTokens vaultOpt newT
              pure newT
            else pure tokens
          handle <- mkOAuthHandle cfg manager t
          pure (Just (MkProvider (mkAnthropicProviderOAuth manager handle)))
resolveProvider OpenAI keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "OPENAI_API_KEY" vaultOpt
  pure (fmap (MkProvider . mkOpenAIProvider manager) mApiKey)
resolveProvider OpenRouter keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "OPENROUTER_API_KEY" vaultOpt
  pure (fmap (MkProvider . mkOpenRouterProvider manager) mApiKey)
resolveProvider Ollama _ _ manager =
  pure (Just (MkProvider (mkOllamaProvider manager)))

-- | Vault key used to cache OAuth tokens between sessions.
oauthVaultKey :: T.Text
oauthVaultKey = "ANTHROPIC_OAUTH_TOKENS"

-- | Resolve an Anthropic provider via OAuth 2.0 PKCE.
-- Loads cached tokens from the vault if available; runs the full browser
-- flow otherwise. Refreshes expired access tokens automatically.
resolveAnthropicOAuth :: Maybe VaultHandle -> HTTP.Manager -> IO SomeProvider
resolveAnthropicOAuth vaultOpt manager = do
  let cfg = defaultOAuthConfig
  cachedBs <- tryVaultLookup vaultOpt oauthVaultKey
  tokens <- case cachedBs >>= eitherToMaybe . deserializeTokens of
    Just t -> do
      now <- getCurrentTime
      if _oat_expiresAt t <= now
        then do
          putStrLn "OAuth access token expired — refreshing..."
          newT <- refreshOAuthToken cfg manager (_oat_refreshToken t)
          saveOAuthTokens vaultOpt newT
          pure newT
        else pure t
    Nothing -> do
      t <- runOAuthFlow cfg manager
      saveOAuthTokens vaultOpt t
      pure t
  handle <- mkOAuthHandle cfg manager tokens
  pure (MkProvider (mkAnthropicProviderOAuth manager handle))

-- | Save OAuth tokens to the vault (best-effort; logs on failure).
saveOAuthTokens :: Maybe VaultHandle -> OAuthTokens -> IO ()
saveOAuthTokens Nothing      _      = pure ()
saveOAuthTokens (Just vh) tokens = do
  result <- _vh_put vh oauthVaultKey (serializeTokens tokens)
  case result of
    Left err -> putStrLn $ "Warning: could not cache OAuth tokens: " <> show err
    Right () -> pure ()

-- | Convert 'Either' to 'Maybe', discarding the error.
eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe (Left  _) = Nothing
eitherToMaybe (Right a) = Just a

-- | Resolve an API key from: CLI flag → vault.
-- Returns 'Nothing' if no key is found.
resolveApiKey :: Maybe String -> String -> Maybe VaultHandle -> IO (Maybe ApiKey)
resolveApiKey (Just key) _ _ = pure (Just (mkApiKey (TE.encodeUtf8 (T.pack key))))
resolveApiKey Nothing vaultKeyName vaultOpt = do
  vaultKey <- tryVaultLookup vaultOpt (T.pack vaultKeyName)
  case vaultKey of
    Just bs -> pure (Just (mkApiKey bs))
    Nothing -> pure Nothing

-- | Try to look up a key from the vault. Returns 'Nothing' if the vault is
-- absent, locked, or does not contain the key.
tryVaultLookup :: Maybe VaultHandle -> T.Text -> IO (Maybe ByteString)
tryVaultLookup Nothing   _   = pure Nothing
tryVaultLookup (Just vh) key = do
  result <- _vh_get vh key
  case result of
    Right bs -> pure (Just bs)
    Left  _  -> pure Nothing

-- | Resolve the memory backend.
resolveMemory :: MemoryBackend -> IO MemoryHandle
resolveMemory NoMemory       = pure mkNoOpMemoryHandle
resolveMemory SQLiteMemory   = do
  dir <- getPureclawDir
  mkSQLiteMemoryHandle (dir ++ "/memory.db")
resolveMemory MarkdownMemory = do
  dir <- getPureclawDir
  mkMarkdownMemoryHandle (dir ++ "/memory")

-- | Open the vault if configured. Returns 'Nothing' if @--no-vault@ is set.
-- When age keys are configured, uses age public-key encryption.
-- Otherwise, falls back to passphrase-based encryption (works out of the box).
resolveVault :: FileConfig -> Bool -> LogHandle -> IO (Maybe VaultHandle)
resolveVault _ True _ = pure Nothing
resolveVault fileCfg False logger =
  case (_fc_vault_recipient fileCfg, _fc_vault_identity fileCfg) of
    (Just recipient, Just identity) -> resolveAgeVault fileCfg recipient identity logger
    _                               -> resolvePassphraseVault fileCfg logger

-- | Resolve vault using age public-key encryption (existing behaviour).
resolveAgeVault :: FileConfig -> T.Text -> T.Text -> LogHandle -> IO (Maybe VaultHandle)
resolveAgeVault fileCfg recipient identity logger = do
  encResult <- mkAgeEncryptor
  case encResult of
    Left err -> do
      _lh_logInfo logger $ "Vault disabled (age not available): " <> T.pack (show err)
      pure Nothing
    Right enc -> do
      dir <- getPureclawDir
      let path  = maybe (dir ++ "/vault/vault.age") T.unpack (_fc_vault_path fileCfg)
          mode  = parseUnlockMode (_fc_vault_unlock fileCfg)
          enc'  = ageVaultEncryptor enc recipient identity
          cfg   = VaultConfig
            { _vc_path    = path
            , _vc_keyType = inferAgeKeyType recipient
            , _vc_unlock  = mode
            }
      vault <- openVault cfg enc'
      exists <- doesFileExist path
      if exists
        then do
          case mode of
            UnlockStartup -> do
              result <- _vh_unlock vault
              case result of
                Left err -> _lh_logInfo logger $
                  "Vault startup unlock failed (vault will be locked): " <> T.pack (show err)
                Right () -> _lh_logInfo logger "Vault unlocked."
            _ -> pure ()
          pure (Just vault)
        else do
          _lh_logInfo logger "No vault found — use `/vault setup` to create one."
          pure Nothing

-- | Resolve vault using passphrase-based encryption (default when no age keys configured).
-- Prompts for passphrase on stdin at startup (if vault file exists).
resolvePassphraseVault :: FileConfig -> LogHandle -> IO (Maybe VaultHandle)
resolvePassphraseVault fileCfg logger = do
  dir <- getPureclawDir
  let path = maybe (dir ++ "/vault/vault.age") T.unpack (_fc_vault_path fileCfg)
      cfg  = VaultConfig
        { _vc_path    = path
        , _vc_keyType = "AES-256 (passphrase)"
        , _vc_unlock  = UnlockStartup
        }
  let getPass = do
        putStr "Vault passphrase: "
        hFlush stdout
        pass <- bracket_
          (hSetEcho stdin False)
          (hSetEcho stdin True >> putStrLn "")
          getLine
        pure (TE.encodeUtf8 (T.pack pass))
  enc <- mkPassphraseVaultEncryptor getPass
  vault <- openVault cfg enc
  exists <- doesFileExist path
  if exists
    then do
      result <- _vh_unlock vault
      case result of
        Left err -> _lh_logInfo logger $
          "Vault unlock failed: " <> T.pack (show err)
        Right () -> _lh_logInfo logger "Vault unlocked."
      pure (Just vault)
    else do
      _lh_logInfo logger "No vault found — use `/vault setup` to create one."
      pure Nothing

-- | Infer a human-readable key type from the age recipient prefix.
inferAgeKeyType :: T.Text -> T.Text
inferAgeKeyType recipient
  | "age-plugin-yubikey" `T.isPrefixOf` recipient = "YubiKey PIV"
  | "age1"               `T.isPrefixOf` recipient = "X25519"
  | otherwise                                      = "Unknown"

-- | Parse vault unlock mode from config text.
parseUnlockMode :: Maybe T.Text -> UnlockMode
parseUnlockMode Nothing            = UnlockOnDemand
parseUnlockMode (Just t) = case t of
  "startup"    -> UnlockStartup
  "on_demand"  -> UnlockOnDemand
  "per_access" -> UnlockPerAccess
  _            -> UnlockOnDemand

-- | Resolve Signal channel config from the file config.
resolveSignalConfig :: FileConfig -> SignalConfig
resolveSignalConfig fileCfg =
  let sigCfg = _fc_signal fileCfg
      dmPolicy = sigCfg >>= _fsc_dmPolicy
      allowFrom = case dmPolicy of
        Just "open" -> AllowAll
        _ -> case sigCfg >>= _fsc_allowFrom of
          Nothing    -> AllowAll
          Just []    -> AllowAll
          Just users -> AllowList (Set.fromList (map UserId users))
  in SignalConfig
    { _sc_account        = fromMaybe "+0000000000" (sigCfg >>= _fsc_account)
    , _sc_textChunkLimit = fromMaybe 6000 (sigCfg >>= _fsc_textChunkLimit)
    , _sc_allowFrom      = allowFrom
    }
