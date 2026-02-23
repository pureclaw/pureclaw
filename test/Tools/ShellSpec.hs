module Tools.ShellSpec (spec) where

import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import System.Exit
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Shell
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Tools.Registry
import PureClaw.Tools.Shell

spec :: Spec
spec = do
  describe "shellTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = shellTool defaultPolicy mkNoOpShellHandle
      _td_name def' `shouldBe` "shell"

    it "rejects commands when policy denies all" $ do
      let (_, handler) = shellTool defaultPolicy mkNoOpShellHandle
          input = object ["command" .= ("ls" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "denied"

    it "executes allowed commands" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "echo") defaultPolicy
          mockShell = ShellHandle $ \_ -> pure ProcessResult
            { _pr_exitCode = ExitSuccess
            , _pr_stdout   = BS8.pack "hello world"
            , _pr_stderr   = ""
            }
          (_, handler) = shellTool policy mockShell
          input = object ["command" .= ("echo hello world" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "hello world"

    it "reports non-zero exit codes" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "false") defaultPolicy
          mockShell = ShellHandle $ \_ -> pure ProcessResult
            { _pr_exitCode = ExitFailure 1
            , _pr_stdout   = ""
            , _pr_stderr   = BS8.pack "error"
            }
          (_, handler) = shellTool policy mockShell
          input = object ["command" .= ("false" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Exit code: 1"

    it "rejects empty commands" $ do
      let (_, handler) = shellTool defaultPolicy mkNoOpShellHandle
          input = object ["command" .= ("" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "rejects commands not in the allowed set" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "echo") defaultPolicy
          (_, handler) = shellTool policy mkNoOpShellHandle
          input = object ["command" .= ("rm -rf /" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not allowed"
