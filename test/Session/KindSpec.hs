module Session.KindSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Maybe (isNothing)
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentName, mkAgentName)
import PureClaw.Core.Types (ModelId (..), ProviderId (..))
import PureClaw.Session.Kind

-- | Helper to force a Right or fail the test.
unsafeRight :: (Show e) => Either e a -> a
unsafeRight (Right a) = a
unsafeRight (Left e) = error ("unsafeRight: Left " ++ show e)

-- | Helper to build an AgentName for tests.
testAgentName :: AgentName
testAgentName = unsafeRight (mkAgentName "my-agent")

spec :: Spec
spec = do
  -- -----------------------------------------------------------------------
  -- Existing tests (mkContainerTarget, mkHCustom, inferProviderId,
  -- fixedFlavourLookup) preserved below.
  -- -----------------------------------------------------------------------
  describe "mkContainerTarget" $ do
    it "accepts a plain container name" $
      (unContainerTarget <$> mkContainerTarget "mycontainer")
        `shouldBe` Right "mycontainer"

    it "accepts kubectl pod/name:container format" $
      (unContainerTarget <$> mkContainerTarget "pod/myapp:web")
        `shouldBe` Right "pod/myapp:web"

    it "rejects empty string with TargetEmpty" $
      mkContainerTarget "" `shouldBe` Left TargetEmpty

    it "rejects shell metacharacters with TargetInvalidChars" $
      mkContainerTarget "foo;rm -rf /" `shouldSatisfy` isInvalidChars

    it "rejects spaces with TargetInvalidChars" $
      mkContainerTarget "foo bar" `shouldSatisfy` isInvalidChars

    it "rejects backtick with TargetInvalidChars" $
      mkContainerTarget "foo`echo hi`" `shouldSatisfy` isInvalidChars

    it "rejects dollar sign with TargetInvalidChars" $
      mkContainerTarget "foo$HOME" `shouldSatisfy` isInvalidChars

    it "rejects pipe with TargetInvalidChars" $
      mkContainerTarget "foo|bar" `shouldSatisfy` isInvalidChars

    it "rejects ampersand with TargetInvalidChars" $
      mkContainerTarget "foo&bar" `shouldSatisfy` isInvalidChars

  describe "mkHCustom" $ do
    it "accepts a bare name" $
      mkHCustom "claude" `shouldBe` Right (HCustom "claude")

    it "rejects forward slash (path separator)" $
      mkHCustom "/tmp/evil/claude" `shouldSatisfy` isPathSep

    it "rejects backslash (path separator)" $
      mkHCustom "foo\\bar" `shouldSatisfy` isPathSep

    it "rejects empty string with HCustomEmpty" $
      mkHCustom "" `shouldBe` Left HCustomEmpty

  describe "inferProviderId" $ do
    it "maps claude-* to anthropic" $
      inferProviderId "claude-opus-4-7" `shouldBe` ProviderId "anthropic"

    it "maps opus-* to anthropic" $
      inferProviderId "opus-4" `shouldBe` ProviderId "anthropic"

    it "maps sonnet-* to anthropic" $
      inferProviderId "sonnet-3.5" `shouldBe` ProviderId "anthropic"

    it "maps haiku-* to anthropic" $
      inferProviderId "haiku-3" `shouldBe` ProviderId "anthropic"

    it "maps gpt-* to openai" $
      inferProviderId "gpt-4o" `shouldBe` ProviderId "openai"

    it "maps o1-* to openai" $
      inferProviderId "o1-preview" `shouldBe` ProviderId "openai"

    it "maps o3-* to openai" $
      inferProviderId "o3-mini" `shouldBe` ProviderId "openai"

    it "maps o4-* to openai" $
      inferProviderId "o4-mini" `shouldBe` ProviderId "openai"

    it "maps gemini-* to google" $
      inferProviderId "gemini-2.0" `shouldBe` ProviderId "google"

    it "falls back to anthropic for unknown models" $
      inferProviderId "unknown-model" `shouldBe` ProviderId "anthropic"

  describe "fixedFlavourLookup" $ do
    it "maps claude-code to HClaudeCode" $
      fixedFlavourLookup "claude-code" `shouldBe` HClaudeCode

    it "maps codex to HCodex" $
      fixedFlavourLookup "codex" `shouldBe` HCodex

    it "maps opencode to HOpenCode" $
      fixedFlavourLookup "opencode" `shouldBe` HOpenCode

    it "maps hermes to HHermes" $
      fixedFlavourLookup "hermes" `shouldBe` HHermes

    it "maps pureclaw to HPureClaw" $
      fixedFlavourLookup "pureclaw" `shouldBe` HPureClaw

    it "maps unknown harness name to HCustom" $
      fixedFlavourLookup "unknown-harness" `shouldBe` HCustom "unknown-harness"

  -- -----------------------------------------------------------------------
  -- Aeson round-trip tests
  -- -----------------------------------------------------------------------
  describe "Aeson round-trip" $ do
    describe "ContainerEngine" $ do
      it "round-trips Docker" $
        Aeson.decode (Aeson.encode Docker) `shouldBe` Just Docker

      it "round-trips Podman" $
        Aeson.decode (Aeson.encode Podman) `shouldBe` Just Podman

      it "round-trips Kubectl" $
        Aeson.decode (Aeson.encode Kubectl) `shouldBe` Just Kubectl

    describe "ContainerTarget" $ do
      it "round-trips a valid target" $ do
        let ct = unsafeRight (mkContainerTarget "myapp")
        Aeson.decode (Aeson.encode ct) `shouldBe` Just ct

    describe "ContainerSpec" $ do
      it "round-trips a ContainerSpec" $ do
        let ct = unsafeRight (mkContainerTarget "myapp")
            cs = ContainerSpec Docker ct
        Aeson.decode (Aeson.encode cs) `shouldBe` Just cs

    describe "TmuxConfig" $ do
      it "round-trips with pane" $ do
        let tc = TmuxConfig "main" "0" (Just "1")
        Aeson.decode (Aeson.encode tc) `shouldBe` Just tc

      it "round-trips without pane" $ do
        let tc = TmuxConfig "main" "0" Nothing
        Aeson.decode (Aeson.encode tc) `shouldBe` Just tc

    describe "SshConfig" $ do
      it "round-trips with port" $ do
        let sc = SshConfig "admin" "remote.example.com" (Just 22)
        Aeson.decode (Aeson.encode sc) `shouldBe` Just sc

      it "round-trips without port" $ do
        let sc = SshConfig "admin" "remote.example.com" Nothing
        Aeson.decode (Aeson.encode sc) `shouldBe` Just sc

    describe "TerminalBackend" $ do
      it "round-trips TbLocal" $
        Aeson.decode (Aeson.encode TbLocal) `shouldBe` Just TbLocal

      it "round-trips TbTmux" $ do
        let tb = TbTmux (TmuxConfig "main" "0" (Just "1"))
        Aeson.decode (Aeson.encode tb) `shouldBe` Just tb

      it "round-trips TbSsh" $ do
        let tb = TbSsh (SshConfig "admin" "remote.example.com" (Just 22))
        Aeson.decode (Aeson.encode tb) `shouldBe` Just tb

      it "round-trips TbContainer" $ do
        let ct = unsafeRight (mkContainerTarget "myapp")
            tb = TbContainer (ContainerSpec Docker ct)
        Aeson.decode (Aeson.encode tb) `shouldBe` Just tb

    describe "HarnessFlavour" $ do
      it "round-trips HClaudeCode" $
        Aeson.decode (Aeson.encode HClaudeCode) `shouldBe` Just HClaudeCode

      it "round-trips HCodex" $
        Aeson.decode (Aeson.encode HCodex) `shouldBe` Just HCodex

      it "round-trips HOpenCode" $
        Aeson.decode (Aeson.encode HOpenCode) `shouldBe` Just HOpenCode

      it "round-trips HHermes" $
        Aeson.decode (Aeson.encode HHermes) `shouldBe` Just HHermes

      it "round-trips HPureClaw" $
        Aeson.decode (Aeson.encode HPureClaw) `shouldBe` Just HPureClaw

      it "round-trips HCustom" $ do
        let hc = unsafeRight (mkHCustom "myharness")
        Aeson.decode (Aeson.encode hc) `shouldBe` Just hc

    describe "ProviderSpec" $ do
      it "round-trips with agent" $ do
        let ps = ProviderSpec (ProviderId "anthropic") (ModelId "claude-opus-4-7") (Just testAgentName)
        Aeson.decode (Aeson.encode ps) `shouldBe` Just ps

      it "round-trips without agent" $ do
        let ps = ProviderSpec (ProviderId "anthropic") (ModelId "claude-opus-4-7") Nothing
        Aeson.decode (Aeson.encode ps) `shouldBe` Just ps

    describe "HarnessSpec" $ do
      it "round-trips with cwd and args" $ do
        let hs' = HarnessSpec HClaudeCode TbLocal (Just "/tmp") ["--flag"]
        Aeson.decode (Aeson.encode hs') `shouldBe` Just hs'

      it "round-trips without cwd, empty args" $ do
        let hs' = HarnessSpec HClaudeCode TbLocal Nothing []
        Aeson.decode (Aeson.encode hs') `shouldBe` Just hs'

    describe "SessionKind" $ do
      it "round-trips SkProvider" $ do
        let sk = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "claude-opus-4-7") (Just testAgentName))
        Aeson.decode (Aeson.encode sk) `shouldBe` Just sk

      it "round-trips SkHarness" $ do
        let sk = SkHarness (HarnessSpec HClaudeCode TbLocal (Just "/tmp") ["--flag"])
        Aeson.decode (Aeson.encode sk) `shouldBe` Just sk

  -- -----------------------------------------------------------------------
  -- Security validation at deserialization
  -- -----------------------------------------------------------------------
  describe "Aeson security validation" $ do
    it "FromJSON HarnessFlavour rejects custom:/tmp/evil (S12)" $ do
      let json = Aeson.String "custom:/tmp/evil"
      (Aeson.parseMaybe Aeson.parseJSON json :: Maybe HarnessFlavour)
        `shouldSatisfy` isNothing

    it "FromJSON ContainerTarget rejects foo;rm -rf / (S1)" $ do
      let json = Aeson.String "foo;rm -rf /"
      (Aeson.parseMaybe Aeson.parseJSON json :: Maybe ContainerTarget)
        `shouldSatisfy` isNothing

  -- -----------------------------------------------------------------------
  -- Tag discrimination tests
  -- -----------------------------------------------------------------------
  describe "Aeson tag discrimination" $ do
    it "parses {\"tag\":\"provider\",...} as SkProvider" $ do
      let json = Aeson.object
            [ "tag" Aeson..= ("provider" :: String)
            , "provider" Aeson..= ("anthropic" :: String)
            , "model" Aeson..= ("claude-opus-4-7" :: String)
            ]
      let result = Aeson.parseMaybe Aeson.parseJSON json :: Maybe SessionKind
      case result of
        Just (SkProvider _) -> pure ()
        other -> expectationFailure ("Expected SkProvider, got: " ++ show other)

    it "parses {\"tag\":\"harness\",...} as SkHarness" $ do
      let json = Aeson.object
            [ "tag" Aeson..= ("harness" :: String)
            , "flavour" Aeson..= ("claude-code" :: String)
            , "backend" Aeson..= Aeson.object ["tag" Aeson..= ("local" :: String)]
            ]
      let result = Aeson.parseMaybe Aeson.parseJSON json :: Maybe SessionKind
      case result of
        Just (SkHarness _) -> pure ()
        other -> expectationFailure ("Expected SkHarness, got: " ++ show other)

    it "rejects unknown tag" $ do
      let json = Aeson.object
            [ "tag" Aeson..= ("unknown" :: String)
            , "provider" Aeson..= ("anthropic" :: String)
            , "model" Aeson..= ("claude-opus-4-7" :: String)
            ]
      (Aeson.parseMaybe Aeson.parseJSON json :: Maybe SessionKind)
        `shouldSatisfy` isNothing

  -- -----------------------------------------------------------------------
  -- Edge cases: optional field handling
  -- -----------------------------------------------------------------------
  describe "Aeson edge cases" $ do
    it "ProviderSpec with agent=Nothing omits agent key" $ do
      let ps = ProviderSpec (ProviderId "anthropic") (ModelId "claude-opus-4-7") Nothing
          encoded = Aeson.encode ps
          -- Decode as a raw Aeson.Object to inspect keys
          obj = Aeson.decode encoded :: Maybe Aeson.Object
      case obj of
        Just o ->
          case Aeson.parseMaybe (Aeson..: "agent") o :: Maybe Aeson.Value of
            Nothing -> pure ()  -- key absent, as expected
            Just _  -> expectationFailure "agent key should be absent when Nothing"
        Nothing -> expectationFailure "Failed to decode ProviderSpec as Object"

    it "HarnessSpec with cwd=Nothing, args=[] defaults on decode" $ do
      -- Encode a minimal HarnessSpec JSON without cwd and args
      let json = Aeson.object
            [ "flavour" Aeson..= ("claude-code" :: String)
            , "backend" Aeson..= Aeson.object ["tag" Aeson..= ("local" :: String)]
            ]
          expected = HarnessSpec HClaudeCode TbLocal Nothing []
      Aeson.parseMaybe Aeson.parseJSON json `shouldBe` Just expected

    it "TmuxConfig with pane=Nothing omits pane key" $ do
      let tc = TmuxConfig "main" "0" Nothing
          encoded = Aeson.encode tc
          obj = Aeson.decode encoded :: Maybe Aeson.Object
      case obj of
        Just o ->
          case Aeson.parseMaybe (Aeson..: "pane") o :: Maybe Aeson.Value of
            Nothing -> pure ()
            Just _  -> expectationFailure "pane key should be absent when Nothing"
        Nothing -> expectationFailure "Failed to decode TmuxConfig as Object"

    it "SshConfig with port=Nothing omits port key" $ do
      let sc = SshConfig "admin" "remote.example.com" Nothing
          encoded = Aeson.encode sc
          obj = Aeson.decode encoded :: Maybe Aeson.Object
      case obj of
        Just o ->
          case Aeson.parseMaybe (Aeson..: "port") o :: Maybe Aeson.Value of
            Nothing -> pure ()
            Just _  -> expectationFailure "port key should be absent when Nothing"
        Nothing -> expectationFailure "Failed to decode SshConfig as Object"

-- Helpers for pattern-matching on Left variants

isInvalidChars :: Either ContainerTargetError a -> Bool
isInvalidChars (Left (TargetInvalidChars _)) = True
isInvalidChars _                              = False

isPathSep :: Either HCustomError a -> Bool
isPathSep (Left (HCustomPathSeparator _)) = True
isPathSep _                                = False
