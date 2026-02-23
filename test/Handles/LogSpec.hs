module Handles.LogSpec (spec) where

import Test.Hspec

import PureClaw.Handles.Log

spec :: Spec
spec = do
  describe "mkStderrLogHandle" $ do
    it "creates a handle with all four log functions" $ do
      let handle = mkStderrLogHandle
      -- Verify the handle can be constructed — functions are present
      -- We don't call logInfo etc. here to avoid polluting test output
      handle `seq` pure () :: IO ()

  describe "mkNoOpLogHandle" $ do
    it "logInfo succeeds silently" $ do
      _lh_logInfo mkNoOpLogHandle "test message"

    it "logWarn succeeds silently" $ do
      _lh_logWarn mkNoOpLogHandle "test warning"

    it "logError succeeds silently" $ do
      _lh_logError mkNoOpLogHandle "test error"

    it "logDebug succeeds silently" $ do
      _lh_logDebug mkNoOpLogHandle "test debug"
