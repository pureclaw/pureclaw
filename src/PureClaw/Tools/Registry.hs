module PureClaw.Tools.Registry
  ( -- * Tool execution
    ToolHandler (..)
  , ToolRegistry
    -- * Registry operations
  , emptyRegistry
  , registerTool
  , registerRichTool
  , registryDefinitions
  , executeTool
  ) where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import PureClaw.Providers.Class

-- | A tool handler: given JSON input, produce a text result.
-- The Bool in the result indicates whether the result is an error.
newtype ToolHandler = ToolHandler
  { runTool :: Value -> IO (Text, Bool)
  }

-- | Registry of available tools. Maps tool names to their definitions
-- and handlers that return rich content (text + images).
newtype ToolRegistry = ToolRegistry
  { _tr_tools :: Map Text (ToolDefinition, Value -> IO ([ToolResultPart], Bool))
  }

-- | Empty registry with no tools.
emptyRegistry :: ToolRegistry
emptyRegistry = ToolRegistry Map.empty

-- | Register a text-only tool with its definition and handler.
registerTool :: ToolDefinition -> ToolHandler -> ToolRegistry -> ToolRegistry
registerTool def handler = registerRichTool def $ \v -> do
  (text, isErr) <- runTool handler v
  pure ([TRPText text], isErr)

-- | Register a tool that returns rich content (text, images).
registerRichTool :: ToolDefinition -> (Value -> IO ([ToolResultPart], Bool)) -> ToolRegistry -> ToolRegistry
registerRichTool def handler reg = reg
  { _tr_tools = Map.insert (_td_name def) (def, handler) (_tr_tools reg)
  }

-- | Get all tool definitions for sending to the provider.
registryDefinitions :: ToolRegistry -> [ToolDefinition]
registryDefinitions = map fst . Map.elems . _tr_tools

-- | Execute a tool by name. Returns Nothing if the tool is not found.
executeTool :: ToolRegistry -> Text -> Value -> IO (Maybe ([ToolResultPart], Bool))
executeTool reg name input =
  case Map.lookup name (_tr_tools reg) of
    Nothing -> pure Nothing
    Just (_, handler) -> Just <$> handler input
