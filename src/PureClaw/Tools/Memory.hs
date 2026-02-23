module PureClaw.Tools.Memory
  ( -- * Tool registration
    memoryStoreTool
  , memoryRecallTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Core.Types
import PureClaw.Handles.Memory
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a memory store tool.
memoryStoreTool :: MemoryHandle -> (ToolDefinition, ToolHandler)
memoryStoreTool mh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "memory_store"
      , _td_description = "Store a piece of information in long-term memory for later recall."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "content" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The content to remember" :: Text)
                  ]
              , "tags" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Comma-separated tags for categorization" :: Text)
                  ]
              ]
          , "required" .= (["content"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right (content, tags) -> do
          let source = MemorySource
                { _ms_content  = content
                , _ms_metadata = Map.fromList [("tags", tags)]
                }
          result <- try @SomeException (_mh_save mh source)
          case result of
            Left e -> pure (T.pack (show e), True)
            Right Nothing -> pure ("Failed to store memory", True)
            Right (Just mid) -> pure ("Stored with id: " <> unMemoryId mid, False)

    parseInput :: Value -> Parser (Text, Text)
    parseInput = withObject "MemoryStoreInput" $ \o ->
      (,) <$> o .: "content" <*> o .:? "tags" .!= ""

-- | Create a memory recall tool.
memoryRecallTool :: MemoryHandle -> (ToolDefinition, ToolHandler)
memoryRecallTool mh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "memory_recall"
      , _td_description = "Search long-term memory for relevant information."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "query" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The search query" :: Text)
                  ]
              ]
          , "required" .= (["query"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right query -> do
          result <- try @SomeException (_mh_search mh query defaultSearchConfig)
          case result of
            Left e -> pure (T.pack (show e), True)
            Right [] -> pure ("No memories found for: " <> query, False)
            Right results ->
              let formatted = T.intercalate "\n---\n"
                    [ _sr_content r <> " (score: " <> T.pack (show (_sr_score r)) <> ")"
                    | r <- results
                    ]
              in pure (formatted, False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "MemoryRecallInput" $ \o -> o .: "query"
