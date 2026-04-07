module PureClaw.Agent.SlashCommands
  ( -- * Command data types
    SlashCommand (..)
  , VaultSubCommand (..)
  , ProviderSubCommand (..)
  , ChannelSubCommand (..)
  , TranscriptSubCommand (..)
  , HarnessSubCommand (..)
  , AgentSubCommand (..)
  , SessionSubCommand (..)
    -- * Known harnesses
  , knownHarnesses
    -- * Agent name tab completion helper
  , agentNameMatches
    -- * Session id tab completion helper
  , sessionIdMatches
    -- * Sessions directory helper
  , getSessionsDir
    -- * Command registry — single source of truth
  , CommandGroup (..)
  , CommandSpec (..)
  , allCommandSpecs
    -- * Parsing (derived from allCommandSpecs)
  , parseSlashCommand
    -- * Execution
  , executeSlashCommand
    -- * Discovery
  , discoverHarnesses
  , discoverHarnessesIn
  ) where

import Control.Applicative ((<|>))
import Control.Exception
import Control.Monad
import Data.Foldable (asum)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.List qualified as L
import Data.Maybe qualified
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Network.HTTP.Client.TLS qualified as HTTP
import System.Directory qualified as Dir
import System.FilePath ((</>))

import Data.ByteString.Lazy qualified as BL
import System.Exit
import System.IO (Handle, hGetLine)
import System.Process.Typed qualified as P

import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.Agent.Compaction
import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Auth.AnthropicOAuth
import PureClaw.CLI.Config
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript
import PureClaw.Harness.ClaudeCode
import PureClaw.Harness.Tmux
import Data.Text.Read qualified as TR
import PureClaw.Providers.Class
import PureClaw.Providers.Ollama
import PureClaw.Security.Policy
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age
import PureClaw.Security.Vault.Passphrase
import PureClaw.Security.Vault.Plugin
import PureClaw.Transcript.Types

import Data.Time.Clock qualified as Time
import PureClaw.Session.Handle qualified as Session
import PureClaw.Session.Types qualified as SessionTypes

-- ---------------------------------------------------------------------------
-- Command taxonomy
-- ---------------------------------------------------------------------------

-- | Organisational group for display in '/help'.
data CommandGroup
  = GroupSession     -- ^ Session and context management
  | GroupProvider    -- ^ Model provider configuration
  | GroupChannel     -- ^ Chat channel configuration
  | GroupVault       -- ^ Encrypted secrets vault
  | GroupTranscript  -- ^ Transcript / permanent log
  | GroupHarness    -- ^ Harness management (tmux-based AI CLI tools)
  | GroupAgent      -- ^ Agent management (bootstrap file collections)
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | Human-readable section heading for '/help' output.
groupHeading :: CommandGroup -> Text
groupHeading GroupSession  = "Session"
groupHeading GroupProvider = "Provider"
groupHeading GroupChannel  = "Channel"
groupHeading GroupVault      = "Vault"
groupHeading GroupTranscript = "Transcript"
groupHeading GroupHarness    = "Harness"
groupHeading GroupAgent      = "Agent"

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

-- | Subcommands of the '/channel' family.
data ChannelSubCommand
  = ChannelList               -- ^ Show current channel + available options
  | ChannelSetup Text         -- ^ Interactive setup for a specific channel
  | ChannelUnknown Text       -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/transcript' family.
data TranscriptSubCommand
  = TranscriptRecent (Maybe Int)  -- ^ Show last N entries (default 20)
  | TranscriptSearch Text         -- ^ Filter by source name
  | TranscriptPath                -- ^ Show log file path
  | TranscriptUnknown Text        -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/harness' family.
data HarnessSubCommand
  = HarnessStart Text (Maybe Text) Bool -- ^ Start a named harness, optional working directory, unsafe mode
  | HarnessStop Text           -- ^ Stop a named harness
  | HarnessList                -- ^ List running harnesses
  | HarnessAttach              -- ^ Show tmux attach command
  | HarnessUnknown Text        -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/session' family.
data SessionSubCommand
  = SessionNew                         -- ^ Create a new session (clear ctx + write on disk)
  | SessionList (Maybe Text)           -- ^ List recent sessions (optionally filter by agent)
  | SessionResume Text                 -- ^ Resume a session by id or prefix
  | SessionLast                        -- ^ Resume the most recent session
  | SessionInfo                        -- ^ Show info for the current session
  | SessionReset                       -- ^ Full reset (alias for CmdReset behaviour)
  | SessionCompact                     -- ^ Compact the current session (alias for CmdCompact)
  | SessionUnknown Text                -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/agent' family.
data AgentSubCommand
  = AgentList                  -- ^ List discovered agents
  | AgentInfo (Maybe Text)     -- ^ Show info for a named agent (or the current one when 'Nothing')
  | AgentStart Text            -- ^ Switch to a named agent (placeholder in WU1)
  | AgentUnknown Text          -- ^ Unrecognised subcommand
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
  | CmdTarget (Maybe Text)            -- ^ Show or switch message target
  | CmdTargetList                    -- ^ List available targets (models + harnesses)
  | CmdProvider ProviderSubCommand  -- ^ Provider configuration command family
  | CmdVault VaultSubCommand        -- ^ Vault command family
  | CmdChannel ChannelSubCommand       -- ^ Channel configuration
  | CmdTranscript TranscriptSubCommand -- ^ Transcript query commands
  | CmdHarness HarnessSubCommand      -- ^ Harness management commands
  | CmdAgent AgentSubCommand          -- ^ Agent management commands
  | CmdSession SessionSubCommand      -- ^ Session management commands
  | CmdMsg Text Text                  -- ^ Send a message to a specific target (name, message)
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
allCommandSpecs = sessionCommandSpecs ++ sessionFamilyCommandSpecs ++ providerCommandSpecs ++ channelCommandSpecs ++ vaultCommandSpecs ++ transcriptCommandSpecs ++ harnessCommandSpecs ++ agentCommandSpecs ++ msgCommandSpecs

sessionCommandSpecs :: [CommandSpec]
sessionCommandSpecs =
  [ CommandSpec "/help"    "Show this command reference"               GroupSession (exactP "/help"    CmdHelp)
  , CommandSpec "/status"  "Session status (messages, tokens used)"   GroupSession (exactP "/status"  CmdStatus)
  , CommandSpec "/new"     "Clear conversation, keep configuration"   GroupSession (exactP "/new"     CmdNew)
  , CommandSpec "/reset"   "Full reset including usage counters"      GroupSession (exactP "/reset"   CmdReset)
  , CommandSpec "/compact" "Summarise conversation to save context"   GroupSession (exactP "/compact" CmdCompact)
  , CommandSpec "/last"    "Resume the most recent session"           GroupSession (exactP "/last"    (CmdSession SessionLast))
  ]

-- | The '/session' command family. Subcommands manage the on-disk session
-- lifecycle (create, list, resume, info, reset, compact).
sessionFamilyCommandSpecs :: [CommandSpec]
sessionFamilyCommandSpecs =
  [ CommandSpec "/session new"              "Create a new session (clears context)"          GroupSession (sessionExactP "new"     SessionNew)
  , CommandSpec "/session list [<agent>]"   "List recent sessions (optionally by agent)"     GroupSession sessionListP
  , CommandSpec "/session resume <id>"      "Resume a session by id or unambiguous prefix"   GroupSession sessionResumeP
  , CommandSpec "/session last"             "Resume the most recent session"                 GroupSession (sessionExactP "last"    SessionLast)
  , CommandSpec "/session info"             "Show current session info"                      GroupSession (sessionExactP "info"    SessionInfo)
  , CommandSpec "/session reset"            "Full reset of current session"                  GroupSession (sessionExactP "reset"   SessionReset)
  , CommandSpec "/session compact"          "Compact current session"                        GroupSession (sessionExactP "compact" SessionCompact)
  ]

-- | Case-insensitive exact match for "/session <sub>" with no argument.
sessionExactP :: Text -> SessionSubCommand -> Text -> Maybe SlashCommand
sessionExactP sub cmd t =
  if T.toLower t == "/session " <> sub then Just (CmdSession cmd) else Nothing

