module Tools.ShellSpec (spec) where

import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
import Data.Text qualified as T
import System.Exit
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Shell
import PureClaw.Providers.Class
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Tools.Registry
import PureClaw.Tools.Shell

-- | Mock shell handle that records the AuthorizedCommand it was called
-- with and returns a fixed ProcessResult. Lets us inspect exactly which
-- argv reached the executor, which is the whole point of the
-- shell-vs-exec distinction.
mkRecordingShell :: ProcessResult -> IO (ShellHandle, IORef (Maybe (FilePath, [T.Text])))
mkRecordingShell pr = do
  ref <- newIORef Nothing
  let h = ShellHandle $ \_opts cmd -> do
        writeIORef ref (Just (getCommandProgram cmd, getCommandArgs cmd))
        pure pr
  pure (h, ref)

shellPolicy :: SecurityPolicy
shellPolicy = withAutonomy Full
            $ allowCommand (CommandName "shell") defaultPolicy

okResult :: BS8.ByteString -> ProcessResult
okResult out = ProcessResult { _pr_exitCode = ExitSuccess, _pr_stdout = out, _pr_stderr = "" }

spec :: Spec
spec = do
  describe "shellTool (bash -c)" $ do
    it "is named shell" $ do
      let (def', _) = shellTool defaultPolicy mkNoOpShellHandle
      _td_name def' `shouldBe` "shell"

    it "rejects when the policy does not list shell in the allowlist" $ do
      -- Autonomy=Full so the allowlist check is the one that fires.
      let policy       = withAutonomy Full defaultPolicy
          (_, handler) = shellTool policy mkNoOpShellHandle
          input        = object ["command" .= ("echo hi" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not enabled"

    it "rejects empty commands" $ do
      let (_, handler) = shellTool shellPolicy mkNoOpShellHandle
          input = object ["command" .= ("" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "rejects when autonomy is Deny even if shell is in the allowlist" $ do
      let policy        = allowCommand (CommandName "shell") defaultPolicy  -- autonomy = Deny
          (_, handler)  = shellTool policy mkNoOpShellHandle
          input         = object ["command" .= ("echo hi" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "passes the verbatim command string through bash -c (no T.words split)" $ do
      (sh, ref) <- mkRecordingShell (okResult "ok")
      let (_, handler) = shellTool shellPolicy sh
          input        = object ["command" .= ("ls ~/portfolio.png | wc -l" :: String)]
      _ <- runTool handler input
      called <- readIORef ref
      called `shouldBe` Just ("bash", ["-c", "ls ~/portfolio.png | wc -l"])

    it "returns combined stdout for a successful call" $ do
      (sh, _) <- mkRecordingShell (okResult (BS8.pack "hello world"))
      let (_, handler) = shellTool shellPolicy sh
          input        = object ["command" .= ("echo hello world" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "hello world"

    it "appends an Exit code: N suffix on non-zero exit" $ do
      let pr = ProcessResult { _pr_exitCode = ExitFailure 2, _pr_stdout = "", _pr_stderr = BS8.pack "boom" }
      (sh, _) <- mkRecordingShell pr
      let (_, handler) = shellTool shellPolicy sh
          input        = object ["command" .= ("false" :: String)]
      (output, _) <- runTool handler input
      T.unpack output `shouldContain` "Exit code: 2"

    it "flags non-zero exit as an error so the model and UI see it as a failure" $ do
      let pr = ProcessResult { _pr_exitCode = ExitFailure 1, _pr_stdout = "", _pr_stderr = BS8.pack "cat: /etc/issue: No such file or directory" }
      (sh, _) <- mkRecordingShell pr
      let (_, handler) = shellTool shellPolicy sh
          input        = object ["command" .= ("cat /etc/issue" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "leaves isErr=False on a clean exit" $ do
      (sh, _) <- mkRecordingShell (okResult (BS8.pack "ok"))
      let (_, handler) = shellTool shellPolicy sh
          input        = object ["command" .= ("true" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` False

  describe "execTool (argv-direct)" $ do
    it "is named exec" $ do
      let (def', _) = execTool defaultPolicy mkNoOpShellHandle
      _td_name def' `shouldBe` "exec"

    it "rejects programs not in the allowlist" $ do
      let policy       = withAutonomy Full
                       $ allowCommand (CommandName "echo") defaultPolicy
          (_, handler) = execTool policy mkNoOpShellHandle
          input        = object ["program" .= ("rm" :: String), "args" .= (["-rf", "/"] :: [String])]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not allowed"

    it "allows whitelisted programs and passes args through as literal strings" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "ls") defaultPolicy
      (sh, ref) <- mkRecordingShell (okResult "fake-listing")
      let (_, handler) = execTool policy sh
          input        = object [ "program" .= ("ls" :: String)
                                , "args"    .= (["~/portfolio.png"] :: [String])
                                ]
      _ <- runTool handler input
      called <- readIORef ref
      -- Literal tilde reaches the program — no shell expansion happened.
      called `shouldBe` Just ("ls", ["~/portfolio.png"])

    it "defaults args to empty when omitted" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "pwd") defaultPolicy
      (sh, ref) <- mkRecordingShell (okResult "/tmp")
      let (_, handler) = execTool policy sh
          input        = object ["program" .= ("pwd" :: String)]
      _ <- runTool handler input
      called <- readIORef ref
      called `shouldBe` Just ("pwd", [])

    it "rejects empty program" $ do
      let (_, handler) = execTool defaultPolicy mkNoOpShellHandle
          input        = object ["program" .= ("" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True
