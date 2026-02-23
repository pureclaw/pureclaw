module Tools.MemorySpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Memory
import PureClaw.Providers.Class
import PureClaw.Tools.Memory
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "memoryStoreTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = memoryStoreTool mkNoOpMemoryHandle
      _td_name def' `shouldBe` "memory_store"

    it "reports failure when save returns Nothing" $ do
      let (_, handler) = memoryStoreTool mkNoOpMemoryHandle
          input = object ["content" .= ("remember this" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Failed"

    it "reports success with memory id" $ do
      let mh = mkNoOpMemoryHandle { _mh_save = \_ -> pure (Just (MemoryId "mem-1")) }
          (_, handler) = memoryStoreTool mh
          input = object ["content" .= ("remember this" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "mem-1"

  describe "memoryRecallTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = memoryRecallTool mkNoOpMemoryHandle
      _td_name def' `shouldBe` "memory_recall"

    it "reports no memories when search returns empty" $ do
      let (_, handler) = memoryRecallTool mkNoOpMemoryHandle
          input = object ["query" .= ("something" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No memories found"

    it "returns results when found" $ do
      let results = [ SearchResult (MemoryId "1") "found it" 0.9 ]
          mh = mkNoOpMemoryHandle { _mh_search = \_ _ -> pure results }
          (_, handler) = memoryRecallTool mh
          input = object ["query" .= ("search" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "found it"
