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

import Control.Exception (bracket_)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Maybe
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP
import Options.Applicative
import System.Directory (doesFileExist)
import System.Environment
import System.IO

import PureClaw.Auth.AnthropicOAuth
import PureClaw.CLI.Config

import PureClaw.Agent.Env
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

  -- Load config file: --config flag overrides default search locations
  fileCfg <- maybe loadConfig loadFileConfig (_co_config opts)

  -- Resolve effective values: CLI flag > config file > default
  let effectiveProvider = fromMaybe Anthropic  (_co_provider opts <|> parseProviderMaybe (_fc_provider fileCfg))
      effectiveModel    = fromMaybe "claude-sonnet-4-20250514" (_co_model opts <|> fmap T.unpack (_fc_model fileCfg))
      effectiveMemory   = fromMaybe NoMemory    (_co_memory opts <|> parseMemoryMaybe (_fc_memory fileCfg))
      effectiveApiKey   = _co_apiKey opts <|> fmap T.unpack (_fc_apiKey fileCfg)
      effectiveSystem   = _co_system opts <|> fmap T.unpack (_fc_system fileCfg)
      effectiveAllow    = _co_allowCommands opts <> maybe [] (map T.unpack) (_fc_allow fileCfg)

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
  let policy = buildPolicy effectiveAllow

  -- Handles
  let channel   = mkCLIChannelHandle
      workspace = WorkspaceRoot "."
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
      "No credentials configured \x2014 use /vault setup or /vault add to get started"
  _lh_logInfo logger $ "Model: " <> T.pack effectiveModel
  _lh_logInfo logger $ "Memory: " <> T.pack (memoryToText effectiveMemory)
  case effectiveAllow of
    [] -> _lh_logInfo logger "Commands: none (deny all)"
    cmds -> _lh_logInfo logger $ "Commands: " <> T.intercalate ", " (map T.pack cmds)
  putStrLn "PureClaw 0.1.0 — Haskell-native AI agent runtime"
  putStrLn "Type your message and press Enter. Ctrl-D to exit."
  putStrLn ""
  vaultRef    <- newIORef vaultOpt
  providerRef <- newIORef mProvider
  let env = AgentEnv
        { _env_provider     = providerRef
        , _env_model        = model
        , _env_channel      = channel
        , _env_logger       = logger
        , _env_systemPrompt = sysPrompt
        , _env_registry     = registry
        , _env_vault        = vaultRef
        , _env_pluginHandle = mkPluginHandle
        }
  runAgentLoop env

-- | Parse a provider type from a text value (used for config file).
parseProviderMaybe :: Maybe T.Text -> Maybe ProviderType
parseProviderMaybe Nothing  = Nothing
parseProviderMaybe (Just t) = case T.unpack t of
  "anthropic"  -> Just Anthropic
  "openai"     -> Just OpenAI
  "openrouter" -> Just OpenRouter
  "ollama"     -> Just Ollama
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
-- Checks the vault for the API key (using the env var name as the vault key)
-- before falling back to CLI flag or environment variable.
-- Returns 'Nothing' if no credentials are available (the agent loop
-- will still start, allowing the user to configure credentials via
-- slash commands like /vault setup).
resolveProvider :: ProviderType -> Maybe String -> Maybe VaultHandle -> HTTP.Manager -> IO (Maybe SomeProvider)
resolveProvider Anthropic keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "ANTHROPIC_API_KEY" vaultOpt
  pure (fmap (\k -> MkProvider (mkAnthropicProvider manager k)) mApiKey)
resolveProvider OpenAI keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "OPENAI_API_KEY" vaultOpt
  pure (fmap (\k -> MkProvider (mkOpenAIProvider manager k)) mApiKey)
resolveProvider OpenRouter keyOpt vaultOpt manager = do
  mApiKey <- resolveApiKey keyOpt "OPENROUTER_API_KEY" vaultOpt
  pure (fmap (\k -> MkProvider (mkOpenRouterProvider manager k)) mApiKey)
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

-- | Resolve an API key from: CLI flag → vault → environment variable.
-- Returns 'Nothing' if no key is found anywhere.
resolveApiKey :: Maybe String -> String -> Maybe VaultHandle -> IO (Maybe ApiKey)
resolveApiKey (Just key) _ _ = pure (Just (mkApiKey (TE.encodeUtf8 (T.pack key))))
resolveApiKey Nothing envVar vaultOpt = do
  vaultKey <- tryVaultLookup vaultOpt (T.pack envVar)
  case vaultKey of
    Just bs -> pure (Just (mkApiKey bs))
    Nothing -> do
      envKey <- lookupEnv envVar
      case envKey of
        Just key -> pure (Just (mkApiKey (TE.encodeUtf8 (T.pack key))))
        Nothing  -> pure Nothing

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
-- Prompts for passphrase on stdin at startup (if vault file exists), or reads
-- from the PURECLAW_VAULT_PASSPHRASE environment variable.
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
        envPass <- lookupEnv "PURECLAW_VAULT_PASSPHRASE"
        case envPass of
          Just p  -> pure (TE.encodeUtf8 (T.pack p))
          Nothing -> do
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
