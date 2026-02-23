module Agent.ContextSpec (spec) where

import Test.Hspec

import PureClaw.Agent.Context
import PureClaw.Providers.Class

spec :: Spec
spec = do
  describe "emptyContext" $ do
    it "starts with no messages" $ do
      let ctx = emptyContext Nothing
      contextMessages ctx `shouldBe` []

    it "stores the system prompt" $ do
      let ctx = emptyContext (Just "Be helpful")
      contextSystemPrompt ctx `shouldBe` Just "Be helpful"

    it "supports no system prompt" $ do
      let ctx = emptyContext Nothing
      contextSystemPrompt ctx `shouldBe` Nothing

  describe "addMessage" $ do
    it "appends a message" $ do
      let ctx = addMessage (Message User "hello") (emptyContext Nothing)
          msgs = contextMessages ctx
      length msgs `shouldBe` 1
      case msgs of
        [m] -> _msg_content m `shouldBe` "hello"
        _   -> expectationFailure "expected exactly one message"

    it "preserves chronological order" $ do
      let ctx = addMessage (Message Assistant "hi back")
              $ addMessage (Message User "hello")
              $ emptyContext Nothing
          msgs = contextMessages ctx
      length msgs `shouldBe` 2
      case msgs of
        [m1, m2] -> do
          _msg_role m1 `shouldBe` User
          _msg_role m2 `shouldBe` Assistant
        _ -> expectationFailure "expected exactly two messages"

    it "preserves system prompt across additions" $ do
      let ctx = addMessage (Message User "test")
              $ emptyContext (Just "system")
      contextSystemPrompt ctx `shouldBe` Just "system"

  describe "contextMessages" $ do
    it "returns messages oldest first" $ do
      let ctx = addMessage (Message User "third")
              $ addMessage (Message User "second")
              $ addMessage (Message User "first")
              $ emptyContext Nothing
      map _msg_content (contextMessages ctx) `shouldBe` ["first", "second", "third"]
