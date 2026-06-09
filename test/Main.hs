module Main where

import Test.Hspec

import qualified Auth.AnthropicOAuthSpec
import qualified Core.TypesSpec
import qualified Core.MessageSourceSpec
import qualified Core.ErrorsSpec
import qualified Core.ConfigSpec
import qualified Security.SecretsSpec
import qualified Security.PolicySpec
import qualified Security.PathSpec
import qualified Security.CommandSpec
import qualified Security.AdoptionSpec
import qualified Handles.LogSpec
import qualified Handles.FileSpec
import qualified Handles.ShellSpec
import qualified Handles.NetworkSpec
import qualified Handles.MemorySpec
import qualified Handles.ChannelSpec
import qualified Handles.BackendSpec
import qualified Backend.LocalSpec
import qualified Backend.PtySpec
import qualified Backend.SSHSpec
import qualified Backend.TmuxSpec
import qualified Internal.RedactSpec
import qualified Internal.ShellQuoteSpec
import qualified Providers.ClassSpec
import qualified Agent.AgentDefSpec
import qualified Agent.CompletionSpec
import qualified Agent.ContextSpec
import qualified Providers.AnthropicSpec
import qualified Agent.LoopSpec
import qualified Channels.CLISpec
import qualified CLI.CommandsSpec
import qualified CLI.ConfigSpec
import qualified CLI.ImportSpec
import qualified Tools.RegistrySpec
import qualified Tools.ShellSpec
import qualified Tools.FileReadSpec
import qualified Tools.GitSpec
import qualified Tools.MemorySpec
import qualified Tools.FileWriteSpec
import qualified Tools.EditSpec
import qualified Tools.ProcessSpec
import qualified Handles.ProcessSpec
import qualified Tools.WebSearchSpec
import qualified Tools.MessageSpec
import qualified Tools.CronSpec
import qualified Tools.ImageSpec
import qualified Tools.SearchFilesSpec
import qualified Tools.ClarifySpec
import qualified Tools.WebExtractSpec
import qualified Tools.PatchSpec
import qualified Tools.DelegateSpec
import qualified Tools.TodoSpec
import qualified Tools.ExecuteCodeSpec
import qualified Tools.SessionSearchSpec
import qualified Memory.NoneSpec
import qualified Memory.MarkdownSpec
import qualified Memory.SQLiteSpec
import qualified Agent.MemorySpec
import qualified Agent.CompactionSpec
import qualified Agent.ContextTrackerSpec
import qualified Agent.SlashCommandsSpec
import qualified Providers.OpenAISpec
import qualified Providers.OllamaSpec
import qualified Providers.OpenRouterSpec
import qualified Security.CryptoSpec
import qualified Security.PairingSpec
import qualified Security.VaultAgeSpec
import qualified Security.VaultPassphraseSpec
import qualified Security.VaultPluginSpec
import qualified Security.VaultSpec
import qualified Gateway.AuthSpec
import qualified Gateway.RoutesSpec
import qualified Gateway.ServerSpec
import qualified Channels.AllowListSpec
import qualified Channels.ClassSpec
import qualified Channels.TelegramSpec
import qualified Channels.SignalSpec
import qualified Channels.SignalTransportSpec
import qualified Agent.IdentitySpec
import qualified Scheduler.CronSpec
import qualified Scheduler.HeartbeatSpec
import qualified Integration.SignalFlowSpec
import qualified Integration.CLISpec
import qualified Integration.ImportRoundTripSpec
import qualified Transcript.TypesSpec
import qualified Handles.TranscriptSpec
import qualified Handles.HarnessSpec
import qualified Harness.ClaudeCodeSpec
import qualified Harness.ClaudeLogConvertSpec
import qualified Harness.ClaudeLogPathSpec
import qualified Harness.ClaudeSessionSpec
import qualified Harness.DiscoverySpec
import qualified Harness.JsonlTailSpec
import qualified Harness.ReconcileSpec
import qualified Harness.RegistrySpec
import qualified Harness.TmuxSpec
import qualified Transcript.CombinatorSpec
import qualified Transcript.ProviderSpec
import qualified Session.TypesSpec
import qualified Session.HandleSpec

