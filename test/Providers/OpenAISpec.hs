module Providers.OpenAISpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Providers.OpenAI

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "encodes a basic request" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "gpt-4"
            , _cr_messages     = [textMessage User "Hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> do
          val `shouldSatisfy` hasKey "model"
          val `shouldSatisfy` hasKey "messages"

    it "puts system prompt in messages array" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "gpt-4"
            , _cr_messages     = [textMessage User "Hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case KM.lookup "messages" obj of
            Just (Array msgs) -> length msgs `shouldBe` 2  -- system + user
            _ -> expectationFailure "messages not found"
        Just _ -> expectationFailure "Expected object"

    it "includes tools when provided" $ do
      let tool = ToolDefinition "test" "A test" (object ["type" .= ("object" :: String)])
          req = CompletionRequest
            { _cr_model        = ModelId "gpt-4"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = [tool]
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` hasKey "tools"

  describe "decodeResponse" $ do
    it "decodes a text response" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"choices\":[{\"message\":{\"content\":\"Hello!\"}}]"
            , ",\"model\":\"gpt-4\""
            , ",\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          responseText resp `shouldBe` "Hello!"
          _crsp_model resp `shouldBe` ModelId "gpt-4"
          _crsp_usage resp `shouldBe` Just (Usage 5 3)

    it "decodes a response with tool calls" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"choices\":[{\"message\":{\"content\":null"
            , ",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\""
            , ",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]"
            , "}}],\"model\":\"gpt-4\"}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          let calls = toolUseCalls resp
          length calls `shouldBe` 1

    it "returns error on invalid JSON" $ do
      decodeResponse "not json" `shouldSatisfy` isLeft

hasKey :: Key -> Value -> Bool
hasKey k (Object obj) = KM.member k obj
hasKey _ _ = False

