module PureClaw.Agent.SlashCommands
  ( -- * Command data types
    SlashCommand (..)
  , VaultSubCommand (..)
  , ProviderSubCommand (..)
    -- * Command registry — single source of truth
  , CommandGroup (..)
  , CommandSpec (..)
  , allCommandSpecs
    -- * Parsing (derived from allCommandSpecs)
  , parseSlashCommand
    -- * Execution
  , executeSlashCommand
  ) where

import Control.Applicative ((<|>))
import Control.Exception
import Data.Foldable (asum)
import Data.IORef
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client.TLS qualified as HTTP
import System.Directory qualified as Dir
import System.FilePath ((</>))

import PureClaw.Agent.Compaction
import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Auth.AnthropicOAuth
import PureClaw.CLI.Config
import PureClaw.Handles.Channel
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Passphrase
import PureClaw.Security.Vault.Plugin

-- ---------------------------------------------------------------------------
-- Command taxonomy
-- ---------------------------------------------------------------------------

-- | Organisational group for display in '/help'.
data CommandGroup
  = GroupSession   -- ^ Session and context management
  | GroupProvider  -- ^ Model provider configuration
  | GroupVault     -- ^ Encrypted secrets vault
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | Human-readable section heading for '/help' output.
groupHeading :: CommandGroup -> Text
groupHeading GroupSession  = "Session"
groupHeading GroupProvider = "Provider"
groupHeading GroupVault    = "Vault"

-- | Specification for a single slash command.
-- 'allCommandSpecs' is the single source of truth: 'parseSlashCommand'
-- is derived from '_cs_parse' and '/help' renders from '_cs_syntax' /
-- '_cs_description', so the two cannot diverge.
data CommandSpec = CommandSpec
  { _cs_syntax      :: Text          -- ^ Display syntax, e.g. "/vault add <name>"
  , _cs_description :: Text          -- ^ One-line description shown in '/help'
  , _cs_group       :: CommandGroup  -- ^ Organisational group
  , _cs_parse       :: Text -> Maybe SlashCommand
    -- ^ Try to parse a stripped, original-case input as this command.
    -- Match is case-insensitive on keywords; argument case is preserved.
  }

-- ---------------------------------------------------------------------------
-- Vault subcommands
-- ---------------------------------------------------------------------------

-- | Subcommands of the '/vault' family.
data VaultSubCommand
  = VaultSetup              -- ^ Interactive vault setup wizard
  | VaultAdd Text           -- ^ Store a named secret
  | VaultList               -- ^ List secret names
  | VaultDelete Text        -- ^ Delete a named secret
  | VaultLock               -- ^ Lock the vault
  | VaultUnlock             -- ^ Unlock the vault
  | VaultStatus'            -- ^ Show vault status
  | VaultUnknown Text       -- ^ Unrecognised subcommand (not in allCommandSpecs)
  deriving stock (Show, Eq)

-- | Subcommands of the '/provider' family.
data ProviderSubCommand
  = ProviderList              -- ^ List available providers
  | ProviderConfigure Text   -- ^ Configure a specific provider
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Top-level commands
-- ---------------------------------------------------------------------------

-- | All recognised slash commands.
data SlashCommand
  = CmdHelp                         -- ^ Show command reference
  | CmdNew                          -- ^ Clear conversation, keep configuration
  | CmdReset                        -- ^ Full reset including usage counters
  | CmdStatus                       -- ^ Show session status
  | CmdCompact                      -- ^ Summarise conversation to save context
  | CmdProvider ProviderSubCommand  -- ^ Provider configuration command family
  | CmdVault VaultSubCommand        -- ^ Vault command family
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Command registry
-- ---------------------------------------------------------------------------

-- | All recognised slash commands, in the order they appear in '/help'.
-- This is the authoritative definition: 'parseSlashCommand' is derived
-- from '_cs_parse' across this list, and '/help' renders from it.
-- To add a command, add a 'CommandSpec' here — parsing and help update
-- automatically.
allCommandSpecs :: [CommandSpec]
allCommandSpecs = sessionCommandSpecs ++ providerCommandSpecs ++ vaultCommandSpecs

