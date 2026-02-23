module PureClaw.CLI.Commands
  ( -- * Entry point
    runCLI
    -- * Options (exported for testing)
  , ChatOptions (..)
  , chatOptionsParser
  ) where

import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client.TLS qualified as HTTP
import Options.Applicative
import System.Environment
import System.Exit
import System.IO

import PureClaw.Agent.Loop
import PureClaw.Channels.CLI
import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Handles.Log
import PureClaw.Handles.Memory
import PureClaw.Handles.Shell
import PureClaw.Providers.Anthropic
import PureClaw.Security.Policy
import PureClaw.Security.Secrets
import PureClaw.Tools.FileRead
import PureClaw.Tools.FileWrite
import PureClaw.Tools.Git
import PureClaw.Tools.Memory
import PureClaw.Tools.Registry
import PureClaw.Tools.Shell

-- | CLI chat options.
data ChatOptions = ChatOptions
  { _co_model  :: String
  , _co_apiKey :: Maybe String
  , _co_system :: Maybe String
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
     <> help "Anthropic API key (default: ANTHROPIC_API_KEY env var)"
      ))
  <*> optional (strOption
      ( long "system"
     <> short 's'
     <> help "System prompt"
      ))

-- | Full CLI parser with help and version.
cliParserInfo :: ParserInfo ChatOptions
cliParserInfo = info (chatOptionsParser <**> helper)
  ( fullDesc
 <> progDesc "Interactive AI chat powered by Anthropic"
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
  apiKey <- resolveApiKey (_co_apiKey opts)
  manager <- HTTP.newTlsManager
  let provider  = mkAnthropicProvider manager apiKey
      model     = ModelId (T.pack (_co_model opts))
      sysPrompt = T.pack <$> _co_system opts
      logger    = mkStderrLogHandle
      channel   = mkCLIChannelHandle
      workspace = WorkspaceRoot "."
      policy    = defaultPolicy
      sh        = mkShellHandle logger
      fh        = mkFileHandle workspace
      mh        = mkNoOpMemoryHandle
      registry  = buildRegistry policy sh workspace fh mh
  hSetBuffering stdout LineBuffering
  putStrLn "PureClaw 0.1.0 — Haskell-native AI agent runtime"
  putStrLn "Type your message and press Enter. Ctrl-D to exit."
  putStrLn ""
  runAgentLoop provider model channel logger sysPrompt registry

-- | Build the tool registry with all available tools.
buildRegistry :: SecurityPolicy -> ShellHandle -> WorkspaceRoot -> FileHandle -> MemoryHandle -> ToolRegistry
buildRegistry policy sh workspace fh mh =
  let reg = uncurry registerTool
  in reg (shellTool policy sh)
   $ reg (fileReadTool workspace fh)
   $ reg (fileWriteTool workspace fh)
   $ reg (gitTool policy sh)
   $ reg (memoryStoreTool mh)
   $ reg (memoryRecallTool mh)
     emptyRegistry

-- | Resolve the API key from a CLI flag or the ANTHROPIC_API_KEY env var.
resolveApiKey :: Maybe String -> IO ApiKey
resolveApiKey (Just key) = pure (mkApiKey (TE.encodeUtf8 (T.pack key)))
resolveApiKey Nothing = do
  envKey <- lookupEnv "ANTHROPIC_API_KEY"
  case envKey of
    Just key -> pure (mkApiKey (TE.encodeUtf8 (T.pack key)))
    Nothing  -> die "No API key provided. Use --api-key or set ANTHROPIC_API_KEY"
