module Security.CryptoSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Security.Crypto
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "encrypt / decrypt" $ do
    it "roundtrips plaintext through encryption" $ do
      let key = mkSecretKey (BS.replicate 32 0x42)
          plaintext = "Hello, PureClaw!"
      encrypted <- encrypt key plaintext
      case encrypted of
        Left err -> expectationFailure $ "encrypt failed: " ++ show err
        Right ct -> decrypt key ct `shouldBe` Right plaintext

    it "produces different ciphertext each time (random IV)" $ do
      let key = mkSecretKey (BS.replicate 32 0xAA)
          plaintext = "same message"
      ct1 <- encrypt key plaintext
      ct2 <- encrypt key plaintext
      case (ct1, ct2) of
        (Right a, Right b) -> a `shouldNotBe` b
        _ -> expectationFailure "encryption failed"

    it "rejects keys that are not 32 bytes" $ do
      let shortKey = mkSecretKey (BS.replicate 16 0x00)
      result <- encrypt shortKey "test"
      result `shouldBe` Left InvalidKeyLength

    it "decrypt rejects keys that are not 32 bytes" $ do
      let shortKey = mkSecretKey (BS.replicate 16 0x00)
          fakeCt = BS.replicate 32 0x00
      decrypt shortKey fakeCt `shouldBe` Left InvalidKeyLength

    it "decrypt rejects ciphertext shorter than IV (16 bytes)" $ do
      let key = mkSecretKey (BS.replicate 32 0x42)
      decrypt key (BS.replicate 10 0x00) `shouldBe` Left InvalidIV

    it "handles empty plaintext" $ do
      let key = mkSecretKey (BS.replicate 32 0x42)
      encrypted <- encrypt key ""
      case encrypted of
        Left err -> expectationFailure $ "encrypt failed: " ++ show err
        Right ct -> do
          BS.length ct `shouldBe` 16  -- IV only, no ciphertext
          decrypt key ct `shouldBe` Right ""

  describe "getRandomBytes" $ do
    it "returns the requested number of bytes" $ do
      bytes <- getRandomBytes 32
      BS.length bytes `shouldBe` 32

    it "returns different bytes each time" $ do
      a <- getRandomBytes 16
      b <- getRandomBytes 16
      a `shouldNotBe` b

  describe "generateToken" $ do
    it "returns hex text of 2x the byte length" $ do
      token <- generateToken 16
      T.length token `shouldBe` 32

    it "returns different tokens each time" $ do
      a <- generateToken 16
      b <- generateToken 16
      a `shouldNotBe` b

  describe "constantTimeEq" $ do
    it "returns True for equal bytestrings" $
      constantTimeEq "hello" "hello" `shouldBe` True

    it "returns False for different bytestrings" $
      constantTimeEq "hello" "world" `shouldBe` False

    it "returns False for different lengths" $
      constantTimeEq "short" "longer" `shouldBe` False

  describe "sha256Hash" $ do
    it "returns consistent hashes" $
      sha256Hash "test" `shouldBe` sha256Hash "test"

    it "returns different hashes for different inputs" $
      sha256Hash "a" `shouldNotBe` sha256Hash "b"

    it "returns a 64-byte hex string" $
      BS.length (sha256Hash "test") `shouldBe` 64

  describe "CryptoError" $ do
    it "has Show instance" $
      show InvalidKeyLength `shouldBe` "InvalidKeyLength"

    it "has Eq instance" $
      InvalidKeyLength `shouldBe` InvalidKeyLength