-- WU2 (Session.Kind leaf module)
import qualified Session.KindSpec

-- WU1 (frontend server settings + CORS)
import qualified Frontend.ServerSpec

-- WU-7 (POST /api/tabs/new unified endpoint)
import qualified Frontend.APISpec

-- WU0 (tabbed-chat) red-phase scaffold specs
import qualified Routing.ParseSpec
import qualified Routing.ConfigSpec
import qualified Onboarding.StartSpec
-- Tabs-as-View (GitHub #79) WU1
import qualified Tabs.TypesSpec
-- Tabs-as-View (GitHub #79) WU2
import qualified Tabs.CursorSpec
-- Tabs-as-View (GitHub #79) WU3
import qualified Tabs.PersistSpec
-- Tabs-as-View (GitHub #79) WU5
import qualified Tabs.SessionPoolSpec
-- Tabs-as-View (GitHub #79) WU6
import qualified Tabs.WizardSpec
-- Tabs-as-View (GitHub #79) WU7
import qualified Tabs.RelaySpec
-- WU1 (live transcript streaming)
import qualified Frontend.StreamBrokerSpec
-- WU2 (broadcasting transcript decorator)
import qualified Frontend.BroadcastingTranscriptSpec
-- WU3 (WS endpoint + wire protocol + Origin/cap enforcement)
import qualified Frontend.StreamSpec
-- WU3b (wire-protocol golden fixtures + WS integration tests)
import qualified Frontend.StreamGoldensSpec
import qualified Frontend.StreamIntegrationSpec
-- WU4 (activity probe loop)
import qualified Frontend.ActivityProbeSpec
-- Frontend.APISpec is already imported at the top of this block (from main)

-- WU-10 (Container + Local harness factory arms)
import qualified Tab.ContainerSpec

-- WU9 (HPureClaw depth limit)
import qualified Routing.DepthLimitSpec

main :: IO ()
main = hspec $ do
  describe "Auth.AnthropicOAuth" Auth.AnthropicOAuthSpec.spec
  describe "Core.Types" Core.TypesSpec.spec
  describe "Core.MessageSource" Core.MessageSourceSpec.spec
  describe "Core.Errors" Core.ErrorsSpec.spec
  describe "Core.Config" Core.ConfigSpec.spec
  describe "Security.Secrets" Security.SecretsSpec.spec
  describe "Security.Policy" Security.PolicySpec.spec
  describe "Security.Path" Security.PathSpec.spec
  describe "Security.Command" Security.CommandSpec.spec
  describe "Security.Adoption" Security.AdoptionSpec.spec
  describe "Handles.Log" Handles.LogSpec.spec
  describe "Handles.File" Handles.FileSpec.spec
  describe "Handles.Shell" Handles.ShellSpec.spec
  describe "Handles.Network" Handles.NetworkSpec.spec
  describe "Handles.Memory" Handles.MemorySpec.spec
  describe "Handles.Channel" Handles.ChannelSpec.spec
  describe "Handles.Backend" Handles.BackendSpec.spec
  describe "Backend.Local" Backend.LocalSpec.spec
  describe "Backend.Pty" Backend.PtySpec.spec
  describe "Backend.SSH" Backend.SSHSpec.spec
  describe "Backend.Tmux" Backend.TmuxSpec.spec
  describe "Internal.Redact" Internal.RedactSpec.spec
  describe "Internal.ShellQuote" Internal.ShellQuoteSpec.spec
  describe "Providers.Class" Providers.ClassSpec.spec
  describe "Agent.AgentDef" Agent.AgentDefSpec.spec
  describe "Agent.Context" Agent.ContextSpec.spec
  describe "Agent.Completion" Agent.CompletionSpec.spec
  describe "Providers.Anthropic" Providers.AnthropicSpec.spec
  describe "Agent.Loop" Agent.LoopSpec.spec
  describe "Channels.CLI" Channels.CLISpec.spec
  describe "CLI.Commands" CLI.CommandsSpec.spec
  describe "CLI.Config" CLI.ConfigSpec.spec
  describe "CLI.Import" CLI.ImportSpec.spec
  describe "Tools.Registry" Tools.RegistrySpec.spec
  describe "Tools.Shell" Tools.ShellSpec.spec
  describe "Tools.FileRead" Tools.FileReadSpec.spec
  describe "Tools.Git" Tools.GitSpec.spec
  describe "Tools.Memory" Tools.MemorySpec.spec
  describe "Tools.FileWrite" Tools.FileWriteSpec.spec
  describe "Tools.Edit" Tools.EditSpec.spec
  describe "Tools.Process" Tools.ProcessSpec.spec
  describe "Handles.Process" Handles.ProcessSpec.spec
  describe "Tools.WebSearch" Tools.WebSearchSpec.spec
  describe "Tools.Message" Tools.MessageSpec.spec
  describe "Tools.Cron" Tools.CronSpec.spec
  describe "Tools.Image" Tools.ImageSpec.spec
  describe "Tools.SearchFiles" Tools.SearchFilesSpec.spec
  describe "Tools.Clarify" Tools.ClarifySpec.spec
  describe "Tools.WebExtract" Tools.WebExtractSpec.spec
  describe "Tools.Patch" Tools.PatchSpec.spec
  describe "Tools.Delegate" Tools.DelegateSpec.spec
  describe "Tools.Todo" Tools.TodoSpec.spec
  describe "Tools.ExecuteCode" Tools.ExecuteCodeSpec.spec
  describe "Tools.SessionSearch" Tools.SessionSearchSpec.spec
  describe "Memory.None" Memory.NoneSpec.spec
  describe "Memory.Markdown" Memory.MarkdownSpec.spec
  describe "Memory.SQLite" Memory.SQLiteSpec.spec
  describe "Agent.Memory" Agent.MemorySpec.spec
  describe "Agent.Compaction" Agent.CompactionSpec.spec
  describe "Agent.ContextTracker" Agent.ContextTrackerSpec.spec
  describe "Agent.SlashCommands" Agent.SlashCommandsSpec.spec
  describe "Providers.OpenAI" Providers.OpenAISpec.spec
  describe "Providers.Ollama" Providers.OllamaSpec.spec
  describe "Providers.OpenRouter" Providers.OpenRouterSpec.spec
  describe "Security.Crypto" Security.CryptoSpec.spec
  describe "Security.Pairing" Security.PairingSpec.spec
  describe "Security.VaultAge" Security.VaultAgeSpec.spec
  describe "Security.VaultPassphrase" Security.VaultPassphraseSpec.spec
  describe "Security.VaultPlugin" Security.VaultPluginSpec.spec
  describe "Security.Vault" Security.VaultSpec.spec
  describe "Gateway.Auth" Gateway.AuthSpec.spec
  describe "Gateway.Routes" Gateway.RoutesSpec.spec
  describe "Gateway.Server" Gateway.ServerSpec.spec
  describe "Channels.AllowList" Channels.AllowListSpec.spec
  describe "Channels.Class" Channels.ClassSpec.spec
  describe "Channels.Telegram" Channels.TelegramSpec.spec
  describe "Channels.Signal" Channels.SignalSpec.spec
  describe "Channels.Signal.Transport" Channels.SignalTransportSpec.spec
  describe "Agent.Identity" Agent.IdentitySpec.spec
  describe "Scheduler.Cron" Scheduler.CronSpec.spec
  describe "Scheduler.Heartbeat" Scheduler.HeartbeatSpec.spec
  describe "Integration.SignalFlow" Integration.SignalFlowSpec.spec
  describe "Integration.CLI" Integration.CLISpec.spec
  describe "Integration.ImportRoundTrip" Integration.ImportRoundTripSpec.spec
  describe "Transcript.Types" Transcript.TypesSpec.spec
  describe "Handles.Transcript" Handles.TranscriptSpec.spec
  describe "Handles.Harness" Handles.HarnessSpec.spec
  describe "Harness.ClaudeCode" Harness.ClaudeCodeSpec.spec
  describe "Harness.ClaudeLogConvert" Harness.ClaudeLogConvertSpec.spec
  describe "Harness.ClaudeLogPath" Harness.ClaudeLogPathSpec.spec
  describe "Harness.ClaudeSession" Harness.ClaudeSessionSpec.spec
  describe "Harness.Discovery" Harness.DiscoverySpec.spec
  describe "Harness.JsonlTail" Harness.JsonlTailSpec.spec
  describe "Harness.Reconcile" Harness.ReconcileSpec.spec
  describe "Harness.Registry" Harness.RegistrySpec.spec
  describe "Harness.Tmux" Harness.TmuxSpec.spec
  describe "Transcript.Combinator" Transcript.CombinatorSpec.spec
  describe "Transcript.Provider" Transcript.ProviderSpec.spec
  describe "Session.Types" Session.TypesSpec.spec
  describe "Session.Handle" Session.HandleSpec.spec
  -- WU2 (Session.Kind leaf module)
  describe "Session.Kind"         Session.KindSpec.spec
  -- WU1 (frontend server settings + CORS)
  describe "Frontend.Server"      Frontend.ServerSpec.spec
  -- WU-7 (POST /api/tabs/new unified endpoint)
  describe "Frontend.API"          Frontend.APISpec.spec
  -- WU0 (tabbed-chat) red-phase scaffold specs
  describe "Routing.Parse"        Routing.ParseSpec.spec
  describe "Routing.Config"       Routing.ConfigSpec.spec
  describe "Onboarding.Start"     Onboarding.StartSpec.spec
  -- Tabs-as-View (GitHub #79) WU1
  describe "Tabs.Types"           Tabs.TypesSpec.spec
  -- Tabs-as-View (GitHub #79) WU2
  describe "Tabs.Cursor"          Tabs.CursorSpec.spec
  -- Tabs-as-View (GitHub #79) WU3
  describe "Tabs.Persist"         Tabs.PersistSpec.spec
  -- Tabs-as-View (GitHub #79) WU5
  describe "Tabs.SessionPool"     Tabs.SessionPoolSpec.spec
  -- Tabs-as-View (GitHub #79) WU6
  describe "Tabs.Wizard"          Tabs.WizardSpec.spec
  -- Tabs-as-View (GitHub #79) WU7
  describe "Tabs.Relay"           Tabs.RelaySpec.spec
  -- WU1 (live transcript streaming)
  describe "Frontend.StreamBroker" Frontend.StreamBrokerSpec.spec
  -- WU2 (broadcasting transcript decorator)
  describe "Frontend.BroadcastingTranscript"
    Frontend.BroadcastingTranscriptSpec.spec
  -- WU3 (WS endpoint + wire protocol)
  describe "Frontend.Stream" Frontend.StreamSpec.spec
  -- WU3b (wire-protocol golden fixtures + WS integration tests)
  describe "Frontend.StreamGoldens" Frontend.StreamGoldensSpec.spec
  describe "Frontend.StreamIntegration" Frontend.StreamIntegrationSpec.spec
  -- WU4 (activity probe loop)
  describe "Frontend.ActivityProbe" Frontend.ActivityProbeSpec.spec
  -- Frontend.APISpec is registered earlier (from main's WU-7 unified endpoint)
  -- WU9 (HPureClaw depth limit)
  describe "Routing.DepthLimit"  Routing.DepthLimitSpec.spec
  -- WU-10 (Container + Local harness factory arms)
  describe "Tab.Container"      Tab.ContainerSpec.spec
