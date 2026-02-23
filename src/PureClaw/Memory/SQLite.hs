module PureClaw.Memory.SQLite
  ( -- * Construction
    mkSQLiteMemoryHandle
  , withSQLiteMemory
  ) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
import Database.SQLite.Simple

import PureClaw.Core.Types
import PureClaw.Handles.Memory

-- | Create a SQLite-backed memory handle. Opens the database at the
-- given path and creates the schema if needed.
mkSQLiteMemoryHandle :: FilePath -> IO MemoryHandle
mkSQLiteMemoryHandle dbPath = do
  conn <- open dbPath
  initSchema conn
  counterRef <- newIORef (0 :: Int)
  pure MemoryHandle
    { _mh_search = searchMemories conn
    , _mh_save   = saveMemory conn counterRef
    , _mh_recall = recallMemory conn
    }

-- | Convenience: open a SQLite memory handle, run an action, then close.
withSQLiteMemory :: FilePath -> (MemoryHandle -> IO a) -> IO a
withSQLiteMemory dbPath action = do
  mh <- mkSQLiteMemoryHandle dbPath
  action mh

-- | Initialize the database schema.
initSchema :: Connection -> IO ()
initSchema conn = execute_ conn
  "CREATE TABLE IF NOT EXISTS memories (\
  \  id TEXT PRIMARY KEY,\
  \  content TEXT NOT NULL,\
  \  metadata TEXT NOT NULL DEFAULT '{}',\
  \  created_at TEXT NOT NULL\
  \)"

-- | Save a memory entry.
saveMemory :: Connection -> IORef Int -> MemorySource -> IO (Maybe MemoryId)
saveMemory conn counterRef source = do
  n <- atomicModifyIORef' counterRef (\i -> (i + 1, i + 1))
  now <- getCurrentTime
  let mid = MemoryId (T.pack ("mem-" <> show n))
      ts = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      metaText = renderMetadata (_ms_metadata source)
  execute conn
    "INSERT INTO memories (id, content, metadata, created_at) VALUES (?, ?, ?, ?)"
    (unMemoryId mid, _ms_content source, metaText, ts)
  pure (Just mid)

-- | Search memories using LIKE (case-insensitive substring match).
-- SQLite FTS5 would be better for production, but LIKE is sufficient
-- to get the interface working.
searchMemories :: Connection -> Text -> SearchConfig -> IO [SearchResult]
searchMemories conn queryText config = do
  rows <- query conn
    "SELECT id, content FROM memories WHERE content LIKE ? LIMIT ?"
    ("%" <> queryText <> "%" :: Text, _sc_maxResults config)
  pure [ SearchResult (MemoryId mid) content 1.0
       | (mid, content) <- rows :: [(Text, Text)]
       ]

-- | Recall a specific memory by ID.
recallMemory :: Connection -> MemoryId -> IO (Maybe MemoryEntry)
recallMemory conn mid = do
  rows <- query conn
    "SELECT content, metadata, created_at FROM memories WHERE id = ?"
    (Only (unMemoryId mid))
  case rows of
    [] -> pure Nothing
    ((content, metaText, tsText) : _) ->
      pure $ Just MemoryEntry
        { _me_memoryId  = mid
        , _me_content   = content
        , _me_metadata  = parseMetadata metaText
        , _me_createdAt = parseTimestamp tsText
        }

-- | Render metadata map as a simple key=value text.
renderMetadata :: Map.Map Text Text -> Text
renderMetadata m = T.intercalate ";" [ k <> "=" <> v | (k, v) <- Map.toList m ]

-- | Parse metadata from key=value text.
parseMetadata :: Text -> Map.Map Text Text
parseMetadata t
  | T.null t = Map.empty
  | otherwise = Map.fromList
      [ (k, v)
      | pair <- T.splitOn ";" t
      , let (k, rawV) = T.breakOn "=" pair
      , not (T.null rawV)
      , let v = T.drop 1 rawV
      ]

-- | Parse a timestamp, with a fallback.
parseTimestamp :: Text -> UTCTime
parseTimestamp t =
  case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t) of
    Just ts -> ts
    Nothing -> UTCTime (fromGregorian 2000 1 1) 0
