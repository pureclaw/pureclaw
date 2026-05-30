module Core.TypesSpec (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Aeson qualified as Aeson
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import PureClaw.Core.Types

spec :: Spec
spec = do
  describe "AllowList" $ do
    -- Test with String (has Arbitrary instance) to verify AllowList logic
    it "AllowAll allows any element" $
      property $ \(x :: String) ->
        isAllowed AllowAll (CommandName (T.pack x)) `shouldBe` True

    it "AllowList allows elements in the set" $ do
      let al = AllowList (Set.fromList ["git" :: String, "ls"])
      isAllowed al "git" `shouldBe` True
      isAllowed al "ls" `shouldBe` True

    it "AllowList rejects elements not in the set" $ do
      let al = AllowList (Set.fromList ["git" :: String, "ls"])
      isAllowed al "rm" `shouldBe` False
      isAllowed al "curl" `shouldBe` False

    it "empty AllowList rejects everything" $
      property $ \(x :: String) ->
        isAllowed (AllowList Set.empty) (CommandName (T.pack x)) `shouldBe` False

    -- Also verify it works with CommandName specifically
    it "works with CommandName" $ do
      let al = AllowList (Set.fromList [CommandName "git"])
      isAllowed al (CommandName "git") `shouldBe` True
      isAllowed al (CommandName "rm") `shouldBe` False

  describe "AutonomyLevel" $ do
    it "has Show instances" $ do
      show Full `shouldBe` "Full"
      show Supervised `shouldBe` "Supervised"
      show Deny `shouldBe` "Deny"

    it "has Eq instance" $ do
      Full `shouldBe` Full
      Supervised `shouldNotBe` Deny

  describe "newtypes" $ do
    it "ProviderId wraps Text" $ do
      let p = ProviderId "anthropic"
      show p `shouldSatisfy` (not . null)

    it "ModelId wraps Text" $ do
      let m = ModelId "claude-3"
      show m `shouldSatisfy` (not . null)

    it "Port wraps Int" $ do
      let p = Port 8080
      show p `shouldSatisfy` (not . null)

    it "WorkspaceRoot wraps FilePath" $ do
      let w = WorkspaceRoot "/home/user/workspace"
      show w `shouldSatisfy` (not . null)

    it "CommandName has Ord for Set usage" $ do
      let s = Set.fromList [CommandName "a", CommandName "b", CommandName "a"]
      Set.size s `shouldBe` 2

  describe "ChannelKind text round-trip" $ do
    let kinds = [CkCli, CkWeb, CkSignal, CkTelegram, CkBackground, CkOther "matrix"]
    it "round-trips all kinds including CkOther" $
      mapM_ (\k -> channelKindFromText (channelKindToText k) `shouldBe` k) kinds

    it "channelKindToText produces expected strings" $ do
      channelKindToText CkCli `shouldBe` "cli"
      channelKindToText CkWeb `shouldBe` "web"
      channelKindToText CkSignal `shouldBe` "signal"
      channelKindToText CkTelegram `shouldBe` "telegram"
      channelKindToText CkBackground `shouldBe` "background"
      channelKindToText (CkOther "matrix") `shouldBe` "matrix"

    it "shadowing guard: \"signal\" never decodes to CkOther \"signal\"" $
      channelKindFromText "signal" `shouldBe` CkSignal

    it "unknown names decode to CkOther" $
      channelKindFromText "matrix" `shouldBe` CkOther "matrix"

    it "ChannelKind encodes as a plain JSON string" $ do
      encode CkSignal `shouldBe` "\"signal\""
      encode (CkOther "matrix") `shouldBe` "\"matrix\""

    it "ChannelKind JSON round-trips" $
      mapM_ (\k -> eitherDecode (encode k) `shouldBe` Right k) kinds

  describe "MessageSource JSON" $ do
    it "round-trips with empty fields and no user id" $ do
      let src = mkMessageSource CkWeb Nothing Map.empty
      eitherDecode (encode src) `shouldBe` Right src

    it "round-trips with non-empty fields and a user id" $ do
      let src = mkMessageSource CkSignal (Just (UserId "+15551234567"))
                  (Map.fromList [("uuid", Aeson.String "abc-123")])
      eitherDecode (encode src) `shouldBe` Right src

    it "uses snake_case keys" $ do
      let src = mkMessageSource CkSignal (Just (UserId "+1555"))
                  (Map.fromList [("uuid", Aeson.String "abc")])
          out = BL.unpack (encode src)
      out `shouldSatisfy` ("\"channel\"" `isSubOf`)
      out `shouldSatisfy` ("\"user_id\"" `isSubOf`)
      out `shouldSatisfy` ("\"fields\"" `isSubOf`)

    it "serializes user_id as a plain string" $ do
      let src = mkMessageSource CkSignal (Just (UserId "+1555")) Map.empty
          out = BL.unpack (encode src)
      out `shouldSatisfy` ("\"+1555\"" `isSubOf`)

    it "omits user_id when Nothing" $ do
      let src = mkMessageSource CkWeb Nothing Map.empty
          out = BL.unpack (encode src)
      out `shouldSatisfy` (not . ("\"user_id\"" `isSubOf`))

    it "omits fields when empty" $ do
      let src = mkMessageSource CkWeb Nothing Map.empty
          out = BL.unpack (encode src)
      out `shouldSatisfy` (not . ("\"fields\"" `isSubOf`))

    it "tolerant decode: missing user_id and fields" $ do
      let json = "{\"channel\":\"web\"}"
      eitherDecode json `shouldBe` Right (mkMessageSource CkWeb Nothing Map.empty)

  describe "mkMessageSource normalization" $ do
    it "strips control chars and newlines on the user id" $ do
      let src = mkMessageSource CkSignal (Just (UserId "a\nb\tc\rd")) Map.empty
      _ms_userId src `shouldBe` Just (UserId "abcd")

    it "strips control chars on a field string value" $ do
      let src = mkMessageSource CkTelegram Nothing
                  (Map.fromList [("username", Aeson.String "ev\nil\tname")])
      Map.lookup "username" (_ms_fields src)
        `shouldBe` Just (Aeson.String "evilname")

    it "normalizes nested string values inside fields" $ do
      let nested = Aeson.object ["inner" Aeson..= Aeson.String "x\ny"]
          src = mkMessageSource CkTelegram Nothing (Map.fromList [("o", nested)])
      Map.lookup "o" (_ms_fields src)
        `shouldBe` Just (Aeson.object ["inner" Aeson..= Aeson.String "xy"])

    it "bounds user id length to maxSourceLen" $ do
      let long = T.replicate (maxSourceLen + 100) "a"
          src = mkMessageSource CkSignal (Just (UserId long)) Map.empty
      case _ms_userId src of
        Just (UserId t) -> T.length t `shouldBe` maxSourceLen
        Nothing -> expectationFailure "expected Just user id"

    it "bounds field string length to maxSourceLen" $ do
      let long = T.replicate (maxSourceLen + 100) "b"
          src = mkMessageSource CkTelegram Nothing
                  (Map.fromList [("k", Aeson.String long)])
      case Map.lookup "k" (_ms_fields src) of
        Just (Aeson.String t) -> T.length t `shouldBe` maxSourceLen
        _ -> expectationFailure "expected Just (String ...)"

    it "folds CkOther \"signal\" to CkSignal" $ do
      let src = mkMessageSource (CkOther "signal") Nothing Map.empty
      _ms_channel src `shouldBe` CkSignal

    it "maxSourceLen is 512" $
      maxSourceLen `shouldBe` 512
  where
    isSubOf :: String -> String -> Bool
    isSubOf needle haystack = needle `elem` substrings
      where
        n = length needle
        substrings = [take n (drop i haystack) | i <- [0 .. length haystack - n]]
