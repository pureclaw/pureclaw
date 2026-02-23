module Scheduler.HeartbeatSpec (spec) where

import Control.Concurrent.STM
import Data.IORef
import Test.Hspec

import PureClaw.Handles.Log
import PureClaw.Scheduler.Heartbeat

spec :: Spec
spec = do
  describe "defaultHeartbeatConfig" $ do
    it "has 60 second interval" $
      _hb_intervalSeconds defaultHeartbeatConfig `shouldBe` 60

    it "has a name" $
      _hb_name defaultHeartbeatConfig `shouldBe` "heartbeat"

    it "has Show and Eq instances" $ do
      show defaultHeartbeatConfig `shouldContain` "HeartbeatConfig"
      defaultHeartbeatConfig `shouldBe` defaultHeartbeatConfig

  describe "mkHeartbeatState" $ do
    it "starts not running" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      isHeartbeatRunning hbs `shouldReturn` False

    it "starts with no last tick" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      readTVarIO (_hbs_lastTick hbs) `shouldReturn` Nothing

    it "starts with zero tick count" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      readTVarIO (_hbs_tickCount hbs) `shouldReturn` 0

  describe "heartbeatTick" $ do
    it "executes the action and returns True" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      ref <- newIORef (0 :: Int)
      result <- heartbeatTick hbs mkNoOpLogHandle (modifyIORef ref (+ 1))
      result `shouldBe` True
      readIORef ref `shouldReturn` 1

    it "updates the tick count" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      _ <- heartbeatTick hbs mkNoOpLogHandle (pure ())
      _ <- heartbeatTick hbs mkNoOpLogHandle (pure ())
      readTVarIO (_hbs_tickCount hbs) `shouldReturn` 2

    it "updates the last tick time" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      _ <- heartbeatTick hbs mkNoOpLogHandle (pure ())
      lastTick <- readTVarIO (_hbs_lastTick hbs)
      lastTick `shouldSatisfy` (/= Nothing)

    it "catches exceptions and returns False" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      result <- heartbeatTick hbs mkNoOpLogHandle (error "boom")
      result `shouldBe` False

    it "does not update tick count on failure" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      _ <- heartbeatTick hbs mkNoOpLogHandle (error "boom")
      readTVarIO (_hbs_tickCount hbs) `shouldReturn` 0

  describe "stopHeartbeat" $ do
    it "sets running to False" $ do
      hbs <- mkHeartbeatState defaultHeartbeatConfig
      atomically $ writeTVar (_hbs_running hbs) True
      stopHeartbeat hbs
      isHeartbeatRunning hbs `shouldReturn` False
