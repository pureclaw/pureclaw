module Providers.OllamaSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef
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

  describe "freshenToolUseIds" $ do
    it "assigns a unique id to every ToolUseBlock, even within one response" $ do
      counter <- newIORef 0
      let resp = CompletionResponse
            { _crsp_content =
                [ TextBlock "ok"
                , ToolUseBlock (ToolCallId "ollama-shell") "shell" (object ["command" .= ("ls" :: String)])
                , ToolUseBlock (ToolCallId "ollama-shell") "shell" (object ["command" .= ("pwd" :: String)])
                ]
            , _crsp_model   = ModelId "gemma4:26b"
            , _crsp_usage   = Nothing
            }
      out <- freshenToolUseIds counter resp
      let ids = [unToolCallId i | ToolUseBlock i _ _ <- _crsp_content out]
      case ids of
        [a, b] -> a `shouldNotBe` b
        _      -> expectationFailure ("expected exactly two ids, got " ++ show ids)

    it "keeps non-tool-use blocks unchanged" $ do
      counter <- newIORef 0
      let resp = CompletionResponse
            { _crsp_content = [TextBlock "hello"]
            , _crsp_model   = ModelId "gemma4:26b"
            , _crsp_usage   = Nothing
            }
      out <- freshenToolUseIds counter resp
      _crsp_content out `shouldBe` [TextBlock "hello"]

    it "draws ids monotonically across successive responses (no cross-call collision)" $ do
      counter <- newIORef 0
      let oneCall = CompletionResponse
            { _crsp_content =
                [ ToolUseBlock (ToolCallId "ollama-shell") "shell" Null
                ]
            , _crsp_model   = ModelId "gemma4:26b"
            , _crsp_usage   = Nothing
            }
      r1 <- freshenToolUseIds counter oneCall
      r2 <- freshenToolUseIds counter oneCall
      let idOf r = case [unToolCallId i | ToolUseBlock i _ _ <- _crsp_content r] of
            (x:_) -> Just x
            []    -> Nothing
      case (idOf r1, idOf r2) of
        (Just a, Just b) -> a `shouldNotBe` b
        _                -> expectationFailure "expected one tool-use block per response"

  describe "parseModelNames" $ do
    it "parses models from Ollama /api/tags response" $ do
      let json = object
            [ "models" .= [ object ["name" .= ("llama3:latest" :: String)]
                          , object ["name" .= ("gemma4:26b" :: String)]
                          , object ["name" .= ("codellama:7b" :: String)]
                          ]
            ]
      parseModelNames json `shouldBe`
        [ModelId "llama3:latest", ModelId "gemma4:26b", ModelId "codellama:7b"]

    it "returns empty list for missing models key" $ do
      parseModelNames (object []) `shouldBe` []

    it "returns empty list for non-object input" $ do
      parseModelNames (String "not an object") `shouldBe` []

hasKey :: Key -> Value -> Bool
hasKey k (Object obj) = KM.member k obj
hasKey _ _ = False

