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
    -- * Channel config resolution (exported for testing)
  , resolveSignalConfig
  , resolveTelegramConfig
  , signalAllowListContext
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, SomeException, bracket_, catch, try)
import Control.Monad (filterM, unless, when)
import Data.ByteString (ByteString)
import Data.Either (fromRight)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP
import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, getCurrentDirectory)

import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO
import System.Process.Typed qualified as P

import PureClaw.Auth.AnthropicOAuth
import PureClaw.CLI.Config

import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.Agent.Completion
import PureClaw.Agent.Env
import PureClaw.Agent.Identity
import PureClaw.Tabs (overwriteTabs, readTabs)
import PureClaw.Tabs.Persist (PersistDeps (..), loadTabs, saveTabs)
import PureClaw.Tabs.Wiring (SessionStore, mkExecDeps, mkTabDispatchDeps, runTabbedLoop)
import PureClaw.Routing.TabDispatch (TabDispatchDeps (..), runTabCommand)
import PureClaw.Agent.SlashCommands
import PureClaw.Routing.Config qualified as Routing
import PureClaw.Routing.Types qualified as Routing
import PureClaw.Session.Handle
  ( ResumeError (..)
  , SessionHandle (..)
  , markBootstrapConsumed
  , mkSessionHandle
  , resolveResumedTarget
  , resumeSession
  )
import PureClaw.Session.Types qualified as SessionTypes
import PureClaw.Frontend.API
  ( broadcastLists
  , mkStreamGuard
  , productionReleaseTmux
  , productionKillWindow
  , spawnHarnessSession
  )
