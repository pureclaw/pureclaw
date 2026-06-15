module Core.SessionIdValidatorSpec (spec) where

import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (fromGregorian)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..), isValidSessionId)
import PureClaw.Session.Types qualified as SessionTypes

spec :: Spec
spec = do
  describe "isValidSessionId" $ do
    it "accepts a timestamp-style session id" $
      isValidSessionId "20260610-122113-257" `shouldBe` True

    it "accepts an id with underscore and dash" $
      isValidSessionId "agent_run-01" `shouldBe` True

    it "rejects the empty string" $
      isValidSessionId "" `shouldBe` False

    it "rejects a leading-dot id" $
      isValidSessionId ".hidden" `shouldBe` False

    it "rejects a path-traversal segment" $
      isValidSessionId "../etc" `shouldBe` False

    it "rejects a forward slash" $
      isValidSessionId "a/b" `shouldBe` False

    it "rejects a NUL byte" $
      isValidSessionId "a\x00b" `shouldBe` False

    it "rejects a backslash" $
      isValidSessionId "a\\b" `shouldBe` False

    it "rejects a colon" $
      isValidSessionId "a:b" `shouldBe` False

    it "rejects a dot inside the id" $
      isValidSessionId "a.b" `shouldBe` False

    it "round-trips: newSessionId produces a valid id" $
      let t = UTCTime (fromGregorian 2026 6 11) (secondsToDiffTime 45296)
          sid = SessionTypes.newSessionId Nothing t
      in isValidSessionId (unSessionId sid) `shouldBe` True
