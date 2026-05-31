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
    -- * Message target
  , MessageTarget (..)
    -- * Message source / origin
  , ChannelKind (..)
  , MessageSource (..)
  , mkMessageSource
  , channelKindToText
  , channelKindFromText
  , maxSourceLen
    -- * Workspace
  , WorkspaceRoot (..)
    -- * Autonomy
  , AutonomyLevel (..)
    -- * Allow-lists
  , AllowList (..)
  , isAllowed
  , allowListOpen
  , allowListWarning
  ) where

import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Char qualified as Char
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
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

-- | Where incoming user messages are routed. Lives in 'Core.Types'
-- (rather than 'PureClaw.Agent.Env') so that 'PureClaw.Session.Types'
-- can refer to it without creating an import cycle through
-- 'PureClaw.Session.Handle'.
data MessageTarget
  = TargetProvider          -- ^ Send to the configured LLM provider + model
  | TargetHarness Text      -- ^ Send to a named running harness
  deriving stock (Show, Eq)

-- | The kind of channel a message originated from. Known channels get a
-- typed constructor; 'CkOther' is an open escape hatch for channels that
-- do not (yet) have a dedicated tag.
data ChannelKind
  = CkCli
  | CkWeb
  | CkSignal
  | CkTelegram
  | CkBackground
  | CkOther !Text
  deriving stock (Show, Eq, Generic)

-- | Render a 'ChannelKind' as a flat lowercase tag. 'CkOther' carries its
-- own name verbatim. Mirrors the @flavourToText@ precedent.
channelKindToText :: ChannelKind -> Text
channelKindToText CkCli        = "cli"
channelKindToText CkWeb        = "web"
channelKindToText CkSignal     = "signal"
channelKindToText CkTelegram   = "telegram"
channelKindToText CkBackground = "background"
channelKindToText (CkOther n)  = n

-- | Parse a flat tag back into a 'ChannelKind'. Known names map to their
-- typed constructor; everything else becomes 'CkOther'. Critically,
-- @"signal"@ maps to 'CkSignal' (never @CkOther "signal"@), so a
-- 'CkOther' naming a known channel cannot round-trip into existence.
channelKindFromText :: Text -> ChannelKind
channelKindFromText "cli"        = CkCli
channelKindFromText "web"        = CkWeb
channelKindFromText "signal"     = CkSignal
channelKindFromText "telegram"   = CkTelegram
channelKindFromText "background" = CkBackground
channelKindFromText t            = CkOther t

instance Aeson.ToJSON ChannelKind where
  toJSON = Aeson.String . channelKindToText

instance Aeson.FromJSON ChannelKind where
  parseJSON = Aeson.withText "ChannelKind" (pure . channelKindFromText)

-- | Maximum length (in characters) for any attacker-controlled string
-- stored inside a 'MessageSource' after normalization.
maxSourceLen :: Int
maxSourceLen = 512

-- | Where an inbound message came from. Structured and extensible: a typed
-- 'ChannelKind', the channel's user id (when one exists), and an open
-- field map for supplementary, channel-specific data (which may carry
-- nested JSON).
--
-- Construct via 'mkMessageSource', never the raw record — the smart
-- constructor normalizes attacker-controlled input.
--
-- Invariants (enforced by convention, not the type): '_ms_fields' must not
-- duplicate '_ms_userId' and must never contain credentials/secrets.
data MessageSource = MessageSource
  { _ms_channel :: !ChannelKind
  , _ms_userId  :: !(Maybe UserId)
  , _ms_fields  :: !(Map Text Aeson.Value)
  } deriving stock (Show, Eq, Generic)

-- | Strip ASCII control characters (covers newlines, tabs, carriage
-- returns and other control bytes) and bound the result to 'maxSourceLen'
-- characters.
normalizeText :: Text -> Text
normalizeText = T.take maxSourceLen . T.filter (not . Char.isControl)

-- | Recursively normalize every 'Aeson.String' leaf in a JSON value,
-- leaving the structure otherwise intact.
normalizeValue :: Aeson.Value -> Aeson.Value
normalizeValue (Aeson.String t) = Aeson.String (normalizeText t)
normalizeValue (Aeson.Array xs) = Aeson.Array (fmap normalizeValue xs)
normalizeValue (Aeson.Object o) = Aeson.Object (fmap normalizeValue o)
normalizeValue v                = v

-- | Smart constructor for 'MessageSource'. Normalizes attacker-controlled
-- input: strips control characters / newlines and bounds length on the
-- user id and on every string leaf inside the field map, and folds a
-- 'CkOther' naming a known channel (e.g. @CkOther "signal"@) down to its
-- typed constructor.
mkMessageSource :: ChannelKind -> Maybe UserId -> Map Text Aeson.Value -> MessageSource
mkMessageSource ch uid fields = MessageSource
  { _ms_channel = foldChannel ch
  , _ms_userId  = fmap (UserId . normalizeText . unUserId) uid
  , _ms_fields  = fmap normalizeValue fields
  }
  where
    foldChannel (CkOther n) = channelKindFromText n
    foldChannel c           = c

instance Aeson.ToJSON MessageSource where
  toJSON s = Aeson.object $
    ["channel" .= _ms_channel s]
      <> case _ms_userId s of
        Just u  -> ["user_id" .= unUserId u]
        Nothing -> []
      <> ["fields" .= _ms_fields s | not (Map.null (_ms_fields s))]

instance Aeson.FromJSON MessageSource where
  parseJSON = Aeson.withObject "MessageSource" $ \o -> do
    ch     <- o .:  "channel"
    uid    <- o .:? "user_id"
    fields <- o .:? "fields" .!= Map.empty
    pure MessageSource
      { _ms_channel = ch
      , _ms_userId  = fmap UserId uid
      , _ms_fields  = fields
      }

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

-- | True when the list permits every sender (no restriction configured).
allowListOpen :: AllowList a -> Bool
allowListOpen _ = False -- RED stub

-- | Banner lines plus a WARN log line describing an OPEN allow-list on the
--   named channel, or Nothing when senders are restricted. Pure.
allowListWarning :: Text -> AllowList a -> Maybe ([Text], Text)
allowListWarning _ _ = Nothing -- RED stub
