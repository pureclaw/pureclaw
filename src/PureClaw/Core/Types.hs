module PureClaw.Core.Types
  ( -- * Identity types
    ProviderId (..)
  , ModelId (..)
  , Port (..)
  , UserId (..)
  , CommandName (..)
  , ToolCallId (..)
  , MemoryId (..)
    -- * Session ID
    -- The data constructor 'SessionId' is exported because session IDs are
    -- opaque strings with no validation invariant. 'parseSessionId' is just
    -- the constructor under a friendlier name.
  , SessionId (..)
  , parseSessionId
    -- * Workspace
  , WorkspaceRoot (..)
    -- * Autonomy
  , AutonomyLevel (..)
    -- * Allow-lists
  , AllowList (..)
  , isAllowed
  ) where

import Data.Aeson qualified as Aeson
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

-- | Opaque session identifier. The string format is produced by
-- 'PureClaw.Session.Types.newSessionId' but is not validated on parse —
-- 'SessionId' is treated as an opaque label so that on-disk session
-- directories created by older or newer code remain readable.
newtype SessionId = SessionId { unSessionId :: Text }
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (Aeson.ToJSON)

instance Aeson.FromJSON SessionId where
  parseJSON = Aeson.withText "SessionId" (pure . SessionId)

-- | Friendly alias for the 'SessionId' constructor. Provided for
-- symmetry with smart constructors elsewhere; performs no validation.
parseSessionId :: Text -> SessionId
parseSessionId = SessionId

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
