module PureClaw.Memory.Markdown
  ( -- * Construction
    mkMarkdownMemoryHandle
  ) where

import Data.IORef
import Data.List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time
import System.Directory
import System.FilePath

import PureClaw.Core.Types
import PureClaw.Handles.Memory

-- | Create a file-based markdown memory handle. Each memory entry is
-- stored as a markdown file in the given directory. Search is a simple
-- case-insensitive substring match (no embeddings).
mkMarkdownMemoryHandle :: FilePath -> IO MemoryHandle
mkMarkdownMemoryHandle dir = do
  createDirectoryIfMissing True dir
  counterRef <- newIORef (0 :: Int)
  pure MemoryHandle
    { _mh_search = searchMemories dir
    , _mh_save   = saveMemory dir counterRef
    , _mh_recall = recallMemory dir
    }

-- | Save a memory entry as a markdown file.
saveMemory :: FilePath -> IORef Int -> MemorySource -> IO (Maybe MemoryId)
saveMemory dir counterRef source = do
  n <- atomicModifyIORef' counterRef (\i -> (i + 1, i + 1))
  now <- getCurrentTime
  let mid = MemoryId (T.pack (show n))
      filename = T.unpack (unMemoryId mid) <> ".md"
      path = dir </> filename
      content = renderEntry mid now source
  TIO.writeFile path content
  pure (Just mid)

-- | Search memories by case-insensitive substring match.
searchMemories :: FilePath -> Text -> SearchConfig -> IO [SearchResult]
searchMemories dir query config = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      files <- listDirectory dir
      let mdFiles = filter (".md" `isSuffixOf`) files
      results <- mapM (matchFile dir queryLower) mdFiles
      pure $ take (_sc_maxResults config)
           $ sortOn (negate . _sr_score)
           $ concatMap (filter (\r -> _sr_score r >= _sc_minScore config)) results
  where
    queryLower = T.toLower query

-- | Check if a file matches the query.
matchFile :: FilePath -> Text -> FilePath -> IO [SearchResult]
matchFile dir queryLower filename = do
  content <- TIO.readFile (dir </> filename)
  let bodyText = extractBody content
      mid = MemoryId (T.pack (takeBaseName filename))
  if queryLower `T.isInfixOf` T.toLower bodyText
    then pure [SearchResult mid bodyText 1.0]
    else pure []

-- | Recall a specific memory by ID.
recallMemory :: FilePath -> MemoryId -> IO (Maybe MemoryEntry)
recallMemory dir mid = do
  let path = dir </> T.unpack (unMemoryId mid) <> ".md"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      pure (Just (parseEntry mid content))

-- | Render a memory entry as markdown.
renderEntry :: MemoryId -> UTCTime -> MemorySource -> Text
renderEntry mid now source = T.unlines $
  [ "---"
  , "id: " <> unMemoryId mid
  , "created: " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  ]
  ++ renderMetadata (_ms_metadata source)
  ++ [ "---"
     , ""
     , _ms_content source
     ]

renderMetadata :: Map Text Text -> [Text]
renderMetadata m = [ k <> ": " <> v | (k, v) <- Map.toList m ]

-- | Extract the body (after frontmatter) from a markdown file.
extractBody :: Text -> Text
extractBody content =
  case T.stripPrefix "---\n" content of
    Nothing -> content
    Just rest ->
      case T.breakOn "---\n" rest of
        (_, after) -> T.strip (T.drop 4 after)

-- | Parse a markdown file into a MemoryEntry.
parseEntry :: MemoryId -> Text -> MemoryEntry
parseEntry mid content =
  let body = extractBody content
      metadata = parseFrontmatter content
      created = case Map.lookup "created" metadata of
        Just ts -> case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack ts) of
          Just t  -> t
          Nothing -> UTCTime (fromGregorian 2000 1 1) 0
        Nothing -> UTCTime (fromGregorian 2000 1 1) 0
  in MemoryEntry
    { _me_memoryId  = mid
    , _me_content   = body
    , _me_metadata  = Map.delete "id" (Map.delete "created" metadata)
    , _me_createdAt = created
    }

-- | Parse frontmatter key-value pairs from markdown.
parseFrontmatter :: Text -> Map Text Text
parseFrontmatter content =
  case T.stripPrefix "---\n" content of
    Nothing -> Map.empty
    Just rest ->
      case T.breakOn "---\n" rest of
        (fm, _) ->
          Map.fromList
            [ (T.strip k, T.strip v)
            | line <- T.lines fm
            , let (k, rawV) = T.breakOn ":" line
            , not (T.null rawV)
            , let v = T.drop 1 rawV
            ]

