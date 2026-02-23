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
      let ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
          msgs = contextMessages ctx
      length msgs `shouldBe` 1
      case msgs of
        [m] -> _msg_content m `shouldBe` [TextBlock "hello"]
        _   -> expectationFailure "expected exactly one message"

    it "preserves chronological order" $ do
      let ctx = addMessage (textMessage Assistant "hi back")
              $ addMessage (textMessage User "hello")
              $ emptyContext Nothing
          msgs = contextMessages ctx
      length msgs `shouldBe` 2
      case msgs of
        [m1, m2] -> do
          _msg_role m1 `shouldBe` User
          _msg_role m2 `shouldBe` Assistant
        _ -> expectationFailure "expected exactly two messages"

    it "preserves system prompt across additions" $ do
      let ctx = addMessage (textMessage User "test")
              $ emptyContext (Just "system")
      contextSystemPrompt ctx `shouldBe` Just "system"

  describe "contextMessages" $ do
    it "returns messages oldest first" $ do
      let ctx = addMessage (textMessage User "third")
              $ addMessage (textMessage User "second")
              $ addMessage (textMessage User "first")
              $ emptyContext Nothing
          contents = [ t | m <- contextMessages ctx, TextBlock t <- _msg_content m ]
      contents `shouldBe` ["first", "second", "third"]
