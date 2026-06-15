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
  , McpSubCommand (..)
  , TabSlashCommand (..)
  , TabKindArg (..)
  , ForceMode (..)
    -- * Known harnesses
  , knownHarnesses
  , startHarnessByName
  , resolveHarnessName
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
import Data.Char qualified as Char
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
import System.Process (proc)
import System.Process.Typed qualified as P

import Data.Aeson qualified as Aeson
import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.MCP qualified as MCP
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
import PureClaw.Harness.ClaudeSession (mintClaudeSessionUuid, unClaudeSessionUuid)
import PureClaw.Harness.Registry qualified as Registry
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
import PureClaw.Routing.Onboarding qualified as Onboarding
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
  | GroupMcp        -- ^ MCP server management
  | GroupTab        -- ^ Tabbed Chat (/tab*, /tabs)
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
groupHeading GroupMcp        = "MCP"
groupHeading GroupTab        = "Tab"

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
  = SessionNew (Maybe Text) (Maybe Text) -- ^ Create session: (agent, target). Both optional.
  | SessionList (Maybe Text)           -- ^ List recent sessions (optionally filter by agent)
  | SessionResume Text                 -- ^ Resume a session by id or prefix
  | SessionLast                        -- ^ Resume the most recent session
  | SessionInfo                        -- ^ Show info for the current session
  | SessionCompact                     -- ^ Compact the current session (alias for CmdCompact)
  | SessionUnknown Text                -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/agent' family.
data AgentSubCommand
  = AgentList                  -- ^ List discovered agents
  | AgentInfo (Maybe Text)     -- ^ Show info for a named agent (or the current one when 'Nothing')
  | AgentDefault (Maybe Text)  -- ^ View or set the default agent
  | AgentUnknown Text          -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | Subcommands of the '/mcp' family.
data McpSubCommand
  = McpConnect Text [Text]    -- ^ Connect to server: (name, command + args)
  | McpDisconnect Text        -- ^ Disconnect a named server
  | McpList                   -- ^ List connected servers and their tools
  | McpUnknown Text           -- ^ Unrecognised subcommand
  deriving stock (Show, Eq)

-- | A redacted enumeration of @TabKind@ as it appears in the @/tab new@
-- command. Local to this module to avoid an import cycle through
-- 'PureClaw.Handles.Tab' (which imports this module for 'SlashCommand'
-- in its 'TabUnsupportedCommand' constructor). WU2 introduces this type
-- alongside the @/tab@ command family; downstream WUs that need a
-- 'PureClaw.Handles.Tab.TabKind' translate via a trivial total
-- conversion at the handler layer (WU9).
data TabKindArg
  = TkaAi
  | TkaProvider
  | TkaHarness
  | TkaShell
  | TkaSsh
  | TkaTmux
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | Whether @/tab close N@ was passed the @--force@ flag.
--
-- For @KindAi@ tabs, @ForceYes@ skips the session archive on close
-- (transcript deleted from disk). For non-AI tabs the close path is
-- already destructive so the flag is a no-op semantically — the
-- distinction is preserved here so 'executeSlashCommand' (WU9) can
-- still echo what the user asked for.
data ForceMode
  = ForceNo
  | ForceYes
  deriving stock (Show, Eq, Ord, Bounded, Enum)

