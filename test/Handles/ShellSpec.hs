module Handles.ShellSpec (spec) where

import Data.ByteString.Char8 qualified as BS8
import System.Exit
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Log
import PureClaw.Handles.Shell
import PureClaw.Security.Command
import PureClaw.Security.Policy

spec :: Spec
spec = do
  describe "mkShellHandle" $ do
    it "executes an authorized command and captures output" $ do
      let sh = mkShellHandle mkNoOpLogHandle
      case authorizeEcho of
        Left _ -> expectationFailure "authorize failed"
        Right cmd -> do
          result <- _sh_execute sh cmd
          _pr_exitCode result `shouldBe` ExitSuccess
          _pr_stdout result `shouldBe` "hello\n"
          _pr_stderr result `shouldBe` ""

    it "captures non-zero exit codes" $ do
      let sh = mkShellHandle mkNoOpLogHandle
      case authorizeFalse of
        Left _ -> expectationFailure "authorize failed"
        Right cmd -> do
          result <- _sh_execute sh cmd
          _pr_exitCode result `shouldBe` ExitFailure 1

    it "strips the subprocess environment" $ do
      let sh = mkShellHandle mkNoOpLogHandle
      case authorizeEnv of
        Left _ -> expectationFailure "authorize failed"
        Right cmd -> do
          result <- _sh_execute sh cmd
          _pr_exitCode result `shouldBe` ExitSuccess
          let outputLines = lines (BS8.unpack (_pr_stdout result))
          -- The subprocess should only have PATH from safeEnv
          outputLines `shouldSatisfy` any (isPrefixOfStr "PATH=")
          -- Should NOT have inherited HOME, USER, etc.
          outputLines `shouldSatisfy` (not . any (isPrefixOfStr "HOME="))

  describe "mkNoOpShellHandle" $ do
    it "returns ExitSuccess with empty output" $ do
      case authorizeEcho of
        Left _ -> expectationFailure "authorize failed"
        Right cmd -> do
          result <- _sh_execute mkNoOpShellHandle cmd
          _pr_exitCode result `shouldBe` ExitSuccess
          _pr_stdout result `shouldBe` ""
          _pr_stderr result `shouldBe` ""

  describe "ProcessResult" $ do
    it "has Show and Eq instances" $ do
      let r = ProcessResult ExitSuccess "out" "err"
      show r `shouldContain` "ExitSuccess"
      r `shouldBe` r

-- | Test policy that allows echo, false, and env commands.
testPolicy :: SecurityPolicy
testPolicy =
  withAutonomy Full
  $ allowCommand (CommandName "echo")
  $ allowCommand (CommandName "false")
  $ allowCommand (CommandName "env")
  $ defaultPolicy

authorizeEcho :: Either CommandError AuthorizedCommand
authorizeEcho = authorize testPolicy "/bin/echo" ["hello"]

authorizeFalse :: Either CommandError AuthorizedCommand
authorizeFalse = authorize testPolicy "/usr/bin/false" []

authorizeEnv :: Either CommandError AuthorizedCommand
authorizeEnv = authorize testPolicy "/usr/bin/env" []

isPrefixOfStr :: String -> String -> Bool
isPrefixOfStr [] _ = True
isPrefixOfStr _ [] = False
isPrefixOfStr (x:xs) (y:ys) = x == y && isPrefixOfStr xs ys
