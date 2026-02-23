module Providers.OpenRouterSpec (spec) where

import Data.Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Providers.OpenRouter

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "produces valid JSON (same as OpenAI format)" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "anthropic/claude-3.5-sonnet"
            , _cr_messages     = [textMessage User "Hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just _ -> pure ()

  describe "decodeResponse" $ do
    it "decodes an OpenAI-format response" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"choices\":[{\"message\":{\"content\":\"Hello!\"}}]"
            , ",\"model\":\"anthropic/claude-3.5-sonnet\"}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          responseText resp `shouldBe` "Hello!"
          _crsp_model resp `shouldBe` ModelId "anthropic/claude-3.5-sonnet"

    it "returns error on invalid JSON" $ do
      decodeResponse "not json" `shouldSatisfy` isLeft

