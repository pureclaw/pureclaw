module Tools.RegistrySpec (spec) where

import Data.Aeson
import Test.Hspec

import PureClaw.Providers.Class
import PureClaw.Tools.Registry

spec :: Spec
spec = do
  describe "emptyRegistry" $ do
    it "has no tool definitions" $ do
      registryDefinitions emptyRegistry `shouldBe` []

    it "returns Nothing for any tool" $ do
      result <- executeTool emptyRegistry "shell" (object [])
      result `shouldBe` Nothing

  describe "registerTool" $ do
    it "adds a tool to the registry" $ do
      let def' = ToolDefinition "test" "A test tool" (object [])
          handler = ToolHandler $ \_ -> pure ("ok", False)
          reg = registerTool def' handler emptyRegistry
      length (registryDefinitions reg) `shouldBe` 1

    it "tool can be executed after registration" $ do
      let def' = ToolDefinition "echo" "Echo tool" (object [])
          handler = ToolHandler $ \_ -> pure ("echoed", False)
          reg = registerTool def' handler emptyRegistry
      result <- executeTool reg "echo" (object [])
      result `shouldBe` Just ([TRPText "echoed"], False)

    it "returns Nothing for unregistered tools" $ do
      let def' = ToolDefinition "echo" "Echo tool" (object [])
          handler = ToolHandler $ \_ -> pure ("echoed", False)
          reg = registerTool def' handler emptyRegistry
      result <- executeTool reg "other" (object [])
      result `shouldBe` Nothing

  describe "registryDefinitions" $ do
    it "returns all registered definitions" $ do
      let def1 = ToolDefinition "tool1" "First" (object [])
          def2 = ToolDefinition "tool2" "Second" (object [])
          handler = ToolHandler $ \_ -> pure ("ok", False)
          reg = registerTool def2 handler
              $ registerTool def1 handler emptyRegistry
          names = map _td_name (registryDefinitions reg)
      "tool1" `elem` names `shouldBe` True
      "tool2" `elem` names `shouldBe` True
