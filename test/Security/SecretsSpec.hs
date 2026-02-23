module Security.SecretsSpec (spec) where

import Test.Hspec
import Data.ByteString (ByteString)
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "ApiKey" $ do
    it "Show is redacted" $ do
      let k = mkApiKey "sk-secret-123"
      show k `shouldBe` "ApiKey <redacted>"

    it "withApiKey provides access to the underlying value" $ do
      let k = mkApiKey "sk-secret-123"
      withApiKey k id `shouldBe` ("sk-secret-123" :: ByteString)

  describe "BearerToken" $ do
    it "Show is redacted" $ do
      let t = mkBearerToken "token-abc"
      show t `shouldBe` "BearerToken <redacted>"

    it "withBearerToken provides access" $ do
      let t = mkBearerToken "token-abc"
      withBearerToken t id `shouldBe` ("token-abc" :: ByteString)

  describe "PairingCode" $ do
    it "Show is redacted" $ do
      let p = mkPairingCode "123456"
      show p `shouldBe` "PairingCode <redacted>"

    it "withPairingCode provides access" $ do
      let p = mkPairingCode "123456"
      withPairingCode p id `shouldBe` "123456"

  describe "SecretKey" $ do
    it "Show is redacted" $ do
      let s = mkSecretKey "supersecretkey"
      show s `shouldBe` "SecretKey <redacted>"

    it "withSecretKey provides access" $ do
      let s = mkSecretKey "supersecretkey"
      withSecretKey s id `shouldBe` ("supersecretkey" :: ByteString)
