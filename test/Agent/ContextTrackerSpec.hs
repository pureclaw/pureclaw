module Agent.ContextTrackerSpec (spec) where

import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Context
import PureClaw.Agent.ContextTracker
import PureClaw.Core.Types
import PureClaw.Providers.Class

spec :: Spec
spec = do
  describe "contextWindowForModel" $ do
    it "returns 200k for claude-3-5-sonnet" $ do
      contextWindowForModel (ModelId "claude-3-5-sonnet-20241022") `shouldBe` 200000

    it "returns 200k for claude-sonnet-4" $ do
      contextWindowForModel (ModelId "claude-sonnet-4-20250514") `shouldBe` 200000

    it "returns 128k for gpt-4o" $ do
      contextWindowForModel (ModelId "gpt-4o") `shouldBe` 128000

    it "returns 128k for gpt-4-turbo" $ do
      contextWindowForModel (ModelId "gpt-4-turbo") `shouldBe` 128000

    it "returns a default for unknown models" $ do
      contextWindowForModel (ModelId "some-unknown-model") `shouldBe` defaultContextWindow

  describe "contextStatus" $ do
    it "reports zero usage for empty context" $ do
      let status = contextStatus (ModelId "claude-sonnet-4-20250514") (emptyContext Nothing)
      _cs_estimatedTokens status `shouldBe` 0
      _cs_messageCount status `shouldBe` 0
      _cs_utilizationPct status `shouldSatisfy` (< 0.01)

    it "includes system prompt in estimates" $ do
      let ctx = emptyContext (Just "You are a helpful assistant")
          status = contextStatus (ModelId "claude-sonnet-4-20250514") ctx
      _cs_estimatedTokens status `shouldSatisfy` (> 0)

    it "tracks message count" $ do
      let ctx = addMessage (textMessage Assistant "hi")
              $ addMessage (textMessage User "hello")
              $ emptyContext Nothing
          status = contextStatus (ModelId "claude-sonnet-4-20250514") ctx
      _cs_messageCount status `shouldBe` 2

    it "computes utilization as fraction of context window" $ do
      let bigText = T.replicate 400000 "x"  -- ~100k tokens at 4 chars/token
          ctx = addMessage (textMessage User bigText)
              $ emptyContext Nothing
          status = contextStatus (ModelId "claude-sonnet-4-20250514") ctx
      -- 100k / 200k = ~50%
      _cs_utilizationPct status `shouldSatisfy` (> 0.4)
      _cs_utilizationPct status `shouldSatisfy` (< 0.6)

    it "includes context window limit" $ do
      let status = contextStatus (ModelId "gpt-4o") (emptyContext Nothing)
      _cs_contextWindow status `shouldBe` 128000

    it "includes cumulative provider-reported usage" $ do
      let ctx = recordUsage (Just (Usage 500 200))
              $ emptyContext Nothing
          status = contextStatus (ModelId "claude-sonnet-4-20250514") ctx
      _cs_totalInputTokens status `shouldBe` 500
      _cs_totalOutputTokens status `shouldBe` 200

  describe "isContextHigh" $ do
    it "returns False for empty context" $ do
      isContextHigh (ModelId "claude-sonnet-4-20250514") (emptyContext Nothing) `shouldBe` False

    it "returns True when utilization exceeds threshold" $ do
      let bigText = T.replicate 720000 "x"  -- ~180k tokens, 90% of 200k
          ctx = addMessage (textMessage User bigText) (emptyContext Nothing)
      isContextHigh (ModelId "claude-sonnet-4-20250514") ctx `shouldBe` True

  describe "formatContextStatus" $ do
    it "produces human-readable status text" $ do
      let status = contextStatus (ModelId "claude-sonnet-4-20250514") (emptyContext Nothing)
          text = formatContextStatus status
      text `shouldSatisfy` T.isInfixOf "Context window"
      text `shouldSatisfy` T.isInfixOf "200000"
