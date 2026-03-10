module Handles.ProcessSpec (spec) where

import System.Exit
import Test.Hspec

import PureClaw.Handles.Process

spec :: Spec
spec = do
  describe "ProcessId" $ do
    it "has Show instance" $ do
      show (ProcessId 42) `shouldContain` "42"

    it "has Eq instance" $ do
      ProcessId 1 `shouldBe` ProcessId 1
      ProcessId 1 `shouldNotBe` ProcessId 2

    it "has Ord instance" $ do
      compare (ProcessId 1) (ProcessId 2) `shouldBe` LT

  describe "ProcessInfo" $ do
    it "has Show and Eq instances" $ do
      let info = ProcessInfo (ProcessId 1) "echo hello" True Nothing
      show info `shouldContain` "echo hello"
      info `shouldBe` info

  describe "ProcessStatus" $ do
    it "represents running processes" $ do
      let status = ProcessRunning "out" "err"
      show status `shouldContain` "ProcessRunning"
      status `shouldBe` ProcessRunning "out" "err"

    it "represents completed processes" $ do
      let status = ProcessDone ExitSuccess "out" "err"
      show status `shouldContain` "ProcessDone"
      status `shouldBe` ProcessDone ExitSuccess "out" "err"

  describe "mkNoOpProcessHandle" $ do
    it "spawn returns ProcessId 1" $ do
      -- We can't test spawn without an AuthorizedCommand, which needs
      -- Security.Command internals. Tested in Tools.ProcessSpec instead.
      pure () :: IO ()

    it "list returns empty" $ do
      procs <- _ph_list mkNoOpProcessHandle
      procs `shouldBe` []

    it "poll returns completed" $ do
      result <- _ph_poll mkNoOpProcessHandle (ProcessId 1)
      result `shouldBe` Just (ProcessDone ExitSuccess "" "")

    it "kill returns True" $ do
      ok <- _ph_kill mkNoOpProcessHandle (ProcessId 1)
      ok `shouldBe` True

    it "writeStdin returns True" $ do
      ok <- _ph_writeStdin mkNoOpProcessHandle (ProcessId 1) "data"
      ok `shouldBe` True