-- | Parse "/session list [<agent>]". With no argument yields @SessionList Nothing@.
sessionListP :: Text -> Maybe SlashCommand
sessionListP t =
  let pfx   = "/session list"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdSession (SessionList Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdSession (SessionList Nothing))
                  else Just (CmdSession (SessionList (Just arg)))
          else Nothing

-- | Parse "/session resume <id>". The argument is required.
sessionResumeP :: Text -> Maybe SlashCommand
sessionResumeP t =
  let pfx   = "/session resume"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let arg = T.strip (T.drop (T.length pfx) t)
          in if T.null arg
             then Nothing
             else Just (CmdSession (SessionResume arg))
     else Nothing

-- | Catch-all for any "/session <X>" not matched by 'allCommandSpecs'.
sessionUnknownFallback :: Text -> Maybe SlashCommand
sessionUnknownFallback t =
  let lower = T.toLower t
  in if "/session" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/session") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdSession (SessionUnknown sub))
     else Nothing

providerCommandSpecs :: [CommandSpec]
providerCommandSpecs =
  [ CommandSpec "/provider [name]" "List or configure a model provider" GroupProvider (providerArgP ProviderList ProviderConfigure)
  , CommandSpec "/target list"      "List available targets (models + harnesses)" GroupProvider (exactP "/target list" CmdTargetList)
  , CommandSpec "/target [name]"   "Show or switch the message target"           GroupProvider targetArgP
  ]

channelCommandSpecs :: [CommandSpec]
channelCommandSpecs =
  [ CommandSpec "/channel"              "Show current channel and available options" GroupChannel (channelArgP ChannelList ChannelSetup)
  , CommandSpec "/channel signal"       "Set up Signal messenger integration"       GroupChannel (channelExactP "signal" (ChannelSetup "signal"))
  , CommandSpec "/channel telegram"     "Set up Telegram bot integration"           GroupChannel (channelExactP "telegram" (ChannelSetup "telegram"))
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

transcriptCommandSpecs :: [CommandSpec]
transcriptCommandSpecs =
  [ CommandSpec "/transcript [N]"              "Show last N entries (default 20)"  GroupTranscript transcriptRecentP
  , CommandSpec "/transcript search <source>"  "Filter by source name"             GroupTranscript (transcriptArgP "search" TranscriptSearch)
  , CommandSpec "/transcript path"             "Show the JSONL file path"          GroupTranscript (transcriptExactP "path" TranscriptPath)
  ]

harnessCommandSpecs :: [CommandSpec]
harnessCommandSpecs =
  [ CommandSpec "/harness start <name> [dir] [--unsafe]"  "Start a harness (--unsafe skips permission checks)"   GroupHarness harnessStartP
  , CommandSpec "/harness stop <name>"   "Stop a running harness"               GroupHarness (harnessArgP "stop" HarnessStop)
  , CommandSpec "/harness list"          "List running harnesses"               GroupHarness (harnessExactP "list" HarnessList)
  , CommandSpec "/harness attach"        "Show tmux attach command"             GroupHarness (harnessExactP "attach" HarnessAttach)
  ]

agentCommandSpecs :: [CommandSpec]
agentCommandSpecs =
  [ CommandSpec "/agent list"          "List discovered agents in ~/.pureclaw/agents/" GroupAgent (agentExactP "list" AgentList)
  , CommandSpec "/agent info [<name>]" "Show files and frontmatter for an agent"       GroupAgent agentInfoP
  , CommandSpec "/agent start <name>"  "Switch to a named agent"                       GroupAgent agentStartP
  ]

-- | Case-insensitive exact match for "/agent <sub>" with no argument.
agentExactP :: Text -> AgentSubCommand -> Text -> Maybe SlashCommand
agentExactP sub cmd t =
  if T.toLower t == "/agent " <> sub then Just (CmdAgent cmd) else Nothing

-- | Parse "/agent info [<name>]". With no argument, yields @AgentInfo Nothing@.
agentInfoP :: Text -> Maybe SlashCommand
agentInfoP t =
  let pfx   = "/agent info"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdAgent (AgentInfo Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdAgent (AgentInfo Nothing))
                  else Just (CmdAgent (AgentInfo (Just arg)))
          else Nothing

-- | Parse "/agent start <name>". The name is required; a bare "/agent start"
-- falls through to the unknown fallback ("start").
agentStartP :: Text -> Maybe SlashCommand
agentStartP t =
  let pfx   = "/agent start"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let arg = T.strip (T.drop (T.length pfx) t)
          in if T.null arg
             then Nothing
             else Just (CmdAgent (AgentStart arg))
     else Nothing

-- | Catch-all for any "/agent <X>" not matched by 'allCommandSpecs'.
agentUnknownFallback :: Text -> Maybe SlashCommand
agentUnknownFallback t =
  let lower = T.toLower t
  in if "/agent" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/agent") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdAgent (AgentUnknown sub))
     else Nothing

msgCommandSpecs :: [CommandSpec]
msgCommandSpecs =
  [ CommandSpec "/msg <target> <message>" "Send a message to a specific harness/model" GroupHarness msgArgP
  ]

-- | Parse "/msg <target> <message>". The first word after /msg is the target,
-- the rest is the message body. Both are required.
msgArgP :: Text -> Maybe SlashCommand
msgArgP t =
  let pfx   = "/msg"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length pfx) t)
              (target, body) = T.break (== ' ') rest
          in if T.null target || T.null (T.strip body)
             then Nothing
             else Just (CmdMsg target (T.strip body))
     else Nothing

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
            <|> channelUnknownFallback stripped
            <|> vaultUnknownFallback stripped
            <|> transcriptUnknownFallback stripped
            <|> harnessUnknownFallback stripped
            <|> agentUnknownFallback stripped
            <|> sessionUnknownFallback stripped
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

-- | Case-insensitive match for "/target" with optional argument.
targetArgP :: Text -> Maybe SlashCommand
targetArgP t =
  let pfx   = "/target"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdTarget Nothing)
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in Just (CmdTarget (if T.null arg then Nothing else Just arg))
          else Nothing

-- | Case-insensitive match for "/channel" with optional argument.
channelArgP :: ChannelSubCommand -> (Text -> ChannelSubCommand) -> Text -> Maybe SlashCommand
channelArgP listCmd mkSetupCmd t =
  let pfx   = "/channel"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdChannel listCmd)
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdChannel listCmd)
                  else Just (CmdChannel (mkSetupCmd (T.toLower arg)))
          else Nothing

-- | Case-insensitive exact match for "/channel <sub>".
channelExactP :: Text -> ChannelSubCommand -> Text -> Maybe SlashCommand
channelExactP sub cmd t =
  if T.toLower t == "/channel " <> sub then Just (CmdChannel cmd) else Nothing

-- | Catch-all for any "/channel <X>" not matched by 'allCommandSpecs'.
channelUnknownFallback :: Text -> Maybe SlashCommand
channelUnknownFallback t =
  let lower = T.toLower t
  in if "/channel" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/channel") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdChannel (ChannelUnknown sub))
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

-- | Parse "/transcript" with optional numeric argument.
-- "/transcript" -> TranscriptRecent Nothing
-- "/transcript 50" -> TranscriptRecent (Just 50)
transcriptRecentP :: Text -> Maybe SlashCommand
transcriptRecentP t =
  let pfx   = "/transcript"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdTranscript (TranscriptRecent Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdTranscript (TranscriptRecent Nothing))
                  else case reads (T.unpack arg) of
                    [(n, "")] -> Just (CmdTranscript (TranscriptRecent (Just n)))
                    _         -> Nothing
          else Nothing

-- | Case-insensitive exact match for "/transcript <sub>".
transcriptExactP :: Text -> TranscriptSubCommand -> Text -> Maybe SlashCommand
transcriptExactP sub cmd t =
  if T.toLower t == "/transcript " <> sub then Just (CmdTranscript cmd) else Nothing

