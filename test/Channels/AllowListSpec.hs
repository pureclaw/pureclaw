module Channels.AllowListSpec (spec) where

import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

import PureClaw.Channels.AllowList
import PureClaw.Core.Types
import PureClaw.Handles.Log

-- | A 'LogHandle' that records WARN messages into an 'IORef'. All other
-- log functions are no-ops.
mkRecordingLogHandle :: IORef [Text] -> LogHandle
mkRecordingLogHandle ref =
  LogHandle
    { _lh_logInfo  = \_ -> pure ()
    , _lh_logWarn  = \msg -> modifyIORef' ref (++ [msg])
    , _lh_logError = \_ -> pure ()
    , _lh_logDebug = \_ -> pure ()
    }

closedList :: AllowList UserId
closedList = AllowList (Set.fromList [UserId "a"])

spec :: Spec
spec = do
  describe "allowListOpen" $ do
    it "is True for AllowAll" $
      allowListOpen (AllowAll :: AllowList UserId) `shouldBe` True

    it "is False for a non-empty AllowList" $
      allowListOpen closedList `shouldBe` False

  describe "allowListWarning" $ do
    it "returns Just with a prominent banner and log line when open" $ do
      case allowListWarning "Signal" (AllowAll :: AllowList UserId) of
        Nothing -> expectationFailure "expected Just for an open allow-list"
        Just (banner, logLine) -> do
          banner `shouldSatisfy` (not . null)
          let joined = T.unlines banner
          joined `shouldSatisfy` T.isInfixOf "SECURITY WARNING"
          joined `shouldSatisfy` T.isInfixOf "Signal"
          logLine `shouldSatisfy` T.isInfixOf "no allow-list configured"

    it "returns Nothing when senders are restricted" $
      allowListWarning "X" closedList `shouldBe` Nothing

  describe "emitAllowListWarning" $ do
    it "writes the banner to the Handle and fires a WARN log when open" $ do
      logRef <- newIORef []
      let lh = mkRecordingLogHandle logRef
      contents <-
        withSystemTempFile "allowlist-open.txt" $ \path h -> do
          emitAllowListWarning h lh "Signal" (AllowAll :: AllowList UserId)
          hClose h
          TIO.readFile path
      contents `shouldSatisfy` T.isInfixOf "SECURITY WARNING"
      contents `shouldSatisfy` T.isInfixOf "Signal"
      logged <- readIORef logRef
      logged `shouldSatisfy` (not . null)
      T.unlines logged `shouldSatisfy` T.isInfixOf "no allow-list configured"

    it "writes nothing and logs nothing when senders are restricted" $ do
      logRef <- newIORef []
      let lh = mkRecordingLogHandle logRef
      contents <-
        withSystemTempFile "allowlist-closed.txt" $ \path h -> do
          emitAllowListWarning h lh "Signal" closedList
          hClose h
          TIO.readFile path
      contents `shouldBe` ""
      logged <- readIORef logRef
      logged `shouldBe` []
