module Tools.CronSpec (spec) where

import Data.Aeson
import Data.IORef
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Scheduler.Cron
import PureClaw.Tools.Cron
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "cronTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
      _td_name def' `shouldBe` "cron"

    it "adds a cron job" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object
            [ "action" .= ("add" :: String)
            , "name" .= ("daily-report" :: String)
            , "schedule" .= ("0 9 * * *" :: String)
            , "message" .= ("Time for the daily report" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Added cron job"
      T.unpack output `shouldContain` "daily-report"

    it "rejects invalid cron expressions" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object
            [ "action" .= ("add" :: String)
            , "name" .= ("bad-job" :: String)
            , "schedule" .= ("invalid cron" :: String)
            , "message" .= ("test" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Invalid cron"

    it "removes a cron job" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object
            [ "action" .= ("remove" :: String)
            , "name" .= ("old-job" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Removed"

    it "reports error when removing nonexistent job" $ do
      let mockCrh = mkNoOpCronHandle { _crh_remove = \_ -> pure False }
          (_, handler) = cronTool mkNoOpChannelHandle mockCrh
          input = object
            [ "action" .= ("remove" :: String)
            , "name" .= ("ghost-job" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not found"

    it "lists cron jobs" $ do
      let mockCrh = mkNoOpCronHandle
            { _crh_list = pure [("daily", "0 9 * * *"), ("hourly", "0 * * * *")]
            }
          (_, handler) = cronTool mkNoOpChannelHandle mockCrh
          input = object ["action" .= ("list" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "daily"
      T.unpack output `shouldContain` "hourly"

    it "shows empty message when no jobs" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object ["action" .= ("list" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No cron jobs"

    it "rejects unknown actions" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object ["action" .= ("explode" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Unknown action"

    it "rejects invalid JSON input" $ do
      let (_, handler) = cronTool mkNoOpChannelHandle mkNoOpCronHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

  describe "mkCronHandle" $ do
    it "adds and lists jobs via IORef" $ do
      ref <- newIORef mkCronScheduler
      let crh = mkCronHandle ref
      case parseCronExpr "*/5 * * * *" of
        Left _ -> expectationFailure "should parse"
        Right expr -> do
          _ <- _crh_add crh "test-job" expr (pure ())
          jobs <- _crh_list crh
          case jobs of
            [(name, _)] -> name `shouldBe` "test-job"
            _ -> expectationFailure $ "Expected 1 job, got " ++ show (length jobs)

    it "removes jobs via IORef" $ do
      ref <- newIORef mkCronScheduler
      let crh = mkCronHandle ref
      case parseCronExpr "0 * * * *" of
        Left _ -> expectationFailure "should parse"
        Right expr -> do
          _ <- _crh_add crh "removable" expr (pure ())
          removed <- _crh_remove crh "removable"
          removed `shouldBe` True
          jobs <- _crh_list crh
          jobs `shouldBe` []

    it "returns False when removing nonexistent job" $ do
      ref <- newIORef mkCronScheduler
      let crh = mkCronHandle ref
      removed <- _crh_remove crh "ghost"
      removed `shouldBe` False

  describe "mkNoOpCronHandle" $ do
    it "add returns True" $ do
      case parseCronExpr "* * * * *" of
        Left _ -> expectationFailure "should parse"
        Right expr -> do
          result <- _crh_add mkNoOpCronHandle "test" expr (pure ())
          result `shouldBe` True

    it "remove returns True" $ do
      result <- _crh_remove mkNoOpCronHandle "test"
      result `shouldBe` True

    it "list returns empty" $ do
      jobs <- _crh_list mkNoOpCronHandle
      jobs `shouldBe` []
