module PureClaw.CLI.Commands
  ( -- * Entry point
    runCLI
    -- * Options (exported for testing)
  , ChatOptions (..)
  , chatOptionsParser
    -- * Enums (exported for testing)
  , MemoryBackend (..)
  ) where

import Control.Exception (bracket_)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.List (isPrefixOf)
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
import System.Exit
import System.IO
import Text.Read (readMaybe)

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
import PureClaw.Tools.FileRead
import PureClaw.Tools.FileWrite
import PureClaw.Tools.Git
import PureClaw.Tools.HttpRequest
import PureClaw.Tools.Memory
import PureClaw.Tools.Registry
import PureClaw.Tools.Shell

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
  , _co_system        :: Maybe String
  , _co_provider      :: Maybe ProviderType
  , _co_allowCommands :: [String]
  , _co_memory        :: Maybe MemoryBackend
  , _co_soul          :: Maybe String
  , _co_config        :: Maybe FilePath
  , _co_noVault       :: Bool
  }
  deriving stock (Show, Eq)

-- | Parser for chat options.
chatOptionsParser :: Parser ChatOptions
chatOptionsParser = ChatOptions
  <$> optional (strOption
      ( long "model"
     <> short 'm'
     <> help "Model to use, e.g. claude-sonnet-4-20250514 or anthropic:claude-opus-4-5"
      ))
  <*> optional (strOption
      ( long "system"
     <> short 's'
     <> help "System prompt (overrides SOUL.md)"
      ))
  <*> optional (option parseProviderType
      ( long "provider"
     <> short 'p'
     <> help "LLM provider override: anthropic, openai, openrouter, ollama"
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

-- | Parse a provider type from a CLI string.
parseProviderType :: ReadM ProviderType
parseProviderType = eitherReader $ \s -> case parseProviderString s of
  Just p  -> Right p
  Nothing -> Left $ "Unknown provider: " <> s <> ". Choose: anthropic, openai, openrouter, ollama"

-- | Parse a provider type from a string.
parseProviderString :: String -> Maybe ProviderType
parseProviderString "anthropic"  = Just PTAnthropic
parseProviderString "openai"     = Just PTOpenAI
parseProviderString "openrouter" = Just PTOpenRouter
parseProviderString "ollama"     = Just PTOllama
parseProviderString _            = Nothing

-- | Display a provider type as a CLI string.
providerTypeToText :: ProviderType -> String
providerTypeToText PTAnthropic  = "anthropic"
providerTypeToText PTOpenAI     = "openai"
providerTypeToText PTOpenRouter = "openrouter"
providerTypeToText PTOllama     = "ollama"

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

  -- Resolve model and provider (handles "provider:model" syntax and interactive picker)
  (effectiveProvider, effectiveModel) <- resolveModelAndProvider opts fileCfg

  let effectiveMemory = fromMaybe NoMemory    (_co_memory opts <|> parseMemoryMaybe (_fc_memory fileCfg))
      effectiveSystem = _co_system opts <|> fmap T.unpack (_fc_system fileCfg)
      effectiveAllow  = _co_allowCommands opts <> maybe [] (map T.unpack) (_fc_allow fileCfg)

  -- Vault (opened before provider so API keys can be fetched from vault)
  vaultOpt <- resolveVault fileCfg (_co_noVault opts) logger

  -- Check if OAuth is needed (from provider config)
  let useOAuth = case effectiveProvider of
        AnthropicProvider cfg -> _apc_auth cfg == AuthOAuth
        _                     -> False

  -- For OAuth: require an initialised vault before opening the browser.
  when useOAuth $
    ensureVaultForOAuth fileCfg (_co_noVault opts)

  -- Provider
  manager <- HTTP.newTlsManager
  providerResult <- if useOAuth
    then fmap Right (resolveAnthropicOAuth vaultOpt manager)
    else resolveProvider effectiveProvider vaultOpt manager

  provider <- case providerResult of
    Right p -> pure p
    Left envVar -> do
      let pt = providerType effectiveProvider
      putStrLn ""
      _lh_logInfo logger $ "⚠️  No credentials found for " <> T.pack (providerTypeToText pt)
      _lh_logInfo logger "Run `/provider <your-chosen-provider>` to configure credentials."
      _lh_logInfo logger $ "Or: export " <> T.pack envVar <> "=your-api-key"
      putStrLn ""
      -- Return a stub provider that explains the issue when actually used
      pure (mkStubProvider pt envVar)

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
  let pt = providerType effectiveProvider
  _lh_logInfo logger $ "Provider: " <> T.pack (providerTypeToText pt)
  _lh_logInfo logger $ "Model: " <> T.pack effectiveModel
  _lh_logInfo logger $ "Memory: " <> T.pack (memoryToText effectiveMemory)
  case effectiveAllow of
    [] -> _lh_logInfo logger "Commands: none (deny all)"
    cmds -> _lh_logInfo logger $ "Commands: " <> T.intercalate ", " (map T.pack cmds)
  putStrLn "PureClaw 0.1.0 — Haskell-native AI agent runtime"
  putStrLn "Type your message and press Enter. Ctrl-D to exit."
  putStrLn ""
  let env = AgentEnv
        { _env_provider     = provider
        , _env_model        = model
        , _env_channel      = channel
        , _env_logger       = logger
        , _env_systemPrompt = sysPrompt
        , _env_registry     = registry
        , _env_vault        = vaultOpt
        }
  runAgentLoop env

-- ---------------------------------------------------------------------------
-- Model / provider resolution
-- ---------------------------------------------------------------------------

-- | A provider type + model pair parsed from @"provider:model"@ syntax.
data ModelSpec = ModelSpec ProviderType String

-- | Parse @"provider:model"@ syntax. Returns Nothing if no colon is present
-- or the prefix is not a known provider name.
parseModelSpec :: String -> Maybe ModelSpec
parseModelSpec s = case break (== ':') s of
  (prefix, ':' : model') | not (null model') ->
    ModelSpec <$> parseProviderString prefix <*> pure model'
  _ -> Nothing

-- | Well-known models for each provider, used in the interactive picker.
-- Ollama and OpenRouter have no fixed list — the user enters the model name.
knownModels :: ProviderType -> [String]
knownModels PTAnthropic  = [ "claude-opus-4-5"
                            , "claude-sonnet-4-20250514"
                            , "claude-haiku-4-5-20251001"
                            ]
knownModels PTOpenAI     = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
knownModels PTOpenRouter = []
knownModels PTOllama     = []

-- | Default model for a provider when none is specified.
defaultModel :: ProviderType -> String
defaultModel PTAnthropic  = "claude-sonnet-4-20250514"
defaultModel PTOpenAI     = "gpt-4o"
defaultModel PTOpenRouter = "openai/gpt-4o"
defaultModel PTOllama     = "llama3.2"

-- | Build a default 'ModelProvider' for a 'ProviderType' (all defaults).
defaultProviderConfig :: ProviderType -> ModelProvider
defaultProviderConfig PTAnthropic  = AnthropicProvider (AnthropicProviderConfig AuthApiKey)
defaultProviderConfig PTOpenAI     = OpenAIProvider (OpenAIProviderConfig Nothing)
defaultProviderConfig PTOpenRouter = OpenRouterProvider OpenRouterProviderConfig
defaultProviderConfig PTOllama     = OllamaProvider (OllamaProviderConfig Nothing)

-- | Find the config entry for a given provider type, if configured.
findProvider :: ProviderType -> FileConfig -> Maybe ModelProvider
findProvider pt cfg = listToMaybe
  [ p | p <- _fc_providers cfg, providerType p == pt ]

-- | Try to infer a provider from a bare model name (e.g. "claude-*" → Anthropic).
inferProvider :: String -> [ProviderType] -> Maybe ProviderType
inferProvider m ps
  | "claude-" `isPrefixOf` m          , PTAnthropic  `elem` ps = Just PTAnthropic
  | any (`isPrefixOf` m) ["gpt-", "o1-", "o3-", "o4-"]
                                      , PTOpenAI     `elem` ps = Just PTOpenAI
  | '/' `elem` m                     , PTOpenRouter `elem` ps = Just PTOpenRouter
  | otherwise                                                  = Nothing

-- | Resolve the effective (provider, model) pair from CLI options and config.
--
-- Priority:
--
-- 1. @"provider:model"@ in @--model@ flag or config @model = "..."@
-- 2. @--provider@ flag with model from @--model@ or config
-- 3. Single configured provider → auto-select
-- 4. Multiple configured providers with a bare model → infer provider
-- 5. Multiple configured providers, no model → interactive picker
-- 6. No providers configured → default to Anthropic (backward compat)
resolveModelAndProvider :: ChatOptions -> FileConfig -> IO (ModelProvider, String)
resolveModelAndProvider opts fileCfg = do
  let modelStr  = _co_model opts <|> fmap T.unpack (_fc_model fileCfg)
      providers = _fc_providers fileCfg
      ptypes    = map providerType providers
  case modelStr >>= parseModelSpec of
    Just (ModelSpec pt m) ->
      let mp = fromMaybe (defaultProviderConfig pt) (findProvider pt fileCfg)
      in pure (mp, m)
    Nothing -> case _co_provider opts of
      Just pt ->
        let mp = fromMaybe (defaultProviderConfig pt) (findProvider pt fileCfg)
        in pure (mp, fromMaybe (defaultModel pt) modelStr)
      Nothing -> case providers of
        [p] -> pure (p, fromMaybe (defaultModel (providerType p)) modelStr)
        []  -> pure (defaultProviderConfig PTAnthropic, fromMaybe (defaultModel PTAnthropic) modelStr)
        _   -> case modelStr of
          Just m -> case inferProvider m ptypes of
            Just pt -> let mp = fromMaybe (defaultProviderConfig pt) (findProvider pt fileCfg)
                       in pure (mp, m)
            Nothing -> case providers of
              (p:_) -> pure (p, m)
          Nothing -> pickModelInteractive ptypes fileCfg

-- | Interactive model picker shown when multiple providers are configured
-- and no model is specified.
pickModelInteractive :: [ProviderType] -> FileConfig -> IO (ModelProvider, String)
pickModelInteractive ptypes fileCfg = do
  putStrLn "\nSelect a model:"
  putStrLn ""
  let entries = concatMap providerEntries ptypes
      providerEntries p =
        let models = knownModels p
        in if null models
           then [(p, Nothing)]
           else map (\m -> (p, Just m)) models
      numbered = zip [1 :: Int ..] entries
  forM_ numbered $ \(n, (p, mModel)) -> case mModel of
    Nothing ->
      putStrLn $ "  " <> show n <> ".  " <> providerTypeToText p <> ":...  (enter model name)"
    Just m ->
      let mark = if m == defaultModel p then "  [default]" else ""
      in putStrLn $ "  " <> show n <> ".  " <> providerTypeToText p <> ":" <> m <> mark
  putStrLn ""
  putStr "Enter number or provider:model — " >> hFlush stdout
  line <- T.unpack . T.strip . T.pack <$> getLine
  case readMaybe line :: Maybe Int of
    Just n | n >= 1 && n <= length numbered ->
      let (p, mModel) = snd (numbered !! (n - 1))
          mp = fromMaybe (defaultProviderConfig p) (findProvider p fileCfg)
      in case mModel of
        Just m  -> pure (mp, m)
        Nothing -> do
          putStr ("  Model name for " <> providerTypeToText p <> ": ") >> hFlush stdout
          m <- T.unpack . T.strip . T.pack <$> getLine
          pure (mp, m)
    _ -> case parseModelSpec line of
      Just (ModelSpec p m) ->
        let mp = fromMaybe (defaultProviderConfig p) (findProvider p fileCfg)
        in pure (mp, m)
      Nothing -> do
        putStrLn "Invalid. Enter a number or use provider:model format (e.g. anthropic:claude-sonnet-4-20250514)."
        pickModelInteractive ptypes fileCfg

-- ---------------------------------------------------------------------------
-- Provider resolution
-- ---------------------------------------------------------------------------

-- | Resolve the LLM provider from its config.
-- API key lookup order: vault (by env var name) → environment variable.
-- API keys are never read from the config file.
-- Returns Left with an error message if credentials cannot be resolved.
resolveProvider :: ModelProvider -> Maybe VaultHandle -> HTTP.Manager -> IO (Either String SomeProvider)
resolveProvider (AnthropicProvider _) vaultOpt manager = do
  result <- resolveApiKeyMaybe "ANTHROPIC_API_KEY" vaultOpt
  case result of
    Just apiKey -> pure $ Right (MkProvider (mkAnthropicProvider manager apiKey))
    Nothing -> do
      -- Fall back to OAuth tokens cached in vault (e.g. configured via /provider anthropic)
      oauthOpt <- loadCachedOAuthProvider vaultOpt manager
      pure $ maybe (Left "ANTHROPIC_API_KEY") Right oauthOpt
resolveProvider (OpenAIProvider _cfg) vaultOpt manager = do
  result <- resolveApiKeyMaybe "OPENAI_API_KEY" vaultOpt
  case result of
    Just apiKey -> pure $ Right (MkProvider (mkOpenAIProvider manager apiKey))
    Nothing -> pure $ Left "OPENAI_API_KEY"
  -- TODO: use _oaipc_baseUrl when mkOpenAIProvider supports custom endpoints
resolveProvider (OpenRouterProvider _) vaultOpt manager = do
  result <- resolveApiKeyMaybe "OPENROUTER_API_KEY" vaultOpt
  case result of
    Just apiKey -> pure $ Right (MkProvider (mkOpenRouterProvider manager apiKey))
    Nothing -> pure $ Left "OPENROUTER_API_KEY"
resolveProvider (OllamaProvider _cfg) _ manager =
  -- TODO: use _olpc_baseUrl when mkOllamaProvider supports custom endpoints
  pure $ Right (MkProvider (mkOllamaProvider manager))

-- ---------------------------------------------------------------------------
-- OAuth
-- ---------------------------------------------------------------------------

-- | Vault key used to cache OAuth tokens between sessions.
oauthVaultKey :: T.Text
oauthVaultKey = "ANTHROPIC_OAUTH_TOKENS"

-- | Load a cached Anthropic OAuth provider from the vault, refreshing if expired.
-- Returns Nothing if no cached tokens exist.
loadCachedOAuthProvider :: Maybe VaultHandle -> HTTP.Manager -> IO (Maybe SomeProvider)
loadCachedOAuthProvider vaultOpt manager = do
  let cfg = defaultOAuthConfig
  cachedBs <- tryVaultLookup vaultOpt oauthVaultKey
  case cachedBs >>= eitherToMaybe . deserializeTokens of
    Nothing -> pure Nothing
    Just t  -> do
      now <- getCurrentTime
      tokens <- if _oat_expiresAt t <= now
        then do
          putStrLn "OAuth access token expired — refreshing..."
          newT <- refreshOAuthToken cfg manager (_oat_refreshToken t)
          saveOAuthTokens vaultOpt newT
          pure newT
        else pure t
      handle <- mkOAuthHandle cfg manager tokens
      pure $ Just (MkProvider (mkAnthropicProviderOAuth manager handle))

-- | Resolve an Anthropic provider via OAuth 2.0 PKCE.
-- Loads cached tokens from the vault if available; runs the full browser
-- flow otherwise. Refreshes expired access tokens automatically.
resolveAnthropicOAuth :: Maybe VaultHandle -> HTTP.Manager -> IO SomeProvider
resolveAnthropicOAuth vaultOpt manager = do
  cached <- loadCachedOAuthProvider vaultOpt manager
  case cached of
    Just p  -> pure p
    Nothing -> do
      tokens <- runOAuthFlow defaultOAuthConfig manager
      saveOAuthTokens vaultOpt tokens
      handle <- mkOAuthHandle defaultOAuthConfig manager tokens
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

-- | Abort with a helpful message if no vault file exists when OAuth is requested.
-- Tokens cannot be persisted without an initialised vault, making every session
-- require a fresh browser flow.
ensureVaultForOAuth :: FileConfig -> Bool -> IO ()
ensureVaultForOAuth _ True =
  die "--no-vault is incompatible with OAuth: tokens cannot be persisted between sessions."
ensureVaultForOAuth fileCfg False = do
  dir  <- getPureclawDir
  let path = maybe (dir ++ "/vault.age") T.unpack (_fc_vault_path fileCfg)
  exists <- doesFileExist path
  unless exists $ die $ unlines
    [ "OAuth requires a vault to store tokens between sessions."
    , "No vault found at: " <> path
    , ""
    , "Create one first:"
    , "  pureclaw"
    , "  /vault init"
    , ""
    , "Then re-run with auth = \"oauth\" in your config."
    ]

-- ---------------------------------------------------------------------------
-- API key resolution
-- ---------------------------------------------------------------------------

-- | Resolve an API key from the vault (preferred) or environment variable.
-- Returns Nothing if the key is not found (without dying).
resolveApiKeyMaybe :: String -> Maybe VaultHandle -> IO (Maybe ApiKey)
resolveApiKeyMaybe envVar vaultOpt = do
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

-- ---------------------------------------------------------------------------
-- Memory
-- ---------------------------------------------------------------------------

-- | Resolve the memory backend.
resolveMemory :: MemoryBackend -> IO MemoryHandle
resolveMemory NoMemory       = pure mkNoOpMemoryHandle
resolveMemory SQLiteMemory   = do
  dir <- getPureclawDir
  mkSQLiteMemoryHandle (dir ++ "/memory.db")
resolveMemory MarkdownMemory = do
  dir <- getPureclawDir
  mkMarkdownMemoryHandle (dir ++ "/memory")

-- ---------------------------------------------------------------------------
-- Vault
-- ---------------------------------------------------------------------------

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
      let path  = maybe (dir ++ "/vault.age") T.unpack (_fc_vault_path fileCfg)
          mode  = parseUnlockMode (_fc_vault_unlock fileCfg)
          enc'  = ageVaultEncryptor enc recipient identity
          cfg   = VaultConfig
            { _vc_path    = path
            , _vc_keyType = inferAgeKeyType recipient
            , _vc_unlock  = mode
            }
      vault <- openVault cfg enc'
      case mode of
        UnlockCached -> do
          result <- _vh_unlock vault
          case result of
            Left err -> _lh_logInfo logger $
              "Vault startup unlock failed (vault will be locked): " <> T.pack (show err)
            Right () -> _lh_logInfo logger "Vault unlocked."
        _ -> pure ()
      pure (Just vault)

-- | Resolve vault using passphrase-based encryption (default when no age keys configured).
-- Prompts for passphrase on stdin at startup (if vault file exists), or reads
-- from the PURECLAW_VAULT_PASSPHRASE environment variable.
resolvePassphraseVault :: FileConfig -> LogHandle -> IO (Maybe VaultHandle)
resolvePassphraseVault fileCfg logger = do
  dir <- getPureclawDir
  let path = maybe (dir ++ "/vault.age") T.unpack (_fc_vault_path fileCfg)
      cfg  = VaultConfig
        { _vc_path    = path
        , _vc_keyType = "AES-256 (passphrase)"
        , _vc_unlock  = UnlockCached
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
    else
      _lh_logInfo logger "Vault ready (not yet initialized — use /vault init to set up)."
  pure (Just vault)

-- ---------------------------------------------------------------------------
-- Policy and registry
-- ---------------------------------------------------------------------------

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

-- | A provider that fails with a helpful message.
-- Used when credentials are not configured, allowing the agent to start
-- so the user can use /vault add to configure them.
newtype StubProvider = StubProvider String

instance Provider StubProvider where
  complete _ _ = failWithMessage
  completeStream _ _ _ = failWithMessage

failWithMessage :: IO a
failWithMessage = do
  putStrLn ""
  putStrLn "Error: No API credentials configured."
  putStrLn ""
  putStrLn "To configure credentials, use the /vault command:"
  putStrLn "  /vault add ANTHROPIC_API_KEY"
  putStrLn ""
  putStrLn "Or set the environment variable:"
  putStrLn "  export ANTHROPIC_API_KEY=your-api-key"
  putStrLn ""
  exitFailure

-- | Create a stub provider that allows the agent to start without credentials.
mkStubProvider :: ProviderType -> String -> SomeProvider
mkStubProvider _ envVar = MkProvider (StubProvider envVar)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Parse a memory backend from a text value (used for config file).
parseMemoryMaybe :: Maybe T.Text -> Maybe MemoryBackend
parseMemoryMaybe Nothing  = Nothing
parseMemoryMaybe (Just t) = case T.unpack t of
  "none"     -> Just NoMemory
  "sqlite"   -> Just SQLiteMemory
  "markdown" -> Just MarkdownMemory
  _          -> Nothing

-- | Infer a human-readable key type from the age recipient prefix.
inferAgeKeyType :: T.Text -> T.Text
inferAgeKeyType recipient
  | "age-plugin-yubikey" `T.isPrefixOf` recipient = "YubiKey PIV"
  | "age1"               `T.isPrefixOf` recipient = "X25519"
  | otherwise                                      = "Unknown"

-- | Parse vault unlock mode from config text.
-- "cached" or "startup" → UnlockCached (decrypt once at startup, keep in memory)
-- "per_access"          → UnlockPerAccess (decrypt on every access; for hardware keys)
parseUnlockMode :: Maybe T.Text -> UnlockMode
parseUnlockMode Nothing = UnlockCached
parseUnlockMode (Just t) = case t of
  "cached"     -> UnlockCached
  "startup"    -> UnlockCached
  "per_access" -> UnlockPerAccess
  _            -> UnlockCached
