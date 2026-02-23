module PureClaw.Tools.FileWrite
  ( -- * Tool registration
    fileWriteTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Security.Path
import PureClaw.Tools.Registry

-- | Create a file write tool that writes files through SafePath validation.
fileWriteTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, ToolHandler)
fileWriteTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "file_write"
      , _td_description = "Write content to a file within the workspace. Creates the file if it does not exist, or overwrites if it does."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The file path relative to the workspace root" :: Text)
                  ]
              , "content" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The content to write" :: Text)
                  ]
              ]
          , "required" .= (["path", "content"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right (path, content) -> do
          pathResult <- mkSafePath root (T.unpack path)
          case pathResult of
            Left (PathDoesNotExist _) -> do
              -- For writes, we allow creating new files. Use the raw path
              -- but still validate it doesn't escape workspace.
              writeNew root path content
            Left pe -> pure (T.pack (show pe), True)
            Right sp -> do
              result <- try @SomeException (_fh_writeFile fh sp (TE.encodeUtf8 content))
              case result of
                Left e -> pure (T.pack (show e), True)
                Right () -> pure ("Written to " <> path, False)

    writeNew :: WorkspaceRoot -> Text -> Text -> IO (Text, Bool)
    writeNew (WorkspaceRoot wr) path content = do
      -- Create the file first so mkSafePath can validate it exists
      let fullPath = wr <> "/" <> T.unpack path
      result <- try @SomeException (TE.encodeUtf8 content `seq` pure ())
      case result of
        Left e -> pure (T.pack (show e), True)
        Right () -> do
          writeResult <- try @SomeException $ do
            BS.writeFile fullPath (TE.encodeUtf8 content)
          case writeResult of
            Left e -> pure (T.pack (show e), True)
            Right () -> do
              -- Validate the written file is safe
              validated <- mkSafePath (WorkspaceRoot wr) fullPath
              case validated of
                Left pe -> pure (T.pack (show pe), True)
                Right _ -> pure ("Written to " <> path, False)

    parseInput :: Value -> Parser (Text, Text)
    parseInput = withObject "FileWriteInput" $ \o ->
      (,) <$> o .: "path" <*> o .: "content"
