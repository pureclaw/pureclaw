module Providers.ClassSpec (spec) where

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
      let msg = Message User "hello"
      show msg `shouldContain` "hello"
      msg `shouldBe` msg

  describe "CompletionRequest" $ do
    it "can be constructed with all fields" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "test-model"
            , _cr_messages     = [Message User "hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Just 1024
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
            }
      _cr_systemPrompt req `shouldBe` Nothing
      _cr_maxTokens req `shouldBe` Nothing

  describe "CompletionResponse" $ do
    it "can be constructed" $ do
      let resp = CompletionResponse
            { _crsp_content = "Hello!"
            , _crsp_model   = ModelId "claude"
            , _crsp_usage   = Just (Usage 10 5)
            }
      _crsp_content resp `shouldBe` "Hello!"

  describe "Usage" $ do
    it "has Show and Eq instances" $ do
      let u = Usage 100 50
      show u `shouldContain` "100"
      u `shouldBe` u
