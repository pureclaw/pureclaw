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
            , _cr_messages     = [textMessage User "Hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Just 1024
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
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
            , _cr_messages     = [textMessage User "Hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
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
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
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
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case KM.lookup "max_tokens" obj of
            Just (Number n) -> n `shouldBe` 4096
            _ -> expectationFailure "max_tokens not found or not a number"
        Just _ -> expectationFailure "Expected object"

    it "includes tools when provided" $ do
      let tool = ToolDefinition "shell" "Run a shell command" (object ["type" .= ("object" :: String)])
          req = CompletionRequest
            { _cr_model        = ModelId "m"
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

    it "omits tools when empty" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` (not . hasKey "tools")

    it "encodes messages with content block arrays" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = [textMessage User "hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case KM.lookup "messages" obj of
            Just (Array msgs) -> do
              length msgs `shouldBe` 1
            _ -> expectationFailure "messages not found or not an array"
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
          _crsp_content resp `shouldBe` [TextBlock "Hello!"]
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
        Right resp -> responseText resp `shouldBe` "Hello \nworld!"

    it "decodes tool_use content blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls\"}}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          let calls = toolUseCalls resp
          length calls `shouldBe` 1

    it "decodes mixed text and tool_use blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"}"
            , ",{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls\"}}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          responseText resp `shouldBe` "Let me check."
          length (toolUseCalls resp) `shouldBe` 1

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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
