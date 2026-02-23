module PureClaw.Core.Types
  ( -- * Identity types
    ProviderId (..)
  , ModelId (..)
  , Port (..)
  , UserId (..)
  , CommandName (..)
  , ToolCallId (..)
  , MemoryId (..)
    -- * Workspace
  , WorkspaceRoot (..)
    -- * Autonomy
  , AutonomyLevel (..)
    -- * Allow-lists
  , AllowList (..)
  , isAllowed
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Provider identifier (e.g. "anthropic", "openai")
newtype ProviderId = ProviderId { unProviderId :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Model identifier (e.g. "claude-3-opus")
newtype ModelId = ModelId { unModelId :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Network port number
newtype Port = Port { unPort :: Int }
  deriving stock (Show, Eq, Ord, Generic)

-- | User identifier for allow-list matching
newtype UserId = UserId { unUserId :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Command name for policy evaluation (e.g. "git", "ls")
newtype CommandName = CommandName { unCommandName :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Tool call identifier from provider responses
newtype ToolCallId = ToolCallId { unToolCallId :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Memory entry identifier
newtype MemoryId = MemoryId { unMemoryId :: Text }
  deriving stock (Show, Eq, Ord, Generic)

-- | Workspace root directory — anchors all SafePath resolution
newtype WorkspaceRoot = WorkspaceRoot { unWorkspaceRoot :: FilePath }
  deriving stock (Show, Eq, Ord, Generic)

-- | Agent autonomy level
data AutonomyLevel
  = Full        -- ^ Agent can act without confirmation
  | Supervised  -- ^ Agent must confirm before acting
  | Deny        -- ^ Agent cannot act at all
  deriving stock (Show, Eq, Ord, Generic)

-- | Typed allow-list. @AllowAll@ explicitly opts in to allowing everything.
-- @AllowList s@ restricts to the given set.
data AllowList a
  = AllowAll
  | AllowList (Set a)
  deriving stock (Show, Eq, Generic)

-- | Check whether a value is permitted by the allow-list.
isAllowed :: Ord a => AllowList a -> a -> Bool
isAllowed AllowAll      _ = True
isAllowed (AllowList s) x = Set.member x s