sessionCommandSpecs :: [CommandSpec]
sessionCommandSpecs =
  [ CommandSpec "/help"    "Show this command reference"               GroupSession (exactP "/help"    CmdHelp)
  , CommandSpec "/status"  "Session status (messages, tokens used)"   GroupSession (exactP "/status"  CmdStatus)
  , CommandSpec "/new"     "Clear conversation, keep configuration"   GroupSession (exactP "/new"     CmdNew)
  , CommandSpec "/reset"   "Full reset including usage counters"      GroupSession (exactP "/reset"   CmdReset)
  , CommandSpec "/compact" "Summarise conversation to save context"   GroupSession (exactP "/compact" CmdCompact)
  ]

providerCommandSpecs :: [CommandSpec]
providerCommandSpecs =
  [ CommandSpec "/provider [name]" "List or configure a model provider" GroupProvider (providerArgP ProviderList ProviderConfigure)
  ]

vaultCommandSpecs :: [CommandSpec]
vaultCommandSpecs =
  [ CommandSpec "/vault setup"           "Set up or rekey the encrypted secrets vault" GroupVault (vaultExactP "setup"  VaultSetup)
  , CommandSpec "/vault add <name>"      "Store a named secret (prompts for value)"  GroupVault (vaultArgP   "add"    VaultAdd)
  , CommandSpec "/vault list"            "List all stored secret names"              GroupVault (vaultExactP "list"   VaultList)
  , CommandSpec "/vault delete <name>"   "Delete a named secret"                     GroupVault (vaultArgP   "delete" VaultDelete)
  , CommandSpec "/vault lock"            "Lock the vault"                            GroupVault (vaultExactP "lock"   VaultLock)
  , CommandSpec "/vault unlock"          "Unlock the vault"                          GroupVault (vaultExactP "unlock" VaultUnlock)
  , CommandSpec "/vault status"          "Show vault state and key type"             GroupVault (vaultExactP "status" VaultStatus')
  ]

-- ---------------------------------------------------------------------------
-- Parsing — derived from allCommandSpecs
-- ---------------------------------------------------------------------------

-- | Parse a user message as a slash command.
-- Implemented as 'asum' over '_cs_parse' from 'allCommandSpecs', followed
-- by a catch-all for unrecognised @\/vault@ subcommands.
-- Returns 'Nothing' only for input that does not begin with @\/@.
parseSlashCommand :: Text -> Maybe SlashCommand
parseSlashCommand input =
  let stripped = T.strip input
  in if "/" `T.isPrefixOf` stripped
     then asum (map (`_cs_parse` stripped) allCommandSpecs)
            <|> vaultUnknownFallback stripped
     else Nothing

-- | Exact case-insensitive match.
exactP :: Text -> SlashCommand -> Text -> Maybe SlashCommand
exactP keyword cmd t = if T.toLower t == keyword then Just cmd else Nothing

-- | Case-insensitive match for "/vault <sub>" with no argument.
vaultExactP :: Text -> VaultSubCommand -> Text -> Maybe SlashCommand
vaultExactP sub cmd t =
  if T.toLower t == "/vault " <> sub then Just (CmdVault cmd) else Nothing

-- | Case-insensitive prefix match for "/vault <sub> [arg]".
-- Argument is extracted from the original-case input, preserving its case.
vaultArgP :: Text -> (Text -> VaultSubCommand) -> Text -> Maybe SlashCommand
vaultArgP sub mkCmd t =
  let pfx   = "/vault " <> sub
      lower = T.toLower t
  in if lower == pfx || (pfx <> " ") `T.isPrefixOf` lower
     then Just (CmdVault (mkCmd (T.strip (T.drop (T.length pfx) t))))
     else Nothing

-- | Case-insensitive match for "/provider [name]".
-- With no argument, returns the list command. With an argument, returns
-- the configure command with the argument preserved in original case.
providerArgP :: ProviderSubCommand -> (Text -> ProviderSubCommand) -> Text -> Maybe SlashCommand
providerArgP listCmd mkCfgCmd t =
  let pfx   = "/provider"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdProvider listCmd)
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdProvider listCmd)
                  else Just (CmdProvider (mkCfgCmd arg))
          else Nothing

-- | Catch-all for any "/vault <X>" not matched by 'allCommandSpecs'.
-- Not included in the spec list so it does not appear in '/help'.
vaultUnknownFallback :: Text -> Maybe SlashCommand
vaultUnknownFallback t =
  let lower = T.toLower t
  in if "/vault" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/vault") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdVault (VaultUnknown sub))
     else Nothing

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