-- | The @/tab@ command family (introduced by WU2 of Tabbed Chat #51).
--
-- Tab indices are stored as plain 'Int' rather than as
-- 'PureClaw.Handles.Tab.TabIndex' to avoid an import cycle. The parser
-- ('PureClaw.Routing.Parse.parseInput') validates the index against
-- @_rc_maxTabs@ via @mkTabIndex@ before constructing these values, so
-- callers may treat the contained 'Int' as well-formed for the
-- configured cap; downstream handlers (WU9) are still expected to
-- re-wrap via @mkTabIndex@ when crossing into 'TabIndex'-typed APIs.
--
-- @TabResumeCmd@ carries the validated 'SessionId' produced by
-- @mkSessionId@ (WU2 smart constructor).
--
-- /tmux-style packing update:/ @TabNewCmd@ no longer carries an
-- explicit target index — new tabs are always allocated at the lowest
-- free slot. The constructor's payload is therefore just the optional
-- kind keyword and the optional argument-text remainder.
data TabSlashCommand
  = TabNewCmd !(Maybe TabKindArg) !(Maybe Text)
    -- ^ @\/tab new [\<kind\> [\<arg-text\>]]@. Index is allocated at
    --   the lowest free slot by the handler (tmux-style packing). The
    --   second field is the remainder of the line after the kind,
    --   captured as a single 'Text' for the handler to split further.
  | TabListCmd
    -- ^ @\/tab list@ (and the @\/tabs@ alias).
  | TabCloseCmd !Int !ForceMode
    -- ^ @\/tab close \<N\> [--force]@. Remaining tabs are renumbered
    --   down by one starting at @N+1@ so the registry is always packed
    --   in the lowest slots (tmux @renumber-windows on@ model).
  | TabFocusCmd !Int
    -- ^ @\/tab focus \<N\>@ (functional alias of @\/N@).
  | TabResumeCmd !SessionId
    -- ^ @\/tab resume \<session-id\>@. Validation lives in
    --   @mkSessionId@; rejection surfaces as
    --   @ParseErrorInvalidSessionId@.
  | TabRenameCmd !Int !Text
    -- ^ @\/tab rename \<N\> \<name\>@. Parser captures the requested
    --   name verbatim; @sanitizeTabName@ runs at handler time per
    --   S10 so the user sees the rejection reason when applicable.
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Top-level commands
-- ---------------------------------------------------------------------------

-- | All recognised slash commands.
data SlashCommand
  = CmdHelp                         -- ^ Show command reference
  | CmdNew                          -- ^ Clear conversation, keep configuration
  | CmdStatus                       -- ^ Show session status
  | CmdCompact                      -- ^ Summarise conversation to save context
  | CmdStart                        -- ^ Onboarding entry point (Tabbed Chat O1; Telegram @\/start@ convention)
  | CmdTarget (Maybe Text)            -- ^ Show or switch message target
  | CmdTargetList                    -- ^ List available targets (models + harnesses)
  | CmdTargetDefault (Maybe Text)    -- ^ View or set the default target for new sessions
  | CmdProvider ProviderSubCommand  -- ^ Provider configuration command family
  | CmdVault VaultSubCommand        -- ^ Vault command family
  | CmdChannel ChannelSubCommand       -- ^ Channel configuration
  | CmdTranscript TranscriptSubCommand -- ^ Transcript query commands
  | CmdHarness HarnessSubCommand      -- ^ Harness management commands
  | CmdAgent AgentSubCommand          -- ^ Agent management commands
  | CmdSession SessionSubCommand      -- ^ Session management commands
  | CmdMsg Text Text                  -- ^ Send a message to a specific target (name, message)
  | CmdMcp McpSubCommand              -- ^ MCP server management commands
  | CmdTab TabSlashCommand            -- ^ Tabbed Chat @\/tab*@ / @\/tabs@ family (WU2; handlers in WU9)
  | CmdBg !Text                       -- ^ Run a prompt in a fresh background session (issue #52)
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
allCommandSpecs = sessionCommandSpecs ++ sessionFamilyCommandSpecs ++ providerCommandSpecs ++ channelCommandSpecs ++ vaultCommandSpecs ++ transcriptCommandSpecs ++ harnessCommandSpecs ++ agentCommandSpecs ++ mcpCommandSpecs ++ msgCommandSpecs ++ bgCommandSpecs ++ tabFamilyCommandSpecs

-- | The @\/tab@ command family + @\/tabs@ alias (Tabbed Chat #51).
--
-- These specs let the LEGACY parser ('parseSlashCommand') recognise
-- the tab vocabulary so that a user running the CLI loop
-- ('PureClaw.Tabs.Wiring.runTabbedLoop') sees
-- a real handler rather than \"Unrecognized slash command\". The
-- handlers themselves live in 'PureClaw.Routing.AutoSpawn'; the
-- 'CmdTab' arm of 'executeSlashCommand' dispatches to them.
--
-- The canonical parser used by 'PureClaw.Routing.Dispatcher' is
-- 'PureClaw.Routing.Parse.parseInput'; this list parallels that
-- parser's @\/tab*@ shapes but is intentionally separate so
-- @Agent.SlashCommands@ doesn't depend on @Routing.Parse@ (import
-- cycle).
tabFamilyCommandSpecs :: [CommandSpec]
tabFamilyCommandSpecs =
  [ CommandSpec "/tabs"                              "List all tabs (alias of /tab list)"          GroupTab (exactP "/tabs" (CmdTab TabListCmd))
  , CommandSpec "/tab list"                          "List all tabs"                               GroupTab (exactP "/tab list" (CmdTab TabListCmd))
  , CommandSpec "/tab new [<kind>]"                  "Open a new tab (kind: provider, harness, shell, ssh, tmux)" GroupTab tabNewP
  , CommandSpec "/tab close <N> [--force]"           "Close tab N (--force skips archive on AI)"    GroupTab tabCloseP
  , CommandSpec "/tab focus <N>"                     "Switch focus to tab N (alias of /N)"          GroupTab tabFocusP
  , CommandSpec "/tab resume <id>"                   "Resume a session into a new tab"             GroupTab tabResumeP
  , CommandSpec "/tab rename <N> <name>"             "Rename tab N (subject to sanitization)"      GroupTab tabRenameP
  ]

sessionCommandSpecs :: [CommandSpec]
sessionCommandSpecs =
  [ CommandSpec "/help"    "Show this command reference"               GroupSession (exactP "/help"    CmdHelp)
  , CommandSpec "/status"  "Session status (messages, tokens used)"   GroupSession (exactP "/status"  CmdStatus)
  , CommandSpec "/new"     "Clear conversation, keep configuration"   GroupSession (exactP "/new"     CmdNew)
  , CommandSpec "/compact" "Summarise conversation to save context"   GroupSession (exactP "/compact" CmdCompact)
  , CommandSpec "/last"    "Resume the most recent session"           GroupSession (exactP "/last"    (CmdSession SessionLast))
  , CommandSpec "/start"   "Tabbed Chat \x2014 onboarding orientation" GroupSession (exactP "/start"   CmdStart)
  ]

-- | The '/session' command family. Subcommands manage the on-disk session
-- lifecycle (create, list, resume, info, compact).
sessionFamilyCommandSpecs :: [CommandSpec]
sessionFamilyCommandSpecs =
  [ CommandSpec "/session new [<agent>] [--target <name>]" "Create a new session" GroupSession sessionNewP
  , CommandSpec "/session list [<agent>]"   "List recent sessions (optionally by agent)"     GroupSession sessionListP
  , CommandSpec "/session resume <id>"      "Resume a session by id or unambiguous prefix"   GroupSession sessionResumeP
  , CommandSpec "/session last"             "Resume the most recent session"                 GroupSession (sessionExactP "last"    SessionLast)
  , CommandSpec "/session info"             "Show current session info"                      GroupSession (sessionExactP "info"    SessionInfo)
  , CommandSpec "/session compact"          "Compact current session"                        GroupSession (sessionExactP "compact" SessionCompact)
  ]

-- | Case-insensitive exact match for "/session <sub>" with no argument.
sessionExactP :: Text -> SessionSubCommand -> Text -> Maybe SlashCommand
sessionExactP sub cmd t =
  if T.toLower t == "/session " <> sub then Just (CmdSession cmd) else Nothing

-- | Parse "/session new [<agent>] [--target <name>]". The positional argument
-- is the agent name; the @--target@ flag specifies a target.
sessionNewP :: Text -> Maybe SlashCommand
sessionNewP t =
  let pfx   = "/session new"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdSession (SessionNew Nothing Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let rest = T.strip (T.drop (T.length pfx) t)
                   (mAgent, mTarget) = parseSessionNewArgs rest
               in Just (CmdSession (SessionNew mAgent mTarget))
          else Nothing

-- | Parse the arguments after "/session new": an optional positional agent name
-- and an optional @--target <name>@ flag. The flag can appear before or after
-- the positional argument.
parseSessionNewArgs :: Text -> (Maybe Text, Maybe Text)
parseSessionNewArgs rest =
  let ws = T.words rest
      (targetVal, otherWords) = extractFlag "--target" ws
      agentVal = case otherWords of
        []    -> Nothing
        (a:_) -> Just a
  in (agentVal, targetVal)

-- | Extract a flag and its value from a word list. Returns the value (if found)
-- and the remaining words with the flag and its argument removed.
extractFlag :: Text -> [Text] -> (Maybe Text, [Text])
extractFlag _    [] = (Nothing, [])
extractFlag flag (w:ws)
  | T.toLower w == flag = case ws of
      (v:rest) -> (Just v, rest)
      []       -> (Nothing, [])   -- flag with no value — treat as absent
  | otherwise = let (val, rest) = extractFlag flag ws
                in (val, w : rest)

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
  , CommandSpec "/target list"      "List available targets (models + harnesses)" GroupSession (exactP "/target list" CmdTargetList)
  , CommandSpec "/target default [<name>]" "View or set the default target for new sessions" GroupSession targetDefaultP
  , CommandSpec "/target [name]"   "Show or switch the message target"           GroupSession targetArgP
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
  [ CommandSpec "/agent list"              "List discovered agents in ~/.pureclaw/agents/" GroupAgent (agentExactP "list" AgentList)
  , CommandSpec "/agent info [<name>]"   "Show files and frontmatter for an agent"       GroupAgent agentInfoP
  , CommandSpec "/agent default [<name>]" "View or set the default agent"               GroupAgent agentDefaultP
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

-- | Parse "/agent default [<name>]". With no argument, shows the current default.
agentDefaultP :: Text -> Maybe SlashCommand
agentDefaultP t =
  let pfx   = "/agent default"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdAgent (AgentDefault Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdAgent (AgentDefault Nothing))
                  else Just (CmdAgent (AgentDefault (Just arg)))
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

mcpCommandSpecs :: [CommandSpec]
mcpCommandSpecs =
  [ CommandSpec "/mcp connect <name> <command...>"
      "Connect to an MCP server" GroupMcp mcpConnectP
  , CommandSpec "/mcp disconnect <name>"
      "Disconnect from an MCP server" GroupMcp mcpDisconnectP
  , CommandSpec "/mcp list"
      "List connected MCP servers and their tools" GroupMcp mcpListP
  ]

mcpConnectP :: Text -> Maybe SlashCommand
mcpConnectP t =
  let lower = T.toLower t
  in if "/mcp connect " `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length "/mcp connect") t)
              (name, cmdPart) = T.break (== ' ') rest
          in if T.null name || T.null (T.strip cmdPart)
               then Nothing
               else Just (CmdMcp (McpConnect name (T.words (T.strip cmdPart))))
     else Nothing

mcpDisconnectP :: Text -> Maybe SlashCommand
mcpDisconnectP t =
  let lower = T.toLower t
  in if "/mcp disconnect " `T.isPrefixOf` lower
     then let name = T.strip (T.drop (T.length "/mcp disconnect") t)
          in if T.null name then Nothing else Just (CmdMcp (McpDisconnect name))
     else Nothing

mcpListP :: Text -> Maybe SlashCommand
mcpListP t =
  let lower = T.toLower (T.strip t)
  in if lower == "/mcp list" || lower == "/mcp"
     then Just (CmdMcp McpList)
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

bgCommandSpecs :: [CommandSpec]
bgCommandSpecs =
  [ CommandSpec "/bg <prompt>" "Run a prompt in a fresh background session" GroupSession bgArgP
  ]

-- | Parse "/bg <prompt>". The remainder after @\/bg @ is the prompt,
-- stripped of surrounding whitespace; an empty prompt is rejected.
-- Mirrors 'msgArgP' for the keyword/whitespace handling.
bgArgP :: Text -> Maybe SlashCommand
bgArgP t =
  let pfx   = "/bg"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then let rest = T.strip (T.drop (T.length pfx) t)
          in if T.null rest
             then Nothing
             else Just (CmdBg rest)
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

-- ---------------------------------------------------------------------------
-- /tab* parser helpers (Tabbed Chat #51)
-- ---------------------------------------------------------------------------

-- | Parse @\/tab new [<kind> [<arg-text>]]@.
--
-- Grammar:
--   /tab new                         -> TabNewCmd Nothing Nothing
--   /tab new <kind>                  -> TabNewCmd (Just k) Nothing
--   /tab new <kind> <rest>           -> TabNewCmd (Just k) (Just rest)
--
-- Kind keywords: ai, harness, shell, ssh, tmux (case-insensitive).
-- An unknown kind word is malformed (returns Nothing); a missing kind
-- is the force-prompt form (Right (Nothing, Nothing)).
tabNewP :: Text -> Maybe SlashCommand
tabNewP t =
  let pfx   = "/tab new"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdTab (TabNewCmd Nothing Nothing))
     else if (pfx <> " ") `T.isPrefixOf` lower
          then case T.words (T.strip (T.drop (T.length pfx) t)) of
                 []      -> Just (CmdTab (TabNewCmd Nothing Nothing))
                 (k:ws)  -> case parseTabKindArg k of
                   Nothing -> Nothing  -- unknown kind keyword
                   Just kind ->
                     let argText = case ws of
                           [] -> Nothing
                           _  -> Just (T.unwords ws)
                     in Just (CmdTab (TabNewCmd (Just kind) argText))
          else Nothing

-- | Parse @\/tab close <N> [--force]@. @N@ is a non-negative decimal.
tabCloseP :: Text -> Maybe SlashCommand
tabCloseP t =
  let pfx   = "/tab close"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then case T.words (T.strip (T.drop (T.length pfx) t)) of
            [nTxt]              -> mkClose nTxt ForceNo
            [nTxt, flagTxt]
              | T.toLower flagTxt == "--force"
                -> mkClose nTxt ForceYes
            _                   -> Nothing
     else Nothing
  where
    mkClose nTxt force = do
      n <- parseDecimalNonNegative nTxt
      pure (CmdTab (TabCloseCmd n force))

-- | Parse @\/tab focus <N>@.
tabFocusP :: Text -> Maybe SlashCommand
tabFocusP t =
  let pfx   = "/tab focus"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then case T.words (T.strip (T.drop (T.length pfx) t)) of
            [nTxt] -> do
              n <- parseDecimalNonNegative nTxt
              pure (CmdTab (TabFocusCmd n))
            _      -> Nothing
     else Nothing

-- | Parse @\/tab resume <id>@. Mirrors the S3 invariants in
-- 'PureClaw.Routing.Parse.mkSessionId' (rejects @\/@, @\\@, @..@, NUL,
-- and any character outside @[a-zA-Z0-9_-]@). Inlined here rather than
-- imported to avoid a cycle with @Routing.Parse@; the handler
-- revalidates before use.
tabResumeP :: Text -> Maybe SlashCommand
tabResumeP t =
  let pfx   = "/tab resume"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then case T.words (T.strip (T.drop (T.length pfx) t)) of
            [sid] | isValidSessionId sid
              -> Just (CmdTab (TabResumeCmd (SessionId sid)))
            _ -> Nothing
     else Nothing

-- | Parse @\/tab rename <N> <name>@. The name captures the remainder
-- verbatim; 'PureClaw.Routing.Parse.sanitizeTabName' runs at handler
-- time per S10.
tabRenameP :: Text -> Maybe SlashCommand
tabRenameP t =
  let pfx   = "/tab rename"
      lower = T.toLower t
  in if (pfx <> " ") `T.isPrefixOf` lower
     then case T.words (T.strip (T.drop (T.length pfx) t)) of
            (nTxt:nameWords) | not (null nameWords) -> do
              n <- parseDecimalNonNegative nTxt
              pure (CmdTab (TabRenameCmd n (T.unwords nameWords)))
            _ -> Nothing
     else Nothing

-- | Map a kind keyword to its 'TabKindArg' enum value.
parseTabKindArg :: Text -> Maybe TabKindArg
parseTabKindArg w = case T.toLower w of
  "ai"       -> Just TkaAi
  "provider" -> Just TkaProvider
  "harness"  -> Just TkaHarness
  "shell"    -> Just TkaShell
  "ssh"      -> Just TkaSsh
  "tmux"     -> Just TkaTmux
  _          -> Nothing

-- | Parse a decimal non-negative 'Int'. Rejects empty input, leading
-- whitespace (caller pre-strips), signs, and any non-digit characters.
parseDecimalNonNegative :: Text -> Maybe Int
parseDecimalNonNegative t
  | T.null t                     = Nothing
  | T.any (not . Char.isDigit) t = Nothing
  | otherwise                    = case T.foldl' step 0 t of
      n | n >= 0 -> Just n
      _          -> Nothing
  where
    step acc c = acc * 10 + (fromEnum c - fromEnum '0')

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

-- | Parse "/target default [<name>]". With no argument, shows the current default.
targetDefaultP :: Text -> Maybe SlashCommand
targetDefaultP t =
  let pfx   = "/target default"
      lower = T.toLower t
  in if lower == pfx
     then Just (CmdTargetDefault Nothing)
     else if (pfx <> " ") `T.isPrefixOf` lower
          then let arg = T.strip (T.drop (T.length pfx) t)
               in if T.null arg
                  then Just (CmdTargetDefault Nothing)
                  else Just (CmdTargetDefault (Just arg))
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
  -- Render the full slash-command reference EXCEPT the Tab group, then
  -- append the Tabbed Chat \"Tab commands\" subsection from
  -- 'Onboarding.helpTabSection' (O2). The hand-authored helpTabSection
  -- covers the same vocabulary as 'tabFamilyCommandSpecs' plus the @\/N@
  -- routing grammar and the tmux-packing note — so it is the single
  -- source of truth for Tab help. Filtering 'GroupTab' from the
  -- auto-render keeps 'tabFamilyCommandSpecs' as the parser source of
  -- truth (it must stay in 'allCommandSpecs' so the parser recognises
  -- the family) without producing a duplicate help block.
  let nonTabSpecs = filter ((/= GroupTab) . _cs_group) allCommandSpecs
      body = renderHelpText nonTabSpecs <> "\n" <> Onboarding.helpTabSection
  _ch_send (_env_channel env) (OutgoingMessage body)
  pure ctx

executeSlashCommand env CmdStart ctx = do
  -- Tabbed Chat onboarding (O1). Delegated wholesale to
  -- 'Onboarding.handleStart' so the orientation text + side-effect
  -- (single _ch_send) live next to the BotFather registration list
  -- they document. Returns the context unchanged.
  Onboarding.handleStart env
  pure ctx

executeSlashCommand env CmdNew ctx = do
  _ch_send (_env_channel env) (OutgoingMessage "Session cleared. Starting fresh.")
  pure (clearMessages ctx)

executeSlashCommand env CmdStatus ctx = do
  mModel <- readIORef (_env_model env)
  target <- readIORef (_env_target env)
  mProvider <- readIORef (_env_provider env)
  mVault <- readIORef (_env_vault env)
  th <- envTranscript env
  transcriptPath <- _th_getPath th
  harnesses <- readIORef (_env_harnesses env)
  -- Session origin (set-once provenance). 'Nothing' for legacy sessions or
  -- sessions that have not yet received an inbound message — render those as
  -- "unknown" so the absence reads as intentional.
  --
  -- SECURITY: _sm_source is attacker-asserted; it is DISPLAY ONLY and never
  -- used for any access-control decision.
  activeSession <- readIORef (_env_session env)
  meta <- readIORef (Session._sh_meta activeSession)
  let modelText = maybe "(not set)" unModelId mModel
      targetLine = case target of
        TargetProvider    -> "  Target:    model: " <> modelText
        TargetHarness name -> "  Target:    harness: " <> name
      providerLine = case mProvider of
        Nothing -> "  Provider:  (not configured)"
        Just _  -> "  Provider:  configured"
      vaultLine = case mVault of
        Nothing -> "  Vault:     (not configured)"
        Just _  -> "  Vault:     configured"
      transcriptLine = if null transcriptPath
        then "  Transcript: disabled"
        else "  Transcript: " <> T.pack transcriptPath
      harnessLine = if Map.null harnesses
        then "  Harnesses: (none)"
        else "  Harnesses: " <> T.intercalate ", "
               [n <> " (" <> _hh_name h <> ")" | (n, h) <- Map.toList harnesses]
      policyLine = "  Policy:    " <> T.pack (show (_sp_autonomy (_env_policy env)))
      sourceLine = case SessionTypes._sm_source meta of
        Nothing  -> "  Source:    unknown"
        Just src -> "  Source:    " <> sourceLabel src
      sourceLabel src = case _ms_userId src of
        Just u  -> unUserId u <> " (" <> channelKindToText (_ms_channel src) <> ")"
        Nothing -> "(" <> channelKindToText (_ms_channel src) <> ")"
      status = T.intercalate "\n"
        [ "Session status:"
        , targetLine
        , providerLine
        , policyLine
        , sourceLine
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

executeSlashCommand env (CmdTargetDefault Nothing) ctx = do
  fileCfg <- loadConfig
  let send = _ch_send (_env_channel env) . OutgoingMessage
  case _fc_defaultTarget fileCfg of
    Nothing -> send "No default target set (defaults to provider)."
    Just name -> send ("Default target: " <> name)
  pure ctx

executeSlashCommand env (CmdTargetDefault (Just name)) ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  pureclawDir <- getPureclawDir
  let configPath = pureclawDir </> "config.toml"
  Dir.createDirectoryIfMissing True pureclawDir
  if name == "provider"
    then do
      updateDefaultsConfig configPath Keep Clear
      send "Default target cleared (will use provider)."
    else do
      updateDefaultsConfig configPath Keep (Set name)
      send ("Default target set to: " <> name)
  pure ctx

executeSlashCommand env (CmdTarget Nothing) ctx = do
  target <- readIORef (_env_target env)
  mModel <- readIORef (_env_model env)
  let desc = case target of
        TargetProvider    -> "model: " <> maybe "(not set)" unModelId mModel
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
      -- Validate the name is a known model before accepting it.
      mProvider <- readIORef (_env_provider env)
      models <- case mProvider of
        Nothing -> pure []
        Just provider -> listModels provider
      if ModelId name `elem` models
        then do
          writeIORef (_env_target env) TargetProvider
          writeIORef (_env_model env) (Just (ModelId name))
          pureclawDir <- getPureclawDir
          let configPath = pureclawDir </> "config.toml"
          existing <- loadFileConfig configPath
          Dir.createDirectoryIfMissing True pureclawDir
          writeFileConfig configPath (existing { _fc_model = Just name })
          send $ "Target switched to model: " <> name
        else do
          let harnessNames = if Map.null harnesses
                then ""
                else "\nRunning harnesses: " <> T.intercalate ", " (Map.keys harnesses)
              modelNames = if null models
                then "\nNo models available (provider not configured?)"
                else "\nAvailable models: " <> T.intercalate ", " (map unModelId models)
          send $ "Unknown target: \"" <> name <> "\"." <> harnessNames <> modelNames
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
      mModel <- readIORef (_env_model env)
      case mModel of
        Nothing -> do
          _ch_send (_env_channel env) (OutgoingMessage "Cannot compact: no model configured.")
          pure ctx
        Just model -> do
          (ctx', result) <- compactContext
            provider
            model
            0
            defaultKeepRecent
            ctx
          case result of
            Compacted o n summaryText -> do
              -- Record the compaction summary to the transcript so it
              -- survives a gateway restart.  The metadata key marks this
              -- entry as a compaction boundary; loadRecentMessages will
              -- only replay entries from the last such boundary forward.
              th <- envTranscript env
              now <- Time.getCurrentTime
              let entry = TranscriptEntry
                    { _te_id            = "compaction-" <> T.pack (show now)
                    , _te_timestamp     = now
                    , _te_harness       = Nothing
                    , _te_model         = Nothing
                    , _te_direction     = Request
                    , _te_payload       = summaryText
                    , _te_durationMs    = Nothing
                    , _te_correlationId = "compaction"
                    , _te_metadata      = Map.singleton compactionMetadataKey
                                            (Aeson.Bool True)
                    }
              _th_record th entry
              _th_flush th
              let msg = "Compacted: " <> T.pack (show o)
                        <> " messages \x2192 " <> T.pack (show n)
              _ch_send (_env_channel env) (OutgoingMessage msg)
              pure ctx'
            NotNeeded -> do
              _ch_send (_env_channel env) (OutgoingMessage "Nothing to compact (too few messages).")
              pure ctx
            CompactionError e -> do
              _ch_send (_env_channel env) (OutgoingMessage ("Compaction failed: " <> e))
              pure ctx

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

executeSlashCommand env (CmdMcp sub) ctx = do
  executeMcpCommand env sub ctx

-- | Tabbed Chat @\/tab*@ fallback handler.
--
-- The canonical @\/tab*@ surface is owned by
-- 'PureClaw.Routing.Dispatcher.dispatchTab' (WU9) — the dispatcher
-- intercepts every 'CmdTab' before it reaches this executor, so
-- production paths NEVER call this branch.
--
-- This case remains as a defensive fallback for two situations:
-- (1) a slash-command executor is driven outside the tabbed dispatcher
-- and the user typed a @\/tab*@ command; (2) an AI tab loop somehow
-- received a 'CmdTab' via '_tabHandle_enqueueSlash' (the I5 path) —
-- defensive coverage.
executeSlashCommand env (CmdTab _) ctx = do
  _ch_send (_env_channel env)
    (OutgoingMessage
       "Tab commands require the tabbed-chat dispatcher \
       \(PureClaw.Routing.Dispatcher.runDispatcher).")
  pure ctx

-- | Fallback arm for @\/bg@ when no dispatcher is in scope. The real
-- background-session handling lives in the tabbed-chat dispatcher
-- (issue #52, WU3); when a slash-command executor runs without that
-- dispatcher to spawn a fresh session, we emit an explanatory
-- message and leave the context unchanged. This arm is
-- correctness-mandatory: @-Wincomplete-patterns@ is off in this
-- project, so omitting it compiles clean and then crashes at runtime.
executeSlashCommand env (CmdBg _) ctx = do
  _ch_send (_env_channel env)
    (OutgoingMessage
       "Background tasks (/bg) require the tabbed-chat dispatcher \
       \(PureClaw.Routing.Dispatcher.runDispatcher).")
  pure ctx

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

-- ---------------------------------------------------------------------------
-- MCP commands
-- ---------------------------------------------------------------------------

executeMcpCommand :: AgentEnv -> McpSubCommand -> Context -> IO Context
executeMcpCommand env (McpConnect name cmdArgs) ctx = do
  let channel = _env_channel env
      logger  = _env_logger env
  servers <- readIORef (_env_mcpServers env)
  if Map.member name servers
    then do
      _ch_send channel (OutgoingMessage $
        "MCP server \"" <> name <> "\" is already connected. Disconnect it first with /mcp disconnect " <> name)
      pure ctx
    else do
      case cmdArgs of
        [] -> do
          _ch_send channel (OutgoingMessage
            "Usage: /mcp connect <name> <command> [args...]")
          pure ctx
        (cmdText : argTexts) -> do
          let cmd  = T.unpack cmdText
              args = map T.unpack argTexts
          result <- try @SomeException $
            MCP.connectServer logger name cmdArgs (proc cmd args)
          case result of
            Left e -> do
              _ch_send channel (OutgoingMessage $
                "Failed to connect to MCP server \"" <> name <> "\": " <> T.pack (show e))
              pure ctx
            Right server -> do
              atomicModifyIORef' (_env_mcpServers env) $ \m ->
                (Map.insert name server m, ())
              let toolNames = MCP.mcpToolNames server
                  toolList = T.intercalate ", " toolNames
              _ch_send channel (OutgoingMessage $
                "Connected to MCP server \"" <> name <> "\" ("
                <> T.pack (show (length toolNames)) <> " tools: " <> toolList <> ")")
              pure ctx

executeMcpCommand env (McpDisconnect name) ctx = do
  let channel = _env_channel env
      logger  = _env_logger env
  servers <- readIORef (_env_mcpServers env)
  case Map.lookup name servers of
    Nothing -> do
      _ch_send channel (OutgoingMessage $
        "No MCP server named \"" <> name <> "\" is connected.")
      pure ctx
    Just server -> do
      MCP.disconnectServer logger server
      atomicModifyIORef' (_env_mcpServers env) $ \m ->
        (Map.delete name m, ())
      _ch_send channel (OutgoingMessage $
        "Disconnected MCP server \"" <> name <> "\".")
      pure ctx

executeMcpCommand env McpList ctx = do
  let channel = _env_channel env
  servers <- readIORef (_env_mcpServers env)
  if Map.null servers
    then _ch_send channel (OutgoingMessage
           "No MCP servers connected. Use /mcp connect <name> <command...> to connect one.")
    else do
      let lines' = flip map (Map.toList servers) $ \(sName, server) ->
            let nTools = length (MCP.mcpToolNames server)
                cmd = T.intercalate " " (MCP._ms_command server)
            in "  " <> sName <> " (" <> T.pack (show nTools)
               <> " tools) \x2014 " <> cmd
          msg = "Connected MCP servers:\n" <> T.intercalate "\n" lines'
      _ch_send channel (OutgoingMessage msg)
  pure ctx

executeMcpCommand env (McpUnknown sub) ctx = do
  _ch_send (_env_channel env) (OutgoingMessage $
    "Unknown /mcp subcommand: " <> sub
    <> "\nAvailable: connect, disconnect, list")
  pure ctx

executeProviderCommand :: AgentEnv -> VaultHandle -> ProviderSubCommand -> Context -> IO Context
executeProviderCommand env _vault ProviderList ctx = do
  let send = _ch_send (_env_channel env) . OutgoingMessage
  mProvider <- readIORef (_env_provider env)
  mModel <- readIORef (_env_model env)
  let activeIndicator = case mProvider of
        Nothing -> "(not configured)"
        Just _  -> "active, model: " <> maybe "(not set)" unModelId mModel
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
      ollamaProvider <- if baseUrl == "http://localhost:11434"
        then mkOllamaProvider manager
        else mkOllamaProviderWithUrl manager (T.unpack baseUrl)
      writeIORef (_env_provider env) (Just (MkProvider ollamaProvider))
      writeIORef (_env_model env) (Just (ModelId model))
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
  th <- envTranscript env
  case sub of
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
      if null path
        then send "No transcript configured."
        else send (T.pack path)
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
      th <- envTranscript env
      let logger = _env_logger env
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
      -- Assign a window index and build the unique harness key (display-only).
      -- The durable identity is the @pcl_id stamped by the spawn path; the
      -- window name (harnessKey) stays the legacy canonical-<idx> convention.
      windowIdx <- readIORef (_env_nextWindowIdx env)
      let canonical  = Data.Maybe.fromMaybe name (resolveHarnessName name)
          harnessKey = canonical <> "-" <> T.pack (show windowIdx)
          harnessSession = "pureclaw"
      result <- startHarnessByName (_env_policy env) th harnessSession name
                  harnessKey windowIdx resolvedDir skipPerms (_env_harnessRegistry env)
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
        Right (_hid, hh, _mUuid) -> do
          -- D-ADD-2: the spawn path already registered the HarnessId entry; sync
          -- the legacy name-keyed map so legacy consumers keep working. The
          -- minted claude-code session uuid (_mUuid) is not persisted on this
          -- CLI '/harness start' path — there is no session.json to write it
          -- into. The optional JSONL log view (WU7) is a frontend-only feature,
          -- so a CLI-only spawn intentionally does not correlate a log file.
          -- window is created already named harnessKey (addHarnessWindowNamed),
          -- so no separate rename is needed.
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

    AgentDefault Nothing -> do
      fileCfg <- loadConfig
      case _fc_defaultAgent fileCfg of
        Nothing -> send "No default agent set. Use /agent default <name> to set one."
        Just name -> send ("Default agent: " <> name)
      pure ctx

    AgentDefault (Just name) -> do
      -- Validate that the agent exists before persisting.
      case AgentDef.mkAgentName name of
        Left _ -> do
          send ("Invalid agent name: \"" <> name <> "\".")
          pure ctx
        Right validName -> do
          agentsDir <- getAgentsDir
          mDef <- AgentDef.loadAgent agentsDir validName
          case mDef of
            Nothing -> do
              send ("Agent \"" <> name <> "\" not found.")
              pure ctx
            Just _ -> do
              pureclawDir <- getPureclawDir
              let configPath = pureclawDir </> "config.toml"
              Dir.createDirectoryIfMissing True pureclawDir
              updateDefaultsConfig configPath (Set name) Keep
              send ("Default agent set to: " <> name)
              pure ctx

    AgentUnknown subcmd
      | T.null subcmd -> do
          send (T.intercalate "\n"
            [ "Agent commands:"
            , "  /agent list"
            , "  /agent info [<name>]"
            , "  /agent default [<name>]"
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
-- @/agent info@ without needing IO. When the prefix is empty, all
-- candidates are returned.
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
    SessionNew mAgent mTargetName -> do
      -- WU-11 C4: emit deprecation notice
      _ch_send (_env_channel env)
        (OutgoingMessage
           "\x26a0 /session new is deprecated. Use /tab new provider instead.")
      -- Resolve agent: explicit arg > config default > None
      fileCfg <- loadConfig
      let agentName = mAgent <|> _fc_defaultAgent fileCfg
      -- Resolve target: --target flag > config default > provider
      let effectiveTarget = case mTargetName of
            Just t  -> Just t
            Nothing -> _fc_defaultTarget fileCfg
      -- Validate harness if targeting one
      case effectiveTarget of
        Just name | name /= "provider" -> do
          harnesses <- readIORef (_env_harnesses env)
          case Map.lookup name harnesses of
            Nothing -> do
              send ("Target \"" <> name <> "\" is not running. "
                    <> "Start it first with /harness start " <> name)
              pure ctx
            Just _ -> createSession env ctx agentName
                        (SessionTypes.SkHarness (SessionTypes.HarnessSpec
                          (SessionTypes.fixedFlavourLookup name)
                          (SessionTypes.TbTmux (SessionTypes.TmuxConfig name name Nothing))
                          Nothing [] Nothing Nothing Nothing))
        _ -> createSession env ctx agentName
               (SessionTypes.SkProvider (SessionTypes.ProviderSpec
                 (SessionTypes.inferProviderId "") (ModelId "") Nothing))

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
          eHandle <- Session.resumeSession
                       (_env_broker env) (_env_logger env) sessionsDir sid
          case eHandle of
            Left err -> do
              send ("Failed to resume session: " <> T.pack (show err))
              pure ctx
            Right newHandle -> do
              writeIORef (_env_session env) newHandle
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
          eHandle <- Session.resumeSession
                       (_env_broker env) (_env_logger env) sessionsDir sid
          case eHandle of
            Left err -> do
              send ("Failed to resume session: " <> T.pack (show err))
              pure ctx
            Right newHandle -> do
              writeIORef (_env_session env) newHandle
              send ("Resumed session " <> unSessionId sid)
              pure ctx

    SessionInfo -> do
      activeSession <- readIORef (_env_session env)
      meta <- readIORef (_sh_meta activeSession)
      mModel <- readIORef (_env_model env)
      target <- readIORef (_env_target env)
      let sidLine    = "  Session: " <> unSessionId (_sm_id meta)
          agentLine  = case _sm_agent meta of
            Nothing -> "  Agent:   (no agent)"
            Just a  -> "  Agent:   " <> AgentDef.unAgentName a
          runtimeLine = "  Runtime: " <> SessionTypes.sessionKindToText (_sm_kind meta)
          targetLine = case target of
            TargetProvider     -> "  Target:  model: " <> maybe "(not set)" unModelId mModel
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

    SessionCompact -> executeSlashCommand env CmdCompact ctx

    SessionUnknown subcmd
      | T.null subcmd -> do
          send (T.intercalate "\n"
            [ "Session commands:"
            , "  /session new [<agent>] [--target <name>]"
            , "  /session list [<agent>]"
            , "  /session resume <id>"
            , "  /session last"
            , "  /session info"
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
    _sm_kind = SessionTypes._sm_kind

    -- | Shared helper: create a new on-disk session with the given kind,
    -- swap it into '_env_session', set '_env_target' to match, and return a
    -- fresh context. When an agent name is given, validates it, records it
    -- in session metadata, and loads its system prompt into the new context.
    createSession envS ctxS mAgentText kind = do
      let sendS = _ch_send (_env_channel envS) . OutgoingMessage
      -- Resolve the agent name, if given.
      mValidAgent <- case mAgentText of
        Nothing -> pure (Right Nothing)
        Just raw -> case AgentDef.mkAgentName raw of
          Left _ -> pure (Left ("Invalid agent name: \"" <> raw <> "\"."))
          Right validName -> do
            agentsDir <- getAgentsDir
            mDef <- AgentDef.loadAgent agentsDir validName
            case mDef of
              Nothing -> pure (Left ("Agent \"" <> raw <> "\" not found."))
              Just _def -> pure (Right (Just validName))
      case mValidAgent of
        Left err -> do
          sendS err
          pure ctxS
        Right mAgent -> do
          -- Compose the agent's system prompt if an agent was resolved.
          mSysPrompt <- case mAgent of
            Nothing -> pure Nothing
            Just agentName -> do
              agentsDir <- getAgentsDir
              mDef <- AgentDef.loadAgent agentsDir agentName
              case mDef of
                Nothing -> pure Nothing
                Just def -> Just <$> AgentDef.composeAgentPrompt (_env_logger envS) def 8000
          sessionsDir <- getSessionsDir
          Dir.createDirectoryIfMissing True sessionsDir
          now <- Time.getCurrentTime
          let sid = SessionTypes.newSessionId Nothing now
              meta = SessionTypes.SessionMeta
                { SessionTypes._sm_id                = sid
                , SessionTypes._sm_agent             = mAgent
                , SessionTypes._sm_kind              = kind
                , SessionTypes._sm_model             = ""
                , SessionTypes._sm_channel           = ""
                , SessionTypes._sm_createdAt         = now
                , SessionTypes._sm_lastActive        = now
                , SessionTypes._sm_bootstrapConsumed = False
                , SessionTypes._sm_archived          = False
                , SessionTypes._sm_description       = Nothing
                , SessionTypes._sm_autoSummary       = Nothing
                , SessionTypes._sm_source            = Nothing
                }
          newHandle <- Session.mkSessionHandle
                         (_env_broker envS) (_env_logger envS) sessionsDir meta
          writeIORef (_env_session envS) newHandle
          writeIORef (_env_target envS) (SessionTypes.defaultTarget kind)
          let agentMsg = case mAgent of
                Nothing -> ""
                Just a  -> "\nAgent: " <> AgentDef.unAgentName a
              runtimeMsg = case kind of
                SessionTypes.SkProvider _  -> ""
                SessionTypes.SkHarness _   -> "\nTarget: harness:" <> SessionTypes.sessionKindToText kind
              -- Use the agent's system prompt if available, otherwise
              -- carry forward the existing context's system prompt.
              newSysPrompt = mSysPrompt <|> contextSystemPrompt ctxS
          sendS ("New session created: " <> unSessionId sid
                <> "\nSession cleared. Starting fresh." <> agentMsg <> runtimeMsg)
          pure (emptyContext newSysPrompt)

-- | Known harnesses: (canonical name, aliases, description).
knownHarnesses :: [(Text, [Text], Text)]
knownHarnesses =
  [ ("claude-code", ["claude", "cc"], "Anthropic Claude Code CLI")
  ]

-- | Start a harness by name or alias.
--
-- Threads the tmux @session@ and the @windowName@ (display-only, the
-- @canonical-\<idx\>@ convention) through to 'mkClaudeCodeHarness', which stamps
-- the durable @\@pcl_id@ identity, records the shell+harness PIDs, and registers
-- a @Spawned@ entry in the supplied 'HarnessRegistry' (D4.2). On success it
-- returns the generated 'HarnessId' alongside the handle so the caller can
-- persist the identity and keep the legacy name-keyed map in sync (D-ADD-2).
--
-- WU6 (JSONL log correlation): for the @claude-code@ flavour we mint a fresh
-- canonical 'ClaudeSessionUuid' and inject it as @--session-id \<uuid\>@ into
-- the spawned @claude@ argv (via 'claudeCodeExtraArgs', through the EXISTING
-- @[Text]@ args — the @_ccd_addWindow@ seam is not widened). The SAME minted
-- uuid text is returned as the third tuple element so the caller can persist it
-- into '_h_claudeSessionUuid'; this guarantees the persisted uuid matches the
-- one claude-code writes its on-disk JSONL log under. Non-@claude-code@ spawns
-- mint nothing and return 'Nothing'.
startHarnessByName
  :: SecurityPolicy
  -> TranscriptHandle
  -> Text             -- ^ tmux session name (default @"pureclaw"@)
  -> Text             -- ^ harness name or alias (for flavour resolution, e.g. @cc@)
  -> Text             -- ^ tmux window name (display-only, e.g. @claude-code-0@)
  -> Int              -- ^ tmux window index (placement hint)
  -> Maybe FilePath   -- ^ optional working directory
  -> Bool             -- ^ skip permission checks
  -> Registry.HarnessRegistry
  -> IO (Either HarnessError (Registry.HarnessId, HarnessHandle, Maybe Text))
startHarnessByName policy th session name windowName windowIdx mWorkDir skipPerms reg =
  case resolveHarnessName name of
    Just "claude-code" -> do
      -- Mint ONCE: the same value is injected into the argv (below) and
      -- returned to the caller for persistence — they cannot diverge.
      uuid <- mintClaudeSessionUuid
      let uuidText  = unClaudeSessionUuid uuid
          extraArgs = claudeCodeExtraArgs skipPerms (Just uuidText)
      result <- mkClaudeCodeHarness policy th session windowName windowIdx
                  mWorkDir extraArgs reg
      pure (fmap (\(hid, hh) -> (hid, hh, Just uuidText)) result)
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
  handles <- mapM (\(name, _idx, canonical) -> do
    hh <- mkHandle canonical name
    pure (name, hh)) discovered
  let harnessMap = Map.fromList handles
      nextIdx = if null discovered
        then 0
        else maximum [idx | (_, idx, _) <- discovered] + 1
  pure (harnessMap, nextIdx)
  where
    -- Reconstruct a name-targeting handle for an existing window. The window
    -- name (e.g. @claude-code-0@) is the durable target now that the harness
    -- ops address @(session, windowName)@ (WU1/WU4).
    mkHandle :: Text -> Text -> IO HarnessHandle
    mkHandle canonical windowName = case canonical of
      "claude-code" -> mkDiscoveredClaudeCodeHandle th session windowName
      -- Future harness types go here
      _             -> mkDiscoveredClaudeCodeHandle th session windowName  -- fallback

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