import PureClaw.Handles.Harness (HarnessError (..))
import PureClaw.Tabs.Types (TabRef (..))
import PureClaw.Frontend.Server
import PureClaw.Frontend.StreamBroker
  ( BrokerConfig (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  )
import PureClaw.Harness.ClaudeCode (adoptExternalWindow, defaultClaudeCodeDeps)
import PureClaw.Harness.Reconcile qualified as Reconcile
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Handles.Transcript (mkNoOpTranscriptHandle)
import PureClaw.Channels.AllowList
import PureClaw.Channels.CLI
import PureClaw.Channels.Signal
import PureClaw.Channels.Telegram
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
import PureClaw.Security.Adoption (ConsentChannel (..))
import PureClaw.Security.Policy
import PureClaw.Security.Secrets
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Passphrase
import PureClaw.Security.Vault.Plugin
import PureClaw.Tools.Clarify
import PureClaw.Tools.Edit
import PureClaw.Tools.FileRead
import PureClaw.Tools.FileWrite
import PureClaw.Tools.Git
import PureClaw.Tools.HttpRequest
import PureClaw.Tools.Memory
import PureClaw.Tools.Patch
import PureClaw.Tools.Registry
import PureClaw.Tools.SearchFiles
import PureClaw.Tools.Delegate
import PureClaw.Tools.ExecuteCode
import PureClaw.Tools.SessionSearch
import PureClaw.Tools.Shell
import PureClaw.Tools.Todo
import PureClaw.Tools.WebExtract

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
  , _co_logLevel      :: Maybe LogLevel
  , _co_bind          :: Maybe String
  , _co_soul          :: Maybe String
  , _co_config        :: Maybe FilePath
  , _co_noVault       :: Bool
  , _co_oauth         :: Bool
  , _co_agent         :: Maybe String
  , _co_session       :: Maybe String
  , _co_prefix        :: Maybe String
  , _co_depth         :: Int
    -- ^ Current HPureClaw recursion depth. Internal — set by the parent
    -- process when spawning a child via @--depth N@. Not user-facing.
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
  <*> optional (option parseLogLevelOpt
      ( long "log-level"
     <> metavar "LEVEL"
     <> help "Minimum log severity: debug, info, warn, error (default: info)"
      ))
  <*> optional (strOption
      ( long "bind"
     <> metavar "HOST"
     <> help "Interface for the web frontend to bind (default 127.0.0.1). \
             \Setting a non-loopback host (e.g. 0.0.0.0) exposes the FULL \
             \slash-command surface, including local code execution via \
             \/mcp connect, to anything that can reach that address — use \
             \only on trusted networks." ))
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
  <*> optional (strOption
      ( long "agent"
     <> help "Load a named agent from ~/.pureclaw/agents/<name>/ as the system prompt"
      ))
  <*> optional (strOption
      ( long "session"
     <> help "Resume an existing session by exact ID (mutually exclusive with --prefix)"
      ))
  <*> optional (strOption
      ( long "prefix"
     <> help "Prefix for the new session ID (mutually exclusive with --session)"
      ))
  <*> option auto
      ( long "depth"
     <> value 0
     <> internal
     <> help "HPureClaw recursion depth (internal, set by parent process)"
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

-- | Parse a log level from a CLI string, failing with a clear message.
parseLogLevelOpt :: ReadM LogLevel
parseLogLevelOpt = eitherReader $ \s -> case parseLogLevel s of
  Just lvl -> Right lvl
  Nothing  -> Left $ "Unknown log level: " <> s <> ". Choose: debug, info, warn, error"

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
    -- FEAS-2 / D3 (SEC-1): the consent channel is derived from the invocation
    -- mode here, where the 'Command' is known. The foreground TUI gets
    -- 'ConsentInteractive' and the gateway-served web UI gets 'ConsentWeb' — in
    -- both, a human explicitly picks the window to adopt (the New-Tab form /
    -- "Existing Harness" selection), which IS the consent. Only a truly
    -- unattended mode with no human picking a window ('CmdImport', and any
    -- future cron\/daemon\/background mode) maps to 'ConsentHeadless' so
    -- adoption fails closed.
    CmdTui opts     -> runChat ConsentInteractive opts { _co_channel = Just "cli" }
    CmdGateway opts -> runChat ConsentWeb opts
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
--
-- The 'ConsentChannel' is supplied by 'runCLI' from the invocation mode
-- (FEAS-2): the foreground interactive TUI passes 'ConsentInteractive'; the
-- gateway\/headless modes pass 'ConsentHeadless'. It is stored on the
-- 'FrontendEnv' as '_fe_consentChannel' so the @POST \/api\/adopt@ endpoint can
-- fail closed for non-interactive runs (design §8 B2 / SEC-1).
runChat :: ConsentChannel -> ChatOptions -> IO ()
runChat consentChannel opts = do
  logger <- mkStderrLogHandleAt (fromMaybe LlInfo (_co_logLevel opts))

  -- --session and --prefix are mutually exclusive. We enforce this
  -- post-parse because optparse-applicative's <|> would make one
  -- flag shadow the other rather than producing a clear error.
  case (_co_session opts, _co_prefix opts) of
    (Just _, Just _) -> do
      _lh_logWarn logger "--session and --prefix are mutually exclusive"
      exitFailure
    _ -> pure ()

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

  -- Agent resolution: CLI --agent > config default_agent > Nothing.
  -- On invalid name or missing agent, log a clear error and exit non-zero.
  let rawAgentName =
        fmap T.pack (_co_agent opts) <|> _fc_defaultAgent fileCfg
  pureclawDir <- getPureclawDir
  let agentsDir = pureclawDir </> "agents"
      truncateLimit = fromMaybe 8000 (_fc_agentTruncateLimit fileCfg)
  mAgentDef <- case rawAgentName of
    Nothing -> pure Nothing
    Just raw -> case AgentDef.mkAgentName raw of
      Left _ -> do
        _lh_logWarn logger $ "invalid agent name: " <> raw
        exitFailure
      Right validName -> do
        mDef <- AgentDef.loadAgent agentsDir validName
        case mDef of
          Just d  -> pure (Just d)
          Nothing -> do
            defs <- AgentDef.discoverAgents logger agentsDir
            let names = [AgentDef.unAgentName (AgentDef._ad_name d) | d <- defs]
                avail = if null names then "(none)" else T.intercalate ", " names
            _lh_logWarn logger $
              "Agent \"" <> raw <> "\" not found. Available agents: " <> avail
            exitFailure

  agentSysPrompt <- case mAgentDef of
    Nothing  -> pure Nothing
    Just def -> Just <$> AgentDef.composeAgentPrompt logger def truncateLimit

  -- System prompt: agent > effective --system flag > SOUL.md > nothing
  sysPrompt <- case agentSysPrompt of
    Just p  -> pure (Just p)
    Nothing -> case effectiveSystem of
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

  hSetBuffering stdout LineBuffering
  case mProvider of
    Just _  -> _lh_logInfo logger $ "Provider: " <> T.pack (providerToText effectiveProvider)
    Nothing -> _lh_logInfo logger
      "No providers configured \x2014 use /provider to get started"
  _lh_logInfo logger $ "Default agent: "
    <> fromMaybe "(none)" (_fc_defaultAgent fileCfg)
  _lh_logInfo logger $ "Default target: "
    <> fromMaybe "(none)" (_fc_defaultTarget fileCfg)
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

  -- IORef for two-phase init: completer is built before AgentEnv exists,
  -- but reads the env at completion time via this ref.
  envRef <- newIORef Nothing
  slashCompleter <- buildCompleter envRef

  let startWithChannel :: ChannelHandle -> IO ()
      startWithChannel channel = do
        -- WU3: construct the in-process broker and the WS per-origin guard
        -- BEFORE any session-handle/transcript construction so every
        -- write site (resumeSession, mkSessionHandle, handleSend) can
        -- thread it down. Exactly one broker per process — see the
        -- design doc §Lifecycle and Shutdown.
        broker      <- mkInProcessBroker defaultBrokerConfig
        streamGuard <- mkStreamGuard (_bc_maxSubsPerOrigin defaultBrokerConfig)
        -- Build registry: pure tools + IO tools (todo needs IORef state)
        (todoDef, todoHandler) <- todoTool
        let sessSearchTool = sessionSearchTool logger (pureclawDir </> "sessions")
            registry = registerTool todoDef todoHandler
                     $ uncurry registerTool sessSearchTool
                     $ buildRegistry policy sh workspace fh mh nh channel
        putStrLn "PureClaw 0.1.0 \x2014 Haskell-native AI agent runtime"
        case effectiveChannel of
          "cli" -> putStrLn "Type your message and press Enter. Ctrl-D to exit."
          _     -> putStrLn $ "Channel: " <> effectiveChannel
        putStrLn ""
        -- Build a real on-disk session. The transcript now lives inside
        -- the session directory at @~/.pureclaw/sessions/<id>/transcript.jsonl@;
        -- the legacy @~/.pureclaw/transcripts/@ directory is no longer written to.
        let sessionsDir = pureclawDir </> "sessions"
        createDirectoryIfMissing True sessionsDir
        now <- getCurrentTime
        -- Validate and construct the optional session prefix. Invalid
        -- prefixes (path traversal, reserved words, bad chars) are
        -- rejected before any on-disk state is touched.
        -- Prefix resolution: explicit --prefix flag > agent name > Nothing.
        -- The agent name is already validated (AgentName smart constructor),
        -- but we still route it through mkSessionPrefix in case the two
        -- character sets diverge in the future.
        let rawPrefix = fmap T.pack (_co_prefix opts)
                    <|> fmap (AgentDef.unAgentName . AgentDef._ad_name) mAgentDef
                    <|> _fc_sessionPrefix fileCfg
        mPrefix <- case rawPrefix of
          Nothing  -> pure Nothing
          Just raw -> case SessionTypes.mkSessionPrefix raw of
            Right p -> pure (Just p)
            Left  e -> do
              _lh_logWarn logger $ "invalid --prefix: " <> T.pack (show e)
              exitFailure
        -- If --session is supplied, resume that session; otherwise
        -- create a fresh one.
        sessionHandle <- case _co_session opts of
          Just sidRaw -> do
            _lh_logInfo logger $ "Resuming session " <> T.pack sidRaw
            -- WU3: the broker is constructed at the top of
            -- 'startWithChannel' and threaded through here so the resumed
            -- session's transcript handle becomes a broadcasting handle.
            result <- resumeSession (Just broker) logger sessionsDir
                        (parseSessionId (T.pack sidRaw))
            case result of
              Right resumed -> pure resumed
              Left (ResumeMissingMetadata _) -> do
                _lh_logWarn logger $
                  "Session not found: " <> T.pack sidRaw
                exitFailure
              Left (ResumeCorruptedMetadata _ msg) -> do
                _lh_logWarn logger $
                  "Session not found (corrupted metadata): " <> T.pack msg
                exitFailure
              Left ResumeInvalidId -> do
                _lh_logWarn logger $
                  "Session id is invalid (contains path traversal or forbidden characters): "
                    <> T.pack sidRaw
                exitFailure
          Nothing -> do
            let sid = SessionTypes.newSessionId mPrefix now
                mAgent = fmap AgentDef._ad_name mAgentDef
                initialMeta = SessionTypes.SessionMeta
                  { SessionTypes._sm_id                = sid
                  , SessionTypes._sm_agent             = mAgent
                  , SessionTypes._sm_kind              = SessionTypes.SkProvider
                      (SessionTypes.ProviderSpec
                        (SessionTypes.inferProviderId (T.pack effectiveModel))
                        (ModelId (T.pack effectiveModel))
                        mAgent)
                  , SessionTypes._sm_model             = T.pack effectiveModel
                  , SessionTypes._sm_channel           = T.pack effectiveChannel
                  , SessionTypes._sm_createdAt         = now
                  , SessionTypes._sm_lastActive        = now
                  , SessionTypes._sm_bootstrapConsumed = False
                  , SessionTypes._sm_archived          = False
                  , SessionTypes._sm_description       = Nothing
                  , SessionTypes._sm_autoSummary       = Nothing
                  , SessionTypes._sm_source            = Nothing
                  }
            -- WU3: see broker construction at the top of startWithChannel.
            mkSessionHandle (Just broker) logger sessionsDir initialMeta
        -- Log the active session ID so tests and humans can find it.
        do
          currentMeta <- readIORef (_sh_meta sessionHandle)
          _lh_logInfo logger $ "Session: "
            <> unSessionId (SessionTypes._sm_id currentMeta)
        let th = _sh_transcript sessionHandle
        -- Discover any harnesses still running from a previous session
        (discoveredHarnesses, nextWindowIdx) <- discoverHarnesses th
        unless (Map.null discoveredHarnesses) $
          _lh_logInfo logger $ "Discovered " <> T.pack (show (Map.size discoveredHarnesses))
            <> " running harness(es) from previous session"
        harnessRef  <- newIORef discoveredHarnesses
        -- One shared HarnessId registry (TVar) for the whole process: the
        -- agent ('_env_harnessRegistry') and the frontend
        -- ('_fe_harnessRegistry') MUST observe the same registry, so both
        -- fields are set to this single value below.
        harnessReg  <- Registry.newRegistry
        vaultRef    <- newIORef vaultOpt
        providerRef <- newIORef mProvider
        modelRef    <- newIORef (Just model)
        -- Runtime validation on resume: if the session's recorded
        -- kind was an SkHarness, validate that the harness is still
        -- running (it may have been discovered by 'discoverHarnesses'
        -- above). Missing harness falls back to TargetProvider with a
        -- warning; fresh sessions simply start at TargetProvider.
        initialTarget <- case _co_session opts of
          Just _  -> do
            resumedMeta <- readIORef (_sh_meta sessionHandle)
            resolveResumedTarget logger discoveredHarnesses
              (SessionTypes._sm_kind resumedMeta)
          Nothing -> pure TargetProvider
        targetRef   <- newIORef initialTarget
        windowIdxRef <- newIORef nextWindowIdx
        sessionRef <- newIORef sessionHandle
        -- Install a one-shot "bootstrap consumed" callback that fires
        -- after the first StreamDone. Only arm it if the agent has a
        -- BOOTSTRAP.md and its consumed flag is currently False.
        onFirstStreamDoneRef <- newIORef
          =<< resolveBootstrapCallback logger mAgentDef sessionHandle
        mcpRef <- newIORef Map.empty
        -- Task C2 (web /tab dispatch): the ONE shared session-handle pool the
        -- tabbed loop ('runTabbedLoop') and the web @\/tab@ seam both bind
        -- through. Created here (rather than privately inside 'runTabbedLoop')
        -- so @/tab new@\/@/tab resume@ typed into the web chat box mutate the
        -- SAME pool the loop drives — without it the two paths would
        -- split-brain the session pool.
        tabStore <- newIORef Map.empty :: IO SessionStore
        -- WU3 (Tabbed Chat #51) — load routing config from disk.
        routingCfg0    <- Routing.loadRoutingConfig pureclawDir
        let routingCfg = routingCfg0
              { Routing._rc_pureClawDepth = _co_depth opts }
        -- Tabs-as-View (GitHub #79) — build the LIVE tab subsystem bundle
        -- (tab registry, cursors, runtime registry, relay writer, sink
        -- registry, wizard state, ref-tagged tab-output queue). The tab-output
        -- queue reuses the channel-out queue bound. 'runTabbedLoop' (the new
        -- production entry, wired below) drives these through
        -- 'PureClaw.Routing.TabDispatch' + the relay-writer thread.
        tabSub <- newTabSubsystem (Routing._rc_channelOutQBound routingCfg)
        -- Use lazy circular binding: delegateTaskTool captures env, and
        -- env.registry includes the delegate tool. Haskell's laziness
        -- makes this safe — the tool closure only forces env when invoked.
        let fullRegistry = uncurry registerTool (delegateTaskTool env) registry
            -- Task C2: the deps for the web @\/tab@ seam, built over the SAME
            -- shared @tabStore@ the tabbed loop uses (mkExecDeps/mkTabDispatchDeps
            -- close over @env@ lazily, exactly like '_env_onTabsChanged' /
            -- '_env_startHarness' forward-reference 'frontendEnv').
            tabExecDeps     = mkExecDeps env tabStore
            tabDispatchDeps = mkTabDispatchDeps env tabExecDeps tabStore
            -- The 'ConversationKey' the web path runs @\/tab@ against when the
            -- caller supplies none (the web chat box has no 'ConversationKey').
            webConvKey      = (CkWeb, ConversationId "web")
            env = AgentEnv
              { _env_provider     = providerRef
              , _env_model        = modelRef
              , _env_channel      = channel
              , _env_logger       = logger
              , _env_systemPrompt = sysPrompt
              , _env_registry     = fullRegistry
              , _env_vault        = vaultRef
              , _env_pluginHandle = mkPluginHandle
              , _env_policy       = policy
              , _env_harnesses    = harnessRef
              , _env_harnessRegistry = harnessReg
              , _env_target       = targetRef
              , _env_nextWindowIdx = windowIdxRef
              , _env_agentDef     = mAgentDef
              , _env_session      = sessionRef
              , _env_onFirstStreamDone = onFirstStreamDoneRef
              , _env_mcpServers   = mcpRef
              , _env_routingConfig    = routingCfg
              , _env_fork             = defaultEnvFork
              , _env_broker           = Just broker
              -- Tabs-as-View (GitHub #79) — live tab subsystem fields.
              , _env_tabRegistry      = _ts_tabRegistry tabSub
              , _env_cursors          = _ts_cursors tabSub
              , _env_exec             = _ts_exec tabSub
              , _env_relayWriter      = _ts_relayWriter tabSub
              , _env_sinks            = _ts_sinks tabSub
              , _env_wizard           = _ts_wizard tabSub
              , _env_tabOutQ          = _ts_tabOutQ tabSub
              -- WU8 (#80): a chat-side tab mutation (e.g. @/nt@\/@/close@) now
              -- (a) persists the tab view to @state\/tabs.json@ (best-effort —
              -- a save failure is swallowed so it never crashes the loop) and
              -- (b) broadcasts the refreshed sidebar lists to any WS
              -- subscribers via 'frontendEnv'. The action references
              -- 'frontendEnv' lazily through this recursive @let@ group; it is
              -- a thunked 'IO' value, so the forward reference is never forced
              -- at construction time (mirrors the existing @env <-> fullRegistry@
              -- circular binding above).
              , _env_onTabsChanged    = do
                  tl      <- readTabs (_ts_tabRegistry tabSub)
                  cursors <- readIORef (_ts_cursors tabSub)
                  ignoreExc (saveTabs (pureclawDir </> "state") tl cursors)
                  broadcastLists frontendEnv
              -- WU-B (#?): the production harness-spawn seam the @\/tab new
              -- harness@ dispatcher routes through. Reuses the frontend's
              -- 'spawnHarnessSession' (spawn + persist + registry link), then
              -- projects its result onto the dispatcher's @('TabRef', label)@
              -- contract: the durable 'Registry.HarnessId' becomes a
              -- 'BoundHarness' ref and the harness window key becomes the tab
              -- label. A 'HarnessError' is rendered to user-facing 'Text'. The
              -- action references 'frontendEnv' lazily through this recursive
              -- @let@ group (a thunked closure, never forced at construction
              -- time — mirrors '_env_onTabsChanged' above).
              , _env_startHarness     = \spec -> do
                  r <- spawnHarnessSession frontendEnv spec (SessionTypes.SkHarness spec)
                  pure $ either
                    (Left . harnessErrText)
                    (\(_sid, hid, _meta, key) -> Right (BoundHarness hid, key))
                    r
              -- Task C2: the dispatcher-reachable @\/tab@ command seam, wired to
              -- the shared @runTabCommand@ over @tabDispatchDeps@. The web path
              -- captures dispatcher output via the scoped /capture/ channel
              -- @chan@ (its '_env_channel'), NOT '_env_sinks' — so @_td_emit@ is
              -- overridden to send the reply text to @chan@ rather than the
              -- conversation's sink. @Nothing@ (no caller 'ConversationKey')
              -- falls back to @webConvKey@.
              , _env_runTabCommand    = \chan mConv cmd ->
                  runTabCommand
                    (tabDispatchDeps
                       { _td_emit = \_ t -> _ch_send chan (OutgoingMessage t) })
                    (fromMaybe webConvKey mConv)
                    cmd
              }
        -- Start the frontend server and the activity probe loop under
        -- structured 'Async.withAsync' scopes so both are automatically
        -- cancelled when the agent loop exits or throws (WU3 + WU4
        -- lifecycle changes). The probe loop is a sibling of the WAI
        -- server inside @runAgentLoopWith@'s scope (D24): both share
        -- @startWithChannel@ as the common parent, and both are
        -- guaranteed to be cancelled within 1 s of @runAgentLoopWith@
        -- returning or throwing.
            listModelsForProvider providerName =
              case parseProviderMaybe (Just providerName) of
                Nothing -> pure []
                Just ptype -> do
                  mProv <- resolveProvider ptype effectiveApiKey vaultOpt manager
                  case mProv of
                    Nothing -> pure []
                    Just sp -> do
                      result <- try @SomeException (listModels sp)
                      case result of
                        Left  _   -> pure []
                        Right ids -> pure (map unModelId ids)
            listConfiguredProviders = do
              let all_ = [minBound .. maxBound] :: [ProviderType]
              keepers <- filterM
                (\p -> hasProviderCredentials manager p effectiveApiKey vaultOpt)
                all_
              pure $ map
                (\p -> ProviderInfo
                  { _pi_name         = T.pack (providerToText p)
                  , _pi_isDefault    = p == effectiveProvider
                  , _pi_defaultModel =
                      if p == effectiveProvider
                        then Just (unModelId model)
                        else Nothing
                  })
                keepers
            frontendEnv = FrontendEnv
              { _fe_harnesses    = harnessRef
              , _fe_harnessRegistry = harnessReg
              , _fe_consentChannel = consentChannel
              , _fe_adopt        =
                  adoptExternalWindow defaultClaudeCodeDeps harnessReg
                    mkNoOpTranscriptHandle sessionsDir
              , _fe_releaseTmux  = productionReleaseTmux
              , _fe_killWindow   = productionKillWindow
              , _fe_sessionsDir  = sessionsDir
              , _fe_recentLimit  = 50
              , _fe_provider     = providerRef
              , _fe_model        = modelRef
              , _fe_systemPrompt = sysPrompt
              , _fe_logger       = logger
              , _fe_agentsDir    = agentsDir
              , _fe_defaultAgent = _fc_defaultAgent fileCfg
              , _fe_broker       = Just broker
              , _fe_streamGuard  = Just streamGuard
              , _fe_maxTabs      = Routing._rc_maxTabs routingCfg
              , _fe_tabRegistry  = _ts_tabRegistry tabSub
              , _fe_cursors      = _ts_cursors tabSub
              , _fe_exec         = _ts_exec tabSub
              , _fe_closeTab     = \_ -> pure (Left "not wired")
              , _fe_startHarness = \spec transcript -> do
                  windowIdx <- readIORef windowIdxRef
                  let name      = SessionTypes.flavourToText (SessionTypes._h_flavour spec)
                      skipPerms = "--unsafe" `elem` SessionTypes._h_args spec
                                    || "--dangerously-skip-permissions" `elem` SessionTypes._h_args spec
                      cwd       = fmap T.unpack (SessionTypes._h_cwd spec)
                      canonical = fromMaybe name (resolveHarnessName name)
                      harnessKey = canonical <> "-" <> T.pack (show windowIdx)
                      -- WU7 (epic core fix): honor the requested tmux session
                      -- (default "pureclaw"). The window is still auto-assigned
                      -- (harnessKey = canonical-<idx>); honoring a caller's
                      -- _tc_window for placement is deferred (pureclaw-jlc).
                      session = resolveHarnessSession spec
                  result <- startHarnessByName policy transcript session name
                              harnessKey windowIdx cwd skipPerms harnessReg
                  case result of
                    Left err -> pure (Left err)
                    Right (hid, hh, mUuid) -> do
                      modifyIORef' harnessRef (Map.insert harnessKey hh)
                      modifyIORef' windowIdxRef (+ 1)
                      -- WU6 (D6.3): persist the canonicalized spawn cwd ONLY when
                      -- we actually minted a claude-code session uuid (mUuid is
                      -- Just for the claude-code flavour, Nothing otherwise), so
                      -- the JSONL log path can be re-derived after a restart. The
                      -- canonical cwd is the resolved spawn workdir
                      -- ('cwd' = _h_cwd) when supplied, else the process's
                      -- current working directory (which a tmux window with no
                      -- explicit -c inherits). 'canonicalizePath' resolves
                      -- symlinks/.. so it matches claude-code's own sanitize(cwd).
                      mCanonCwd <- case mUuid of
                        Nothing -> pure Nothing
                        Just _  -> do
                          base <- maybe getCurrentDirectory pure cwd
                          canon <- canonicalizePath base
                          pure (Just (T.pack canon))
                      pure (Right (StartedHarness
                        { _shh_key  = harnessKey
                        , _shh_tmux = SessionTypes.TmuxConfig
                            { SessionTypes._tc_session = session
                            , SessionTypes._tc_window  = harnessKey
                            , SessionTypes._tc_pane    = Nothing
                            }
                        , _shh_id   = hid
                        , _shh_claudeSessionUuid = mUuid
                        , _shh_canonicalCwd      = mCanonCwd
                        }))
              , _fe_listModels   = listModelsForProvider
              , _fe_listProviders = listConfiguredProviders
              , _fe_registry     = fullRegistry
              , _fe_maxToolIterations = 90
              , _fe_agentEnv     = env
              }
        -- Fill the envRef so the tab completer can access the live env.
        writeIORef envRef (Just env)
        -- Boot reconstruction (WU5, D5.6): one tmux sweep builds the registry
        -- from windows carrying our @pcl_id (PCL-restart reconnect) and lazily
        -- stamps legacy claude-code-<idx> windows. The legacy '_env_harnesses'
        -- map was already seeded in parallel by 'discoverHarnesses' above.
        Reconcile.bootReconstruct Reconcile.defaultReconcileDeps harnessReg logger
        -- Orphan grace policy (WU2): run the reconcile loop with an eviction
        -- seam that, once an entry has been Orphaned for
        -- 'Reconcile.defaultOrphanGraceTicks' consecutive ticks, drops it from
        -- the legacy '_env_harnesses' map (keyed by the window-name label). The
        -- reconcile LOOP owns the registry delete (it calls
        -- 'Registry.deleteEntry' inside 'reconcileTick'); per the '_rd_evict'
        -- seam contract this callback is responsible ONLY for the legacy map, so
        -- it does NOT delete the registry entry again (that would be a redundant
        -- double-delete — idempotent, but contradicting the seam's contract).
        -- Neither path touches 'session.json', so the session reappears in
        -- Recent Sessions.
        let reconcileDeps = Reconcile.defaultReconcileDeps
              { Reconcile._rd_evict = \_hid label ->
                  modifyIORef' harnessRef (Map.delete label)
              }
        -- WU8 (#80): restore the persisted tab view BEFORE the frontend server
        -- (and the tabbed loop) start, so the very first sidebar lists snapshot
        -- already reflects the tabs from the previous run. 'loadTabs' decodes
        -- @state\/tabs.json@ and reconciles each tab against ground truth:
        --
        --   * @_pd_discoveryReady = pure ()@ — the synchronous
        --     'Reconcile.bootReconstruct' above has already completed one
        --     harness-discovery sweep, so no further await is needed before
        --     pruning dead-harness tabs.
        --   * @_pd_harnessLive@ — a 'BoundHarness' tab survives only if its id
        --     resolves to a registry entry whose reconciled liveness is not
        --     'Registry.LivenessOrphaned' (no live window+PID).
        --   * @_pd_sessionExists@ — a 'BoundSession' tab survives only if its
        --     @session.json@ is still on disk.
        --
        -- The reconciled @(tabs, cursors)@ then SEED the shared subsystem cells
        -- ('overwriteTabs' for the registry, 'writeIORef' for the cursors), so
        -- chat @/N@ and the frontend observe the restored tabs identically.
        let bootPersistDeps = PersistDeps
              { _pd_stateDir       = pureclawDir </> "state"
              , _pd_harnessLive    = \hid -> do
                  mEntry <- Registry.lookupById harnessReg hid
                  pure $ case mEntry of
                    Just e  -> Registry._he_liveness e /= Registry.LivenessOrphaned
                    Nothing -> False
              , _pd_discoveryReady = pure ()
              , _pd_sessionExists  = \sid ->
                  doesFileExist (sessionsDir </> T.unpack (unSessionId sid) </> "session.json")
              }
        (loadedTabs, loadedCursors) <- loadTabs bootPersistDeps
        overwriteTabs (_ts_tabRegistry tabSub) loadedTabs
        writeIORef (_ts_cursors tabSub) loadedCursors
            -- Bind host precedence: --bind flag, else config-file bind_host,
            -- else the loopback default.
        let feCfg = defaultFrontendConfig
                      { _fsc_bindHost =
                          fromMaybe (_fsc_bindHost defaultFrontendConfig)
                            (_co_bind opts <|> fmap T.unpack (_fc_bindHost fileCfg))
                      }
        Async.withAsync
          (runFrontend feCfg (Just frontendEnv) logger) $ \_serverAsync ->
          Async.withAsync
            (Reconcile.runReconcileLoopWith
               Reconcile.defaultTickMicros reconcileDeps harnessReg broker logger)
            $ \_probeAsync ->
            -- Tabs-as-View (GitHub #79) — the production entry is the tabbed
            -- loop. It seeds each provider runtime's context from the session
            -- transcript directly (via 'loadRecentMessages'), so a
            -- foreground-wide message replay at boot is not needed here.
            runTabbedLoop env tabStore

  case effectiveChannel of
    "signal" -> do
      let sigCfg = resolveSignalConfig fileCfg
      -- Warn loudly if Signal accepts messages from any sender (no allow-list).
      warnIfOpenAllowList logger signalAllowListContext (_sc_allowFrom sigCfg)
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
          mkCLIChannelHandle (Just slashCompleter) >>= startWithChannel
        Right _ -> do
          _lh_logInfo logger $ "Signal account: " <> _sc_account sigCfg
          transport <- mkSignalCliTransport (_sc_account sigCfg) logger
          withSignalChannel sigCfg transport logger startWithChannel
    "cli" ->
      mkCLIChannelHandle (Just slashCompleter) >>= startWithChannel
    other -> do
      _lh_logWarn logger $ "Unknown channel: " <> T.pack other <> ". Using CLI."
      mkCLIChannelHandle (Just slashCompleter) >>= startWithChannel

-- | Decide whether the first streamed completion should trigger
-- 'markBootstrapConsumed' on the active session.
--
-- Returns @Just action@ only if there is an active agent, the agent
-- directory contains a non-empty @BOOTSTRAP.md@, and the session's
-- current metadata has @_sm_bootstrapConsumed == False@. Otherwise
-- returns 'Nothing' so the loop performs no work on first
-- 'StreamDone'.
resolveBootstrapCallback
  :: LogHandle
  -> Maybe AgentDef.AgentDef
  -> SessionHandle
  -> IO (Maybe (IO ()))
resolveBootstrapCallback _ Nothing _ = pure Nothing
resolveBootstrapCallback _ (Just def) sh = do
  let bootstrapPath = AgentDef._ad_dir def </> "BOOTSTRAP.md"
  hasBootstrap <- doesFileExist bootstrapPath
  meta <- readIORef (_sh_meta sh)
  if hasBootstrap && not (SessionTypes._sm_bootstrapConsumed meta)
    then pure (Just (markBootstrapConsumedShim sh))
    else pure Nothing
  where
    markBootstrapConsumedShim = markBootstrapConsumed

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
buildRegistry :: SecurityPolicy -> ShellHandle -> WorkspaceRoot -> FileHandle -> MemoryHandle -> NetworkHandle -> ChannelHandle -> ToolRegistry
buildRegistry policy sh workspace fh mh nh ch =
  let reg = uncurry registerTool
  in reg (shellTool policy sh)
   $ reg (execTool policy sh)
   $ reg (fileReadTool workspace fh)
   $ reg (fileWriteTool workspace fh)
   $ reg (editTool workspace fh)
   $ reg (patchTool workspace fh)
   $ reg (searchFilesTool workspace)
   $ reg (clarifyTool ch)
   $ reg (gitTool policy sh)
   $ reg (memoryStoreTool mh)
   $ reg (memoryRecallTool mh)
   $ reg (httpRequestTool AllowAll nh)
   $ reg (webExtractTool AllowAll nh)
   $ reg (executeCodeTool policy)
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
  { _sp_allowedCommands       = AllowAll
  , _sp_autonomy              = level
  , _sp_allowedRemoteCommands = AllowList Set.empty
  }
buildPolicy (Just level) cmds =
  let cmdNames = Set.fromList (map (CommandName . T.pack) cmds)
  in SecurityPolicy
    { _sp_allowedCommands       = AllowList cmdNames
    , _sp_autonomy              = level
    , _sp_allowedRemoteCommands = AllowList Set.empty
    }
buildPolicy Nothing [] = defaultPolicy
buildPolicy Nothing cmds =
  let cmdNames = Set.fromList (map (CommandName . T.pack) cmds)
  in SecurityPolicy
    { _sp_allowedCommands       = AllowList cmdNames
    , _sp_autonomy              = Full
    , _sp_allowedRemoteCommands = AllowList Set.empty
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
resolveProvider Ollama _ _ manager = do
  provider <- mkOllamaProvider manager
  pure (Just (MkProvider provider))

-- | Cheap check for whether a provider is "configured" — i.e., the
-- frontend should offer it in the provider dropdown.
--
--   * @Anthropic@: API key in flag/env/vault, or cached OAuth tokens in
--     the vault. Does not refresh expired tokens.
--   * @OpenAI@ \/ @OpenRouter@: API key in flag/env/vault.
--   * @Ollama@: a sub-second HTTP probe of @\/api\/tags@ on @localhost:11434@.
--
-- Never throws. Intended to be safe to call on every modal open.
hasProviderCredentials
  :: HTTP.Manager
  -> ProviderType
  -> Maybe String
  -> Maybe VaultHandle
  -> IO Bool
hasProviderCredentials _ Anthropic keyOpt vaultOpt = do
  mApiKey <- resolveApiKey keyOpt "ANTHROPIC_API_KEY" vaultOpt
  case mApiKey of
    Just _  -> pure True
    Nothing -> do
      cachedBs <- tryVaultLookup vaultOpt oauthVaultKey
      pure (isJust (cachedBs >>= eitherToMaybe . deserializeTokens))
hasProviderCredentials _ OpenAI keyOpt vaultOpt =
  isJust <$> resolveApiKey keyOpt "OPENAI_API_KEY" vaultOpt
hasProviderCredentials _ OpenRouter keyOpt vaultOpt =
  isJust <$> resolveApiKey keyOpt "OPENROUTER_API_KEY" vaultOpt
hasProviderCredentials manager Ollama _ _ = do
  result <- try @SomeException $ do
    initReq <- HTTP.parseRequest "http://localhost:11434/api/tags"
    let req = initReq
          { HTTP.method          = "GET"
          , HTTP.responseTimeout = HTTP.responseTimeoutMicro 1000000  -- 1s
          }
    _ <- HTTP.httpLbs req manager
    pure True
  pure (fromRight False result)

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

-- | Run an 'IO' action best-effort, swallowing any exception. Used by the WU8
-- (#80) tab-change notify so a 'saveTabs' failure (disk full, permission
-- error) degrades to a no-op instead of crashing the agent loop — the tab
-- view is machine-local runtime state, not ground truth, so a missed persist
-- is recoverable on the next mutation.
ignoreExc :: IO () -> IO ()
ignoreExc act = act `catch` \(_ :: SomeException) -> pure ()

-- | Render a 'HarnessError' to a concise user-facing 'Text' for the
-- @\/tab new harness@ dispatcher (WU-B). Mirrors the surface
-- 'PureClaw.Frontend.API.harnessErrorResponse' uses, but as plain text for the
-- chat banner rather than an HTTP body.
harnessErrText :: HarnessError -> T.Text
harnessErrText err = case err of
  HarnessNotAuthorized ce    -> "harness not authorized: " <> T.pack (show ce)
  HarnessBinaryNotFound bin  -> "harness binary not found: " <> bin
  HarnessTmuxNotAvailable det -> "tmux not available: " <> det

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

-- | Allow-list warning context for the Signal channel: display name, lowercase
--   TOML table key, and a concrete example @allow_from@ entry.
signalAllowListContext :: AllowListContext
signalAllowListContext = AllowListContext "Signal" "signal" "edf52444-6e27-4a42-a9ad-9f4f4aca9b26"

-- | Resolve Telegram channel config from the file config. Mirrors
--   'resolveSignalConfig': @dm_policy = "open"@ or a missing/empty @allow_from@
--   yields an open allow-list (AllowAll); otherwise the listed numeric IDs are
--   wrapped as 'UserId's. The API base is fixed; the bot token defaults to "".
resolveTelegramConfig :: FileConfig -> TelegramConfig
resolveTelegramConfig fileCfg =
  let tgCfg = _fc_telegram fileCfg
      dmPolicy = tgCfg >>= _ftc_dmPolicy
      allowFrom = case dmPolicy of
        Just "open" -> AllowAll
        _ -> case tgCfg >>= _ftc_allowFrom of
          Nothing    -> AllowAll
          Just []    -> AllowAll
          Just users -> AllowList (Set.fromList (map UserId users))
  in TelegramConfig
    { _tc_botToken = fromMaybe "" (tgCfg >>= _ftc_botToken)
    , _tc_apiBase  = "https://api.telegram.org"
    , _tc_allowFrom = allowFrom
    }
