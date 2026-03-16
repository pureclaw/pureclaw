module Channels.SignalTransportSpec (spec) where

import Control.Concurrent.STM
import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Channels.Signal.Transport

spec :: Spec
spec = do
  describe "chunkMessage" $ do
    it "returns a single chunk for short messages" $ do
      chunkMessage 6000 "Hello" `shouldBe` ["Hello"]

    it "returns empty list for empty text" $ do
      chunkMessage 6000 "" `shouldBe` [""]

    it "splits on paragraph boundaries" $ do
      let text = T.intercalate "\n\n" ["Part one", "Part two", "Part three"]
      let chunks = chunkMessage 20 text
      length chunks `shouldSatisfy` (> 1)
      -- Each chunk should be within the limit
      all (\c -> T.length c <= 20) chunks `shouldBe` True
      -- Reassembled text should preserve content (modulo whitespace)
      let reassembled = T.unwords (map T.strip chunks)
      reassembled `shouldSatisfy` T.isInfixOf "Part one"
      reassembled `shouldSatisfy` T.isInfixOf "Part three"

    it "splits on newline boundaries when no paragraph break fits" $ do
      let text = "Line one\nLine two\nLine three\nLine four"
      let chunks = chunkMessage 20 text
      length chunks `shouldSatisfy` (> 1)
      all (\c -> T.length c <= 20) chunks `shouldBe` True

    it "hard-cuts when no break point exists" $ do
      let text = T.replicate 100 "x"
      let chunks = chunkMessage 30 text
      length chunks `shouldSatisfy` (> 1)
      all (\c -> T.length c <= 30) chunks `shouldBe` True
      T.concat chunks `shouldBe` text

    it "respects the 6000 char Signal limit" $ do
      let text = T.replicate 12000 "a"
      let chunks = chunkMessage 6000 text
      length chunks `shouldBe` 2
      all (\c -> T.length c <= 6000) chunks `shouldBe` True

  describe "mkMockSignalTransport" $ do
    it "receives messages from the incoming queue" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
      let testMsg = object ["source" .= ("+1234" :: Text), "timestamp" .= (1 :: Int)]
      atomically $ writeTQueue inQ testMsg
      received <- _st_receive transport
      received `shouldBe` testMsg

    it "sends messages to the outgoing queue" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
      _st_send transport "+1234567890" "Hello!"
      (recipient, body) <- atomically $ readTQueue outQ
      recipient `shouldBe` "+1234567890"
      body `shouldBe` "Hello!"

    it "close is a no-op" $ do
      inQ  <- newTQueueIO
      outQ <- newTQueueIO
      let transport = mkMockSignalTransport inQ outQ
      _st_close transport `shouldReturn` ()
