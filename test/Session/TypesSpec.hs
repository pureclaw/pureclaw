module Session.TypesSpec (spec) where

import Test.Hspec

import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time (UTCTime (..), picosecondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import PureClaw.Agent.AgentDef (mkAgentName)
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
    -- 2025-03-25 14:30:45.678 UTC
    let fixedTime =
          UTCTime (ModifiedJulianDay 60759)
                  (picosecondsToDiffTime 52245678000000000)
        zoePrefix = case mkSessionPrefix "zoe" of
          Right p -> p
          Left e  -> error ("test fixture: " ++ show e)

    it "produces \"<prefix>-YYYYMMDD-HHMMSS-mmm\" when a prefix is supplied" $
      newSessionId (Just zoePrefix) fixedTime
        `shouldBe` parseSessionId "zoe-20250325-143045-678"

    it "omits the prefix and leading hyphen when Nothing is supplied" $
      newSessionId Nothing fixedTime
        `shouldBe` parseSessionId "20250325-143045-678"

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

  describe "SessionMeta JSON" $ do
    let zoeAgent = case mkAgentName "zoe" of
          Right n -> n
          Left e  -> error ("test fixture: " ++ show e)
        t0 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 0)
        t1 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 1)
        sample = SessionMeta
          { _sm_id                = parseSessionId "zoe-60759-0"
          , _sm_agent             = Just zoeAgent
          , _sm_runtime           = RTProvider
          , _sm_model             = "claude-3-opus"
          , _sm_channel           = "cli"
          , _sm_createdAt         = t0
          , _sm_lastActive        = t1
          , _sm_bootstrapConsumed = False
          }

    it "round-trips a fully-populated SessionMeta" $
      Aeson.decode (Aeson.encode sample) `shouldBe` Just sample

    it "round-trips a SessionMeta with no agent set" $ do
      let s = sample { _sm_agent = Nothing }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips a harness runtime" $ do
      let s = sample { _sm_runtime = RTHarness "claude-code" }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips bootstrap_consumed = True" $ do
      let s = sample { _sm_bootstrapConsumed = True }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "defaultTarget RTProvider == TargetProvider" $
      defaultTarget RTProvider `shouldBe` TargetProvider

    it "defaultTarget (RTHarness x) == TargetHarness x" $
      defaultTarget (RTHarness "claude-code")
        `shouldBe` TargetHarness "claude-code"

    it "decodes JSON missing the optional agent field" $ do
      let json =
            "{\"id\":\"zoe-60759-0\",\"runtime\":\"provider\","
            <> "\"model\":\"claude-3-opus\",\"channel\":\"cli\","
            <> "\"created_at\":\"2025-04-13T00:00:00Z\","
            <> "\"last_active\":\"2025-04-13T00:00:00Z\","
            <> "\"bootstrap_consumed\":false}"
      fmap _sm_agent (Aeson.decode json :: Maybe SessionMeta) `shouldBe` Just Nothing
