module Session.TypesSpec (spec) where

import Test.Hspec

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson (parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Time (UTCTime (..), picosecondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import PureClaw.Agent.AgentDef (mkAgentName)
import PureClaw.Core.Types
import PureClaw.Session.Kind
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

  describe "SessionMeta JSON (new format)" $ do
    let zoeAgent = case mkAgentName "zoe" of
          Right n -> n
          Left e  -> error ("test fixture: " ++ show e)
        t0 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 0)
        t1 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 1)
        sample = SessionMeta
          { _sm_id                = parseSessionId "zoe-60759-0"
          , _sm_agent             = Just zoeAgent
          , _sm_kind              = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "claude-3-opus") (Just zoeAgent))
          , _sm_model             = "claude-3-opus"
          , _sm_channel           = "cli"
          , _sm_createdAt         = t0
          , _sm_lastActive        = t1
          , _sm_bootstrapConsumed = False
          , _sm_archived          = False
          , _sm_description       = Nothing
          , _sm_autoSummary       = Nothing
          , _sm_source            = Nothing
          }

    it "round-trips a fully-populated SessionMeta" $
      Aeson.decode (Aeson.encode sample) `shouldBe` Just sample

    it "round-trips a SessionMeta with no agent set" $ do
      let s = sample
            { _sm_agent = Nothing
            , _sm_kind = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "claude-3-opus") Nothing)
            }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips a harness kind" $ do
      let s = sample
            { _sm_kind = SkHarness (HarnessSpec HClaudeCode (TbTmux (TmuxConfig "claude-code" "claude-code" Nothing)) Nothing [])
            }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips bootstrap_consumed = True" $ do
      let s = sample { _sm_bootstrapConsumed = True }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips a SessionMeta with a Just _sm_source" $ do
      let src = mkMessageSource CkSignal (Just (UserId "+15551234567")) mempty
          s   = sample { _sm_source = Just src }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "round-trips a SessionMeta with a CkOther source channel" $ do
      let src = mkMessageSource (CkOther "matrix") (Just (UserId "@bob:matrix.org")) mempty
          s   = sample { _sm_source = Just src }
      Aeson.decode (Aeson.encode s) `shouldBe` Just s

    it "decodes legacy JSON without a \"source\" key as _sm_source == Nothing" $ do
      -- Encode a sample that HAS no source, decode it back, and confirm the
      -- field is Nothing — i.e. omission round-trips to Nothing, the same
      -- shape a legacy session.json (written before _sm_source existed)
      -- produces.
      let s = sample { _sm_source = Nothing }
      case Aeson.decode (Aeson.encode s) :: Maybe SessionMeta of
        Just m  -> _sm_source m `shouldBe` Nothing
        Nothing -> expectationFailure "decode of source-less SessionMeta failed"

    it "ToJSON OMITS the \"source\" key when _sm_source is Nothing" $ do
      let s = sample { _sm_source = Nothing }
          obj = Aeson.decode (Aeson.encode s) :: Maybe Aeson.Object
      case obj of
        Just o -> case Aeson.parseMaybe (Aeson..: "source") o :: Maybe Aeson.Value of
          Nothing -> pure ()
          Just _  -> expectationFailure "'source' key should be absent when _sm_source is Nothing"
        Nothing -> expectationFailure "Failed to decode SessionMeta as Object"

    it "ToJSON EMITS the \"source\" key when _sm_source is Just" $ do
      let src = mkMessageSource CkSignal (Just (UserId "+15551234567")) mempty
          s   = sample { _sm_source = Just src }
          obj = Aeson.decode (Aeson.encode s) :: Maybe Aeson.Object
      case obj of
        Just o -> case Aeson.parseMaybe (Aeson..: "source") o :: Maybe Aeson.Value of
          Just _  -> pure ()
          Nothing -> expectationFailure "'source' key should be present when _sm_source is Just"
        Nothing -> expectationFailure "Failed to decode SessionMeta as Object"

    it "defaultTarget SkProvider == TargetProvider" $
      defaultTarget (SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "m") Nothing)) `shouldBe` TargetProvider

    it "defaultTarget SkHarness uses flavour name as harness target" $
      defaultTarget (SkHarness (HarnessSpec HClaudeCode TbLocal Nothing []))
        `shouldBe` TargetHarness "claude-code"

  -- -----------------------------------------------------------------------
  -- Legacy fixture tests (M1-M4)
  -- -----------------------------------------------------------------------
  describe "Legacy JSON fixture decoding" $ do
    it "decodes provider-basic.json as SkProvider with anthropic" $ do
      raw <- LBS.readFile "test/fixtures/legacy-session-json/provider-basic.json"
      case Aeson.eitherDecode' raw :: Either String SessionMeta of
        Left err -> expectationFailure ("parse failed: " ++ err)
        Right m -> do
          _sm_id m `shouldBe` parseSessionId "test-20240101-120000-000"
          case _sm_kind m of
            SkProvider ps -> do
              _ps_provider ps `shouldBe` ProviderId "anthropic"
              _ps_model ps `shouldBe` ModelId "claude-opus-4-7"
              _ps_agent ps `shouldBe` Nothing
            other -> expectationFailure ("Expected SkProvider, got: " ++ show other)

    it "decodes harness-claude-code.json as SkHarness with HClaudeCode" $ do
      raw <- LBS.readFile "test/fixtures/legacy-session-json/harness-claude-code.json"
      case Aeson.eitherDecode' raw :: Either String SessionMeta of
        Left err -> expectationFailure ("parse failed: " ++ err)
        Right m -> do
          _sm_id m `shouldBe` parseSessionId "test-20240101-120000-001"
          case _sm_kind m of
            SkHarness hs -> _h_flavour hs `shouldBe` HClaudeCode
            other -> expectationFailure ("Expected SkHarness, got: " ++ show other)

    it "decodes no-agent.json as SkProvider with openai (inferred)" $ do
      raw <- LBS.readFile "test/fixtures/legacy-session-json/no-agent.json"
      case Aeson.eitherDecode' raw :: Either String SessionMeta of
        Left err -> expectationFailure ("parse failed: " ++ err)
        Right m -> do
          _sm_id m `shouldBe` parseSessionId "test-20240101-120000-002"
          case _sm_kind m of
            SkProvider ps -> do
              _ps_provider ps `shouldBe` ProviderId "openai"
              _ps_model ps `shouldBe` ModelId "gpt-4o"
              _ps_agent ps `shouldBe` Nothing
            other -> expectationFailure ("Expected SkProvider, got: " ++ show other)

    it "decodes missing-runtime.json defaulting to SkProvider" $ do
      raw <- LBS.readFile "test/fixtures/legacy-session-json/missing-runtime.json"
      case Aeson.eitherDecode' raw :: Either String SessionMeta of
        Left err -> expectationFailure ("parse failed: " ++ err)
        Right m -> do
          _sm_id m `shouldBe` parseSessionId "test-20240101-120000-003"
          case _sm_kind m of
            SkProvider ps -> do
              _ps_provider ps `shouldBe` ProviderId "anthropic"
              _ps_model ps `shouldBe` ModelId "claude-opus-4-7"
            other -> expectationFailure ("Expected SkProvider, got: " ++ show other)

    it "decodes new-format-provider.json via the 'kind' key path" $ do
      raw <- LBS.readFile "test/fixtures/legacy-session-json/new-format-provider.json"
      case Aeson.eitherDecode' raw :: Either String SessionMeta of
        Left err -> expectationFailure ("parse failed: " ++ err)
        Right m -> do
          _sm_id m `shouldBe` parseSessionId "test-20240101-120000-004"
          case _sm_kind m of
            SkProvider ps -> do
              _ps_provider ps `shouldBe` ProviderId "anthropic"
              _ps_model ps `shouldBe` ModelId "claude-opus-4-7"
            other -> expectationFailure ("Expected SkProvider, got: " ++ show other)

    it "preserves _sm_agent and _sm_model through round-trip" $ do
      let zoeAgent = case mkAgentName "zoe" of
            Right n -> n
            Left e  -> error ("test fixture: " ++ show e)
          t0 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 0)
          meta = SessionMeta
            { _sm_id                = parseSessionId "rt-test"
            , _sm_agent             = Just zoeAgent
            , _sm_kind              = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "claude-3-opus") (Just zoeAgent))
            , _sm_model             = "claude-3-opus"
            , _sm_channel           = "cli"
            , _sm_createdAt         = t0
            , _sm_lastActive        = t0
            , _sm_bootstrapConsumed = False
            , _sm_archived          = False
            , _sm_description       = Nothing
            , _sm_autoSummary       = Nothing
            , _sm_source            = Nothing
            }
      case Aeson.decode (Aeson.encode meta) :: Maybe SessionMeta of
        Nothing -> expectationFailure "round-trip decode failed"
        Just m -> do
          _sm_agent m `shouldBe` Just zoeAgent
          _sm_model m `shouldBe` "claude-3-opus"

  describe "SessionMeta encodes with 'kind' key" $ do
    it "ToJSON writes 'kind' field (not 'runtime')" $ do
      let t0 = UTCTime (ModifiedJulianDay 60759) (picosecondsToDiffTime 0)
          meta = SessionMeta
            { _sm_id                = parseSessionId "test-1"
            , _sm_agent             = Nothing
            , _sm_kind              = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "m") Nothing)
            , _sm_model             = "m"
            , _sm_channel           = "cli"
            , _sm_createdAt         = t0
            , _sm_lastActive        = t0
            , _sm_bootstrapConsumed = False
            , _sm_archived          = False
            , _sm_description       = Nothing
            , _sm_autoSummary       = Nothing
            , _sm_source            = Nothing
            }
          encoded = Aeson.encode meta
          obj = Aeson.decode encoded :: Maybe Aeson.Object
      case obj of
        Just o -> do
          -- "kind" key should be present
          case Aeson.parseMaybe (Aeson..: "kind") o :: Maybe Aeson.Value of
            Just _  -> pure ()
            Nothing -> expectationFailure "'kind' key should be present in encoded SessionMeta"
          -- "runtime" key should NOT be present in new format
          case Aeson.parseMaybe (Aeson..: "runtime") o :: Maybe Aeson.Value of
            Nothing -> pure ()
            Just _  -> expectationFailure "'runtime' key should not be present in encoded SessionMeta"
        Nothing -> expectationFailure "Failed to decode SessionMeta as Object"
