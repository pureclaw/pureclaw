module CLI.CommandsSpec (spec) where

import Options.Applicative
import Test.Hspec

import PureClaw.CLI.Commands

spec :: Spec
spec = do
  describe "chatOptionsParser" $ do
    it "parses with default model" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) [] of
        Success opts -> _co_model opts `shouldBe` "claude-sonnet-4-20250514"
        _ -> expectationFailure "parse failed"

    it "parses --model flag" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) ["--model", "claude-opus-4-20250514"] of
        Success opts -> _co_model opts `shouldBe` "claude-opus-4-20250514"
        _ -> expectationFailure "parse failed"

    it "parses -m short flag" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) ["-m", "test-model"] of
        Success opts -> _co_model opts `shouldBe` "test-model"
        _ -> expectationFailure "parse failed"

    it "parses --api-key flag" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) ["--api-key", "sk-test"] of
        Success opts -> _co_apiKey opts `shouldBe` Just "sk-test"
        _ -> expectationFailure "parse failed"

    it "api-key defaults to Nothing" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) [] of
        Success opts -> _co_apiKey opts `shouldBe` Nothing
        _ -> expectationFailure "parse failed"

    it "parses --system flag" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) ["--system", "Be brief"] of
        Success opts -> _co_system opts `shouldBe` Just "Be brief"
        _ -> expectationFailure "parse failed"

    it "parses -s short flag for system" $ do
      case execParserPure defaultPrefs (info chatOptionsParser mempty) ["-s", "Be helpful"] of
        Success opts -> _co_system opts `shouldBe` Just "Be helpful"
        _ -> expectationFailure "parse failed"
