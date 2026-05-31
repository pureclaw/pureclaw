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
    -- * Session kind (re-exported from Kind)
  , SessionKind (..)
  , ProviderSpec (..)
  , HarnessSpec (..)
  , HarnessFlavour (..)
  , TerminalBackend (..)
  , TmuxConfig (..)
  , inferProviderId
  , fixedFlavourLookup
  , defaultTarget
    -- * Session metadata
  , SessionMeta (..)
    -- * Conversion helpers
  , sessionKindToText
  ) where

import Data.Aeson ((.=), (.:), (.:?), (.!=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), diffTimeToPicoseconds)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)

import PureClaw.Agent.AgentDef (AgentName, unAgentName)
import PureClaw.Core.Types (MessageSource, MessageTarget (..), ModelId (..), SessionId (..))
import PureClaw.Session.Kind

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
-- and appends the optional 'SessionPrefix' after it, separated by a
-- hyphen. The timestamp leads so that lexicographic sorting of session
-- IDs (and their on-disk directory names) is also chronological.
newSessionId :: Maybe SessionPrefix -> UTCTime -> SessionId
newSessionId mPrefix time =
  let hms     = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" time
      -- Extract milliseconds from the fractional second.
      picoDay = diffTimeToPicoseconds (utctDayTime time)
      millis  = (picoDay `div` 1000000000) `mod` 1000
      timeStr = T.pack hms <> "-" <> T.justifyRight 3 '0' (T.pack (show millis))
      full    = case mPrefix of
        Nothing -> timeStr
        Just p  -> timeStr <> "-" <> unSessionPrefix p
  in SessionId full

-- | Map a 'SessionKind' to its corresponding 'MessageTarget'. Pure helper
-- so the session loader and CLI can share the same default-routing logic
-- without duplicating the case match.
defaultTarget :: SessionKind -> MessageTarget
defaultTarget (SkProvider _)    = TargetProvider
defaultTarget (SkHarness spec)  = TargetHarness (flavourToText (_h_flavour spec))

-- | Render a 'HarnessFlavour' to its canonical text name (matching the
-- harness key used in the harness map).
flavourToText :: HarnessFlavour -> Text
flavourToText HClaudeCode = "claude-code"
flavourToText HCodex      = "codex"
flavourToText HOpenCode   = "opencode"
flavourToText HHermes     = "hermes"
flavourToText HPureClaw   = "pureclaw"
flavourToText (HCustom n) = n

-- | Render a 'SessionKind' to a human-readable text label.
-- Used by the frontend API and session info display.
sessionKindToText :: SessionKind -> Text
sessionKindToText (SkProvider _)   = "provider"
sessionKindToText (SkHarness spec) = "harness:" <> flavourToText (_h_flavour spec)

-- | Persistent metadata for a single session. Stored as @session.json@
-- inside the session's on-disk directory.
data SessionMeta = SessionMeta
  { _sm_id                :: SessionId
  , _sm_agent             :: Maybe AgentName
  , _sm_kind              :: SessionKind
  , _sm_model             :: Text
  , _sm_channel           :: Text
  , _sm_createdAt         :: UTCTime
  , _sm_lastActive        :: UTCTime
  , _sm_bootstrapConsumed :: Bool
  , _sm_archived          :: Bool
    -- ^ User-controllable flag that suppresses this session from
    -- prominent UI surfaces (e.g. the "Recent Sessions" sidebar).
    -- Pure display state — archiving NEVER removes the session
    -- directory or transcript from disk. Defaults to 'False'.
  , _sm_description       :: Maybe Text
    -- ^ Optional user-provided description / title for this session.
    -- Display surfaces prefer this when set; otherwise they fall back
    -- through '_sm_autoSummary', a transcript-derived snippet, the
    -- agent name, and finally the session id. 'Nothing' means "no
    -- user choice — use a fallback."
  , _sm_autoSummary       :: Maybe Text
    -- ^ Optional model-generated short summary of the session,
    -- cached here so it doesn't have to be recomputed on every
    -- recent-sessions poll. Populated lazily by a separate
    -- summarization path (not yet wired up). Defaults to 'Nothing'
    -- on new sessions and after disk loads of older session.json
    -- files.
  , _sm_source            :: Maybe MessageSource
    -- ^ Session origin: the 'MessageSource' of the FIRST inbound
    -- message of this session (set-once). 'Nothing' for legacy
    -- sessions written before this field existed, and for sessions
    -- that have not yet received an inbound message.
    --
    -- SECURITY: this is attacker-asserted provenance — the sender id
    -- is unauthenticated. It MUST NOT feed any access-control or
    -- trust decision. Routing/authz key on the dispatcher's
    -- allow-list, never on this value.
  } deriving stock (Show, Eq, Generic)