-- | Case-insensitive prefix match for "/transcript <sub> <arg>".
transcriptArgP :: Text -> (Text -> TranscriptSubCommand) -> Text -> Maybe SlashCommand
transcriptArgP sub mkCmd t =
  let pfx   = "/transcript " <> sub
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let arg = T.strip (T.drop (T.length pfx) t)
          in if T.null arg
             then Nothing
             else Just (CmdTranscript (mkCmd arg))
     else Nothing

-- | Catch-all for any "/transcript <X>" not matched by 'allCommandSpecs'.
transcriptUnknownFallback :: Text -> Maybe SlashCommand
transcriptUnknownFallback t =
  let lower = T.toLower t
  in if "/transcript" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/transcript") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdTranscript (TranscriptUnknown sub))
     else Nothing

-- | Case-insensitive exact match for "/harness <sub>".
harnessExactP :: Text -> HarnessSubCommand -> Text -> Maybe SlashCommand
harnessExactP sub cmd t =
  if T.toLower t == "/harness " <> sub then Just (CmdHarness cmd) else Nothing

-- | Parse "/harness start <name> [dir] [--unsafe]".
-- The first word after "start" is the harness name. Remaining words are
-- split into an optional directory (any non-flag token) and the
-- @--unsafe@ flag.
harnessStartP :: Text -> Maybe SlashCommand
harnessStartP t =
  let pfx   = "/harness start"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let rest  = T.strip (T.drop (T.length pfx) t)
              (name, afterName) = T.break (== ' ') rest
          in if T.null name
             then Nothing
             else let tokens = T.words (T.strip afterName)
                      skipPerms = "--unsafe" `elem` map T.toLower tokens
                      positional = filter (\tok -> T.toLower tok /= "--unsafe") tokens
                      dir = case positional of
                              (d : _) -> Just d
                              []      -> Nothing
                  in Just (CmdHarness (HarnessStart name dir skipPerms))
     else Nothing

-- | Case-insensitive prefix match for "/harness <sub> <arg>".
harnessArgP :: Text -> (Text -> HarnessSubCommand) -> Text -> Maybe SlashCommand
harnessArgP sub mkCmd t =
  let pfx   = "/harness " <> sub
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let arg = T.strip (T.drop (T.length pfx) t)
          in if T.null arg
             then Nothing
             else Just (CmdHarness (mkCmd arg))
     else Nothing

