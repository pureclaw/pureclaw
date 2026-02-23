module PureClaw.Tools.FileRead
  ( -- * Tool registration
    fileReadTool
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

-- | Create a file read tool that reads files through SafePath validation.
fileReadTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, ToolHandler)
fileReadTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "file_read"
      , _td_description = "Read the contents of a file within the workspace."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The file path relative to the workspace root" :: Text)
                  ]
              ]
          , "required" .= (["path"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right path -> do
          pathResult <- mkSafePath root (T.unpack path)
          case pathResult of
            Left pe -> pure (T.pack (show pe), True)
            Right sp -> do
              result <- try @SomeException (_fh_readFile fh sp)
              case result of
                Left e -> pure (T.pack (show e), True)
                Right bs -> case TE.decodeUtf8' bs of
                  Left _ -> pure ("Binary file (" <> T.pack (show (BS.length bs)) <> " bytes)", False)
                  Right txt -> pure (txt, False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "FileReadInput" $ \o -> o .: "path"
