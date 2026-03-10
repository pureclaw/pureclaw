module PureClaw.Tools.Image
  ( -- * Tool registration
    imageTool
    -- * Helpers (exported for testing)
  , detectMediaType
  , maxImageSize
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Security.Path

-- | Maximum image size in bytes (20 MB).
maxImageSize :: Int
maxImageSize = 20 * 1024 * 1024

-- | Create an image tool for vision model integration.
-- Reads an image file, base64-encodes it, and returns it as rich
-- content that the provider can process visually.
imageTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, Value -> IO ([ToolResultPart], Bool))
imageTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "image"
      , _td_description = "Read an image file for visual analysis. Supports PNG, JPEG, GIF, and WebP."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The image file path relative to the workspace root" :: Text)
                  ]
              ]
          , "required" .= (["path"] :: [Text])
          ]
      }

    handler input =
      case parseEither parseInput input of
        Left err -> pure ([TRPText (T.pack err)], True)
        Right path -> do
          pathResult <- mkSafePath root (T.unpack path)
          case pathResult of
            Left pe -> pure ([TRPText (T.pack (show pe))], True)
            Right sp -> do
              let ext = map toLowerChar (takeExtension (getSafePath sp))
              case detectMediaType ext of
                Nothing -> pure ([TRPText ("Unsupported image format: " <> T.pack ext)], True)
                Just mediaType -> do
                  result <- try @SomeException (_fh_readFile fh sp)
                  case result of
                    Left e -> pure ([TRPText (T.pack (show e))], True)
                    Right bs
                      | BS.length bs > maxImageSize ->
                          pure ([TRPText ("Image too large: " <> T.pack (show (BS.length bs)) <> " bytes (max " <> T.pack (show maxImageSize) <> ")")], True)
                      | otherwise ->
                          let b64 = B64.encode bs
                          in pure ([TRPImage mediaType b64, TRPText ("Image: " <> path <> " (" <> mediaType <> ", " <> T.pack (show (BS.length bs)) <> " bytes)")], False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "ImageInput" $ \o -> o .: "path"

-- | Detect media type from file extension.
detectMediaType :: String -> Maybe Text
detectMediaType ".png"  = Just "image/png"
detectMediaType ".jpg"  = Just "image/jpeg"
detectMediaType ".jpeg" = Just "image/jpeg"
detectMediaType ".gif"  = Just "image/gif"
detectMediaType ".webp" = Just "image/webp"
detectMediaType _       = Nothing

-- | Lowercase a character (ASCII only, avoids Data.Char import overhead).
toLowerChar :: Char -> Char
toLowerChar c
  | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c
