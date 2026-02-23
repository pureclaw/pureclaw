module Gateway.AuthSpec (spec) where

import Data.Aeson
import Data.ByteString.Base16 qualified as Base16
import Data.Either (isLeft, isRight)
import Test.Hspec

import PureClaw.Gateway.Auth
import PureClaw.Handles.Log
import PureClaw.Security.Pairing
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "authenticateRequest" $ do
    it "succeeds with a valid bearer token" $ do
      ps <- mkPairingState defaultPairingConfig
      code <- generatePairingCode ps
      result <- attemptPair ps "test" code
      case result of
        Left err -> expectationFailure $ "pairing failed: " ++ show err
        Right token ->
          withBearerToken token $ \tokenBytes -> do
            let header = "Bearer " <> Base16.encode tokenBytes
            authResult <- authenticateRequest ps header mkNoOpLogHandle
            authResult `shouldSatisfy` isRight

    it "rejects an invalid bearer token" $ do
      ps <- mkPairingState defaultPairingConfig
      let header = "Bearer fake-token-bytes"
      result <- authenticateRequest ps header mkNoOpLogHandle
      result `shouldSatisfy` isLeft

    it "rejects a malformed Authorization header" $ do
      ps <- mkPairingState defaultPairingConfig
      let header = "Basic dXNlcjpwYXNz"
      result <- authenticateRequest ps header mkNoOpLogHandle
      result `shouldBe` Left MalformedHeader

    it "rejects an empty token" $ do
      ps <- mkPairingState defaultPairingConfig
      let header = "Bearer "
      result <- authenticateRequest ps header mkNoOpLogHandle
      result `shouldSatisfy` isLeft

  describe "handlePairRequest" $ do
    it "succeeds with a valid pairing code" $ do
      ps <- mkPairingState defaultPairingConfig
      code <- generatePairingCode ps
      withPairingCode code $ \codeText -> do
        let req = PairRequest codeText
        result <- handlePairRequest ps "client1" req mkNoOpLogHandle
        result `shouldSatisfy` isRight

    it "fails with an invalid pairing code" $ do
      ps <- mkPairingState defaultPairingConfig
      let req = PairRequest "999999"
      result <- handlePairRequest ps "client1" req mkNoOpLogHandle
      result `shouldBe` Left InvalidCode

    it "fails when locked out" $ do
      let config = defaultPairingConfig { _pc_maxAttempts = 2 }
      ps <- mkPairingState config
      let req = PairRequest "000000"
      _ <- handlePairRequest ps "client1" req mkNoOpLogHandle
      _ <- handlePairRequest ps "client1" req mkNoOpLogHandle
      result <- handlePairRequest ps "client1" req mkNoOpLogHandle
      result `shouldBe` Left LockedOut

  describe "PairRequest" $ do
    it "decodes from JSON" $ do
      let json = encode (object ["code" .= ("123456" :: String)])
      case eitherDecode json of
        Left err -> expectationFailure err
        Right (PairRequest c) -> c `shouldBe` "123456"

    it "rejects invalid JSON" $ do
      let json = encode (object ["wrong" .= ("field" :: String)])
      (eitherDecode json :: Either String PairRequest) `shouldSatisfy` isLeft

  describe "PairResponse" $ do
    it "encodes to JSON with token field" $ do
      let resp = PairResponse "test-token"
          json = encode resp
      case decode json of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldBe` object ["token" .= ("test-token" :: String)]

  describe "AuthError" $ do
    it "has Show and Eq instances" $ do
      show MissingToken `shouldBe` "MissingToken"
      show InvalidToken `shouldBe` "InvalidToken"
      show MalformedHeader `shouldBe` "MalformedHeader"
      MissingToken `shouldNotBe` InvalidToken
