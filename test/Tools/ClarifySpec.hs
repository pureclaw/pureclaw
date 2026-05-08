module Tools.ClarifySpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Tools.Clarify
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "clarifyTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = clarifyTool mkNoOpChannelHandle
      _td_name def' `shouldBe` "clarify"

    it "sends an open-ended question and returns user response" $ do
      let ch = mockChannel "my answer"
          (_, handler) = clarifyTool ch
          input = object ["question" .= ("What color?" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "What color?"
      T.unpack output `shouldContain` "my answer"

    it "sends multiple-choice prompt and resolves numeric selection" $ do
      let ch = mockChannel "2"
          (_, handler) = clarifyTool ch
          input = object
            [ "question" .= ("Pick one:" :: String)
            , "choices" .= (["red", "blue", "green"] :: [String])
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      -- User typed "2" which maps to "blue"
      T.unpack output `shouldContain` "blue"

    it "returns raw text for non-numeric choice input" $ do
      let ch = mockChannel "actually purple"
          (_, handler) = clarifyTool ch
          input = object
            [ "question" .= ("Pick one:" :: String)
            , "choices" .= (["red", "blue"] :: [String])
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "actually purple"

    it "handles Other selection (N+1)" $ do
      let ch = mockChannel "3"
          (_, handler) = clarifyTool ch
          input = object
            [ "question" .= ("Pick:" :: String)
            , "choices" .= (["a", "b"] :: [String])
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      -- "3" is the "Other" option (choices.length + 1)
      -- Returns the raw input since no specific freeform was given
      T.unpack output `shouldContain` "3"

    it "returns JSON with choices_offered when choices provided" $ do
      let ch = mockChannel "1"
          (_, handler) = clarifyTool ch
          input = object
            [ "question" .= ("Pick:" :: String)
            , "choices" .= (["yes", "no"] :: [String])
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "choices_offered"

    it "returns JSON without choices_offered for open-ended" $ do
      let ch = mockChannel "freeform"
          (_, handler) = clarifyTool ch
          input = object ["question" .= ("Why?" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldSatisfy` (not . ("choices_offered" `elem`) . words)

    it "rejects invalid JSON input" $ do
      let (_, handler) = clarifyTool mkNoOpChannelHandle
          input = object ["wrong_field" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "handles channel errors gracefully" $ do
      let ch = mkNoOpChannelHandle { _ch_prompt = \_ -> error "channel down" }
          (_, handler) = clarifyTool ch
          input = object ["question" .= ("test?" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Failed to get user response"

-- | Create a mock channel that returns a fixed response to prompts.
mockChannel :: T.Text -> ChannelHandle
mockChannel response = mkNoOpChannelHandle
  { _ch_prompt = \_ -> pure response
  }
