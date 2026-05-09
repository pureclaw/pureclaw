module Tools.TodoSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Providers.Class
import PureClaw.Tools.Registry
import PureClaw.Tools.Todo

spec :: Spec
spec = do
  describe "todoTool" $ do
    it "has the correct tool name" $ do
      (def', _) <- todoTool
      _td_name def' `shouldBe` "todo"

    it "returns empty list when no todos" $ do
      (_, handler) <- todoTool
      let input = object []
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No todos"

    it "writes and reads todos" $ do
      (_, handler) <- todoTool
      let writeInput = object ["todos" .= [
              object ["id" .= ("1" :: String), "content" .= ("do thing" :: String), "status" .= ("pending" :: String)]
            ]]
      (output, isErr) <- runTool handler writeInput
      isErr `shouldBe` False
      T.unpack output `shouldContain` "do thing"
      -- Read back
      let readInput = object []
      (readOutput, readErr) <- runTool handler readInput
      readErr `shouldBe` False
      T.unpack readOutput `shouldContain` "do thing"

    it "replaces all todos by default" $ do
      (_, handler) <- todoTool
      let write1 = object ["todos" .= [
              object ["id" .= ("1" :: String), "content" .= ("first" :: String), "status" .= ("pending" :: String)]
            ]]
          write2 = object ["todos" .= [
              object ["id" .= ("2" :: String), "content" .= ("second" :: String), "status" .= ("pending" :: String)]
            ]]
      _ <- runTool handler write1
      (output, _) <- runTool handler write2
      T.unpack output `shouldContain` "second"
      T.unpack output `shouldSatisfy` (not . ("first" `elem`) . words)

    it "merges when merge=true" $ do
      (_, handler) <- todoTool
      let write1 = object ["todos" .= [
              object ["id" .= ("1" :: String), "content" .= ("first" :: String), "status" .= ("pending" :: String)]
            ]]
          write2 = object
            [ "todos" .= [
                object ["id" .= ("2" :: String), "content" .= ("second" :: String), "status" .= ("pending" :: String)]
              ]
            , "merge" .= True
            ]
      _ <- runTool handler write1
      (output, _) <- runTool handler write2
      T.unpack output `shouldContain` "first"
      T.unpack output `shouldContain` "second"

    it "rejects invalid statuses" $ do
      (_, handler) <- todoTool
      let input = object ["todos" .= [
              object ["id" .= ("1" :: String), "content" .= ("x" :: String), "status" .= ("invalid" :: String)]
            ]]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "Invalid status"

    it "groups by status in output" $ do
      (_, handler) <- todoTool
      let input = object ["todos" .= [
              object ["id" .= ("1" :: String), "content" .= ("active" :: String), "status" .= ("in_progress" :: String)],
              object ["id" .= ("2" :: String), "content" .= ("waiting" :: String), "status" .= ("pending" :: String)],
              object ["id" .= ("3" :: String), "content" .= ("done" :: String), "status" .= ("completed" :: String)]
            ]]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "IN_PROGRESS"
      T.unpack output `shouldContain` "PENDING"
      T.unpack output `shouldContain` "COMPLETED"
