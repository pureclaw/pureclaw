module PureClaw.CLI.Commands
  ( -- * Entry point
    runCLI
    -- * Options (exported for testing)
  , ChatOptions (..)
  , chatOptionsParser
    -- * Enums (exported for testing)
  , ProviderType (..)
  , MemoryBackend (..)
  ) where

import Data.Maybe
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP
import Options.Applicative
import System.Environment
import System.Exit
import System.IO

import PureClaw.Agent.Identity
import PureClaw.Agent.Loop
import PureClaw.Channels.CLI
import PureClaw.Core.Types
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
data ChatOptions = ChatOptions
  { _co_model         :: String
  , _co_apiKey        :: Maybe String
  , _co_system        :: Maybe String
  , _co_provider      :: ProviderType
  , _co_allowCommands :: [String]
  , _co_memory        :: MemoryBackend
  , _co_soul          :: Maybe String
  }
  deriving stock (Show, Eq)

-- | Parser for chat options.
chatOptionsParser :: Parser ChatOptions
chatOptionsParser = ChatOptions
  <$> strOption
      ( long "model"
     <> short 'm'
     <> value "claude-sonnet-4-20250514"
     <> showDefault
     <> help "Model to use"
      )
  <*> optional (strOption
      ( long "api-key"
     <> help "API key (default: from env var for chosen provider)"
      ))
  <*> optional (strOption
      ( long "system"
     <> short 's'
     <> help "System prompt (overrides SOUL.md)"
      ))
  <*> option parseProviderType
      ( long "provider"
     <> short 'p'
     <> value Anthropic
     <> showDefaultWith providerToText
     <> help "LLM provider: anthropic, openai, openrouter, ollama"
      )
  <*> many (strOption
      ( long "allow"
     <> short 'a'
     <> help "Allow a shell command (repeatable, e.g. --allow git --allow ls)"
      ))
  <*> option parseMemoryBackend
      ( long "memory"
     <> value NoMemory
     <> showDefaultWith memoryToText
     <> help "Memory backend: none, sqlite, markdown"
      )
  <*> optional (strOption
      ( long "soul"
     <> help "Path to SOUL.md identity file (default: ./SOUL.md if it exists)"
      ))

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

-- | Full CLI parser with help and version.
cliParserInfo :: ParserInfo ChatOptions
cliParserInfo = info (chatOptionsParser <**> helper)
  ( fullDesc
 <> progDesc "Interactive AI chat with tool use"
 <> header "pureclaw — Haskell-native AI agent runtime"
  )

-- | Main CLI entry point.
runCLI :: IO ()
runCLI = do
  opts <- execParser cliParserInfo
  runChat opts

-- | Run an interactive chat session.
runChat :: ChatOptions -> IO ()
runChat opts = do
  let logger = mkStderrLogHandle

  -- Provider
  manager <- HTTP.newTlsManager
  provider <- resolveProvider (_co_provider opts) (_co_apiKey opts) manager

  -- Model
  let model = ModelId (T.pack (_co_model opts))

  -- System prompt: explicit --system flag > SOUL.md > nothing
  sysPrompt <- case _co_system opts of
    Just s  -> pure (Just (T.pack s))
    Nothing -> do
      let soulPath = fromMaybe "SOUL.md" (_co_soul opts)
      ident <- loadIdentity soulPath
      if ident == defaultIdentity
        then pure Nothing
        else pure (Just (identitySystemPrompt ident))

  -- Security policy
  let policy = buildPolicy (_co_allowCommands opts)

  -- Handles
  let channel   = mkCLIChannelHandle
      workspace = WorkspaceRoot "."
      sh        = mkShellHandle logger
      fh        = mkFileHandle workspace
      nh        = mkNetworkHandle manager
  mh <- resolveMemory (_co_memory opts)

  -- Tool registry
  let registry = buildRegistry policy sh workspace fh mh nh

  hSetBuffering stdout LineBuffering
  _lh_logInfo logger $ "Provider: " <> T.pack (providerToText (_co_provider opts))
  _lh_logInfo logger $ "Model: " <> T.pack (_co_model opts)
  _lh_logInfo logger $ "Memory: " <> T.pack (memoryToText (_co_memory opts))
  case _co_allowCommands opts of
    [] -> _lh_logInfo logger "Commands: none (deny all)"
    cmds -> _lh_logInfo logger $ "Commands: " <> T.intercalate ", " (map T.pack cmds)
  putStrLn "PureClaw 0.1.0 — Haskell-native AI agent runtime"
  putStrLn "Type your message and press Enter. Ctrl-D to exit."
  putStrLn ""
  runAgentLoop provider model channel logger sysPrompt registry

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

-- | Build a security policy from the list of allowed commands.
buildPolicy :: [String] -> SecurityPolicy
buildPolicy [] = defaultPolicy
buildPolicy cmds =
  let cmdNames = Set.fromList (map (CommandName . T.pack) cmds)
  in defaultPolicy
    { _sp_allowedCommands = AllowList cmdNames
    , _sp_autonomy = Full
    }

-- | Resolve the LLM provider from the provider type.
resolveProvider :: ProviderType -> Maybe String -> HTTP.Manager -> IO SomeProvider
resolveProvider Anthropic keyOpt manager = do
  apiKey <- resolveApiKey keyOpt "ANTHROPIC_API_KEY"
  pure (MkProvider (mkAnthropicProvider manager apiKey))
resolveProvider OpenAI keyOpt manager = do
  apiKey <- resolveApiKey keyOpt "OPENAI_API_KEY"
  pure (MkProvider (mkOpenAIProvider manager apiKey))
resolveProvider OpenRouter keyOpt manager = do
  apiKey <- resolveApiKey keyOpt "OPENROUTER_API_KEY"
  pure (MkProvider (mkOpenRouterProvider manager apiKey))
resolveProvider Ollama _ manager =
  pure (MkProvider (mkOllamaProvider manager))

-- | Resolve an API key from a CLI flag or an environment variable.
resolveApiKey :: Maybe String -> String -> IO ApiKey
resolveApiKey (Just key) _ = pure (mkApiKey (TE.encodeUtf8 (T.pack key)))
resolveApiKey Nothing envVar = do
  envKey <- lookupEnv envVar
  case envKey of
    Just key -> pure (mkApiKey (TE.encodeUtf8 (T.pack key)))
    Nothing  -> die $ "No API key provided. Use --api-key or set " <> envVar

-- | Resolve the memory backend.
resolveMemory :: MemoryBackend -> IO MemoryHandle
resolveMemory NoMemory       = pure mkNoOpMemoryHandle
resolveMemory SQLiteMemory   = mkSQLiteMemoryHandle ".pureclaw/memory.db"
resolveMemory MarkdownMemory = mkMarkdownMemoryHandle ".pureclaw/memory"
