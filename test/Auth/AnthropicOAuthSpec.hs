module Auth.AnthropicOAuthSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime)
import Data.Word (Word8)
import Test.Hspec

import PureClaw.Auth.AnthropicOAuth
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "generateCodeVerifier" $ do
    it "generates a 43-character URL-safe base64url string" $ do
      verifier <- generateCodeVerifier
      BS.length verifier `shouldBe` 43

    it "uses only URL-safe characters (no padding)" $ do
      verifier <- generateCodeVerifier
      BS.all isUrlSafe verifier `shouldBe` True

    it "generates different verifiers each time" $ do
      v1 <- generateCodeVerifier
      v2 <- generateCodeVerifier
      v1 `shouldNotBe` v2

  describe "computeCodeChallenge" $ do
    it "matches the RFC 7636 Appendix B test vector" $ do
      -- From RFC 7636, Appendix B
      let verifier  = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" :: ByteString
          expected  = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" :: ByteString
      computeCodeChallenge verifier `shouldBe` expected

    it "produces a 43-character output" $ do
      let challenge = computeCodeChallenge "any-verifier-value-here-works-fine"
      BS.length challenge `shouldBe` 43

    it "output contains only URL-safe characters" $ do
      let challenge = computeCodeChallenge "test-verifier-value"
      BS.all isUrlSafe challenge `shouldBe` True

  describe "buildAuthorizationUrl" $ do
    it "starts with the configured auth URL" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isPrefixOf "https://claude.ai/oauth/authorize"

    it "includes response_type=code" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "response_type=code"

    it "includes code_challenge_method=S256" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "code_challenge_method=S256"

    it "includes the client_id" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "client_id="

    it "includes the scope" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "scope="

    it "includes the state parameter" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "mystate" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "state=mystate"

    it "uses the OOB redirect URI" $ do
      let url = buildAuthorizationUrl defaultOAuthConfig "verifier" "state" oobRedirectUri
      url `shouldSatisfy` T.isInfixOf "urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob"

  describe "parseTokenResponse" $ do
    let baseTime = UTCTime (fromGregorian 2025 1 1) 0

    it "parses a valid token response" $ do
      let json = "{\"access_token\":\"acc_tok\",\"refresh_token\":\"ref_tok\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
      case parseTokenResponse baseTime (BL.fromStrict (TE.encodeUtf8 (T.pack json))) of
        Left err -> expectationFailure ("Parse failed: " <> T.unpack err)
        Right tokens -> do
          withBearerToken (_oat_accessToken tokens) id `shouldBe` "acc_tok"
          _oat_refreshToken tokens `shouldBe` "ref_tok"

    it "computes the expiry correctly" $ do
      let json = "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":7200}"
          expected = addUTCTime 7200 baseTime
      case parseTokenResponse baseTime (BL.fromStrict (TE.encodeUtf8 (T.pack json))) of
        Left err  -> expectationFailure ("Parse failed: " <> T.unpack err)
        Right tokens -> _oat_expiresAt tokens `shouldBe` expected

    it "fails when access_token is missing" $ do
      let json = "{\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
      parseTokenResponse baseTime (BL.fromStrict (TE.encodeUtf8 (T.pack json)))
        `shouldSatisfy` isLeft

    it "fails when refresh_token is missing" $ do
      let json = "{\"access_token\":\"a\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
      parseTokenResponse baseTime (BL.fromStrict (TE.encodeUtf8 (T.pack json)))
        `shouldSatisfy` isLeft

    it "fails on invalid JSON" $ do
      parseTokenResponse baseTime "not json"
        `shouldSatisfy` isLeft

  describe "serializeTokens / deserializeTokens" $ do
    let baseTime = UTCTime (fromGregorian 2025 6 15) 43200
        makeTokens = OAuthTokens
          { _oat_accessToken  = mkBearerToken "access_token_value"
          , _oat_refreshToken = "refresh_token_value"
          , _oat_expiresAt    = addUTCTime 3600 baseTime
          }

    it "roundtrips access token" $ do
      case deserializeTokens (serializeTokens makeTokens) of
        Left err -> expectationFailure ("Deserialize failed: " <> T.unpack err)
        Right t  -> withBearerToken (_oat_accessToken t) id `shouldBe` "access_token_value"

    it "roundtrips refresh token" $ do
      case deserializeTokens (serializeTokens makeTokens) of
        Left err -> expectationFailure ("Deserialize failed: " <> T.unpack err)
        Right t  -> _oat_refreshToken t `shouldBe` "refresh_token_value"

    it "roundtrips expiry time (to second precision)" $ do
      case deserializeTokens (serializeTokens makeTokens) of
        Left err -> expectationFailure ("Deserialize failed: " <> T.unpack err)
        Right t  -> _oat_expiresAt t `shouldBe` _oat_expiresAt makeTokens

    it "fails on invalid JSON" $ do
      deserializeTokens "not json" `shouldSatisfy` isLeft

    it "fails on missing fields" $ do
      deserializeTokens "{}" `shouldSatisfy` isLeft

-- | Characters allowed in PKCE code verifier / challenge (URL-safe base64, no padding).
isUrlSafe :: Word8 -> Bool
isUrlSafe w =
     (w >= 0x41 && w <= 0x5a)  -- A-Z
  || (w >= 0x61 && w <= 0x7a)  -- a-z
  || (w >= 0x30 && w <= 0x39)  -- 0-9
  || w == 0x2d                  -- -
  || w == 0x5f                  -- _
