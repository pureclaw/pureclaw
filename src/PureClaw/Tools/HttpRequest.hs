module PureClaw.Tools.HttpRequest
  ( -- * Tool registration
    httpRequestTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Core.Types
import PureClaw.Handles.Network
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create an HTTP request tool that sends requests through URL validation.
httpRequestTool :: AllowList Text -> NetworkHandle -> (ToolDefinition, ToolHandler)
httpRequestTool allowList nh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "http_request"
      , _td_description = "Make an HTTP GET request to a URL. The URL must be in the allowed domain list."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "url" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The URL to request" :: Text)
                  ]
              ]
          , "required" .= (["url"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right url ->
          case mkAllowedUrl allowList url of
            Left (UrlNotAllowed u) -> pure ("URL domain not allowed: " <> u, True)
            Left (UrlMalformed u) -> pure ("Malformed URL: " <> u, True)
            Right allowed -> do
              result <- try @SomeException (_nh_httpGet nh allowed)
              case result of
                Left e -> pure (T.pack (show e), True)
                Right resp ->
                  let status = T.pack (show (_hr_statusCode resp))
                      body = T.pack (BS8.unpack (_hr_body resp))
                  in pure ("HTTP " <> status <> "\n" <> body, False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "HttpRequestInput" $ \o -> o .: "url"
