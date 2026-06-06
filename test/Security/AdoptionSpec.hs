module Security.AdoptionSpec (spec) where

import Test.Hspec

import PureClaw.Security.Adoption

spec :: Spec
spec = do
  describe "authorizeAdoption (consent-only gate — allow-list dropped)" $ do
    -- W1.1: interactive consent IS the consent. ANY session string is
    -- adoptable when a human picked it in the foreground New-Tab form.
    -- There is NO allow-list: a bare/odd/long name still mints a token.
    it "W1.1 ConsentInteractive => Right for ANY session (no allow-list), round-trips" $
      case authorizeAdoption ConsentInteractive "any-session" of
        Right ah -> adoptedSession ah `shouldBe` "any-session"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    it "W1.1 ConsentInteractive => Right for a session that the old allow-list would have rejected" $
      -- '*' and a bare leading '-' are exactly the strings the dropped
      -- parseSessionPattern would have refused; consent-only allows them
      -- (the adopt MECHANISM, not the gate, defends identifier hygiene — C3).
      case authorizeAdoption ConsentInteractive "*" of
        Right ah -> adoptedSession ah `shouldBe` "*"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    it "W1.1 ConsentInteractive => Right for the empty session string too" $
      case authorizeAdoption ConsentInteractive "" of
        Right ah -> adoptedSession ah `shouldBe` ""
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    -- W1.1b: the web/gateway UI is an authorizing consent channel. Choosing
    -- "Existing Harness" and picking a window in the browser IS the consent, so
    -- the gateway must mint a token for ANY session (same as interactive).
    it "W1.1b ConsentWeb => Right for ANY session (the web UI selection is the consent)" $
      case authorizeAdoption ConsentWeb "any-session" of
        Right ah -> adoptedSession ah `shouldBe` "any-session"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    it "W1.1b ConsentWeb => Right for an odd session name the old allow-list would reject" $
      case authorizeAdoption ConsentWeb "*" of
        Right ah -> adoptedSession ah `shouldBe` "*"
        Left e   -> expectationFailure ("expected Right, got " <> show e)

    -- W1.2: the LOAD-BEARING remaining control. Truly unattended runs (tests,
    -- bot/cron/import — no UI at all) have no human confirming, so adoption
    -- STILL fails closed.
    it "W1.2 ConsentHeadless => Left AdoptNoConsentChannel for ANY session (headless STILL denied)" $
      authorizeAdoption ConsentHeadless "any-session"
        `shouldBe` Left AdoptNoConsentChannel

    it "W1.2 ConsentHeadless denies even a benign-looking session name" $
      authorizeAdoption ConsentHeadless "work-1"
        `shouldBe` Left AdoptNoConsentChannel

  describe "AdoptError" $ do
    it "has a single remaining constructor (AdoptNoConsentChannel) with Eq/Show" $ do
      AdoptNoConsentChannel `shouldBe` AdoptNoConsentChannel
      show AdoptNoConsentChannel `shouldSatisfy` (not . null)

  describe "derived instances (Eq/Show)" $ do
    it "ConsentChannel has Eq and Show" $ do
      ConsentInteractive `shouldBe` ConsentInteractive
      (ConsentInteractive == ConsentHeadless) `shouldBe` False
      show ConsentHeadless `shouldBe` "ConsentHeadless"

    it "W1.3 AdoptedHarness round-trip token has Eq and Show" $
      case ( authorizeAdoption ConsentInteractive "work"
           , authorizeAdoption ConsentInteractive "work"
           ) of
        (Right a, Right b) -> do
          a `shouldBe` b
          show a `shouldSatisfy` (not . null)
        _ -> expectationFailure "expected two Right tokens"