-- | Catch-all for any "/harness <X>" not matched by 'allCommandSpecs'.
harnessUnknownFallback :: Text -> Maybe SlashCommand
harnessUnknownFallback t =
  let lower = T.toLower t
  in if "/harness" `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/harness") lower)
              sub  = fst (T.break (== ' ') rest)
          in Just (CmdHarness (HarnessUnknown sub))
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
  model <- readIORef (_env_model env)
  target <- readIORef (_env_target env)
  mProvider <- readIORef (_env_provider env)
  mVault <- readIORef (_env_vault env)
  mTranscript <- readIORef (_env_transcript env)
  harnesses <- readIORef (_env_harnesses env)
  let targetLine = case target of
        TargetProvider    -> "  Target:    model: " <> unModelId model
        TargetHarness name -> "  Target:    harness: " <> name
      providerLine = case mProvider of
        Nothing -> "  Provider:  (not configured)"
        Just _  -> "  Provider:  configured"
      vaultLine = case mVault of
        Nothing -> "  Vault:     (not configured)"
        Just _  -> "  Vault:     configured"
      transcriptLine = case mTranscript of
        Nothing -> "  Transcript: disabled"
        Just _  -> "  Transcript: enabled"
      harnessLine = if Map.null harnesses
        then "  Harnesses: (none)"
        else "  Harnesses: " <> T.intercalate ", "
               [n <> " (" <> _hh_name h <> ")" | (n, h) <- Map.toList harnesses]
      policyLine = "  Policy:    " <> T.pack (show (_sp_autonomy (_env_policy env)))
      status = T.intercalate "\n"
        [ "Session status:"
        , targetLine
        , providerLine
        , policyLine
        , vaultLine
        , transcriptLine
        , harnessLine
        , ""
        , "  Messages:            " <> T.pack (show (contextMessageCount ctx))
        , "  Est. context tokens: " <> T.pack (show (contextTokenEstimate ctx))
        , "  Total input tokens:  " <> T.pack (show (contextTotalInputTokens ctx))
        , "  Total output tokens: " <> T.pack (show (contextTotalOutputTokens ctx))
        ]
  _ch_send (_env_channel env) (OutgoingMessage status)
  pure ctx

executeSlashCommand env (CmdTarget Nothing) ctx = do
  target <- readIORef (_env_target env)
  model  <- readIORef (_env_model env)
  let desc = case target of
        TargetProvider    -> "model: " <> unModelId model
        TargetHarness name -> "harness: " <> name
  _ch_send (_env_channel env) (OutgoingMessage ("Current target: " <> desc))
  pure ctx

executeSlashCommand env (CmdTarget (Just name)) ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  harnesses <- readIORef (_env_harnesses env)
  if Map.member name harnesses
    then do
      writeIORef (_env_target env) (TargetHarness name)
      send $ "Target switched to harness: " <> name
    else do
      writeIORef (_env_target env) TargetProvider
      writeIORef (_env_model env) (ModelId name)
      -- Persist to config.toml
      pureclawDir <- getPureclawDir
      let configPath = pureclawDir </> "config.toml"
      existing <- loadFileConfig configPath
      Dir.createDirectoryIfMissing True pureclawDir
      writeFileConfig configPath (existing { _fc_model = Just name })
      send $ "Target switched to model: " <> name
  pure ctx

executeSlashCommand env CmdTargetList ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  -- List running harnesses
  harnesses <- readIORef (_env_harnesses env)
  let harnessLines = if Map.null harnesses
        then ["  (none running)"]
        else map ("  " <>) (Map.keys harnesses)
  -- List models from provider
  mProvider <- readIORef (_env_provider env)
  modelLines <- case mProvider of
    Nothing -> pure ["  (no provider configured)"]
    Just provider -> do
      models <- listModels provider
      pure $ if null models
        then ["  (none available)"]
        else map (\m -> "  " <> unModelId m) models
  send $ T.intercalate "\n" $
    ["Harnesses:"] ++ harnessLines ++ ["", "Models:"] ++ modelLines
  pure ctx

executeSlashCommand env CmdCompact ctx = do
  mProvider <- readIORef (_env_provider env)
  case mProvider of
    Nothing -> do
      _ch_send (_env_channel env) (OutgoingMessage "Cannot compact: no provider configured.")
      pure ctx
    Just provider -> do
      model <- readIORef (_env_model env)
      (ctx', result) <- compactContext
        provider
        model
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

executeSlashCommand env (CmdChannel sub) ctx = do
  executeChannelCommand env sub ctx

executeSlashCommand env (CmdTranscript sub) ctx = do
  executeTranscriptCommand env sub ctx

executeSlashCommand env (CmdMsg target body) ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  harnesses <- readIORef (_env_harnesses env)
  case Map.lookup target harnesses of
    Nothing -> do
      send ("No running harness named '" <> target
        <> "'. Use /harness list to see running harnesses.")
      pure ctx
    Just hh -> do
      _lh_logInfo (_env_logger env) $ "Msg to harness: " <> target
      _hh_send hh (TE.encodeUtf8 body)
      output <- _hh_receive hh
      let response = sanitizeHarnessOutput (TE.decodeUtf8 output)
      unless (T.null (T.strip response)) $
        send (prefixHarnessOutput target response)
      pure ctx

executeSlashCommand env (CmdHarness sub) ctx = do
  executeHarnessCommand env sub ctx

executeSlashCommand env (CmdAgent sub) ctx = do
  executeAgentCommand env sub ctx

executeSlashCommand env (CmdSession sub) ctx = do
  executeSessionCommand env sub ctx

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
  mProvider <- readIORef (_env_provider env)
  model <- readIORef (_env_model env)
  let activeIndicator = case mProvider of
        Nothing -> "(not configured)"
        Just _  -> "active, model: " <> unModelId model
      listing = T.intercalate "\n" $
        [ "Provider: " <> activeIndicator
        , ""
        , "Available providers:"
        ]
        ++ [ "  " <> name <> " \x2014 " <> desc | (name, desc) <- supportedProviders ]
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
      let selectedOption = Data.Maybe.listToMaybe [o | o <- options, T.pack (show (_ao_number o)) == T.strip choice]

      case selectedOption of
        Just opt -> _ao_handler opt env vault ctx
        Nothing  -> do
          send $ "Invalid choice. Please enter 1 to " <> T.pack (show (length options)) <> "."
          pure ctx

    "ollama" -> handleOllamaConfigure env vault ctx

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

-- | Handle Ollama provider configuration.
-- Prompts for base URL (default: http://localhost:11434) and model name.
-- Stores provider, model, and base_url in config.toml (not the vault,
-- since none of these are sensitive credentials).
handleOllamaConfigure :: AgentEnv -> VaultHandle -> Context -> IO Context
handleOllamaConfigure env _vault ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
  urlInput <- _ch_prompt ch "Ollama base URL (default: http://localhost:11434): "
  let baseUrl = let stripped = T.strip urlInput
                in if T.null stripped then "http://localhost:11434" else stripped
  modelName <- _ch_prompt ch "Model name (e.g. llama3, mistral): "
  let model = T.strip modelName
  if T.null model
    then do
      send "Model name is required."
      pure ctx
    else do
      pureclawDir <- getPureclawDir
      let configPath = pureclawDir </> "config.toml"
      existing <- loadFileConfig configPath
      let updated = existing
            { _fc_provider = Just "ollama"
            , _fc_model    = Just model
            , _fc_baseUrl  = if baseUrl == "http://localhost:11434"
                             then Nothing  -- don't store the default
                             else Just baseUrl
            }
      Dir.createDirectoryIfMissing True pureclawDir
      writeFileConfig configPath updated
      -- Hot-swap provider and model in the running session
      manager <- HTTP.newTlsManager
      let ollamaProvider = if baseUrl == "http://localhost:11434"
            then mkOllamaProvider manager
            else mkOllamaProviderWithUrl manager (T.unpack baseUrl)
      writeIORef (_env_provider env) (Just (MkProvider ollamaProvider))
      writeIORef (_env_model env) (ModelId model)
      send $ "Ollama configured successfully. Model: " <> model <> ", URL: " <> baseUrl
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

    VaultUnknown unknownSub
      | T.null unknownSub -> do
          -- Bare /vault: show status + available subcommands
          mVault <- readIORef (_env_vault env)
          let vaultStatus = case mVault of
                Nothing -> "Vault: not configured"
                Just _  -> "Vault: configured"
              subcommands = T.intercalate "\n"
                [ vaultStatus
                , ""
                , "Available commands:"
                , "  /vault setup        — Set up or rekey the vault"
                , "  /vault add <name>   — Store a named secret"
                , "  /vault list         — List stored secret names"
                , "  /vault delete <name> — Delete a secret"
                , "  /vault lock         — Lock the vault"
                , "  /vault unlock       — Unlock the vault"
                , "  /vault status       — Show vault state and key type"
                ]
          send subcommands
          pure ctx
      | otherwise ->
          send ("Unknown vault command: " <> unknownSub <> ". Type /vault to see available commands.")
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
  pureclawDir <- getPureclawDir
  let vaultDir      = pureclawDir </> "vault"
      identityFile  = vaultDir </> T.unpack (_ap_name plugin) <> "-identity.txt"
      identityFileT = T.pack identityFile
      cmd = T.pack (_ap_binary plugin) <> " --generate --pin-policy never --touch-policy never > " <> identityFileT
  Dir.createDirectoryIfMissing True vaultDir
  _ch_send ch (OutgoingMessage (T.intercalate "\n"
    [ "Run this in another terminal to generate a " <> _ap_label plugin <> " identity:"
    , ""
    , "  " <> cmd
    , ""
    , "The plugin will prompt you for a PIN and touch confirmation."
    , "Press Enter here when done (or 'q' to cancel)."
    ]))
  answer <- T.strip <$> _ch_prompt ch ""
  if answer == "q" || answer == "Q"
    then pure (Left "Setup cancelled.")
    else do
      exists <- Dir.doesFileExist identityFile
      if not exists
        then pure (Left ("Identity file not found: " <> identityFileT))
        else do
          contents <- TIO.readFile identityFile
          let outputLines = T.lines contents
              -- age-plugin-yubikey uses "#    Recipient: age1..."
              -- other plugins may use "# public key: age1..."
              findRecipient = L.find (\l ->
                let stripped = T.strip (T.dropWhile (== '#') (T.strip l))
                in T.isPrefixOf "Recipient:" stripped
                   || T.isPrefixOf "public key:" stripped) outputLines
          case findRecipient of
            Nothing ->
              pure (Left "No recipient found in identity file. Expected a '# Recipient: age1...' line.")
            Just rLine -> do
              -- Extract value after the label (Recipient: or public key:)
              let afterHash = T.strip (T.dropWhile (== '#') (T.strip rLine))
                  recipient = T.strip (T.drop 1 (T.dropWhile (/= ':') afterHash))
              ageResult <- mkAgeEncryptor
              case ageResult of
                Left err ->
                  pure (Left ("age error: " <> T.pack (show err)))
                Right ageEnc -> do
                  let enc = ageVaultEncryptor ageEnc recipient identityFileT
                  pure (Right (enc, _ap_label plugin, Just recipient, Just identityFileT))

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
  let configPath   = pureclawDir </> "config.toml"
      vaultPath    = Set (T.pack (pureclawDir </> "vault" </> "vault.age"))
      unlockMode   = Set "on_demand"
      recipientUpd = maybe Clear Set mRecipient
      identityUpd  = maybe Clear Set mIdentity
  updateVaultConfig configPath vaultPath recipientUpd identityUpd unlockMode

-- ---------------------------------------------------------------------------
-- Channel subcommand execution
-- ---------------------------------------------------------------------------

executeChannelCommand :: AgentEnv -> ChannelSubCommand -> Context -> IO Context
executeChannelCommand env ChannelList ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  -- Read current config to show status
  fileCfg <- loadConfig
  let currentChannel = maybe "cli" T.unpack (_fc_defaultChannel fileCfg)
      signalConfigured = case _fc_signal fileCfg of
        Just sig -> case _fsc_account sig of
          Just acct -> " (account: " <> acct <> ")"
          Nothing   -> " (not configured)"
        Nothing -> " (not configured)"
  send $ T.intercalate "\n"
    [ "Chat channels:"
    , ""
    , "  cli       \x2014 Terminal stdin/stdout" <> if currentChannel == "cli" then " [active]" else ""
    , "  signal    \x2014 Signal messenger" <> signalConfigured <> if currentChannel == "signal" then " [active]" else ""
    , "  telegram  \x2014 Telegram bot (coming soon)"
    , ""
    , "Set up a channel:  /channel signal"
    , "Switch channel:    Set default_channel in config, then restart"
    ]
  pure ctx

executeChannelCommand env (ChannelSetup channelName) ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  case channelName of
    "signal"   -> executeSignalSetup env ctx
    "telegram" -> do
      send "Telegram setup is not yet implemented. Coming soon!"
      pure ctx
    other -> do
      send $ "Unknown channel: " <> other <> ". Available: signal, telegram"
      pure ctx

executeChannelCommand env (ChannelUnknown sub) ctx = do
  _ch_send (_env_channel env) (OutgoingMessage
    ("Unknown channel command: " <> sub <> ". Type /channel for available options."))
  pure ctx

-- ---------------------------------------------------------------------------
-- Transcript subcommand execution
-- ---------------------------------------------------------------------------

executeTranscriptCommand :: AgentEnv -> TranscriptSubCommand -> Context -> IO Context
executeTranscriptCommand env sub ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  mTh <- readIORef (_env_transcript env)
  case mTh of
    Nothing -> do
      send "No transcript configured. Start with --transcript to enable logging."
      pure ctx
    Just th -> case sub of
      TranscriptRecent mN -> do
        let n = Data.Maybe.fromMaybe 20 mN
            tf = emptyFilter { _tf_limit = Just n }
        entries <- _th_query th tf
        if null entries
          then send "No entries found."
          else send (T.intercalate "\n" (map formatEntry entries))
        pure ctx

      TranscriptSearch query -> do
        -- Search matches either harness or model name
        allEntries <- _th_query th emptyFilter
        let matches e = _te_harness e == Just query || _te_model e == Just query
            entries = filter matches allEntries
        if null entries
          then send ("No entries found matching: " <> query)
          else send (T.intercalate "\n" (map formatEntry entries))
        pure ctx

      TranscriptPath -> do
        path <- _th_getPath th
        send (T.pack path)
        pure ctx

      TranscriptUnknown subcmd -> do
        send ("Unknown transcript command: " <> subcmd <> ". Try /help for available commands.")
        pure ctx

-- | Format a transcript entry as a one-line summary.
-- Example: "[2026-04-04T15:30:00Z] ollama/llama3 Request (42ms)"
formatEntry :: TranscriptEntry -> Text
formatEntry entry =
  let ts   = T.pack (show (_te_timestamp entry))
      endpoint = case (_te_harness entry, _te_model entry) of
        (Just h, Just m)  -> h <> "/" <> m
        (Just h, Nothing) -> h
        (Nothing, Just m) -> m
        (Nothing, Nothing) -> "unknown"
      dir  = T.pack (show (_te_direction entry))
      dur  = case _te_durationMs entry of
               Just ms -> " (" <> T.pack (show ms) <> "ms)"
               Nothing -> ""
  in "[" <> ts <> "] " <> endpoint <> " " <> dir <> dur

-- ---------------------------------------------------------------------------
-- Harness commands
-- ---------------------------------------------------------------------------

executeHarnessCommand :: AgentEnv -> HarnessSubCommand -> Context -> IO Context
executeHarnessCommand env sub ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  case sub of
    HarnessStart name mDir skipPerms -> do
      mTh <- readIORef (_env_transcript env)
      let th = Data.Maybe.fromMaybe mkNoOpTranscriptHandle mTh
          logger = _env_logger env
      -- Log diagnostic info before attempting start
      let logInfo = _lh_logInfo logger
          logError = _lh_logError logger
      mTmuxPath <- findTmux
      logInfo $ "Harness start: tmux path = " <> T.pack (show mTmuxPath)
      mClaudePath <- Dir.findExecutable "claude"
      logInfo $ "Harness start: claude path = " <> T.pack (show mClaudePath)
      logInfo $ "Harness start: policy autonomy = " <> T.pack (show (_sp_autonomy (_env_policy env)))
      -- Resolve optional working directory
      resolvedDir <- resolveHarnessDir mDir
      -- Assign a window index and build the unique harness key
      windowIdx <- readIORef (_env_nextWindowIdx env)
      let canonical = Data.Maybe.fromMaybe name (resolveHarnessName name)
          harnessKey = canonical <> "-" <> T.pack (show windowIdx)
      result <- startHarnessByName (_env_policy env) th windowIdx name resolvedDir skipPerms
      case result of
        Left err -> do
          let detail = case err of
                HarnessTmuxNotAvailable tmuxDetail ->
                  tmuxDetail <> "\n  tmux path resolved: " <> T.pack (show mTmuxPath)
                HarnessBinaryNotFound bin ->
                  "binary '" <> bin <> "' not found on PATH"
                    <> "\n  claude path resolved: " <> T.pack (show mClaudePath)
                HarnessNotAuthorized cmdErr ->
                  "command not authorized: " <> T.pack (show cmdErr)
                    <> "\n  policy autonomy: " <> T.pack (show (_sp_autonomy (_env_policy env)))
          send ("Failed to start harness '" <> name <> "':\n  " <> detail)
          logError $ "Harness start failed: " <> T.pack (show err)
          pure ctx
        Right hh -> do
          -- Label the tmux window so discovery can reconstruct on restart
          renameWindow "pureclaw" windowIdx harnessKey
          modifyIORef' (_env_nextWindowIdx env) (+ 1)
          modifyIORef' (_env_harnesses env) (Map.insert harnessKey hh)
          send ("Harness '" <> harnessKey <> "' started (window " <> T.pack (show windowIdx) <> "). Attach with: tmux attach -t pureclaw")
          pure ctx

    HarnessStop name -> do
      harnesses <- readIORef (_env_harnesses env)
      case Map.lookup name harnesses of
        Nothing -> do
          send ("No running harness named '" <> name <> "'.")
          pure ctx
        Just hh -> do
          _hh_stop hh
          modifyIORef' (_env_harnesses env) (Map.delete name)
          send ("Harness '" <> name <> "' stopped.")
          pure ctx

    HarnessList -> do
      harnesses <- readIORef (_env_harnesses env)
      let running = if Map.null harnesses
            then ["  (none)"]
            else map (\(n, hh) -> "  " <> n <> " (" <> _hh_name hh <> ")")
                     (Map.toList harnesses)
          available = map (\(n, aliases, desc) ->
                "  " <> n <> " (aliases: " <> T.intercalate ", " aliases <> ") — " <> desc)
                knownHarnesses
      send (T.intercalate "\n" $
        ["Running:"] <> running <> ["", "Available:"] <> available)
      pure ctx

    HarnessAttach -> do
      send "tmux attach -t pureclaw"
      pure ctx

    HarnessUnknown subcmd
      | T.null subcmd -> do
          -- Bare /harness: show status + available subcommands
          harnesses <- readIORef (_env_harnesses env)
          let runningSection = if Map.null harnesses
                then ["  (none running)"]
                else map (\(n, hh) -> "  " <> n <> " (" <> _hh_name hh <> ")")
                         (Map.toList harnesses)
              availSection = map (\(n, aliases, desc) ->
                    "  " <> n <> " (aliases: " <> T.intercalate ", " aliases <> ") — " <> desc)
                    knownHarnesses
              output = T.intercalate "\n" $
                ["Running:"] <> runningSection <>
                ["", "Available:"] <> availSection <>
                ["", "Commands:"
                , "  /harness start <name> [dir] [--unsafe]"
                , "  /harness stop <name>   — Stop a harness"
                , "  /harness list          — List harnesses"
                , "  /harness attach        — Show tmux attach command"
                ]
          send output
          pure ctx
      | otherwise -> do
          send ("Unknown harness command: " <> subcmd <> ". Type /harness to see available commands.")
          pure ctx

-- ---------------------------------------------------------------------------
-- Agent subcommand execution
-- ---------------------------------------------------------------------------

-- | Directory that holds per-agent bootstrap subdirectories.
-- Derives from 'getPureclawDir' so it honours @HOME@ in tests.
getAgentsDir :: IO FilePath
getAgentsDir = do
  pureclawDir <- getPureclawDir
  pure (pureclawDir </> "agents")

-- | Execute a '/agent' subcommand. In WU1 the environment does not yet
-- carry a currently-selected agent, so '/agent info' without an argument
-- always reports that no agent is selected, and '/agent start' returns a
-- placeholder message pending session support in WU2.
executeAgentCommand :: AgentEnv -> AgentSubCommand -> Context -> IO Context
executeAgentCommand env sub ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
      lg   = _env_logger env
  case sub of
    AgentList -> do
      agentsDir <- getAgentsDir
      defs <- AgentDef.discoverAgents lg agentsDir
      if null defs
        then do
          send "No agents found. Create one at ~/.pureclaw/agents/<name>/"
          pure ctx
        else do
          let names = [AgentDef.unAgentName (AgentDef._ad_name d) | d <- defs]
          send (T.intercalate "\n"
                 ("Agents:" : map ("  " <>) (L.sort names)))
          pure ctx

    AgentInfo Nothing -> do
      send "No agent selected. Use --agent <name>."
      pure ctx

    AgentInfo (Just name) -> do
      agentsDir <- getAgentsDir
      case AgentDef.mkAgentName name of
        Left _ -> do
          send ("Agent \"" <> name <> "\" not found. invalid agent name.")
          pure ctx
        Right validName -> do
          mDef <- AgentDef.loadAgent agentsDir validName
          case mDef of
            Nothing -> do
              defs <- AgentDef.discoverAgents lg agentsDir
              let names = L.sort
                    [AgentDef.unAgentName (AgentDef._ad_name d) | d <- defs]
                  avail = if null names
                    then "(none)"
                    else T.intercalate ", " names
              send ("Agent \"" <> name <> "\" not found. Available agents: " <> avail)
              pure ctx
            Just def -> do
              files <- listAgentFiles (AgentDef._ad_dir def)
              let cfg = AgentDef._ad_config def
                  cfgLines =
                    [ "  model: "        <> fromMaybeT "(unset)" (AgentDef._ac_model cfg)
                    , "  tool_profile: " <> fromMaybeT "(unset)" (AgentDef._ac_toolProfile cfg)
                    , "  workspace: "    <> fromMaybeT "(default)" (AgentDef._ac_workspace cfg)
                    ]
                  output = T.intercalate "\n" $
                    [ "Agent: " <> AgentDef.unAgentName (AgentDef._ad_name def)
                    , "  dir: " <> T.pack (AgentDef._ad_dir def)
                    , "Files:"
                    ] <>
                    (if null files
                       then ["  (none)"]
                       else map ("  " <>) files) <>
                    [ "Config:" ] <> cfgLines
              send output
              pure ctx

    AgentStart name -> do
      agentsDir <- getAgentsDir
      case AgentDef.mkAgentName name of
        Left _ -> do
          send ("invalid agent name: \"" <> name <> "\".")
          pure ctx
        Right validName -> do
          mDef <- AgentDef.loadAgent agentsDir validName
          case mDef of
            Nothing -> do
              send ("Agent \"" <> name <> "\" not found.")
              pure ctx
            Just _ -> do
              send "Agent start will be fully wired up in a later session (requires Session support)."
              pure ctx

    AgentUnknown subcmd
      | T.null subcmd -> do
          send (T.intercalate "\n"
            [ "Agent commands:"
            , "  /agent list"
            , "  /agent info [<name>]"
            , "  /agent start <name>"
            ])
          pure ctx
      | otherwise -> do
          send ("Unknown agent command: " <> subcmd <> ". Type /agent to see available commands.")
          pure ctx

-- | List the known bootstrap @.md@ files present in an agent directory, in
-- the same order used by 'composeAgentPrompt'.
listAgentFiles :: FilePath -> IO [Text]
listAgentFiles dir = do
  let candidates =
        [ "SOUL.md", "USER.md", "AGENTS.md", "MEMORY.md"
        , "IDENTITY.md", "TOOLS.md", "BOOTSTRAP.md"
        ]
  present <- filterM (Dir.doesFileExist . (dir </>)) candidates
  pure (map T.pack present)

fromMaybeT :: Text -> Maybe Text -> Text
fromMaybeT def Nothing  = def
fromMaybeT _   (Just t) = t

-- | Filter a list of agent names by a case-insensitive prefix. Exported as
-- a pure helper so the tab completer can present matching names for
-- @/agent info@ and @/agent start@ without needing IO. When the prefix is
-- empty, all candidates are returned.
agentNameMatches :: [Text] -> Text -> [Text]
agentNameMatches candidates prefix =
  let lowerPfx = T.toLower prefix
  in filter (\c -> lowerPfx `T.isPrefixOf` T.toLower c) candidates

-- ---------------------------------------------------------------------------
-- Session subcommand execution
-- ---------------------------------------------------------------------------

-- | Directory holding per-session subdirectories. Honours @HOME@ via
-- 'getPureclawDir' so tests can redirect via 'withTempHome'.
getSessionsDir :: IO FilePath
getSessionsDir = do
  pureclawDir <- getPureclawDir
  pure (pureclawDir </> "sessions")

-- | Filter a list of session IDs by a case-insensitive prefix. Pure helper
-- used by the tab completer. Empty prefix returns all candidates.
sessionIdMatches :: [Text] -> Text -> [Text]
sessionIdMatches candidates prefix =
  let lowerPfx = T.toLower prefix
  in filter (\c -> lowerPfx `T.isPrefixOf` T.toLower c) candidates

-- | Execute a '/session' subcommand. In Session C scope, @/session new@ and
-- @/session resume@ do NOT swap the active session (that is Session D's job
-- once 'AgentEnv' gains mutable session state); instead they validate,
-- persist to disk (new) or report (resume), and return confirmation
-- messages.
executeSessionCommand :: AgentEnv -> SessionSubCommand -> Context -> IO Context
executeSessionCommand env sub ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  case sub of
    SessionNew -> do
      sessionsDir <- getSessionsDir
      Dir.createDirectoryIfMissing True sessionsDir
      now <- Time.getCurrentTime
      let sid = SessionTypes.newSessionId Nothing now
          meta = SessionTypes.SessionMeta
            { SessionTypes._sm_id                = sid
            , SessionTypes._sm_agent             = Nothing
            , SessionTypes._sm_runtime           = SessionTypes.RTProvider
            , SessionTypes._sm_model             = ""
            , SessionTypes._sm_channel           = ""
            , SessionTypes._sm_createdAt         = now
            , SessionTypes._sm_lastActive        = now
            , SessionTypes._sm_bootstrapConsumed = False
            }
      _ <- Session.mkSessionHandle (_env_logger env) sessionsDir meta
      send ("New session created: " <> unSessionId sid
            <> "\nSession cleared. Starting fresh.")
      pure (clearMessages ctx)

    SessionList mAgentFilter -> do
      sessionsDir <- getSessionsDir
      -- /session list <agent> filters by the named agent; invalid name => empty
      let mAgent = case mAgentFilter of
            Nothing   -> Nothing
            Just name -> case AgentDef.mkAgentName name of
              Right n -> Just n
              Left _  -> Nothing
      metas <- Session.listSessions sessionsDir mAgent 20
      if null metas
        then do
          send "No sessions found."
          pure ctx
        else do
          let line m = "  " <> unSessionId (SessionTypes._sm_id m)
              output = T.intercalate "\n" ("Sessions:" : map line metas)
          send output
          pure ctx

    SessionResume ref -> do
      sessionsDir <- getSessionsDir
      result <- Session.resolveSessionRef sessionsDir ref
      case result of
        Left Session.NotFound -> do
          send ("No session matching " <> ref <> " found.")
          pure ctx
        Left (Session.Ambiguous matches) -> do
          let names = T.intercalate ", " (map unSessionId matches)
          send ("Multiple sessions match: " <> names)
          pure ctx
        Right sid -> do
          eHandle <- Session.resumeSession (_env_logger env) sessionsDir sid
          case eHandle of
            Left err -> do
              send ("Failed to resume session: " <> T.pack (show err))
              pure ctx
            Right _ -> do
              send ("Resumed session " <> unSessionId sid)
              pure ctx

    SessionLast -> do
      sessionsDir <- getSessionsDir
      metas <- Session.listSessions sessionsDir Nothing 1
      case metas of
        [] -> do
          send "No sessions found."
          pure ctx
        (m : _) -> do
          let sid = SessionTypes._sm_id m
          eHandle <- Session.resumeSession (_env_logger env) sessionsDir sid
          case eHandle of
            Left err -> do
              send ("Failed to resume session: " <> T.pack (show err))
              pure ctx
            Right _ -> do
              send ("Resumed session " <> unSessionId sid)
              pure ctx

    SessionInfo -> do
      meta <- readIORef (_sh_meta (_env_session env))
      model <- readIORef (_env_model env)
      target <- readIORef (_env_target env)
      let sidLine    = "  Session: " <> unSessionId (_sm_id meta)
          agentLine  = case _sm_agent meta of
            Nothing -> "  Agent:   (no agent)"
            Just a  -> "  Agent:   " <> AgentDef.unAgentName a
          runtimeLine = "  Runtime: " <> case _sm_runtime meta of
            SessionTypes.RTProvider   -> "provider"
            SessionTypes.RTHarness n  -> "harness:" <> n
          targetLine = case target of
            TargetProvider     -> "  Target:  model: " <> unModelId model
            TargetHarness name -> "  Target:  harness: " <> name
          body = T.intercalate "\n"
            [ "Session info:"
            , sidLine
            , agentLine
            , runtimeLine
            , targetLine
            , "  Messages:            " <> T.pack (show (contextMessageCount ctx))
            , "  Est. context tokens: " <> T.pack (show (contextTokenEstimate ctx))
            , "  Total input tokens:  " <> T.pack (show (contextTotalInputTokens ctx))
            , "  Total output tokens: " <> T.pack (show (contextTotalOutputTokens ctx))
            ]
      send body
      pure ctx

    SessionReset -> executeSlashCommand env CmdReset ctx
    SessionCompact -> executeSlashCommand env CmdCompact ctx

    SessionUnknown subcmd
      | T.null subcmd -> do
          send (T.intercalate "\n"
            [ "Session commands:"
            , "  /session new"
            , "  /session list [<agent>]"
            , "  /session resume <id>"
            , "  /session last"
            , "  /session info"
            , "  /session reset"
            , "  /session compact"
            ])
          pure ctx
      | otherwise -> do
          send ("Unknown session command: " <> subcmd <> ". Type /session to see available commands.")
          pure ctx
  where
    _sh_meta = Session._sh_meta
    _sm_id = SessionTypes._sm_id
    _sm_agent = SessionTypes._sm_agent
    _sm_runtime = SessionTypes._sm_runtime

-- | Known harnesses: (canonical name, aliases, description).
knownHarnesses :: [(Text, [Text], Text)]
knownHarnesses =
  [ ("claude-code", ["claude", "cc"], "Anthropic Claude Code CLI")
  ]

-- | Start a harness by name or alias.
startHarnessByName
  :: SecurityPolicy
  -> TranscriptHandle
  -> Int              -- ^ tmux window index
  -> Text
  -> Maybe FilePath   -- ^ optional working directory
  -> Bool             -- ^ skip permission checks
  -> IO (Either HarnessError HarnessHandle)
startHarnessByName policy th windowIdx name mWorkDir skipPerms =
  case resolveHarnessName name of
    Just "claude-code" ->
      let extraArgs = ["--dangerously-skip-permissions" | skipPerms]
      in mkClaudeCodeHarness policy th windowIdx mWorkDir extraArgs
    _                  -> pure (Left (HarnessBinaryNotFound name))

-- | Resolve an optional directory argument for harness start.
-- Relative paths are interpreted relative to @$HOME@; absolute paths are used as-is.
resolveHarnessDir :: Maybe Text -> IO (Maybe FilePath)
resolveHarnessDir Nothing = pure Nothing
resolveHarnessDir (Just dir) = do
  let path = T.unpack dir
  if isAbsolutePath path
    then pure (Just path)
    else do
      home <- Dir.getHomeDirectory
      pure (Just (home </> path))
  where
    isAbsolutePath ('/':_) = True
    isAbsolutePath _       = False

-- | Resolve a name or alias to the canonical harness name.
resolveHarnessName :: Text -> Maybe Text
resolveHarnessName input =
  let lower = T.toLower input
  in case [canonical | (canonical, aliases, _) <- knownHarnesses
                     , lower == canonical || lower `elem` aliases] of
       (c : _) -> Just c
       []      -> Nothing

-- ---------------------------------------------------------------------------
-- Harness discovery
-- ---------------------------------------------------------------------------

-- | Discover running harnesses by querying tmux window names.
-- Returns the reconstructed harness map and the next window index to use.
--
-- Window names matching @\<canonical\>-\<N\>@ (e.g. @claude-code-0@) are
-- recognised as harness windows. The handle is reconstructed so
-- send\/receive\/stop work against the existing tmux window.
discoverHarnesses
  :: TranscriptHandle
  -> IO (Map.Map Text HarnessHandle, Int)
discoverHarnesses = discoverHarnessesIn "pureclaw"

-- | Like 'discoverHarnesses' but queries a specific tmux session name.
-- Useful for testing with an isolated session.
discoverHarnessesIn
  :: Text             -- ^ tmux session name
  -> TranscriptHandle
  -> IO (Map.Map Text HarnessHandle, Int)
discoverHarnessesIn session th = do
  windows <- listSessionWindows session
  let discovered =
        [ (name, idx, canonical)
        | (idx, name) <- windows
        , Just (canonical, winIdx) <- [parseHarnessWindowName name]
        , winIdx == idx  -- sanity: name encodes the same index
        ]
  handles <- mapM (\(name, idx, canonical) -> do
    hh <- mkHandle canonical idx
    pure (name, hh)) discovered
  let harnessMap = Map.fromList handles
      nextIdx = if null discovered
        then 0
        else maximum [idx | (_, idx, _) <- discovered] + 1
  pure (harnessMap, nextIdx)
  where
    mkHandle :: Text -> Int -> IO HarnessHandle
    mkHandle canonical idx = case canonical of
      "claude-code" -> mkDiscoveredClaudeCodeHandle th idx
      -- Future harness types go here
      _             -> mkDiscoveredClaudeCodeHandle th idx  -- fallback

    -- | Parse a window name like "claude-code-0" into (canonical, index).
    parseHarnessWindowName :: Text -> Maybe (Text, Int)
    parseHarnessWindowName name =
      -- Try each known canonical name as a prefix
      let candidates =
            [ (canonical, T.drop (T.length canonical + 1) name)
            | (canonical, _, _) <- knownHarnesses
            , (canonical <> "-") `T.isPrefixOf` name
            ]
      in case candidates of
        [(canonical, suffix)] ->
          case TR.decimal suffix of
            Right (n, rest) | T.null rest -> Just (canonical, n)
            _ -> Nothing
        _ -> Nothing

-- ---------------------------------------------------------------------------
-- Signal setup wizard
-- ---------------------------------------------------------------------------

-- | Interactive Signal setup. Checks signal-cli, offers link or register,
-- walks through the flow, writes config.
executeSignalSetup :: AgentEnv -> Context -> IO Context
executeSignalSetup env ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage

  -- Step 1: Check signal-cli is installed
  signalCliCheck <- try @IOException $
    P.readProcess (P.proc "signal-cli" ["--version"])
  case signalCliCheck of
    Left _ -> do
      send $ T.intercalate "\n"
        [ "signal-cli is not installed."
        , ""
        , "Install it first:"
        , "  macOS:  brew install signal-cli"
        , "  Nix:    nix-env -i signal-cli"
        , "  Other:  https://github.com/AsamK/signal-cli"
        , ""
        , "Then run /channel signal again."
        ]
      pure ctx
    Right (exitCode, versionOut, _) -> do
      let version = T.strip (TE.decodeUtf8 (BL.toStrict versionOut))
      case exitCode of
        ExitSuccess ->
          send $ "Found signal-cli " <> version
        _ ->
          send "Found signal-cli (version unknown)"

      -- Step 2: Offer link or register
      send $ T.intercalate "\n"
        [ ""
        , "How would you like to connect?"
        , "  [1] Link to an existing Signal account (adds PureClaw as secondary device)"
        , "  [2] Register with a phone number (becomes primary device for that number)"
        , ""
        , "Note: Option 2 will take over the number from any existing Signal registration."
        ]

      choice <- T.strip <$> _ch_prompt ch "Choice [1]: "
      let effectiveChoice = if T.null choice then "1" else choice

      case effectiveChoice of
        "1" -> signalLinkFlow env ctx
        "2" -> signalRegisterFlow env ctx
        _   -> do
          send "Invalid choice. Setup cancelled."
          pure ctx

-- | Link to an existing Signal account by scanning a QR code.
-- signal-cli link outputs the sgnl:// URI, then blocks until the user
-- scans it. We need to stream the output to show the URI immediately.
signalLinkFlow :: AgentEnv -> Context -> IO Context
signalLinkFlow env ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage

  send "Generating link... (this may take a moment)"

  let procConfig = P.setStdout P.createPipe
                 $ P.setStderr P.createPipe
                 $ P.proc "signal-cli" ["link", "-n", "PureClaw"]
  startResult <- try @IOException $ P.startProcess procConfig
  case startResult of
    Left err -> do
      send $ "Failed to start signal-cli: " <> T.pack (show err)
      pure ctx
    Right process -> do
      let stdoutH = P.getStdout process
          stderrH = P.getStderr process
      -- signal-cli outputs the URI to stderr, then blocks waiting for scan.
      -- Read stderr lines until we find the sgnl:// URI.
      linkUri <- readUntilLink stderrH stdoutH
      case linkUri of
        Nothing -> do
          -- Process may have exited with error
          exitCode <- P.waitExitCode process
          send $ "signal-cli link failed (exit " <> T.pack (show exitCode) <> ")"
          pure ctx
        Just uri -> do
          send $ T.intercalate "\n"
            [ "Open Signal on your phone:"
            , "  Settings \x2192 Linked Devices \x2192 Link New Device"
            , ""
            , "Scan this link (or paste into a QR code generator):"
            , ""
            , "  " <> uri
            , ""
            , "Waiting for you to scan... (this will complete automatically)"
            ]
          -- Now wait for signal-cli to finish (user scans the code)
          exitCode <- P.waitExitCode process
          case exitCode of
            ExitSuccess -> do
              send "Linked successfully!"
              detectAndWriteSignalConfig env ctx
            _ -> do
              send "Link failed or was cancelled."
              pure ctx
  where
    -- Read lines from both handles looking for a sgnl:// URI.
    -- signal-cli typically puts it on stderr.
    readUntilLink :: Handle -> Handle -> IO (Maybe Text)
    readUntilLink stderrH stdoutH = go (50 :: Int)  -- max 50 lines to prevent infinite loop
      where
        go 0 = pure Nothing
        go n = do
          lineResult <- try @IOException (hGetLine stderrH)
          case lineResult of
            Left _ -> do
              -- stderr closed, try stdout
              outResult <- try @IOException (hGetLine stdoutH)
              case outResult of
                Left _    -> pure Nothing
                Right line ->
                  let t = T.pack line
                  in if "sgnl://" `T.isInfixOf` t
                     then pure (Just (T.strip t))
                     else go (n - 1)
            Right line ->
              let t = T.pack line
              in if "sgnl://" `T.isInfixOf` t
                 then pure (Just (T.strip t))
                 else go (n - 1)

-- | Register a new phone number.
signalRegisterFlow :: AgentEnv -> Context -> IO Context
signalRegisterFlow env ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage

  phoneNumber <- T.strip <$> _ch_prompt ch "Phone number (E.164 format, e.g. +15555550123): "
  if T.null phoneNumber || not ("+" `T.isPrefixOf` phoneNumber)
    then do
      send "Invalid phone number. Must start with + (E.164 format)."
      pure ctx
    else do
      -- Try register without captcha first, handle captcha if required
      signalRegister env ch phoneNumber Nothing ctx

-- | Attempt signal-cli register, handling captcha if required.
signalRegister :: AgentEnv -> ChannelHandle -> Text -> Maybe Text -> Context -> IO Context
signalRegister env ch phoneNumber mCaptcha ctx = do
  let send = _ch_send ch . OutgoingMessage
      args = ["-u", T.unpack phoneNumber, "register"]
          ++ maybe [] (\c -> ["--captcha", T.unpack c]) mCaptcha
  send $ "Sending verification SMS to " <> phoneNumber <> "..."
  regResult <- try @IOException $
    P.readProcess (P.proc "signal-cli" args)
  case regResult of
    Left err -> do
      send $ "Registration failed: " <> T.pack (show err)
      pure ctx
    Right (exitCode, _, errOut) -> do
      let errText = T.strip (TE.decodeUtf8 (BL.toStrict errOut))
      case exitCode of
        ExitSuccess -> signalVerify env ch phoneNumber ctx
        _ | "captcha" `T.isInfixOf` T.toLower errText -> do
              send $ T.intercalate "\n"
                [ "Signal requires a captcha before sending the SMS."
                , ""
                , "1. Open this URL in a browser:"
                , "   https://signalcaptchas.org/registration/generate.html"
                , "2. Solve the captcha"
                , "3. Open DevTools (F12), go to Network tab"
                , "4. Click \"Open Signal\" \x2014 find the signalcaptcha:// URL in the Network tab"
                , "5. Copy and paste the full URL here (starts with signalcaptcha://)"
                ]
              captchaInput <- T.strip <$> _ch_prompt ch "Captcha token: "
              let token = T.strip (T.replace "signalcaptcha://" "" captchaInput)
              if T.null token
                then do
                  send "No captcha provided. Setup cancelled."
                  pure ctx
                else signalRegister env ch phoneNumber (Just token) ctx
        _ -> do
          send $ "Registration failed: " <> errText
          pure ctx

-- | Verify a phone number after registration SMS was sent.
signalVerify :: AgentEnv -> ChannelHandle -> Text -> Context -> IO Context
signalVerify env ch phoneNumber ctx = do
  let send = _ch_send ch . OutgoingMessage
  send "Verification code sent! Check your SMS."
  code <- T.strip <$> _ch_prompt ch "Verification code: "
  verifyResult <- try @IOException $
    P.readProcess (P.proc "signal-cli"
      ["-u", T.unpack phoneNumber, "verify", T.unpack code])
  case verifyResult of
    Left err -> do
      send $ "Verification failed: " <> T.pack (show err)
      pure ctx
    Right (verifyExit, _, verifyErr) -> case verifyExit of
      ExitSuccess -> do
        send "Phone number verified!"
        writeSignalConfig env phoneNumber ctx
      _ -> do
        send $ "Verification failed: " <> T.strip (TE.decodeUtf8 (BL.toStrict verifyErr))
        pure ctx

-- | Detect the linked account number and write Signal config.
detectAndWriteSignalConfig :: AgentEnv -> Context -> IO Context
detectAndWriteSignalConfig env ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  -- signal-cli stores account info; try to list accounts
  acctResult <- try @IOException $
    P.readProcess (P.proc "signal-cli" ["listAccounts"])
  case acctResult of
    Left _ -> do
      -- Can't detect — ask user
      phoneNumber <- T.strip <$> _ch_prompt (_env_channel env)
        "What phone number was linked? (E.164 format): "
      writeSignalConfig env phoneNumber ctx
    Right (_, out, _) -> do
      let outText = T.strip (TE.decodeUtf8 (BL.toStrict out))
          -- Look for a line starting with + (phone number)
          phones = filter ("+" `T.isPrefixOf`) (map T.strip (T.lines outText))
      case phones of
        (phone:_) -> do
          send $ "Detected account: " <> phone
          writeSignalConfig env phone ctx
        [] -> do
          phoneNumber <- T.strip <$> _ch_prompt (_env_channel env)
            "Could not detect account. Phone number (E.164 format): "
          writeSignalConfig env phoneNumber ctx

-- | Write Signal config to config.toml and confirm.
writeSignalConfig :: AgentEnv -> Text -> Context -> IO Context
writeSignalConfig env phoneNumber ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  pureclawDir <- getPureclawDir
  Dir.createDirectoryIfMissing True pureclawDir
  let configPath = pureclawDir </> "config.toml"

  -- Load existing config, add signal settings
  existing <- loadFileConfig configPath
  let updated = existing
        { _fc_defaultChannel = Just "signal"
        , _fc_signal = Just FileSignalConfig
            { _fsc_account        = Just phoneNumber
            , _fsc_dmPolicy       = Just "open"
            , _fsc_allowFrom      = Nothing
            , _fsc_textChunkLimit = Nothing  -- use default 6000
            }
        }
  writeFileConfig configPath updated

  send $ T.intercalate "\n"
    [ ""
    , "Signal configured!"
    , "  Account: " <> phoneNumber
    , "  DM policy: open (accepts messages from anyone)"
    , "  Default channel: signal"
    , ""
    , "To start chatting:"
    , "  1. Restart PureClaw (or run: pureclaw --channel signal)"
    , "  2. Open Signal on your phone"
    , "  3. Send a message to " <> phoneNumber
    , ""
    , "To restrict access later, edit ~/.pureclaw/config.toml:"
    , "  [signal]"
    , "  dm_policy = \"allowlist\""
    , "  allow_from = [\"<your-uuid>\"]"
    , ""
    , "Your UUID will appear in the logs on first message."
    ]
  pure ctx

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
