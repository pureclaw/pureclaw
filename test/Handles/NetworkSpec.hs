module Handles.NetworkSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Network

spec :: Spec
spec = do
  describe "mkAllowedUrl" $ do
    it "allows a URL whose domain is in the allow-list" $ do
      let allowed = AllowList (Set.fromList ["api.example.com"])
      mkAllowedUrl allowed "https://api.example.com/v1/chat" `shouldSatisfy` isRight

    it "rejects a URL whose domain is not in the allow-list" $ do
      let allowed = AllowList (Set.fromList ["api.example.com"])
      mkAllowedUrl allowed "https://evil.com/steal" `shouldBe` Left (UrlNotAllowed "https://evil.com/steal")

    it "allows any URL when AllowAll is set" $ do
      mkAllowedUrl AllowAll "https://anywhere.com/anything" `shouldSatisfy` isRight

    it "rejects URLs without a scheme" $ do
      mkAllowedUrl AllowAll "not-a-url" `shouldBe` Left (UrlMalformed "not-a-url")

    it "allows http URLs" $ do
      mkAllowedUrl AllowAll "http://localhost:8080/api" `shouldSatisfy` isRight

    it "handles URLs with ports" $ do
      let allowed = AllowList (Set.fromList ["localhost"])
      mkAllowedUrl allowed "https://localhost:8443/api" `shouldSatisfy` isRight

    it "handles URLs with query strings" $ do
      let allowed = AllowList (Set.fromList ["api.example.com"])
      mkAllowedUrl allowed "https://api.example.com/v1?key=val" `shouldSatisfy` isRight

  describe "getAllowedUrl" $ do
    it "returns the original URL text" $ do
      case mkAllowedUrl AllowAll "https://example.com/path" of
        Right url -> getAllowedUrl url `shouldBe` "https://example.com/path"
        Left _ -> expectationFailure "mkAllowedUrl failed"

  describe "AllowedUrl Show" $ do
    it "shows the URL" $ do
      case mkAllowedUrl AllowAll "https://example.com" of
        Right url -> show url `shouldContain` "example.com"
        Left _ -> expectationFailure "mkAllowedUrl failed"

  describe "mkNoOpNetworkHandle" $ do
    it "httpGet returns 200 with empty body" $ do
      case mkAllowedUrl AllowAll "https://example.com" of
        Right url -> do
          resp <- _nh_httpGet mkNoOpNetworkHandle url
          _hr_statusCode resp `shouldBe` 200
          _hr_body resp `shouldBe` ""
        Left _ -> expectationFailure "mkAllowedUrl failed"

    it "httpPost returns 200 with empty body" $ do
      case mkAllowedUrl AllowAll "https://example.com" of
        Right url -> do
          resp <- _nh_httpPost mkNoOpNetworkHandle url "body"
          _hr_statusCode resp `shouldBe` 200
        Left _ -> expectationFailure "mkAllowedUrl failed"

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False
