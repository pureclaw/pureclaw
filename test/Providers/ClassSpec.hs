module Providers.ClassSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson (Value, object)
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class

spec :: Spec
spec = do
  describe "Role" $ do
    it "has Show instances" $ do
      show User `shouldBe` "User"
      show Assistant `shouldBe` "Assistant"

    it "has Eq instance" $ do
      User `shouldBe` User
      User `shouldNotBe` Assistant

  describe "roleToText" $ do
    it "converts User to \"user\"" $ do
      roleToText User `shouldBe` "user"

    it "converts Assistant to \"assistant\"" $ do
      roleToText Assistant `shouldBe` "assistant"

  describe "Message" $ do
    it "has Show and Eq instances" $ do
      let msg = textMessage User "hello"
      show msg `shouldContain` "hello"
      msg `shouldBe` msg

  describe "textMessage" $ do
    it "creates a message with a single TextBlock" $ do
      let msg = textMessage User "hi"
      _msg_role msg `shouldBe` User
      _msg_content msg `shouldBe` [TextBlock "hi"]

  describe "CompletionRequest" $ do
    it "can be constructed with all fields" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "test-model"
            , _cr_messages     = [textMessage User "hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Just 1024
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
      _cr_model req `shouldBe` ModelId "test-model"
      length (_cr_messages req) `shouldBe` 1
      _cr_systemPrompt req `shouldBe` Just "Be helpful"
      _cr_maxTokens req `shouldBe` Just 1024

    it "supports Nothing for optional fields" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
      _cr_systemPrompt req `shouldBe` Nothing
      _cr_maxTokens req `shouldBe` Nothing

  describe "CompletionResponse" $ do
    it "can be constructed" $ do
      let resp = CompletionResponse
            { _crsp_content = [TextBlock "Hello!"]
            , _crsp_model   = ModelId "claude"
            , _crsp_usage   = Just (Usage 10 5)
            }
      _crsp_content resp `shouldBe` [TextBlock "Hello!"]

  describe "responseText" $ do
    it "extracts text from text blocks" $ do
      let resp = CompletionResponse
            { _crsp_content = [TextBlock "Hello", TextBlock "world"]
            , _crsp_model   = ModelId "m"
            , _crsp_usage   = Nothing
            }
      responseText resp `shouldBe` "Hello\nworld"

    it "returns empty for non-text blocks" $ do
      let resp = CompletionResponse
            { _crsp_content = [ToolUseBlock (ToolCallId "1") "shell" emptyObj]
            , _crsp_model   = ModelId "m"
            , _crsp_usage   = Nothing
            }
      responseText resp `shouldBe` ""

  describe "Usage" $ do
    it "has Show and Eq instances" $ do
      let u = Usage 100 50
      show u `shouldContain` "100"
      u `shouldBe` u

  describe "ToolDefinition" $ do
    it "can be constructed" $ do
      let td = ToolDefinition "test" "A test tool" emptyObj
      _td_name td `shouldBe` "test"

  describe "ContentBlock" $ do
    it "supports TextBlock" $ do
      TextBlock "hello" `shouldBe` TextBlock "hello"

    it "supports ToolUseBlock" $ do
      let block = ToolUseBlock (ToolCallId "1") "shell" emptyObj
      _tub_name block `shouldBe` "shell"

    it "supports ToolResultBlock" $ do
      let block = ToolResultBlock (ToolCallId "1") [TRPText "output"] False
      _trb_content block `shouldBe` [TRPText "output"]
      _trb_isError block `shouldBe` False

  describe "SomeProvider" $ do
    it "wraps a provider and delegates complete" $ do
      let mockProvider = MockProvider
          wrapped = MkProvider mockProvider
      resp <- complete wrapped CompletionRequest
        { _cr_model        = ModelId "test"
        , _cr_messages     = []
        , _cr_systemPrompt = Nothing
        , _cr_maxTokens    = Nothing
        , _cr_tools        = []
        , _cr_toolChoice   = Nothing
        }
      responseText resp `shouldBe` "mock response"

  jsonRoundTripSpec

-- A trivial provider for testing SomeProvider dispatch.
data MockProvider = MockProvider

instance Provider MockProvider where
  complete _ _ = pure CompletionResponse
    { _crsp_content = [TextBlock "mock response"]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Nothing
    }

emptyObj :: Value
emptyObj = object []

-- | Helper: encode then decode, checking round-trip
roundTrip :: (Aeson.ToJSON a, Aeson.FromJSON a, Eq a, Show a) => a -> IO ()
roundTrip x = Aeson.decode (Aeson.encode x) `shouldBe` Just x

jsonRoundTripSpec :: Spec
jsonRoundTripSpec = do
  describe "JSON round-trip" $ do
    describe "Role" $ do
      it "round-trips User" $ roundTrip User
      it "round-trips Assistant" $ roundTrip Assistant

    describe "ContentBlock" $ do
      it "round-trips TextBlock" $ roundTrip (TextBlock "hello")
      it "round-trips ToolUseBlock" $
        roundTrip (ToolUseBlock (ToolCallId "tc-1") "shell" emptyObj)
      it "round-trips ToolResultBlock" $
        roundTrip (ToolResultBlock (ToolCallId "tc-1") [TRPText "output"] False)
      it "round-trips ToolResultBlock with error" $
        roundTrip (ToolResultBlock (ToolCallId "tc-1") [TRPText "err"] True)

    describe "ToolResultPart" $ do
      it "round-trips TRPText" $ roundTrip (TRPText "text")
      it "round-trips TRPImage" $ roundTrip (TRPImage "image/png" "base64data")

    describe "Message" $ do
      it "round-trips a text message" $
        roundTrip (textMessage User "hello")
      it "round-trips a tool result message" $
        roundTrip (toolResultMessage [(ToolCallId "1", [TRPText "out"], False)])

    describe "ToolDefinition" $ do
      it "round-trips" $
        roundTrip (ToolDefinition "shell" "Run a command" emptyObj)

    describe "ToolChoice" $ do
      it "round-trips AutoTool" $ roundTrip AutoTool
      it "round-trips AnyTool" $ roundTrip AnyTool
      it "round-trips SpecificTool" $ roundTrip (SpecificTool "shell")

    describe "Usage" $ do
      it "round-trips" $ roundTrip (Usage 100 50)

    describe "CompletionRequest" $ do
      it "round-trips a minimal request" $
        roundTrip CompletionRequest
          { _cr_model        = ModelId "test"
          , _cr_messages     = [textMessage User "hi"]
          , _cr_systemPrompt = Nothing
          , _cr_maxTokens    = Nothing
          , _cr_tools        = []
          , _cr_toolChoice   = Nothing
          }
      it "round-trips a full request" $
        roundTrip CompletionRequest
          { _cr_model        = ModelId "claude-3"
          , _cr_messages     = [textMessage User "hi"]
          , _cr_systemPrompt = Just "Be helpful"
          , _cr_maxTokens    = Just 1024
          , _cr_tools        = [ToolDefinition "shell" "Run" emptyObj]
          , _cr_toolChoice   = Just AutoTool
          }

    describe "CompletionResponse" $ do
      it "round-trips with usage" $
        roundTrip CompletionResponse
          { _crsp_content = [TextBlock "Hello"]
          , _crsp_model   = ModelId "claude"
          , _crsp_usage   = Just (Usage 10 5)
          }
      it "round-trips without usage" $
        roundTrip CompletionResponse
          { _crsp_content = [TextBlock "Hello"]
          , _crsp_model   = ModelId "claude"
          , _crsp_usage   = Nothing
          }

    describe "StreamEvent" $ do
      it "round-trips StreamText" $ roundTrip (StreamText "chunk")
      it "round-trips StreamToolUse" $
        roundTrip (StreamToolUse (ToolCallId "1") "shell")
      it "round-trips StreamToolInput" $ roundTrip (StreamToolInput "{}")
      it "round-trips StreamDone" $
        roundTrip (StreamDone CompletionResponse
          { _crsp_content = [TextBlock "done"]
          , _crsp_model   = ModelId "m"
          , _crsp_usage   = Nothing
          })
