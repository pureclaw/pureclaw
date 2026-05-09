module PureClaw.Tools.Todo
  ( -- * Tool registration
    todoTool
  ) where

import Data.Aeson
import Data.Aeson.Types
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | A single todo item.
data TodoItem = TodoItem
  { _ti_id      :: Text
  , _ti_content :: Text
  , _ti_status  :: Text  -- pending | in_progress | completed | cancelled
  }
  deriving stock (Show, Eq)

instance ToJSON TodoItem where
  toJSON ti = object
    [ "id"      .= _ti_id ti
    , "content" .= _ti_content ti
    , "status"  .= _ti_status ti
    ]

instance FromJSON TodoItem where
  parseJSON = withObject "TodoItem" $ \o ->
    TodoItem <$> o .: "id" <*> o .: "content" <*> o .: "status"

-- | Valid todo statuses.
validStatuses :: [Text]
validStatuses = ["pending", "in_progress", "completed", "cancelled"]

-- | Create an in-memory todo tool for lightweight task tracking.
-- State is per-session (not persisted across restarts).
-- Omit the @todos@ field to read the current list; provide it to write.
todoTool :: IO (ToolDefinition, ToolHandler)
todoTool = do
  stateRef <- newIORef (Map.empty :: Map Text TodoItem)
  let def = ToolDefinition
        { _td_name        = "todo"
        , _td_description = T.unlines
            [ "In-memory task list for decomposing complex work."
            , "Omit 'todos' to read the current list."
            , "Provide 'todos' array to write/update items."
            , "Set merge=true to merge with existing items (default: replace all)."
            , "Statuses: pending, in_progress, completed, cancelled."
            ]
        , _td_inputSchema = object
            [ "type" .= ("object" :: Text)
            , "properties" .= object
                [ "todos" .= object
                    [ "type" .= ("array" :: Text)
                    , "items" .= object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= object
                            [ "id" .= object ["type" .= ("string" :: Text)]
                            , "content" .= object ["type" .= ("string" :: Text)]
                            , "status" .= object
                                [ "type" .= ("string" :: Text)
                                , "enum" .= validStatuses
                                ]
                            ]
                        , "required" .= (["id", "content", "status"] :: [Text])
                        ]
                    , "description" .= ("Todo items to set. Omit to read current list." :: Text)
                    ]
                , "merge" .= object
                    [ "type" .= ("boolean" :: Text)
                    , "description" .= ("Merge with existing items instead of replacing (default: false)" :: Text)
                    ]
                ]
            ]
        }

      handler = ToolHandler $ \input ->
        case parseEither parseTodoInput input of
          Left err -> pure (T.pack err, True)
          Right (Nothing, _) -> do
            -- Read mode
            items <- readIORef stateRef
            pure (formatTodos (Map.elems items), False)
          Right (Just todos, merge) -> do
            -- Validate statuses
            let invalid = filter (\ti -> _ti_status ti `notElem` validStatuses) todos
            if not (null invalid)
              then pure ("Invalid status in: " <> T.intercalate ", " (map _ti_id invalid)
                        <> ". Valid: " <> T.intercalate ", " validStatuses, True)
              else do
                let newMap = Map.fromList [(_ti_id ti, ti) | ti <- todos]
                if merge
                  then atomicModifyIORef' stateRef $ \old ->
                    (Map.union newMap old, ())
                  else writeIORef stateRef newMap
                items <- readIORef stateRef
                pure (formatTodos (Map.elems items), False)

  pure (def, handler)

formatTodos :: [TodoItem] -> Text
formatTodos [] = "No todos."
formatTodos items =
  let grouped = Map.fromListWith (++) [(statusOrder (_ti_status ti), [ti]) | ti <- items]
      sections = map formatSection (Map.toAscList grouped)
  in T.intercalate "\n\n" sections

statusOrder :: Text -> Int
statusOrder "in_progress" = 0
statusOrder "pending"     = 1
statusOrder "completed"   = 2
statusOrder "cancelled"   = 3
statusOrder _             = 4

formatSection :: (Int, [TodoItem]) -> Text
formatSection (_, []) = ""
formatSection (_, items@(first:_)) =
  let header = T.toUpper (_ti_status first)
      lines' = map formatItem items
  in header <> ":\n" <> T.intercalate "\n" lines'

formatItem :: TodoItem -> Text
formatItem ti = "  [" <> _ti_id ti <> "] " <> _ti_content ti

parseTodoInput :: Value -> Parser (Maybe [TodoItem], Bool)
parseTodoInput = withObject "TodoInput" $ \o ->
  (,) <$> o .:? "todos" <*> o .:? "merge" .!= False
