module Handles.HarnessSpec (spec) where

import Data.ByteString ()
import System.Exit
import Test.Hspec

import PureClaw.Handles.Harness
import PureClaw.Security.Command

spec :: Spec
spec = do
  describe "HarnessStatus" $ do
    it "has Show instance" $ do
      show HarnessRunning `shouldContain` "HarnessRunning"

    it "has Eq instance" $ do
      HarnessRunning `shouldBe` HarnessRunning
      HarnessRunning `shouldNotBe` HarnessExited ExitSuccess

    it "represents exit with code" $ do
      let status = HarnessExited (ExitFailure 1)
      show status `shouldContain` "HarnessExited"
      status `shouldBe` HarnessExited (ExitFailure 1)
      status `shouldNotBe` HarnessExited ExitSuccess

  describe "HarnessError" $ do
    it "has Show instance" $ do
      show (HarnessTmuxNotAvailable "test") `shouldContain` "HarnessTmuxNotAvailable"

    it "has Eq instance" $ do
      HarnessTmuxNotAvailable "test" `shouldBe` HarnessTmuxNotAvailable "test"

    it "constructs HarnessBinaryNotFound" $ do
      let err = HarnessBinaryNotFound "claude"
      show err `shouldContain` "HarnessBinaryNotFound"
      show err `shouldContain` "claude"
      err `shouldBe` HarnessBinaryNotFound "claude"
      err `shouldNotBe` HarnessBinaryNotFound "other"

    it "constructs HarnessNotAuthorized" $ do
      let cmdErr = CommandNotAllowed "tmux"
          err = HarnessNotAuthorized cmdErr
      show err `shouldContain` "HarnessNotAuthorized"
      err `shouldBe` HarnessNotAuthorized cmdErr

  describe "mkNoOpHarnessHandle" $ do
    it "send is a no-op" $ do
      _hh_send mkNoOpHarnessHandle "test data"
      -- Should not throw

    it "receive returns empty ByteString" $ do
      result <- _hh_receive mkNoOpHarnessHandle
      result `shouldBe` ""

    it "name returns empty Text" $ do
      _hh_name mkNoOpHarnessHandle `shouldBe` ""

    it "session returns empty Text" $ do
      _hh_session mkNoOpHarnessHandle `shouldBe` ""

    it "status returns HarnessRunning" $ do
      result <- _hh_status mkNoOpHarnessHandle
      result `shouldBe` HarnessRunning

    it "stop is a no-op" $ do
      _hh_stop mkNoOpHarnessHandle
      -- Should not throw
