module Core.ErrorsSpec (spec) where

import Test.Hspec

import PureClaw.Core.Errors

-- A mock internal error type for testing ToPublicError
data MockInternalError
  = MockRateLimit Int
  | MockAuthFailure String
  | MockNetworkError String
  deriving (Show, Eq)

instance ToPublicError MockInternalError where
  toPublicError (MockRateLimit _)    = RateLimitError
  toPublicError (MockAuthFailure _)  = NotAllowedError
  toPublicError (MockNetworkError _) = TemporaryError "Upstream error"

spec :: Spec
spec = do
  describe "PublicError" $ do
    it "TemporaryError carries a message" $ do
      let e = TemporaryError "Something went wrong"
      show e `shouldSatisfy` (not . null)

    it "RateLimitError has Show" $ do
      show RateLimitError `shouldSatisfy` (not . null)

    it "NotAllowedError has Show" $ do
      show NotAllowedError `shouldSatisfy` (not . null)

    it "supports Eq" $ do
      RateLimitError `shouldBe` RateLimitError
      NotAllowedError `shouldNotBe` RateLimitError

  describe "ToPublicError" $ do
    it "strips internal detail from rate limit errors" $ do
      toPublicError (MockRateLimit 42) `shouldBe` RateLimitError

    it "strips internal detail from auth failures" $ do
      toPublicError (MockAuthFailure "bad token xyz") `shouldBe` NotAllowedError

    it "strips internal detail from network errors" $ do
      toPublicError (MockNetworkError "connection refused") `shouldBe` TemporaryError "Upstream error"