-- Hand-written JSON so we don't depend on a 'ToJSON' instance for
-- 'AgentName' (which 'PureClaw.Agent.AgentDef' deliberately does not
-- export). The agent is serialized as its bare 'unAgentName' string and
-- deserialized via the existing 'FromJSON AgentName' instance, which
-- routes through 'mkAgentName'.
instance Aeson.ToJSON SessionMeta where
  toJSON s = Aeson.object $
    [ "id"                 .= _sm_id s
    , "kind"               .= _sm_kind s
    , "model"              .= _sm_model s
    , "channel"            .= _sm_channel s
    , "created_at"         .= _sm_createdAt s
    , "last_active"        .= _sm_lastActive s
    , "bootstrap_consumed" .= _sm_bootstrapConsumed s
    , "archived"           .= _sm_archived s
    , "description"        .= _sm_description s
    , "auto_summary"       .= _sm_autoSummary s
    ] <> (case _sm_agent s of
      Just n  -> ["agent" .= unAgentName n]
      Nothing -> [])
      <> (case _sm_source s of
      Just src -> ["source" .= src]
      Nothing  -> [])

instance Aeson.FromJSON SessionMeta where
  parseJSON = Aeson.withObject "SessionMeta" $ \o -> do
    sid     <- o .:  "id"
    agent   <- o .:? "agent"
    model   <- o .:  "model"
    channel <- o .:  "channel"
    created <- o .:  "created_at"
    active  <- o .:  "last_active"
    boot    <- o .:  "bootstrap_consumed"
    arch    <- o .:? "archived"     .!= False
    desc    <- o .:? "description"
    summ    <- o .:? "auto_summary"
    src     <- o .:? "source"
    -- Parse session kind: accept both new and legacy format.
    kind    <- parseSessionKind o model agent
    pure SessionMeta
      { _sm_id                = sid
      , _sm_agent             = agent
      , _sm_kind              = kind
      , _sm_model             = model
      , _sm_channel           = channel
      , _sm_createdAt         = created
      , _sm_lastActive        = active
      , _sm_bootstrapConsumed = boot
      , _sm_archived          = arch
      , _sm_description       = desc
      , _sm_autoSummary       = summ
      , _sm_source            = src
      }

-- | Parse the session kind from the JSON object. Accepts three formats:
--
--   1. New format: @"kind"@ key present -> parse as 'SessionKind' directly.
--   2. Legacy format: @"runtime"@ key present ->
--      * @"provider"@ -> 'SkProvider' with inferred provider from model.
--      * @"harness:\<name\>"@ -> 'SkHarness' with 'fixedFlavourLookup'.
--   3. Neither present -> default to 'SkProvider' with inferred provider.
parseSessionKind
  :: Aeson.Object
  -> Text              -- ^ model text (for inferring provider)
  -> Maybe AgentName   -- ^ agent (for ProviderSpec)
  -> Parser SessionKind
parseSessionKind o model agent = do
  mKind    <- o .:? "kind"    :: Parser (Maybe Aeson.Value)
  mRuntime <- o .:? "runtime" :: Parser (Maybe Text)
  case mKind of
    Just kindVal -> Aeson.parseJSON kindVal
    Nothing -> case mRuntime of
      Just "provider" ->
        pure (SkProvider (ProviderSpec (inferProviderId model) (ModelId model) agent))
      Just rt | Just name <- T.stripPrefix "harness:" rt ->
        pure (SkHarness (HarnessSpec
          (fixedFlavourLookup name)
          (TbTmux (TmuxConfig name name Nothing))
          Nothing
          []))
      Just _ ->
        -- Unknown runtime text: default to provider
        pure (SkProvider (ProviderSpec (inferProviderId model) (ModelId model) agent))
      Nothing ->
        -- No "kind" and no "runtime": default to provider
        pure (SkProvider (ProviderSpec (inferProviderId model) (ModelId model) agent))
