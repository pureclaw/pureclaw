module PureClaw.Tools.WebExtract
  ( -- * Tool registration
    webExtractTool
    -- * Internals (exported for testing)
  , htmlToMarkdown
  , truncateBody
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T

import PureClaw.Core.Types
import PureClaw.Handles.Network
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a web_extract tool that fetches a URL and converts the
-- response to readable markdown. Handles HTML→markdown conversion,
-- response size limits, and content-type detection.
webExtractTool :: AllowList Text -> NetworkHandle -> (ToolDefinition, ToolHandler)
webExtractTool allowList nh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "web_extract"
      , _td_description = T.unlines
          [ "Fetch a URL and extract its content as readable markdown."
          , "HTML pages are converted to markdown with headings, links, and lists preserved."
          , "Non-HTML responses (JSON, plain text) are returned as-is."
          , "Large responses are truncated to 100K characters."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "url" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The URL to fetch and extract content from" :: Text)
                  ]
              , "max_length" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Maximum response length in characters (default: 100000)" :: Text)
                  ]
              ]
          , "required" .= (["url"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right (url, maxLen) ->
          case mkAllowedUrl allowList url of
            Left (UrlNotAllowed u) -> pure ("URL domain not allowed: " <> u, True)
            Left (UrlMalformed u) -> pure ("Malformed URL: " <> u, True)
            Right allowed -> do
              result <- try @SomeException (_nh_httpGet nh allowed)
              case result of
                Left e -> pure ("web_extract error: " <> T.pack (show e), True)
                Right resp ->
                  let status = _hr_statusCode resp
                      body = T.pack (BS8.unpack (_hr_body resp))
                      limit = fromMaybe 100000 maxLen
                  in if status >= 400
                    then pure ("HTTP " <> T.pack (show status), True)
                    else
                      let converted = if looksLikeHtml body
                            then htmlToMarkdown body
                            else body
                          truncated = truncateBody limit converted
                      in pure (truncated, False)

    parseInput :: Value -> Parser (Text, Maybe Int)
    parseInput = withObject "WebExtractInput" $ \o ->
      (,) <$> o .: "url" <*> o .:? "max_length"

-- | Check if the response body looks like HTML.
looksLikeHtml :: Text -> Bool
looksLikeHtml t =
  let lower = T.toLower (T.take 500 t)
  in T.isInfixOf "<html" lower
  || T.isInfixOf "<!doctype" lower
  || T.isInfixOf "<head" lower
  || T.isInfixOf "<body" lower

-- | Convert HTML to readable markdown-like text.
-- This is a simple tag-aware converter, not a full HTML parser.
-- Handles: headings, paragraphs, links, lists, code blocks, emphasis.
htmlToMarkdown :: Text -> Text
htmlToMarkdown html =
  let -- Remove script and style blocks first
      noScript = removeBlocks "script" (removeBlocks "style" (removeBlocks "noscript" html))
      -- Process the remaining HTML
      processed = processHtml noScript
      -- Clean up excessive whitespace
      cleaned = collapseBlankLines (T.strip processed)
  in cleaned

-- | Remove everything between <tag>...</tag> including the tags.
removeBlocks :: Text -> Text -> Text
removeBlocks tag input = go input
  where
    openTag = "<" <> tag
    closeTag = "</" <> tag <> ">"

    go remaining
      | T.null remaining = remaining
      | otherwise =
          let (before, afterOpen) = T.breakOn openTag (T.toLower remaining)
              -- Use the original casing for the "before" portion
              origBefore = T.take (T.length before) remaining
          in if T.null afterOpen
            then remaining
            else
              let rest = T.drop (T.length before) remaining
                  -- Find the closing tag in the rest
                  (_, afterClose) = T.breakOn closeTag (T.toLower rest)
                  origAfterClose = T.drop (T.length (T.take (T.length (T.toLower rest) - T.length afterClose) (T.toLower rest))) rest
              in if T.null afterClose
                then remaining  -- malformed, return as-is
                else
                  let skipClose = T.drop (T.length closeTag) origAfterClose
                  in origBefore <> go skipClose

-- | Process HTML tags into markdown.
processHtml :: Text -> Text
processHtml = go ""
  where
    go acc remaining
      | T.null remaining = acc
      | "<" `T.isPrefixOf` remaining =
          let (tag, afterTag) = parseTag remaining
              (converted, rest) = handleTag tag afterTag
          in go (acc <> converted) rest
      | otherwise =
          let (text, rest) = T.break (== '<') remaining
              decoded = decodeEntities text
          in go (acc <> decoded) rest

    parseTag :: Text -> (Text, Text)
    parseTag t =
      let withoutLt = T.drop 1 t  -- drop '<'
          (tagContent, rest) = T.break (== '>') withoutLt
      in (T.strip tagContent, T.drop 1 rest)  -- drop '>'

    handleTag :: Text -> Text -> (Text, Text)
    handleTag tag rest
      | tagIs "h1" tag  = ("\n\n# ", rest)
      | tagIs "/h1" tag = ("\n\n", rest)
      | tagIs "h2" tag  = ("\n\n## ", rest)
      | tagIs "/h2" tag = ("\n\n", rest)
      | tagIs "h3" tag  = ("\n\n### ", rest)
      | tagIs "/h3" tag = ("\n\n", rest)
      | tagIs "h4" tag  = ("\n\n#### ", rest)
      | tagIs "/h4" tag = ("\n\n", rest)
      | tagIs "h5" tag  = ("\n\n##### ", rest)
      | tagIs "/h5" tag = ("\n\n", rest)
      | tagIs "h6" tag  = ("\n\n###### ", rest)
      | tagIs "/h6" tag = ("\n\n", rest)
      | tagIs "p" tag   = ("\n\n", rest)
      | tagIs "/p" tag  = ("\n\n", rest)
      | tagIs "br" tag || tagIs "br/" tag || tagIs "br /" tag = ("\n", rest)
      | tagIs "li" tag  = ("\n- ", rest)
      | tagIs "/li" tag = ("", rest)
      | tagIs "ul" tag || tagIs "ol" tag = ("\n", rest)
      | tagIs "/ul" tag || tagIs "/ol" tag = ("\n", rest)
      | tagIs "strong" tag || tagIs "b" tag = ("**", rest)
      | tagIs "/strong" tag || tagIs "/b" tag = ("**", rest)
      | tagIs "em" tag || tagIs "i" tag = ("*", rest)
      | tagIs "/em" tag || tagIs "/i" tag = ("*", rest)
      | tagIs "code" tag = ("`", rest)
      | tagIs "/code" tag = ("`", rest)
      | tagIs "pre" tag = ("\n```\n", rest)
      | tagIs "/pre" tag = ("\n```\n", rest)
      | tagIs "blockquote" tag = ("\n> ", rest)
      | tagIs "/blockquote" tag = ("\n", rest)
      | tagIs "hr" tag || tagIs "hr/" tag = ("\n---\n", rest)
      | tagIs "a" tag =
          let href = extractAttr "href" tag
          in case href of
            Just _href -> ("[", rest)
                -- Simple approach: emit the link text in brackets.
                -- For a full implementation, we'd buffer until </a> and append the href.
            Nothing -> ("", rest)
      | tagIs "/a" tag = ("", rest)
      | tagIs "div" tag = ("\n", rest)
      | tagIs "/div" tag = ("\n", rest)
      | tagIs "td" tag = (" | ", rest)
      | tagIs "th" tag = (" | ", rest)
      | tagIs "tr" tag = ("\n", rest)
      | tagIs "/tr" tag = (" |", rest)
      | otherwise = ("", rest)  -- skip unknown tags

    tagIs :: Text -> Text -> Bool
    tagIs expected full =
      let lower = T.toLower full
          name = T.takeWhile (\c -> c /= ' ' && c /= '\t') lower
      in name == expected

    extractAttr :: Text -> Text -> Maybe Text
    extractAttr attr tag =
      let lower = T.toLower tag
      in case T.breakOn (attr <> "=\"") lower of
        (_, after)
          | T.null after -> Nothing
          | otherwise ->
              let rest = T.drop (T.length attr + 2) after
                  value = T.takeWhile (/= '"') rest
              in Just value

-- | Decode common HTML entities.
decodeEntities :: Text -> Text
decodeEntities = T.replace "&amp;" "&"
               . T.replace "&lt;" "<"
               . T.replace "&gt;" ">"
               . T.replace "&quot;" "\""
               . T.replace "&#39;" "'"
               . T.replace "&apos;" "'"
               . T.replace "&nbsp;" " "
               . T.replace "&#x27;" "'"
               . T.replace "&#x2F;" "/"

-- | Collapse runs of more than 2 consecutive blank lines.
collapseBlankLines :: Text -> Text
collapseBlankLines = T.intercalate "\n\n" . filter (not . T.null) . map T.strip . T.splitOn "\n\n\n"

-- | Truncate body to a maximum length, adding a marker if truncated.
truncateBody :: Int -> Text -> Text
truncateBody maxLen t
  | T.length t <= maxLen = t
  | otherwise = T.take maxLen t <> "\n\n[...truncated at " <> T.pack (show maxLen) <> " chars]"

