module Session.TypesSpec (spec) where

import Test.Hspec

import Data.Aeson qualified as Aeson
import PureClaw.Core.Types

spec :: Spec
spec = do
  describe "SessionId" $ do
    it "round-trips parseSessionId / unSessionId" $
      unSessionId (parseSessionId "abc-123") `shouldBe` "abc-123"

    it "JSON encodes as a plain string" $
      Aeson.encode (parseSessionId "abc-123") `shouldBe` "\"abc-123\""

    it "JSON decodes from a plain string" $
      Aeson.decode "\"abc-123\"" `shouldBe` Just (parseSessionId "abc-123")

    it "JSON round-trip preserves value" $ do
      let sid = parseSessionId "zoe-60759-12345"
      Aeson.decode (Aeson.encode sid) `shouldBe` Just sid
