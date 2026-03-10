module PureClaw.Tools.Edit
  ( -- * Tool registration
    editTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Security.Path
import PureClaw.Tools.Registry

-- | Create an edit tool that performs string replacement in files.
-- The old string must be unique in the file — ambiguous edits are rejected.
editTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, ToolHandler)
editTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "edit"
      , _td_description = "Replace a unique string in a file. The old_string must appear exactly once in the file."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The file path relative to the workspace root" :: Text)
                  ]
              , "old_string" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The exact string to find and replace (must be unique)" :: Text)
                  ]
              , "new_string" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The replacement string" :: Text)
                  ]
              ]
          , "required" .= (["path", "old_string", "new_string"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right (path, oldStr, newStr) -> do
          pathResult <- mkSafePath root (T.unpack path)
          case pathResult of
            Left pe -> pure (T.pack (show pe), True)
            Right sp -> do
              readResult <- try @SomeException (_fh_readFile fh sp)
              case readResult of
                Left e -> pure (T.pack (show e), True)
                Right bs -> case TE.decodeUtf8' bs of
                  Left _ -> pure ("Cannot edit binary file", True)
                  Right content ->
                    let count = countOccurrences oldStr content
                    in case count of
                      0 -> pure ("old_string not found in " <> path, True)
                      1 -> do
                        let newContent = replaceFirst oldStr newStr content
                        writeResult <- try @SomeException
                          (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
                        case writeResult of
                          Left e -> pure (T.pack (show e), True)
                          Right () -> pure ("Edited " <> path, False)
                      n -> pure ("old_string not unique in " <> path
                                <> " (" <> T.pack (show n) <> " occurrences)", True)

    parseInput :: Value -> Parser (Text, Text, Text)
    parseInput = withObject "EditInput" $ \o ->
      (,,) <$> o .: "path" <*> o .: "old_string" <*> o .: "new_string"

-- | Count non-overlapping occurrences of a needle in a haystack.
countOccurrences :: Text -> Text -> Int
countOccurrences needle haystack
  | T.null needle = 0
  | otherwise     = go 0 haystack
  where
    go !n remaining =
      case T.breakOn needle remaining of
        (_, after)
          | T.null after -> n
          | otherwise    -> go (n + 1) (T.drop (T.length needle) after)

-- | Replace the first occurrence of needle with replacement.
replaceFirst :: Text -> Text -> Text -> Text
replaceFirst needle replacement haystack =
  let (before, after) = T.breakOn needle haystack
  in before <> replacement <> T.drop (T.length needle) after
