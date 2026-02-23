module Security.PairingSpec (spec) where

import Data.Char (isDigit)
import Data.Either (isRight)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Security.Pairing
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "generatePairingCode" $ do
    it "generates a 6-digit code" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      withPairingCode code $ \codeText ->
        T.length codeText `shouldBe` 6

    it "generates different codes each time" $ do
      st <- mkPairingState defaultPairingConfig
      code1 <- generatePairingCode st
      code2 <- generatePairingCode st
      withPairingCode code1 $ \t1 ->
        withPairingCode code2 $ \t2 ->
          t1 `shouldNotBe` t2

    it "code is all digits" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      withPairingCode code $ \codeText ->
        T.all isDigit codeText `shouldBe` True

  describe "attemptPair" $ do
    it "succeeds with a valid code" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      result <- attemptPair st "client1" code
      result `shouldSatisfy` isRight

    it "fails with an invalid code" $ do
      st <- mkPairingState defaultPairingConfig
      let badCode = mkPairingCode "999999"
      result <- attemptPair st "client1" badCode
      result `shouldSatisfy` isLeftWith InvalidCode

    it "code can only be used once" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      _ <- attemptPair st "client1" code
      result <- attemptPair st "client2" code
      result `shouldSatisfy` isLeftWith InvalidCode

    it "locks out after max attempts" $ do
      let config = defaultPairingConfig { _pc_maxAttempts = 3 }
      st <- mkPairingState config
      let badCode = mkPairingCode "000000"
      _ <- attemptPair st "client1" badCode
      _ <- attemptPair st "client1" badCode
      _ <- attemptPair st "client1" badCode
      result <- attemptPair st "client1" badCode
      result `shouldSatisfy` isLeftWith LockedOut

    it "lockout is per-client" $ do
      let config = defaultPairingConfig { _pc_maxAttempts = 2 }
      st <- mkPairingState config
      code <- generatePairingCode st
      let badCode = mkPairingCode "000000"
      _ <- attemptPair st "client1" badCode
      _ <- attemptPair st "client1" badCode
      -- client1 is locked out
      result1 <- attemptPair st "client1" code
      result1 `shouldSatisfy` isLeftWith LockedOut
      -- client2 is not locked out
      result2 <- attemptPair st "client2" code
      result2 `shouldSatisfy` isRight

  describe "verifyToken" $ do
    it "verifies a token issued by attemptPair" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      result <- attemptPair st "client1" code
      case result of
        Left err -> expectationFailure $ "pairing failed: " ++ show err
        Right token -> do
          verified <- verifyToken st token
          verified `shouldBe` True

    it "rejects an unknown token" $ do
      st <- mkPairingState defaultPairingConfig
      let fakeToken = mkBearerToken "not-a-real-token"
      verified <- verifyToken st fakeToken
      verified `shouldBe` False

  describe "revokeToken" $ do
    it "makes a previously valid token invalid" $ do
      st <- mkPairingState defaultPairingConfig
      code <- generatePairingCode st
      result <- attemptPair st "client1" code
      case result of
        Left err -> expectationFailure $ "pairing failed: " ++ show err
        Right token -> do
          verified1 <- verifyToken st token
          verified1 `shouldBe` True
          revokeToken st token
          verified2 <- verifyToken st token
          verified2 `shouldBe` False

  describe "PairingConfig" $ do
    it "has Show and Eq instances" $ do
      show defaultPairingConfig `shouldContain` "PairingConfig"
      defaultPairingConfig `shouldBe` defaultPairingConfig

  describe "PairingError" $ do
    it "has Show and Eq instances" $ do
      show InvalidCode `shouldBe` "InvalidCode"
      show LockedOut `shouldBe` "LockedOut"
      show CodeExpired `shouldBe` "CodeExpired"
      InvalidCode `shouldNotBe` LockedOut

isLeftWith :: Eq a => a -> Either a b -> Bool
isLeftWith expected (Left actual) = expected == actual
isLeftWith _ _ = False
