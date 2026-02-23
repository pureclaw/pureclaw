module Scheduler.CronSpec (spec) where

import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Time
import Test.Hspec

import PureClaw.Scheduler.Cron

-- Helper: create a UTCTime from components.
mkTime :: Integer -> Int -> Int -> Int -> Int -> UTCTime
mkTime year month day hour minute =
  UTCTime (fromGregorian year month day) (timeOfDayToTime (TimeOfDay hour minute 0))

-- Helper: parse a cron expression or fail the test.
parseCron :: Text -> IO CronExpr
parseCron input = case parseCronExpr input of
  Left err   -> expectationFailure ("Failed to parse: " ++ err) >> error "unreachable"
  Right expr -> pure expr

spec :: Spec
spec = do
  describe "parseCronExpr" $ do
    it "parses * * * * *" $ do
      expr <- parseCron "* * * * *"
      _ce_minute expr `shouldBe` Wildcard
      _ce_hour expr `shouldBe` Wildcard

    it "parses exact values" $ do
      expr <- parseCron "30 12 1 6 3"
      _ce_minute expr `shouldBe` Exact 30
      _ce_hour expr `shouldBe` Exact 12
      _ce_dayOfMonth expr `shouldBe` Exact 1
      _ce_month expr `shouldBe` Exact 6
      _ce_dayOfWeek expr `shouldBe` Exact 3

    it "parses ranges" $ do
      expr <- parseCron "0-30 9-17 * * *"
      _ce_minute expr `shouldBe` Range 0 30
      _ce_hour expr `shouldBe` Range 9 17

    it "parses steps" $ do
      expr <- parseCron "*/15 */2 * * *"
      _ce_minute expr `shouldBe` Step Wildcard 15
      _ce_hour expr `shouldBe` Step Wildcard 2

    it "parses lists" $ do
      expr <- parseCron "0,15,30,45 * * * *"
      case _ce_minute expr of
        ListField fields -> length fields `shouldBe` 4
        other -> expectationFailure $ "Expected ListField, got " ++ show other

    it "parses range with step" $ do
      expr <- parseCron "1-59/2 * * * *"
      _ce_minute expr `shouldBe` Step (Range 1 59) 2

    it "rejects too few fields" $
      parseCronExpr "* * *" `shouldSatisfy` isLeft

    it "rejects too many fields" $
      parseCronExpr "* * * * * *" `shouldSatisfy` isLeft

    it "rejects invalid values" $
      parseCronExpr "abc * * * *" `shouldSatisfy` isLeft

    it "rejects empty input" $
      parseCronExpr "" `shouldSatisfy` isLeft

  describe "CronField" $ do
    it "has Show and Eq instances" $ do
      show Wildcard `shouldBe` "Wildcard"
      Wildcard `shouldBe` Wildcard
      Exact 5 `shouldNotBe` Exact 10

  describe "cronMatches" $ do
    it "wildcard matches any time" $ do
      expr <- parseCron "* * * * *"
      cronMatches expr (mkTime 2026 1 15 10 30) `shouldBe` True

    it "exact minute matches" $ do
      expr <- parseCron "30 * * * *"
      cronMatches expr (mkTime 2026 1 15 10 30) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 10 15) `shouldBe` False

    it "exact hour matches" $ do
      expr <- parseCron "* 12 * * *"
      cronMatches expr (mkTime 2026 1 15 12 0) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 11 0) `shouldBe` False

    it "range matches inclusive" $ do
      expr <- parseCron "* 9-17 * * *"
      cronMatches expr (mkTime 2026 1 15 9 0) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 17 0) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 8 0) `shouldBe` False
      cronMatches expr (mkTime 2026 1 15 18 0) `shouldBe` False

    it "step matches" $ do
      expr <- parseCron "*/15 * * * *"
      cronMatches expr (mkTime 2026 1 15 10 0) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 10 15) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 10 30) `shouldBe` True
      cronMatches expr (mkTime 2026 1 15 10 7) `shouldBe` False

    it "day of week matches (Sunday = 0)" $ do
      -- 2026-02-22 is a Sunday
      expr <- parseCron "* * * * 0"
      cronMatches expr (mkTime 2026 2 22 10 0) `shouldBe` True
      cronMatches expr (mkTime 2026 2 23 10 0) `shouldBe` False

    it "month matches" $ do
      expr <- parseCron "* * * 6 *"
      cronMatches expr (mkTime 2026 6 15 10 0) `shouldBe` True
      cronMatches expr (mkTime 2026 7 15 10 0) `shouldBe` False

    it "combined fields all must match" $ do
      expr <- parseCron "30 12 15 6 *"
      cronMatches expr (mkTime 2026 6 15 12 30) `shouldBe` True
      cronMatches expr (mkTime 2026 6 15 12 31) `shouldBe` False
      cronMatches expr (mkTime 2026 6 16 12 30) `shouldBe` False

  describe "CronScheduler" $ do
    it "starts empty" $ do
      result <- tickScheduler mkCronScheduler (mkTime 2026 1 1 0 0)
      result `shouldBe` []

    it "adds and runs matching jobs" $ do
      ref <- newIORef (0 :: Int)
      expr <- parseCron "* * * * *"
      let job = CronJob "test" expr (modifyIORef ref (+ 1))
          sched = addJob job mkCronScheduler
      _ <- tickScheduler sched (mkTime 2026 1 1 0 0)
      readIORef ref `shouldReturn` 1

    it "skips non-matching jobs" $ do
      ref <- newIORef (0 :: Int)
      expr <- parseCron "30 12 * * *"
      let job = CronJob "test" expr (modifyIORef ref (+ 1))
          sched = addJob job mkCronScheduler
      _ <- tickScheduler sched (mkTime 2026 1 1 0 0)
      readIORef ref `shouldReturn` 0

    it "returns names of executed jobs" $ do
      expr <- parseCron "* * * * *"
      let job = CronJob "myjob" expr (pure ())
          sched = addJob job mkCronScheduler
      names <- tickScheduler sched (mkTime 2026 1 1 0 0)
      names `shouldBe` ["myjob"]

    it "removes jobs" $ do
      expr <- parseCron "* * * * *"
      let job = CronJob "myjob" expr (pure ())
          sched = removeJob "myjob" (addJob job mkCronScheduler)
      names <- tickScheduler sched (mkTime 2026 1 1 0 0)
      names `shouldBe` []
