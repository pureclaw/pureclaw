module PureClaw.Tools.SessionSearch
  ( -- * Tool registration
    sessionSearchTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import System.Directory (listDirectory, doesFileExist)
import System.FilePath ((</>))

import PureClaw.Core.Types
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript
import PureClaw.Providers.Class
import PureClaw.Session.Types
import PureClaw.Tools.Registry
import PureClaw.Transcript.Types

-- | Create a session_search tool that searches across past session
-- transcripts. Performs substring matching on transcript entries'
-- payload text, returning matching entries grouped by session.
sessionSearchTool :: LogHandle -> FilePath -> (ToolDefinition, ToolHandler)
sessionSearchTool logger sessionsDir = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "session_search"
      , _td_description = T.unlines
          [ "Search across past session transcripts."
          , "Performs substring matching on message content."
          , "Returns matching entries grouped by session, most recent first."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "query" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Search query (substring match, case-insensitive)" :: Text)
                  ]
              , "limit" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Maximum number of matching entries to return (default: 10)" :: Text)
                  ]
              ]
          , "required" .= (["query"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseSearchInput input of
        Left err -> pure (T.pack err, True)
        Right (query, limit) -> searchSessions query limit

    searchSessions :: Text -> Int -> IO (Text, Bool)
    searchSessions query limit = do
      result <- try @SomeException $ do
        sessionDirs <- listSessionDirs sessionsDir
        allMatches <- concat <$> mapM (searchOneSession query) sessionDirs
        let sorted = take limit (sortOn (Down . _sr_timestamp) allMatches)
        pure sorted
      case result of
        Left e -> pure ("session_search error: " <> T.pack (show e), True)
        Right [] -> pure ("No matches found for: " <> query, False)
        Right matches -> pure (formatMatches matches, False)

    searchOneSession :: Text -> FilePath -> IO [SearchResult]
    searchOneSession query sessionDir = do
      let transcriptPath = sessionDir </> "transcript.jsonl"
          metaPath = sessionDir </> "session.json"
      hasTranscript <- doesFileExist transcriptPath
      if not hasTranscript
        then pure []
        else do
          sessionId <- readSessionId metaPath
          th <- mkFileTranscriptHandle logger transcriptPath
          entries <- _th_query th emptyFilter
          _th_close th
          let queryLower = T.toLower query
              matching = filter (matchesQuery queryLower) entries
          pure [SearchResult
            { _sr_sessionId = sessionId
            , _sr_timestamp = _te_timestamp entry
            , _sr_direction = _te_direction entry
            , _sr_snippet   = extractSnippet query (_te_payload entry)
            } | entry <- matching]

    matchesQuery :: Text -> TranscriptEntry -> Bool
    matchesQuery queryLower entry =
      T.isInfixOf queryLower (T.toLower (_te_payload entry))

    readSessionId :: FilePath -> IO Text
    readSessionId metaPath = do
      exists <- doesFileExist metaPath
      if not exists
        then pure "(unknown)"
        else do
          result <- try @SomeException (decodeFileStrict metaPath)
          case result of
            Right (Just meta) -> pure (unSessionId (_sm_id (meta :: SessionMeta)))
            _ -> pure "(unknown)"

    listSessionDirs :: FilePath -> IO [FilePath]
    listSessionDirs dir = do
      entries <- try @SomeException (listDirectory dir)
      case entries of
        Left _ -> pure []
        Right names -> pure [dir </> n | n <- names]

data SearchResult = SearchResult
  { _sr_sessionId :: Text
  , _sr_timestamp :: UTCTime
  , _sr_direction :: Direction
  , _sr_snippet   :: Text
  }

formatMatches :: [SearchResult] -> Text
formatMatches = T.intercalate "\n\n" . map formatMatch

formatMatch :: SearchResult -> Text
formatMatch sr =
  let dir = case _sr_direction sr of
        Request  -> "→"
        Response -> "←"
  in "[" <> _sr_sessionId sr <> "] " <> dir <> " " <> _sr_snippet sr

extractSnippet :: Text -> Text -> Text
extractSnippet query payload =
  let queryLower = T.toLower query
      payloadLower = T.toLower payload
      (before, _) = T.breakOn queryLower payloadLower
      pos = T.length before
      start = max 0 (pos - 50)
      snippet = T.take 250 (T.drop start payload)
      prefix = if start > 0 then "..." else ""
      suffix = if T.length payload > start + 250 then "..." else ""
  in prefix <> snippet <> suffix

parseSearchInput :: Value -> Parser (Text, Int)
parseSearchInput = withObject "SessionSearchInput" $ \o ->
  (,) <$> o .: "query" <*> o .:? "limit" .!= 10
