module Tools.ExecuteCodeSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Security.Policy
import PureClaw.Tools.ExecuteCode
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "executeCodeTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = executeCodeTool defaultPolicy
      _td_name def' `shouldBe` "execute_code"

    it "rejects when interpreter not allowed" $ do
      let (_, handler) = executeCodeTool defaultPolicy
          input = object ["code" .= ("print('hi')" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "denied"

    it "executes Python code when allowed" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "python3") defaultPolicy
          (_, handler) = executeCodeTool policy
          input = object ["code" .= ("print('hello from python')" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "hello from python"

    it "reports non-zero exit codes" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "python3") defaultPolicy
          (_, handler) = executeCodeTool policy
          input = object ["code" .= ("import sys; sys.exit(42)" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "42"

    it "supports custom language" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "bash") defaultPolicy
          (_, handler) = executeCodeTool policy
          input = object
            [ "code" .= ("echo hello from bash" :: String)
            , "language" .= ("bash" :: String)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "hello from bash"

    it "rejects invalid JSON input" $ do
      let (_, handler) = executeCodeTool defaultPolicy
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True
