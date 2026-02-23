module Providers.OllamaSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Providers.Ollama

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "encodes with model and messages" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "llama3"
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
          val `shouldSatisfy` hasKey "stream"

    it "sets stream to false" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "llama3"
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
          KM.lookup "stream" obj `shouldBe` Just (Bool False)
        Just _ -> expectationFailure "Expected object"

    it "includes system prompt in messages" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "llama3"
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
            Just (Array msgs) -> length msgs `shouldBe` 2
            _ -> expectationFailure "messages not found"
        Just _ -> expectationFailure "Expected object"

  describe "decodeResponse" $ do
    it "decodes a text response" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"message\":{\"content\":\"Hello from Ollama!\"}"
            , ",\"model\":\"llama3\"}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          responseText resp `shouldBe` "Hello from Ollama!"
          _crsp_model resp `shouldBe` ModelId "llama3"
          _crsp_usage resp `shouldBe` Nothing

    it "returns error on invalid JSON" $ do
      decodeResponse "not json" `shouldSatisfy` isLeft

hasKey :: Key -> Value -> Bool
hasKey k (Object obj) = KM.member k obj
hasKey _ _ = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
