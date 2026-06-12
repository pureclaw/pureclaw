module Harness.ClaudeSessionSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy (ByteString)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Harness.ClaudeSession

-- | A known-good canonical UUID (lowercase hex, 8-4-4-4-12).
goodUuid :: Text
goodUuid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

spec :: Spec
spec = do
  describe "mkClaudeSessionUuid (D1.1)" $ do
    it "accepts a canonical lowercase uuid" $
      (unClaudeSessionUuid <$> mkClaudeSessionUuid goodUuid)
        `shouldBe` Right goodUuid

    it "has a total Ord/Eq (two distinct uuids compare and order)" $
      case ( mkClaudeSessionUuid "11111111-1111-1111-1111-111111111111"
           , mkClaudeSessionUuid "22222222-2222-2222-2222-222222222222"
           ) of
        (Right a, Right b) -> do
          a `shouldBe` a
          (a == b) `shouldBe` False
          (a < b) `shouldBe` True
        _ -> expectationFailure "expected both uuids to be valid"

    it "rejects the empty string" $
      mkClaudeSessionUuid "" `shouldBe` Left UuidEmpty

    it "rejects a string longer than 36 chars" $
      mkClaudeSessionUuid (goodUuid <> "0")
        `shouldBe` Left UuidWrongLength

    it "rejects a string shorter than 36 chars" $
      mkClaudeSessionUuid (T.dropEnd 1 goodUuid)
        `shouldBe` Left UuidWrongLength

    it "rejects an uppercase uuid (reject-unless-already-canonical)" $
      mkClaudeSessionUuid (T.toUpper goodUuid)
        `shouldSatisfy` isLeft

    it "reports UuidNotCanonical for uppercase (not a length error)" $
      mkClaudeSessionUuid (T.toUpper goodUuid)
        `shouldBe` Left (UuidNotCanonical (T.toUpper goodUuid))

    it "rejects a value containing a path separator '/'" $
      -- length preserved (36) but '/' is not valid in a uuid
      mkClaudeSessionUuid (T.take 35 goodUuid <> "/")
        `shouldSatisfy` isLeft

    it "rejects a value containing '..'" $
      mkClaudeSessionUuid "3f2504e0-4f89-41d3-9a0c-0305e82c..01"
        `shouldSatisfy` isLeft

    it "rejects a value containing a NUL byte" $
      mkClaudeSessionUuid (T.take 35 goodUuid <> "\NUL")
        `shouldSatisfy` isLeft

    it "rejects a non-hex character in a hex position" $
      -- replace first char with 'g' (non-hex), keep length 36
      mkClaudeSessionUuid ("g" <> T.drop 1 goodUuid)
        `shouldSatisfy` isLeft

    it "rejects wrong hyphen positions" $
      -- 36 chars, hex-or-hyphen, but hyphens in the wrong spots
      mkClaudeSessionUuid "3f2504e04-f89-41d3-9a0c-0305e82c330a"
        `shouldSatisfy` isLeft

    it "rejects a uuid with hyphens removed and padded (no hyphens)" $
      mkClaudeSessionUuid "3f2504e04f8941d39a0c0305e82c3301aaaa"
        `shouldSatisfy` isLeft

  describe "FromJSON (D1.3)" $ do
    it "accepts a canonical uuid string" $
      (unClaudeSessionUuid <$> Aeson.eitherDecode (encodeJsonText goodUuid))
        `shouldBe` Right goodUuid

    it "rejects an invalid uuid string (routes through smart constructor)" $
      (Aeson.eitherDecode (encodeJsonText (T.toUpper goodUuid))
         :: Either String ClaudeSessionUuid)
        `shouldSatisfy` isLeft

    it "fails with a message naming ClaudeSessionUuid (forces the fail arm)" $
      case (Aeson.eitherDecode (encodeJsonText (T.toUpper goodUuid))
              :: Either String ClaudeSessionUuid) of
        Right _ -> expectationFailure "expected decode to fail"
        Left msg -> ("invalid ClaudeSessionUuid" `isInfixOf` msg) `shouldBe` True

    it "rejects a non-string JSON value (withText type mismatch)" $
      (Aeson.eitherDecode "123" :: Either String ClaudeSessionUuid)
        `shouldSatisfy` isLeft

  describe "ToJSON / FromJSON round-trip (D1.3)" $
    it "round-trips through JSON" $ do
      case mkClaudeSessionUuid goodUuid of
        Left e -> expectationFailure ("unexpected: " <> show e)
        Right u ->
          Aeson.decode (Aeson.encode u) `shouldBe` Just u

  describe "redacted Show (D1.4)" $
    it "does NOT contain the raw uuid text" $ do
      case mkClaudeSessionUuid goodUuid of
        Left e -> expectationFailure ("unexpected: " <> show e)
        Right u -> do
          let shown = show u
          (T.unpack goodUuid `isInfixOf` shown) `shouldBe` False
          ("redacted" `isInfixOf` shown) `shouldBe` True

  describe "mintClaudeSessionUuid (D1.2)" $ do
    it "produces a value accepted by the smart constructor" $ do
      u <- mintClaudeSessionUuid
      mkClaudeSessionUuid (unClaudeSessionUuid u) `shouldSatisfy` isRight

    it "produces a canonical-length (36 char) lowercase uuid" $ do
      u <- mintClaudeSessionUuid
      let t = unClaudeSessionUuid u
      T.length t `shouldBe` 36
      t `shouldBe` T.toLower t

    it "produces distinct values across two mints" $ do
      a <- mintClaudeSessionUuid
      b <- mintClaudeSessionUuid
      a `shouldNotBe` b

-- | Encode a 'Text' as a JSON string (lazy 'ByteString') for decode tests.
encodeJsonText :: Text -> ByteString
encodeJsonText = Aeson.encode
