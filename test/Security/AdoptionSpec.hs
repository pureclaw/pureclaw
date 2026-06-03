module Security.AdoptionSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import PureClaw.Security.Adoption
import PureClaw.Security.Policy

-- | A policy whose adoptable-session allow-list is exactly the given patterns.
-- Built from 'defaultPolicy' (deny-everything) so the only thing under test
-- is the adoption allow-list.
policyWith :: [SessionPattern] -> SecurityPolicy
policyWith pats = defaultPolicy { _sp_adoptableSessionPatterns = pats }

-- | Parse a pattern that the test author KNOWS is well-formed.
-- Fails loudly if the pattern is unexpectedly rejected, rather than silently
-- producing an empty allow-list (which would make a deny test pass for the
-- wrong reason).
mustParse :: Text -> SessionPattern
mustParse t = case parseSessionPattern t of
  Just p  -> p
  Nothing -> error ("test setup: parseSessionPattern rejected " <> show t)

isJustP :: Maybe a -> Bool
isJustP (Just _) = True
isJustP Nothing  = False

spec :: Spec
spec = do
  describe "parseSessionPattern" $ do
    it "rejects a bare '*' (no implicit allow-all)" $
      parseSessionPattern "*" `shouldBe` Nothing

    it "rejects the empty string" $
      parseSessionPattern "" `shouldBe` Nothing

    it "accepts a literal session name" $
      parseSessionPattern "work-1" `shouldSatisfy` isJustP

    it "accepts a non-empty prefix followed by a single trailing '*'" $
      parseSessionPattern "work*" `shouldSatisfy` isJustP

  describe "partitionSessionPatterns" $ do
    it "returns ([],[]) for an empty input" $
      partitionSessionPatterns [] `shouldBe` ([], [])

    it "drops rejected patterns into the invalids list and keeps order" $ do
      let (invalids, valids) =
            partitionSessionPatterns ["work", "*", "home*", ""]
      invalids `shouldBe` ["*", ""]
      valids `shouldBe` [mustParse "work", mustParse "home*"]

    it "an all-invalid input yields an empty allow-list (default-deny)" $ do
      let (invalids, valids) = partitionSessionPatterns ["*", ""]
      invalids `shouldBe` ["*", ""]
      valids `shouldBe` []

  describe "matchesSessionPattern" $ do
    it "empty pattern list never matches" $
      matchesSessionPattern [] "anything" `shouldBe` False

    it "a literal pattern matches the exact session name" $
      matchesSessionPattern [mustParse "work"] "work" `shouldBe` True

    it "a literal pattern does NOT match a different name" $
      matchesSessionPattern [mustParse "work"] "home" `shouldBe` False

    it "a literal pattern does NOT prefix-match" $
      matchesSessionPattern [mustParse "work"] "work-1" `shouldBe` False

    it "a 'work*' prefix pattern matches 'work-1'" $
      matchesSessionPattern [mustParse "work*"] "work-1" `shouldBe` True

    it "a 'work*' prefix pattern matches the bare prefix 'work'" $
      matchesSessionPattern [mustParse "work*"] "work" `shouldBe` True

    it "a 'work*' prefix pattern does NOT match 'home-1'" $
      matchesSessionPattern [mustParse "work*"] "home-1" `shouldBe` False

    it "a 'work*' prefix pattern does NOT match a shorter 'wor'" $
      matchesSessionPattern [mustParse "work*"] "wor" `shouldBe` False

    it "matches if ANY pattern in the list matches" $
      matchesSessionPattern [mustParse "work", mustParse "home*"] "home-7"
        `shouldBe` True

  describe "authorizeAdoption" $ do
    -- D1.1 default-deny
    it "denies adoption when the allow-list is empty (default-deny)" $
      authorizeAdoption defaultPolicy ConsentInteractive "any"
        `shouldBe` Left (AdoptNotAllowed "any")

    -- D1.2 literal allow + interactive -> Right, round-trips
    it "allows an allow-listed LITERAL session under interactive consent" $
      case authorizeAdoption (policyWith [mustParse "work"]) ConsentInteractive "work" of
        Right ah -> adoptedSession ah `shouldBe` "work"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    -- D1.2 prefix allow + interactive -> Right, round-trips
    it "allows an allow-listed PREFIX session under interactive consent" $
      case authorizeAdoption (policyWith [mustParse "work*"]) ConsentInteractive "work-9" of
        Right ah -> adoptedSession ah `shouldBe` "work-9"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    it "denies a non-allow-listed session even under interactive consent" $
      authorizeAdoption (policyWith [mustParse "work"]) ConsentInteractive "home"
        `shouldBe` Left (AdoptNotAllowed "home")

    -- D1.3 headless-deny dominates, checked FIRST
    it "denies headless adoption EVEN when the session is allow-listed" $
      authorizeAdoption (policyWith [mustParse "work"]) ConsentHeadless "work"
        `shouldBe` Left AdoptNoConsentChannel

    it "headless-deny dominates over the not-allowed check (consent first)" $
      -- session is NOT allow-listed AND headless: the headless error wins,
      -- proving consent is checked before the allow-list.
      authorizeAdoption defaultPolicy ConsentHeadless "home"
        `shouldBe` Left AdoptNoConsentChannel

  describe "derived instances (Eq/Show)" $ do
    it "ConsentChannel has Eq and Show" $ do
      ConsentInteractive `shouldBe` ConsentInteractive
      (ConsentInteractive == ConsentHeadless) `shouldBe` False
      show ConsentHeadless `shouldBe` "ConsentHeadless"

    it "AdoptedHarness round-trip token has Eq and Show" $
      case ( authorizeAdoption (policyWith [mustParse "work"]) ConsentInteractive "work"
           , authorizeAdoption (policyWith [mustParse "work"]) ConsentInteractive "work"
           ) of
        (Right a, Right b) -> do
          a `shouldBe` b
          show a `shouldSatisfy` (not . null)
        _ -> expectationFailure "expected two Right tokens"
