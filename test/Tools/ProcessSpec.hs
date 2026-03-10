module Tools.ProcessSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Exit
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Process
import PureClaw.Providers.Class
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Tools.Process
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "processTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = processTool defaultPolicy mkNoOpProcessHandle
      _td_name def' `shouldBe` "process"

    it "spawns a process when policy allows" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "sleep") defaultPolicy
          mockPH = mkNoOpProcessHandle
          (_, handler) = processTool policy mockPH
          input = object
            [ "action" .= ("spawn" :: String)
            , "command" .= ("sleep 10" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Started process"

    it "rejects spawn when policy denies" $ do
      let (_, handler) = processTool defaultPolicy mkNoOpProcessHandle
          input = object
            [ "action" .= ("spawn" :: String)
            , "command" .= ("rm -rf /" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "denied"

    it "rejects spawn of disallowed commands" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "echo") defaultPolicy
          (_, handler) = processTool policy mkNoOpProcessHandle
          input = object
            [ "action" .= ("spawn" :: String)
            , "command" .= ("rm -rf /" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not allowed"

    it "rejects empty spawn command" $ do
      let policy = withAutonomy Full defaultPolicy
          (_, handler) = processTool policy mkNoOpProcessHandle
          input = object
            [ "action" .= ("spawn" :: String)
            , "command" .= ("" :: String)
            ]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "lists processes" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_list = pure
                [ ProcessInfo (ProcessId 1) "sleep 100" True Nothing
                , ProcessInfo (ProcessId 2) "echo done" False (Just ExitSuccess)
                ]
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object ["action" .= ("list" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "sleep 100"
      T.unpack output `shouldContain` "running"
      T.unpack output `shouldContain` "echo done"
      T.unpack output `shouldContain` "done (exit 0)"

    it "returns 'no background processes' when list is empty" $ do
      let (_, handler) = processTool defaultPolicy mkNoOpProcessHandle
          input = object ["action" .= ("list" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No background"

    it "polls a running process" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_poll = \_ -> pure (Just (ProcessRunning "partial out" ""))
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("poll" :: String)
            , "id" .= (1 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "running"
      T.unpack output `shouldContain` "partial out"

    it "polls a completed process" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_poll = \_ -> pure (Just (ProcessDone ExitSuccess "all done" ""))
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("poll" :: String)
            , "id" .= (1 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "done (exit 0)"
      T.unpack output `shouldContain` "all done"

    it "reports error for unknown process in poll" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_poll = \_ -> pure Nothing
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("poll" :: String)
            , "id" .= (99 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not found"

    it "kills a process" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_kill = \_ -> pure True
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("kill" :: String)
            , "id" .= (1 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Killed"

    it "reports error for unknown process in kill" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_kill = \_ -> pure False
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("kill" :: String)
            , "id" .= (1 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not found"

    it "writes to stdin" $ do
      let mockPH = mkNoOpProcessHandle
            { _ph_writeStdin = \_ _ -> pure True
            }
          (_, handler) = processTool defaultPolicy mockPH
          input = object
            [ "action" .= ("write_stdin" :: String)
            , "id" .= (1 :: Int)
            , "input" .= ("hello\n" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Sent input"

    it "rejects unknown actions" $ do
      let (_, handler) = processTool defaultPolicy mkNoOpProcessHandle
          input = object ["action" .= ("explode" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Unknown action"

    it "rejects invalid JSON input" $ do
      let (_, handler) = processTool defaultPolicy mkNoOpProcessHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

  describe "ProcessHandle (no-op)" $ do
    it "spawn returns ProcessId 1" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "echo") defaultPolicy
      case authorize policy "echo" ["hi"] of
        Left _ -> expectationFailure "authorize should succeed"
        Right cmd -> do
          pid <- _ph_spawn mkNoOpProcessHandle cmd
          pid `shouldBe` ProcessId 1

    it "list returns empty" $ do
      procs <- _ph_list mkNoOpProcessHandle
      procs `shouldBe` []

    it "poll returns completed" $ do
      status <- _ph_poll mkNoOpProcessHandle (ProcessId 1)
      status `shouldBe` Just (ProcessDone ExitSuccess "" "")

    it "kill returns True" $ do
      ok <- _ph_kill mkNoOpProcessHandle (ProcessId 1)
      ok `shouldBe` True

    it "writeStdin returns True" $ do
      ok <- _ph_writeStdin mkNoOpProcessHandle (ProcessId 1) "test"
      ok `shouldBe` True
