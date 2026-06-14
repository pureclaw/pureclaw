module Handles.LogSpec (spec) where

import Control.Exception (finally)
import Data.List (isInfixOf)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

import PureClaw.Handles.Log

-- | Run an action with @stderr@ redirected to a temp file, returning whatever
-- the action wrote there. Used to assert on the filtering logger's output
-- without polluting the test runner's own stderr.
captureStderr :: IO () -> IO String
captureStderr action =
  withSystemTempFile "log-capture.txt" $ \path tmpH -> do
    hFlush stderr
    saved <- hDuplicate stderr
    hDuplicateTo tmpH stderr
    hClose tmpH
    action `finally` (hFlush stderr >> hDuplicateTo saved stderr >> hClose saved)
    readFile' path

spec :: Spec
spec = do
  describe "LogLevel" $ do
    it "orders LlDebug < LlInfo < LlWarn < LlError by severity" $
      [minBound .. maxBound] `shouldBe` [LlDebug, LlInfo, LlWarn, LlError]

  describe "parseLogLevel" $ do
    it "parses each level (lower-case)" $ do
      parseLogLevel "debug" `shouldBe` Just LlDebug
      parseLogLevel "info"  `shouldBe` Just LlInfo
      parseLogLevel "warn"  `shouldBe` Just LlWarn
      parseLogLevel "error" `shouldBe` Just LlError

    it "is case-insensitive" $ do
      parseLogLevel "DEBUG" `shouldBe` Just LlDebug
      parseLogLevel "Warn"  `shouldBe` Just LlWarn

    it "rejects unknown levels" $
      parseLogLevel "verbose" `shouldBe` Nothing

  describe "shouldLog" $ do
    it "emits messages at or above the threshold" $ do
      shouldLog LlWarn LlWarn   `shouldBe` True
      shouldLog LlWarn LlError  `shouldBe` True
      shouldLog LlDebug LlDebug `shouldBe` True

    it "suppresses messages below the threshold" $ do
      shouldLog LlWarn LlInfo  `shouldBe` False
      shouldLog LlError LlWarn `shouldBe` False

  describe "mkStderrLogHandleAt" $ do
    it "suppresses below-threshold and emits at-or-above-threshold messages" $ do
      out <- captureStderr $ do
        handle <- mkStderrLogHandleAt LlWarn
        _lh_logInfo  handle "hidden-info"
        _lh_logError handle "shown-error"
      out `shouldSatisfy` ("shown-error" `isInfixOf`)
      out `shouldSatisfy` (not . ("hidden-info" `isInfixOf`))

    it "emits all four levels at the Debug threshold" $ do
      out <- captureStderr $ do
        handle <- mkStderrLogHandleAt LlDebug
        _lh_logDebug handle "d-msg"
        _lh_logInfo  handle "i-msg"
        _lh_logWarn  handle "w-msg"
        _lh_logError handle "e-msg"
      out `shouldSatisfy` ("d-msg" `isInfixOf`)
      out `shouldSatisfy` ("i-msg" `isInfixOf`)
      out `shouldSatisfy` ("w-msg" `isInfixOf`)
      out `shouldSatisfy` ("e-msg" `isInfixOf`)

  describe "mkStderrLogHandle" $ do
    it "creates a handle with all four log functions" $ do
      handle <- mkStderrLogHandle
      -- Verify the handle can be constructed — functions are present
      -- We don't call logInfo etc. here to avoid polluting test output
      handle `seq` pure () :: IO ()

    it "defaults to the Info threshold (suppresses debug, emits info)" $ do
      out <- captureStderr $ do
        handle <- mkStderrLogHandle
        _lh_logDebug handle "default-hidden-debug"
        _lh_logInfo  handle "default-shown-info"
      out `shouldSatisfy` ("default-shown-info" `isInfixOf`)
      out `shouldSatisfy` (not . ("default-hidden-debug" `isInfixOf`))

  describe "mkNoOpLogHandle" $ do
    it "logInfo succeeds silently" $ do
      _lh_logInfo mkNoOpLogHandle "test message"

    it "logWarn succeeds silently" $ do
      _lh_logWarn mkNoOpLogHandle "test warning"

    it "logError succeeds silently" $ do
      _lh_logError mkNoOpLogHandle "test error"

    it "logDebug succeeds silently" $ do
      _lh_logDebug mkNoOpLogHandle "test debug"
