module Agent.ContextSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Context
import PureClaw.Core.Types
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

    it "starts with zero usage" $ do
      let ctx = emptyContext Nothing
      contextTotalInputTokens ctx `shouldBe` 0
      contextTotalOutputTokens ctx `shouldBe` 0

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

  describe "estimateTokens" $ do
    it "returns 0 for empty text" $ do
      estimateTokens "" `shouldBe` 0

    it "returns at least 1 for non-empty text" $ do
      estimateTokens "hi" `shouldBe` 1

    it "estimates ~4 chars per token" $ do
      estimateTokens (T.replicate 100 "a") `shouldBe` 25

  describe "estimateBlockTokens" $ do
    it "estimates text blocks" $ do
      estimateBlockTokens (TextBlock "hello world test") `shouldSatisfy` (> 0)

    it "estimates tool use blocks" $ do
      let block = ToolUseBlock (ToolCallId "c1") "shell" (object ["cmd" .= ("ls" :: Text)])
      estimateBlockTokens block `shouldSatisfy` (> 0)

    it "estimates tool result blocks" $ do
      let block = ToolResultBlock (ToolCallId "c1") "file contents here" False
      estimateBlockTokens block `shouldSatisfy` (> 0)

  describe "estimateMessageTokens" $ do
    it "includes per-message overhead" $ do
      let msg = textMessage User ""
      estimateMessageTokens msg `shouldSatisfy` (>= 4)

    it "grows with content" $ do
      let short = textMessage User "hi"
          long = textMessage User (T.replicate 1000 "x")
      estimateMessageTokens long `shouldSatisfy` (> estimateMessageTokens short)

  describe "contextTokenEstimate" $ do
    it "returns 0 for empty context without system prompt" $ do
      contextTokenEstimate (emptyContext Nothing) `shouldBe` 0

    it "includes system prompt tokens" $ do
      let ctx = emptyContext (Just "Be a helpful assistant")
      contextTokenEstimate ctx `shouldSatisfy` (> 0)

    it "grows as messages are added" $ do
      let ctx0 = emptyContext Nothing
          ctx1 = addMessage (textMessage User "hello") ctx0
          ctx2 = addMessage (textMessage Assistant "hi there") ctx1
      contextTokenEstimate ctx2 `shouldSatisfy` (> contextTokenEstimate ctx1)
      contextTokenEstimate ctx1 `shouldSatisfy` (> contextTokenEstimate ctx0)

  describe "recordUsage" $ do
    it "accumulates input tokens" $ do
      let ctx = recordUsage (Just (Usage 100 50))
              $ recordUsage (Just (Usage 200 75))
              $ emptyContext Nothing
      contextTotalInputTokens ctx `shouldBe` 300
      contextTotalOutputTokens ctx `shouldBe` 125

    it "ignores Nothing usage" $ do
      let ctx = recordUsage Nothing (emptyContext Nothing)
      contextTotalInputTokens ctx `shouldBe` 0

  describe "contextMessageCount" $ do
    it "returns 0 for empty context" $ do
      contextMessageCount (emptyContext Nothing) `shouldBe` 0

    it "counts messages" $ do
      let ctx = addMessage (textMessage User "b")
              $ addMessage (textMessage User "a")
              $ emptyContext Nothing
      contextMessageCount ctx `shouldBe` 2

  describe "replaceMessages" $ do
    it "replaces all messages" $ do
      let ctx = addMessage (textMessage User "old2")
              $ addMessage (textMessage User "old1")
              $ emptyContext (Just "sys")
          ctx' = replaceMessages [textMessage User "summary"] ctx
      contextMessageCount ctx' `shouldBe` 1
      contextSystemPrompt ctx' `shouldBe` Just "sys"

    it "preserves usage counters" $ do
      let ctx = recordUsage (Just (Usage 100 50))
              $ addMessage (textMessage User "msg")
              $ emptyContext Nothing
          ctx' = replaceMessages [] ctx
      contextTotalInputTokens ctx' `shouldBe` 100

  describe "clearMessages" $ do
    it "removes all messages" $ do
      let ctx = addMessage (textMessage User "msg")
              $ emptyContext (Just "sys")
          ctx' = clearMessages ctx
      contextMessages ctx' `shouldBe` []
      contextSystemPrompt ctx' `shouldBe` Just "sys"

    it "preserves usage counters" $ do
      let ctx = recordUsage (Just (Usage 50 25))
              $ addMessage (textMessage User "msg")
              $ emptyContext Nothing
          ctx' = clearMessages ctx
      contextTotalInputTokens ctx' `shouldBe` 50