-- | Execute a slash command. Returns the (possibly updated) context.
executeSlashCommand :: AgentEnv -> SlashCommand -> Context -> IO Context

executeSlashCommand env CmdHelp ctx = do
  _ch_send (_env_channel env) (OutgoingMessage (renderHelpText allCommandSpecs))
  pure ctx

executeSlashCommand env CmdNew ctx = do
  _ch_send (_env_channel env) (OutgoingMessage "Session cleared. Starting fresh.")
  pure (clearMessages ctx)

executeSlashCommand env CmdReset _ctx = do
  _ch_send (_env_channel env) (OutgoingMessage "Full reset. Context and usage cleared.")
  pure (emptyContext (contextSystemPrompt _ctx))

executeSlashCommand env CmdStatus ctx = do
  let status = T.intercalate "\n"
        [ "Session status:"
        , "  Messages: "          <> T.pack (show (contextMessageCount ctx))
        , "  Est. context tokens: " <> T.pack (show (contextTokenEstimate ctx))
        , "  Total input tokens: "  <> T.pack (show (contextTotalInputTokens ctx))
        , "  Total output tokens: " <> T.pack (show (contextTotalOutputTokens ctx))
        ]
  _ch_send (_env_channel env) (OutgoingMessage status)
  pure ctx

executeSlashCommand env CmdCompact ctx = do
  mProvider <- readIORef (_env_provider env)
  case mProvider of
    Nothing -> do
      _ch_send (_env_channel env) (OutgoingMessage "Cannot compact: no provider configured.")
      pure ctx
    Just provider -> do
      (ctx', result) <- compactContext
        provider
        (_env_model env)
        0
        defaultKeepRecent
        ctx
      let msg = case result of
            NotNeeded         -> "Nothing to compact (too few messages)."
            Compacted o n     -> "Compacted: " <> T.pack (show o)
                              <> " messages \x2192 " <> T.pack (show n)
            CompactionError e -> "Compaction failed: " <> e
      _ch_send (_env_channel env) (OutgoingMessage msg)
      pure ctx'

executeSlashCommand env (CmdProvider sub) ctx = do
  vaultOpt <- readIORef (_env_vault env)
  case vaultOpt of
    Nothing -> do
      _ch_send (_env_channel env) (OutgoingMessage
        "Vault not configured. Run /vault setup first to store provider credentials.")
      pure ctx
    Just vault ->
      executeProviderCommand env vault sub ctx

executeSlashCommand env (CmdVault sub) ctx = do
  vaultOpt <- readIORef (_env_vault env)
  case sub of
    VaultSetup -> do
      executeVaultSetup env ctx
    _ -> case vaultOpt of
      Nothing -> do
        _ch_send (_env_channel env) (OutgoingMessage
          "No vault configured. Run /vault setup to create one.")
        pure ctx
      Just vault ->
        executeVaultCommand env vault sub ctx

-- ---------------------------------------------------------------------------
-- Provider subcommand execution
-- ---------------------------------------------------------------------------

-- | Supported provider names and their descriptions.
supportedProviders :: [(Text, Text)]
supportedProviders =
  [ ("anthropic",  "Anthropic (Claude)")
  , ("openai",     "OpenAI (GPT)")
  , ("openrouter", "OpenRouter (multi-model gateway)")
  , ("ollama",     "Ollama (local models)")
  ]

executeProviderCommand :: AgentEnv -> VaultHandle -> ProviderSubCommand -> Context -> IO Context
executeProviderCommand env _vault ProviderList ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
      listing = T.intercalate "\n" $
        "Available providers:"
        : [ "  " <> name <> " \x2014 " <> desc | (name, desc) <- supportedProviders ]
        ++ ["", "Usage: /provider <name>"]
  send listing
  pure ctx

executeProviderCommand env vault (ProviderConfigure providerName) ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
      lowerName = T.toLower (T.strip providerName)

  case lowerName of
    "anthropic" -> do
      let options = anthropicAuthOptions env vault
          optionLines = map (\o -> "  [" <> T.pack (show (_ao_number o)) <> "] " <> _ao_name o) options
          menu = T.intercalate "\n" ("Configure Anthropic provider. Choose auth method:" : optionLines)
      send menu

      choice <- _ch_prompt ch "Choice: "
      let selectedOption = listToMaybe [o | o <- options, T.pack (show (_ao_number o)) == T.strip choice]

      case selectedOption of
        Just opt -> _ao_handler opt env vault ctx
        Nothing  -> do
          send $ "Invalid choice. Please enter 1 to " <> T.pack (show (length options)) <> "."
          pure ctx

    _ -> do
      send $ "Unknown provider: " <> providerName
      send $ "Supported providers: " <> T.intercalate ", " (map fst supportedProviders)
      pure ctx

-- | Auth method options for a provider.
data AuthOption = AuthOption
  { _ao_number  :: Int
  , _ao_name    :: Text
  , _ao_handler :: AgentEnv -> VaultHandle -> Context -> IO Context
  }

-- | Available Anthropic auth methods.
anthropicAuthOptions :: AgentEnv -> VaultHandle -> [AuthOption]
anthropicAuthOptions env vault =
  [ AuthOption 1 "API Key"
      (\_ _ ctx -> handleAnthropicApiKey env vault ctx)
  , AuthOption 2 "OAuth 2.0"
      (\_ _ ctx -> handleAnthropicOAuth env vault ctx)
  ]

-- | Handle Anthropic API Key authentication.
handleAnthropicApiKey :: AgentEnv -> VaultHandle -> Context -> IO Context
handleAnthropicApiKey env vault ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
  apiKeyText <- _ch_promptSecret ch "Anthropic API key: "
  result <- _vh_put vault "ANTHROPIC_API_KEY" (TE.encodeUtf8 apiKeyText)
  case result of
    Left err -> do
      send ("Error storing API key: " <> T.pack (show err))
      pure ctx
    Right () -> do
      send "Anthropic API key configured successfully."
      pure ctx

-- | Handle Anthropic OAuth authentication.
handleAnthropicOAuth :: AgentEnv -> VaultHandle -> Context -> IO Context
handleAnthropicOAuth env vault ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
  send "Starting OAuth flow... (opens browser)"
  manager <- HTTP.newTlsManager
  oauthTokens <- runOAuthFlow defaultOAuthConfig manager
  result <- _vh_put vault "ANTHROPIC_OAUTH_TOKENS" (serializeTokens oauthTokens)
  case result of
    Left err -> do
      send ("Error storing OAuth tokens: " <> T.pack (show err))
      pure ctx
    Right () -> do
      send "Anthropic OAuth configured successfully."
      send "Tokens cached in vault and will be auto-refreshed."
      pure ctx

-- ---------------------------------------------------------------------------
-- Vault subcommand execution
-- ---------------------------------------------------------------------------

executeVaultCommand :: AgentEnv -> VaultHandle -> VaultSubCommand -> Context -> IO Context
executeVaultCommand env vault sub ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
  case sub of
    VaultSetup ->
      -- VaultSetup is handled before dispatch; should not reach here.
      send "Use /vault setup to set up or rekey the vault."
      >> pure ctx

    VaultAdd name -> do
      valueResult <- try @IOError (_ch_promptSecret ch ("Value for '" <> name <> "': "))
      case valueResult of
        Left e ->
          send ("Error reading secret: " <> T.pack (show e))
        Right value -> do
          result <- _vh_put vault name (TE.encodeUtf8 value)
          case result of
            Left err -> send ("Error storing secret: " <> T.pack (show err))
            Right () -> send ("Secret '" <> name <> "' stored.")
      pure ctx

    VaultList -> do
      result <- _vh_list vault
      case result of
        Left err  -> send ("Error: " <> T.pack (show err))
        Right []  -> send "Vault is empty."
        Right names ->
          send ("Secrets:\n" <> T.unlines (map ("  \x2022 " <>) names))
      pure ctx

    VaultDelete name -> do
      confirm <- _ch_prompt ch ("Delete secret '" <> name <> "'? [y/N]: ")
      if T.strip confirm == "y" || T.strip confirm == "Y"
        then do
          result <- _vh_delete vault name
          case result of
            Left err -> send ("Error: " <> T.pack (show err))
            Right () -> send ("Secret '" <> name <> "' deleted.")
        else send "Cancelled."
      pure ctx

    VaultLock -> do
      _vh_lock vault
      send "Vault locked."
      pure ctx

    VaultUnlock -> do
      result <- _vh_unlock vault
      case result of
        Left err -> send ("Error unlocking vault: " <> T.pack (show err))
        Right () -> send "Vault unlocked."
      pure ctx

    VaultStatus' -> do
      status <- _vh_status vault
      let lockedText = if _vs_locked status then "Locked" else "Unlocked"
          msg = T.intercalate "\n"
            [ "Vault status:"
            , "  State:   " <> lockedText
            , "  Secrets: " <> T.pack (show (_vs_secretCount status))
            , "  Key:     " <> _vs_keyType status
            ]
      send msg
      pure ctx

    VaultUnknown _ ->
      send "Unknown vault command. Type /help to see all available commands."
      >> pure ctx

-- ---------------------------------------------------------------------------
-- Vault setup wizard
-- ---------------------------------------------------------------------------

-- | Interactive vault setup wizard. Detects auth mechanisms, lets the user
-- choose, then creates or rekeys the vault.
executeVaultSetup :: AgentEnv -> Context -> IO Context
executeVaultSetup env ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
      ph   = _env_pluginHandle env

  -- Step 1: Detect available plugins
  plugins <- _ph_detect ph

  -- Step 2: Build choice menu
  let options = buildSetupOptions plugins
      menu    = formatSetupMenu options
  send menu

  -- Step 3: Read user's choice
  choiceText <- _ch_prompt ch "Choice: "
  case parseChoice (length options) (T.strip choiceText) of
    Nothing -> do
      send "Invalid choice. Setup cancelled."
      pure ctx
    Just idx -> do
      let chosen = snd (options !! idx)
      -- Step 4: Create encryptor based on choice
      encResult <- createEncryptorForChoice ch ph chosen
      case encResult of
        Left err -> do
          send err
          pure ctx
        Right (newEnc, keyLabel, mRecipient, mIdentity) -> do
          -- Step 5: Init or rekey
          vaultOpt <- readIORef (_env_vault env)
          case vaultOpt of
            Nothing -> do
              -- No vault handle at all: create from scratch
              setupResult <- firstTimeSetup env newEnc keyLabel
              case setupResult of
                Left err -> send err
                Right () -> do
                  send ("Vault created with " <> keyLabel <> " encryption.")
                  updateConfigAfterSetup mRecipient mIdentity keyLabel
            Just vault -> do
              -- Vault handle exists — but the file may not.
              -- Try init: if it succeeds, this is first-time setup.
              -- If VaultAlreadyExists, we need to rekey.
              initResult <- _vh_init vault
              case initResult of
                Right () -> do
                  -- First-time init succeeded (file didn't exist)
                  send ("Vault created with " <> keyLabel <> " encryption.")
                  updateConfigAfterSetup mRecipient mIdentity keyLabel
                Left VaultAlreadyExists -> do
                  -- Vault exists — rekey it
                  let confirmFn msg = do
                        send msg
                        answer <- _ch_prompt ch "Proceed? [y/N]: "
                        pure (T.strip answer == "y" || T.strip answer == "Y")
                  rekeyResult <- _vh_rekey vault newEnc keyLabel confirmFn
                  case rekeyResult of
                    Left (VaultCorrupted "rekey cancelled by user") ->
                      send "Rekey cancelled."
                    Left err ->
                      send ("Rekey failed: " <> T.pack (show err))
                    Right () -> do
                      send ("Vault rekeyed to " <> keyLabel <> ".")
                      updateConfigAfterSetup mRecipient mIdentity keyLabel
                Left err ->
                  send ("Vault init failed: " <> T.pack (show err))
          pure ctx

-- | A setup option: either passphrase or a detected plugin.
data SetupOption
  = SetupPassphrase
  | SetupPlugin AgePlugin
  deriving stock (Show, Eq)

-- | Build the list of available setup options.
-- Passphrase is always first.
buildSetupOptions :: [AgePlugin] -> [(Text, SetupOption)]
buildSetupOptions plugins =
  ("Passphrase", SetupPassphrase)
    : [(labelFor p, SetupPlugin p) | p <- plugins]
  where
    labelFor p = _ap_label p <> " (" <> _ap_name p <> ")"

-- | Format the setup menu for display.
formatSetupMenu :: [(Text, SetupOption)] -> Text
formatSetupMenu options =
  T.intercalate "\n" $
    "Choose your vault authentication method:"
    : [T.pack (show i) <> ". " <> label | (i, (label, _)) <- zip [(1::Int)..] options]

-- | Parse a numeric choice (1-based) to a 0-based index.
parseChoice :: Int -> Text -> Maybe Int
parseChoice maxN t =
  case reads (T.unpack t) of
    [(n, "")] | n >= 1 && n <= maxN -> Just (n - 1)
    _ -> Nothing

-- | Create an encryptor based on the user's setup choice.
-- Returns (encryptor, key label, maybe recipient, maybe identity path).
createEncryptorForChoice
  :: ChannelHandle
  -> PluginHandle
  -> SetupOption
  -> IO (Either Text (VaultEncryptor, Text, Maybe Text, Maybe Text))
createEncryptorForChoice ch _ph SetupPassphrase = do
  passResult <- try @IOError (_ch_promptSecret ch "Passphrase: ")
  case passResult of
    Left e ->
      pure (Left ("Error reading passphrase: " <> T.pack (show e)))
    Right passphrase -> do
      enc <- mkPassphraseVaultEncryptor (pure (TE.encodeUtf8 passphrase))
      pure (Right (enc, "passphrase", Nothing, Nothing))
createEncryptorForChoice ch _ph (SetupPlugin plugin) = do
  let generateCmd = _ap_binary plugin <> " --generate"
  _ch_send ch (OutgoingMessage (T.intercalate "\n"
    [ "To generate a " <> _ap_label plugin <> " identity, run this in another terminal:"
    , ""
    , "  " <> T.pack generateCmd
    , ""
    , "Then paste the recipient (public key) and identity file path below."
    ]))
  recipient <- T.strip <$> _ch_prompt ch "Recipient (age1...): "
  if T.null recipient
    then pure (Left "No recipient provided. Setup cancelled.")
    else do
      identityPath <- T.strip <$> _ch_prompt ch "Identity file path: "
      if T.null identityPath
        then pure (Left "No identity path provided. Setup cancelled.")
        else do
          ageResult <- mkAgeEncryptor
          case ageResult of
            Left err ->
              pure (Left ("age error: " <> T.pack (show err)))
            Right ageEnc -> do
              let enc = ageVaultEncryptor ageEnc recipient identityPath
              pure (Right (enc, _ap_label plugin, Just recipient, Just identityPath))

-- | First-time vault setup: create directory, open vault, init, write to IORef.
firstTimeSetup :: AgentEnv -> VaultEncryptor -> Text -> IO (Either Text ())
firstTimeSetup env enc keyLabel = do
  pureclawDir <- getPureclawDir
  let vaultDir = pureclawDir </> "vault"
  Dir.createDirectoryIfMissing True vaultDir
  let vaultPath = vaultDir </> "vault.age"
      cfg = VaultConfig
        { _vc_path    = vaultPath
        , _vc_keyType = keyLabel
        , _vc_unlock  = UnlockOnDemand
        }
  vault <- openVault cfg enc
  initResult <- _vh_init vault
  case initResult of
    Left VaultAlreadyExists ->
      pure (Left "A vault file already exists. Use /vault setup to rekey.")
    Left err ->
      pure (Left ("Vault creation failed: " <> T.pack (show err)))
    Right () -> do
      writeIORef (_env_vault env) (Just vault)
      pure (Right ())

-- | Update the config file after a successful setup/rekey.
updateConfigAfterSetup :: Maybe Text -> Maybe Text -> Text -> IO ()
updateConfigAfterSetup mRecipient mIdentity _keyLabel = do
  pureclawDir <- getPureclawDir
  Dir.createDirectoryIfMissing True pureclawDir
  let configPath = pureclawDir </> "config.toml"
      vaultPath  = Just (T.pack (pureclawDir </> "vault" </> "vault.age"))
      unlockMode = Just "on_demand"
  updateVaultConfig configPath vaultPath mRecipient mIdentity unlockMode

-- ---------------------------------------------------------------------------
-- Help rendering — derived from allCommandSpecs
-- ---------------------------------------------------------------------------

-- | Render the full command reference from 'allCommandSpecs'.
renderHelpText :: [CommandSpec] -> Text
renderHelpText specs =
  T.intercalate "\n"
    ("Slash commands:" : concatMap renderGroup [minBound .. maxBound])
  where
    renderGroup g =
      let gs = filter ((== g) . _cs_group) specs
      in if null gs
         then []
         else "" : ("  " <> groupHeading g <> ":") : map renderSpec gs

    renderSpec spec =
      "    " <> padTo 26 (_cs_syntax spec) <> _cs_description spec

    padTo n t = t <> T.replicate (max 1 (n - T.length t)) " "
