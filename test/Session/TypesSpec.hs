module Session.TypesSpec (spec) where

import Test.Hspec

import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time (UTCTime (..), picosecondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import PureClaw.Core.Types
import PureClaw.Session.Types

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

  describe "SessionPrefix" $ do
    it "rejects empty input" $
      mkSessionPrefix "" `shouldBe` Left PrefixEmpty

    it "rejects names longer than 64 characters" $
      mkSessionPrefix (T.replicate 65 "a") `shouldBe` Left PrefixTooLong

    it "rejects forward slashes" $
      mkSessionPrefix "foo/bar" `shouldBe` Left (PrefixInvalidChars "foo/bar")

    it "rejects backslashes" $
      mkSessionPrefix "foo\\bar" `shouldBe` Left (PrefixInvalidChars "foo\\bar")

    it "rejects double-dot" $
      mkSessionPrefix ".." `shouldBe` Left PrefixLeadingDot

    it "rejects null byte" $
      mkSessionPrefix "a\0b" `shouldBe` Left (PrefixInvalidChars "a\0b")

    it "rejects leading dot" $
      mkSessionPrefix ".hidden" `shouldBe` Left PrefixLeadingDot

    it "rejects the reserved word \"new\"" $
      mkSessionPrefix "new" `shouldBe` Left (PrefixReserved "new")

    it "accepts a valid prefix" $
      fmap unSessionPrefix (mkSessionPrefix "zoe") `shouldBe` Right "zoe"

    it "accepts a prefix with digits, underscores, and hyphens" $
      fmap unSessionPrefix (mkSessionPrefix "ops-team_1") `shouldBe` Right "ops-team_1"

    it "FromJSON routes through mkSessionPrefix and rejects \"new\"" $
      (Aeson.decode "\"new\"" :: Maybe SessionPrefix) `shouldBe` Nothing

    it "FromJSON routes through mkSessionPrefix and rejects \"../evil\"" $
      (Aeson.decode "\"../evil\"" :: Maybe SessionPrefix) `shouldBe` Nothing

    it "FromJSON accepts a valid prefix" $
      fmap unSessionPrefix (Aeson.decode "\"zoe\"" :: Maybe SessionPrefix)
        `shouldBe` Just "zoe"

  describe "newSessionId" $ do
    let fixedTime =
          UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 12345000000)
        zoePrefix = case mkSessionPrefix "zoe" of
          Right p -> p
          Left e  -> error ("test fixture: " ++ show e)

    it "produces \"<prefix>-<mjd>-<picos>\" when a prefix is supplied" $
      newSessionId (Just zoePrefix) fixedTime
        `shouldBe` parseSessionId "zoe-60759-12345000000"

    it "omits the prefix and leading hyphen when Nothing is supplied" $
      newSessionId Nothing fixedTime
        `shouldBe` parseSessionId "60759-12345000000"

  describe "RuntimeType JSON" $ do
    it "encodes RTProvider as the bare string \"provider\"" $
      Aeson.encode RTProvider `shouldBe` "\"provider\""

    it "encodes RTHarness as \"harness:<name>\"" $
      Aeson.encode (RTHarness "claude-code") `shouldBe` "\"harness:claude-code\""

    it "decodes \"provider\" to RTProvider" $
      (Aeson.decode "\"provider\"" :: Maybe RuntimeType) `shouldBe` Just RTProvider

    it "decodes \"harness:claude-code\" to RTHarness \"claude-code\"" $
      (Aeson.decode "\"harness:claude-code\"" :: Maybe RuntimeType)
        `shouldBe` Just (RTHarness "claude-code")

    it "round-trips RTProvider" $
      (Aeson.decode (Aeson.encode RTProvider) :: Maybe RuntimeType)
        `shouldBe` Just RTProvider

    it "round-trips RTHarness" $
      (Aeson.decode (Aeson.encode (RTHarness "cc")) :: Maybe RuntimeType)
        `shouldBe` Just (RTHarness "cc")

    it "fails to decode an unknown string" $
      (Aeson.decode "\"banana\"" :: Maybe RuntimeType) `shouldBe` Nothing
