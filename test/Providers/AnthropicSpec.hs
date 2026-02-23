module Providers.AnthropicSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Anthropic
import PureClaw.Providers.Class

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "encodes a basic request as JSON" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "claude-sonnet-4-20250514"
            , _cr_messages     = [Message User "Hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Just 1024
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> do
          val `shouldSatisfy` hasKey "model"
          val `shouldSatisfy` hasKey "messages"
          val `shouldSatisfy` hasKey "max_tokens"

    it "includes system prompt when provided" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "claude-sonnet-4-20250514"
            , _cr_messages     = [Message User "Hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` hasKey "system"

    it "omits system field when no system prompt" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` (not . hasKey "system")

    it "defaults max_tokens to 4096 when Nothing" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case lookup "max_tokens" (objectToList obj) of
            Just (Number n) -> n `shouldBe` 4096
            _ -> expectationFailure "max_tokens not found or not a number"
        Just _ -> expectationFailure "Expected object"

  describe "decodeResponse" $ do
    it "decodes a successful Anthropic response" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Hello!\"}]"
            , ",\"model\":\"claude-sonnet-4-20250514\""
            , ",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          _crsp_content resp `shouldBe` "Hello!"
          _crsp_model resp `shouldBe` ModelId "claude-sonnet-4-20250514"
          _crsp_usage resp `shouldBe` Just (Usage 10 5)

    it "concatenates multiple text content blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Hello \"}"
            , ",{\"type\":\"text\",\"text\":\"world!\"}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> _crsp_content resp `shouldBe` "Hello world!"

    it "skips non-text content blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":{}}"
            , ",{\"type\":\"text\",\"text\":\"Hi\"}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> _crsp_content resp `shouldBe` "Hi"

    it "returns error on invalid JSON" $ do
      decodeResponse "not json" `shouldSatisfy` isLeft

    it "returns error on missing fields" $ do
      decodeResponse "{\"content\":[]}" `shouldSatisfy` isLeft

  describe "AnthropicError" $ do
    it "has a Show instance" $ do
      show (AnthropicAPIError 401 "unauthorized") `shouldContain` "401"
      show (AnthropicParseError "bad json") `shouldContain` "bad json"

-- | Check if a JSON Value (assumed Object) contains a given key.
hasKey :: Key -> Value -> Bool
hasKey k (Object obj) = KM.member k obj
hasKey _ _ = False

-- | Convert an aeson Object to a list of key-value pairs.
objectToList :: Object -> [(Key, Value)]
objectToList = KM.toList

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
