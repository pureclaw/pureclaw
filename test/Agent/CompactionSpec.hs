module Agent.CompactionSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.Compaction
import PureClaw.Agent.Context
import PureClaw.Core.Types
import PureClaw.Providers.Class

-- | Mock provider that returns a fixed summary.
newtype MockProvider = MockProvider Text

instance Provider MockProvider where
  complete (MockProvider summary) _ = pure CompletionResponse
    { _crsp_content = [TextBlock summary]
    , _crsp_model   = ModelId "mock"
    , _crsp_usage   = Just (Usage 10 10)
    }

-- | Mock provider that always fails.
data FailingProvider = FailingProvider

instance Provider FailingProvider where
  complete FailingProvider _ = error "Provider unavailable"

spec :: Spec
spec = do
  let model = ModelId "test-model"

  describe "compactContext" $ do
    it "returns NotNeeded when below threshold" $ do
      let ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      (_, result) <- compactContext (MockProvider "sum") model 100000 5 ctx
      result `shouldBe` NotNeeded

    it "returns NotNeeded when too few messages to split" $ do
      let ctx = addMessage (textMessage User "hello") (emptyContext Nothing)
      (_, result) <- compactContext (MockProvider "sum") model 0 5 ctx
      result `shouldBe` NotNeeded

    it "compacts when above threshold with enough messages" $ do
      -- Build a context with many messages to exceed a low threshold
      let msgs = [textMessage User (T.replicate 100 "x") | _ <- [(1::Int)..20]]
          ctx = foldl (flip addMessage) (emptyContext Nothing) msgs
      (ctx', result) <- compactContext (MockProvider "Summary of conversation") model 1 5 ctx
      case result of
        Compacted old new summary -> do
          old `shouldBe` 20       -- original message count
          new `shouldBe` 6        -- 1 summary + 5 recent
          T.unpack summary `shouldContain` "Summary of conversation"
        _ -> expectationFailure $ "Expected Compacted, got " ++ show result
      -- Summary should be in first message
      case contextMessages ctx' of
        (m:_) -> do
          let content = T.concat [t | TextBlock t <- _msg_content m]
          T.unpack content `shouldContain` "Summary of conversation"
        _ -> expectationFailure "Expected at least one message"

    it "preserves recent messages" $ do
      let msgs = [textMessage User ("msg" <> T.pack (show i)) | i <- [(1::Int)..12]]
          ctx = foldl (flip addMessage) (emptyContext Nothing) msgs
      (ctx', _) <- compactContext (MockProvider "old stuff") model 1 3 ctx
      let recent = drop 1 (contextMessages ctx')  -- skip summary
          recentTexts = [t | m <- recent, TextBlock t <- _msg_content m]
      recentTexts `shouldBe` ["msg10", "msg11", "msg12"]

    it "preserves system prompt" $ do
      let msgs = [textMessage User (T.replicate 100 "x") | _ <- [(1::Int)..10]]
          ctx = foldl (flip addMessage) (emptyContext (Just "Be helpful")) msgs
      (ctx', _) <- compactContext (MockProvider "sum") model 1 3 ctx
      contextSystemPrompt ctx' `shouldBe` Just "Be helpful"

    it "preserves usage counters" $ do
      let msgs = [textMessage User (T.replicate 100 "x") | _ <- [(1::Int)..10]]
          ctx = recordUsage (Just (Usage 500 200))
              $ foldl (flip addMessage) (emptyContext Nothing) msgs
      (ctx', _) <- compactContext (MockProvider "sum") model 1 3 ctx
      contextTotalInputTokens ctx' `shouldBe` 500

    it "returns CompactionError on provider error" $ do
      let msgs = [textMessage User (T.replicate 100 "x") | _ <- [(1::Int)..10]]
          ctx = foldl (flip addMessage) (emptyContext Nothing) msgs
      (_, result) <- compactContext FailingProvider model 1 3 ctx
      case result of
        CompactionError _ -> pure ()
        _ -> expectationFailure $ "Expected CompactionError, got " ++ show result

  describe "CompactionResult" $ do
    it "has Show and Eq instances" $ do
      show NotNeeded `shouldContain` "NotNeeded"
      NotNeeded `shouldBe` NotNeeded
      Compacted 10 3 "s" `shouldBe` Compacted 10 3 "s"

  describe "defaultTokenLimit" $ do
    it "is 200k" $ do
      defaultTokenLimit `shouldBe` 200000

  describe "defaultKeepRecent" $ do
    it "is 10" $ do
      defaultKeepRecent `shouldBe` 10
