module Main where

import Test.Hspec

import qualified Core.TypesSpec
import qualified Core.ErrorsSpec
import qualified Core.ConfigSpec
import qualified Security.SecretsSpec
import qualified Security.PolicySpec
import qualified Security.PathSpec
import qualified Security.CommandSpec
import qualified Handles.LogSpec
import qualified Handles.FileSpec
import qualified Handles.ShellSpec
import qualified Handles.NetworkSpec
import qualified Handles.MemorySpec
import qualified Handles.ChannelSpec
import qualified Providers.ClassSpec
import qualified Agent.ContextSpec
import qualified Providers.AnthropicSpec
import qualified Agent.LoopSpec
import qualified Channels.CLISpec
import qualified CLI.CommandsSpec

main :: IO ()
main = hspec $ do
  describe "Core.Types" Core.TypesSpec.spec
  describe "Core.Errors" Core.ErrorsSpec.spec
  describe "Core.Config" Core.ConfigSpec.spec
  describe "Security.Secrets" Security.SecretsSpec.spec
  describe "Security.Policy" Security.PolicySpec.spec
  describe "Security.Path" Security.PathSpec.spec
  describe "Security.Command" Security.CommandSpec.spec
  describe "Handles.Log" Handles.LogSpec.spec
  describe "Handles.File" Handles.FileSpec.spec
  describe "Handles.Shell" Handles.ShellSpec.spec
  describe "Handles.Network" Handles.NetworkSpec.spec
  describe "Handles.Memory" Handles.MemorySpec.spec
  describe "Handles.Channel" Handles.ChannelSpec.spec
  describe "Providers.Class" Providers.ClassSpec.spec
  describe "Agent.Context" Agent.ContextSpec.spec
  describe "Providers.Anthropic" Providers.AnthropicSpec.spec
  describe "Agent.Loop" Agent.LoopSpec.spec
  describe "Channels.CLI" Channels.CLISpec.spec
  describe "CLI.Commands" CLI.CommandsSpec.spec
