module PureClaw.Session.Types
  ( -- * Session prefix (smart constructor)
    -- The data constructor is intentionally NOT exported. The only way to
    -- obtain a 'SessionPrefix' is via 'mkSessionPrefix' (or its 'FromJSON'
    -- instance, which routes through the same validation).
    SessionPrefix
  , unSessionPrefix
  , mkSessionPrefix
  , SessionPrefixError (..)
    -- * Session ID generation
  , newSessionId
    -- * Runtime type
  , RuntimeType (..)
  , defaultTarget
    -- * Session metadata
  , SessionMeta (..)
  ) where

import Data.Aeson ((.=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), diffTimeToPicoseconds)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)

import PureClaw.Agent.AgentDef (AgentName, unAgentName)
import PureClaw.Core.Types (MessageTarget (..), SessionId (..))

-- | Validated session prefix. Used as the human-readable leading segment
-- of a 'PureClaw.Core.Types.SessionId'. Same character rules as
-- 'PureClaw.Agent.AgentDef.AgentName' plus a reserved-word denylist.
newtype SessionPrefix = SessionPrefix { unSessionPrefix :: Text }
  deriving stock (Show, Eq, Ord)

-- | Reasons a raw 'Text' cannot be promoted to a 'SessionPrefix'.
data SessionPrefixError
  = PrefixEmpty
  | PrefixTooLong
  | PrefixInvalidChars Text
  | PrefixLeadingDot
  | PrefixReserved Text
  deriving stock (Show, Eq)

-- | Maximum allowed length for a session prefix.
sessionPrefixMaxLength :: Int
sessionPrefixMaxLength = 64

-- | Valid character predicate: ASCII letters, digits, underscore, hyphen.
-- Mirrors 'PureClaw.Agent.AgentDef.isValidAgentNameChar'.
isValidPrefixChar :: Char -> Bool
isValidPrefixChar c =
  Char.isAsciiUpper c
    || Char.isAsciiLower c
    || Char.isDigit c
    || c == '_'
    || c == '-'

-- | Reserved tokens that look like prefixes but collide with CLI verbs.
-- Currently just @"new"@, which is the literal argument to
-- @\/session new@ and would create ambiguous resume targets if allowed
-- as a prefix.
reservedPrefixes :: [Text]
reservedPrefixes = ["new"]

-- | Smart constructor. Same validation as 'mkAgentName' (non-empty,
-- max 64 chars, no leading dot, only @[a-zA-Z0-9_-]@), plus rejection
-- of reserved tokens like @"new"@.
mkSessionPrefix :: Text -> Either SessionPrefixError SessionPrefix
mkSessionPrefix raw
  | T.null raw = Left PrefixEmpty
  | T.length raw > sessionPrefixMaxLength = Left PrefixTooLong
  | T.head raw == '.' = Left PrefixLeadingDot
  | not (T.all isValidPrefixChar raw) = Left (PrefixInvalidChars raw)
  | raw `elem` reservedPrefixes = Left (PrefixReserved raw)
  | otherwise = Right (SessionPrefix raw)

-- | Custom 'Aeson.FromJSON' routes through 'mkSessionPrefix' so corrupted
-- on-disk JSON cannot bypass the smart constructor.
instance Aeson.FromJSON SessionPrefix where
  parseJSON = Aeson.withText "SessionPrefix" $ \t ->
    case mkSessionPrefix t of
      Right p -> pure p
      Left e -> fail ("invalid SessionPrefix: " ++ show e)

-- | Pure session ID generator. Encodes a 'UTCTime' as
-- @YYYYMMDD-HHMMSS-mmm@ (milliseconds zero-padded to three digits)
-- and prefixes it with the optional 'SessionPrefix' separated by a
-- hyphen.
newSessionId :: Maybe SessionPrefix -> UTCTime -> SessionId
newSessionId mPrefix time =
  let hms     = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" time
      -- Extract milliseconds from the fractional second.
      picoDay = diffTimeToPicoseconds (utctDayTime time)
      millis  = (picoDay `div` 1000000000) `mod` 1000
      timeStr = T.pack hms <> "-" <> T.justifyRight 3 '0' (T.pack (show millis))
      full    = case mPrefix of
        Nothing -> timeStr
        Just p  -> unSessionPrefix p <> "-" <> timeStr
  in SessionId full

-- | Whether a session targets the LLM provider directly or a named harness
-- (e.g. an interactive @claude-code@ tmux session).
data RuntimeType
  = RTProvider
  | RTHarness Text
  deriving stock (Show, Eq)

-- | JSON encoding: @"provider"@ or @"harness:<name>"@. Custom rather than
-- generic so on-disk @session.json@ files stay human-readable and so we
-- don't tie ourselves to aeson's tagged-sum format.
instance Aeson.ToJSON RuntimeType where
  toJSON RTProvider       = Aeson.String "provider"
  toJSON (RTHarness name) = Aeson.String ("harness:" <> name)

instance Aeson.FromJSON RuntimeType where
  parseJSON = Aeson.withText "RuntimeType" $ \t ->
    case t of
      "provider" -> pure RTProvider
      _ | Just name <- T.stripPrefix "harness:" t -> pure (RTHarness name)
        | otherwise -> fail ("Unknown RuntimeType: " <> T.unpack t)

-- | Map a 'RuntimeType' to its corresponding 'MessageTarget'. Pure helper
-- so the session loader and CLI can share the same default-routing logic
-- without duplicating the case match.
defaultTarget :: RuntimeType -> MessageTarget
defaultTarget RTProvider       = TargetProvider
defaultTarget (RTHarness name) = TargetHarness name

-- | Persistent metadata for a single session. Stored as @session.json@
-- inside the session's on-disk directory.
data SessionMeta = SessionMeta
  { _sm_id                :: SessionId
  , _sm_agent             :: Maybe AgentName
  , _sm_runtime           :: RuntimeType
  , _sm_model             :: Text
  , _sm_channel           :: Text
  , _sm_createdAt         :: UTCTime
  , _sm_lastActive        :: UTCTime
  , _sm_bootstrapConsumed :: Bool
  } deriving stock (Show, Eq, Generic)

-- Hand-written JSON so we don't depend on a 'ToJSON' instance for
-- 'AgentName' (which 'PureClaw.Agent.AgentDef' deliberately does not
-- export). The agent is serialized as its bare 'unAgentName' string and
-- deserialized via the existing 'FromJSON AgentName' instance, which
-- routes through 'mkAgentName'.
instance Aeson.ToJSON SessionMeta where
  toJSON s = Aeson.object $
    [ "id"                 .= _sm_id s
    , "runtime"            .= _sm_runtime s
    , "model"              .= _sm_model s
    , "channel"            .= _sm_channel s
    , "created_at"         .= _sm_createdAt s
    , "last_active"        .= _sm_lastActive s
    , "bootstrap_consumed" .= _sm_bootstrapConsumed s
    ] <> case _sm_agent s of
      Just n  -> ["agent" .= unAgentName n]
      Nothing -> []

instance Aeson.FromJSON SessionMeta where
  parseJSON = Aeson.withObject "SessionMeta" $ \o -> SessionMeta
    <$> o .:  "id"
    <*> o .:? "agent"
    <*> o .:  "runtime"
    <*> o .:  "model"
    <*> o .:  "channel"
    <*> o .:  "created_at"
    <*> o .:  "last_active"
    <*> o .:  "bootstrap_consumed"
