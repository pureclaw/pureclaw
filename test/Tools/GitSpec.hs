module Tools.GitSpec (spec) where

import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import System.Exit
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Shell
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Tools.Git
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "gitTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = gitTool defaultPolicy mkNoOpShellHandle
      _td_name def' `shouldBe` "git"

    it "rejects when autonomy is Deny" $ do
      let (_, handler) = gitTool defaultPolicy mkNoOpShellHandle
          input = object ["subcommand" .= ("status" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "denied"

    it "executes git commands when allowed" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "git") defaultPolicy
          mockShell = ShellHandle $ \_ -> pure ProcessResult
            { _pr_exitCode = ExitSuccess
            , _pr_stdout   = BS8.pack "On branch main"
            , _pr_stderr   = ""
            }
          (_, handler) = gitTool policy mockShell
          input = object ["subcommand" .= ("status" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "On branch main"
