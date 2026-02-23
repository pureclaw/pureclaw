module PureClaw.Handles.Memory
  ( -- * Memory types
    SearchConfig (..)
  , SearchResult (..)
  , MemorySource (..)
  , MemoryEntry (..)
  , defaultSearchConfig
    -- * Handle type
  , MemoryHandle (..)
    -- * Implementations
  , mkNoOpMemoryHandle
  ) where

import Data.Map (Map)
import Data.Text (Text)
import Data.Time

import PureClaw.Core.Types

-- | Configuration for memory search operations.
data SearchConfig = SearchConfig
  { _sc_maxResults :: Int
  , _sc_minScore   :: Double
  }
  deriving stock (Show, Eq)

-- | Sensible defaults for memory search.
defaultSearchConfig :: SearchConfig
defaultSearchConfig = SearchConfig
  { _sc_maxResults = 10
  , _sc_minScore   = 0.0
  }

-- | A single result from a memory search.
data SearchResult = SearchResult
  { _sr_memoryId :: MemoryId
  , _sr_content  :: Text
  , _sr_score    :: Double
  }
  deriving stock (Show, Eq)

-- | Source material to save into memory.
data MemorySource = MemorySource
  { _ms_content  :: Text
  , _ms_metadata :: Map Text Text
  }
  deriving stock (Show, Eq)

-- | A recalled memory entry with its metadata and creation time.
data MemoryEntry = MemoryEntry
  { _me_memoryId  :: MemoryId
  , _me_content   :: Text
  , _me_metadata  :: Map Text Text
  , _me_createdAt :: UTCTime
  }
  deriving stock (Show, Eq)

-- | Memory capability interface. Concrete implementations (SQLite,
-- Markdown, None) live in @PureClaw.Memory.*@ modules.
data MemoryHandle = MemoryHandle
  { _mh_search :: Text -> SearchConfig -> IO [SearchResult]
  , _mh_save   :: MemorySource -> IO (Maybe MemoryId)
  , _mh_recall :: MemoryId -> IO (Maybe MemoryEntry)
  }

-- | No-op memory handle. Search returns empty, save returns Nothing,
-- recall returns Nothing.
mkNoOpMemoryHandle :: MemoryHandle
mkNoOpMemoryHandle = MemoryHandle
  { _mh_search = \_ _ -> pure []
  , _mh_save   = \_ -> pure Nothing
  , _mh_recall = \_ -> pure Nothing
  }
