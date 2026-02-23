module Agent.MemorySpec (spec) where

import Data.IORef
import Test.Hspec

import PureClaw.Agent.Memory
import PureClaw.Core.Types
import PureClaw.Handles.Log
import PureClaw.Handles.Memory

spec :: Spec
spec = do
  describe "autoRecall" $ do
    it "returns Nothing when no memories match" $ do
      let mh = mkNoOpMemoryHandle
      result <- autoRecall mh mkNoOpLogHandle "anything"
      result `shouldBe` Nothing

    it "returns formatted context when memories exist" $ do
      let results = [SearchResult (MemoryId "1") "relevant info" 0.9]
          mh = mkNoOpMemoryHandle { _mh_search = \_ _ -> pure results }
      result <- autoRecall mh mkNoOpLogHandle "query"
      result `shouldSatisfy` isJust
      case result of
        Just t -> show t `shouldContain` "relevant info"
        Nothing -> expectationFailure "expected Just"

  describe "autoSave" $ do
    it "does not save short messages" $ do
      savedRef <- newIORef (0 :: Int)
      let mh = mkNoOpMemoryHandle
            { _mh_save = \_ -> do
                modifyIORef savedRef (+ 1)
                pure (Just (MemoryId "1"))
            }
      autoSave mh mkNoOpLogHandle "short"
      saved <- readIORef savedRef
      saved `shouldBe` 0

    it "saves messages over the minimum length" $ do
      savedRef <- newIORef (0 :: Int)
      let mh = mkNoOpMemoryHandle
            { _mh_save = \_ -> do
                modifyIORef savedRef (+ 1)
                pure (Just (MemoryId "1"))
            }
          longMsg = "This is a message that is definitely longer than fifty characters to trigger auto-save."
      autoSave mh mkNoOpLogHandle longMsg
      saved <- readIORef savedRef
      saved `shouldBe` 1

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing  = False
