module PureClaw.Tools.WebSearch
  ( -- * Tool registration
    webSearchTool
    -- * Exported for testing
  , formatResults
  , escapeQuery
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types.Header qualified as Header

import PureClaw.Core.Types
import PureClaw.Handles.Network
import PureClaw.Providers.Class
import PureClaw.Security.Secrets
import PureClaw.Tools.Registry

-- | Create a web search tool using the Brave Search API.
-- The API key is accessed via CPS to prevent leakage.
webSearchTool :: AllowList Text -> ApiKey -> NetworkHandle -> (ToolDefinition, ToolHandler)
webSearchTool allowList apiKey nh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "web_search"
      , _td_description = "Search the web using Brave Search. Returns titles, URLs, and descriptions."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "query" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The search query" :: Text)
                  ]
              , "count" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Number of results (default 5, max 20)" :: Text)
                  ]
              ]
          , "required" .= (["query"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right (query, count) -> do
          let url = "https://api.search.brave.com/res/v1/web/search?q="
                    <> T.pack (escapeQuery (T.unpack query))
                    <> "&count=" <> T.pack (show (min 20 (max 1 count)))
          case mkAllowedUrl allowList url of
            Left (UrlNotAllowed _) ->
              pure ("Search API domain not in allow-list", True)
            Left (UrlMalformed u) ->
              pure ("Malformed search URL: " <> u, True)
            Right allowed -> do
              let headers = withApiKey apiKey $ \key ->
                    [ ( Header.hAccept, "application/json" )
                    , ( "X-Subscription-Token", key )
                    ]
              result <- try @SomeException
                (_nh_httpGetWithHeaders nh allowed headers)
              case result of
                Left e -> pure (T.pack (show e), True)
                Right resp
                  | _hr_statusCode resp /= 200 ->
                      pure ("Search API error: HTTP "
                            <> T.pack (show (_hr_statusCode resp)), True)
                  | otherwise ->
                      pure (formatResults (_hr_body resp), False)

    parseInput :: Value -> Parser (Text, Int)
    parseInput = withObject "WebSearchInput" $ \o ->
      (,) <$> o .: "query" <*> o .:? "count" .!= 5

-- | URL-encode a query string (minimal: spaces and special chars).
escapeQuery :: String -> String
escapeQuery = concatMap escapeChar
  where
    escapeChar ' ' = "+"
    escapeChar '&' = "%26"
    escapeChar '=' = "%3D"
    escapeChar '+' = "%2B"
    escapeChar '#' = "%23"
    escapeChar '%' = "%25"
    escapeChar c   = [c]

-- | Parse Brave Search JSON response and format as readable text.
formatResults :: ByteString -> Text
formatResults body =
  case eitherDecodeStrict body of
    Left err -> "Failed to parse search results: " <> T.pack err
    Right val ->
      case parseMaybe parseWebResults val of
        Nothing      -> "No results found"
        Just []      -> "No results found"
        Just results -> T.intercalate "\n\n" results

-- | Parse the web.results array from a Brave Search response.
parseWebResults :: Value -> Parser [Text]
parseWebResults = withObject "BraveResponse" $ \o -> do
  web <- o .: "web"
  results <- web .: "results"
  mapM parseResult results

-- | Parse a single search result into formatted text.
parseResult :: Value -> Parser Text
parseResult = withObject "SearchResult" $ \o -> do
  title <- o .:? "title" .!= ""
  url   <- o .:? "url"   .!= ""
  desc  <- o .:? "description" .!= ""
  pure $ title <> "\n" <> url <> "\n" <> desc
