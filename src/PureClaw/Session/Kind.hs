module PureClaw.Session.Kind
  ( -- * Session kind
    -- | 'SessionKind', 'ProviderSpec', and 'HarnessSpec' have hand-written
    -- 'Aeson.ToJSON'/'Aeson.FromJSON' instances.
    SessionKind (..)
  , ProviderSpec (..)
  , HarnessSpec (..)
    -- * Harness flavour
    -- | 'HarnessFlavour' serializes as a plain string.
    -- 'Aeson.FromJSON' routes @custom:*@ through 'mkHCustom' (S12).
  , HarnessFlavour (..)
  , HCustomError (..)
  , mkHCustom
  , fixedFlavourLookup
    -- * Terminal backend
    -- | 'TerminalBackend' is tag-discriminated.
  , TerminalBackend (..)
  , TmuxConfig (..)
  , SshConfig (..)
    -- * Container
    -- | 'ContainerTarget' 'Aeson.FromJSON' routes through 'mkContainerTarget'
    -- (S1).
  , ContainerSpec (..)
  , ContainerEngine (..)
  , ContainerTarget
  , unContainerTarget
  , mkContainerTarget
  , ContainerTargetError (..)
    -- * Provider helpers
  , inferProviderId
  ) where

import Data.Aeson ((.=), (.:), (.:?), (.!=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.AgentDef (AgentName, unAgentName)
import PureClaw.Core.Types (ModelId (..), ProviderId (..))
import PureClaw.Harness.Registry (HarnessId)

-- ---------------------------------------------------------------------------
-- Session kind
-- ---------------------------------------------------------------------------

-- | Top-level discriminator: is this session backed by an LLM provider or by
-- an external harness process?
data SessionKind
  = SkProvider !ProviderSpec
  | SkHarness  !HarnessSpec
  deriving stock (Show, Eq)

-- | Configuration for an LLM-backed session.
data ProviderSpec = ProviderSpec
  { _ps_provider :: !ProviderId
  , _ps_model    :: !ModelId
  , _ps_agent    :: !(Maybe AgentName)
  } deriving stock (Show, Eq)

-- | Configuration for a harness-backed session (an external CLI tool managed
-- in a tmux session).
--
-- A harness ALWAYS runs in tmux — that is the only viable way PureClaw drives
-- an external CLI tool — so the spec carries its tmux coordinates directly
-- ('_h_tmux') rather than a general 'TerminalBackend'. 'TerminalBackend' (local
-- \/ ssh \/ container \/ tmux) is reserved for tool-call execution environments
-- (raw-shell tabs, provider tool backends), a separate concern.
data HarnessSpec = HarnessSpec
  { _h_flavour   :: !HarnessFlavour
  , _h_tmux      :: !TmuxConfig
  , _h_cwd       :: !(Maybe Text)
  , _h_args      :: ![Text]
  , _h_harnessId :: !(Maybe HarnessId)
    -- ^ The durable, UUID-backed harness identity (Harness Registry Phase 1).
    --
    -- ADDITIVE and OPTIONAL (design @docs\/harness-registry.md@ K4): existing
    -- @session.json@ files written before this field decode with
    -- @_h_harnessId == Nothing@ (tolerant @.:? "harnessId"@), and the key is
    -- emitted ONLY when 'Just' (emit-when-Just, like '_h_cwd'). The tmux
    -- window name in '_h_tmux' is /dual-written/ alongside it for one
    -- release so a back-out path and the legacy name-keyed routing fallback
    -- both keep working until the registry is the sole key.
  , _h_claudeSessionUuid :: !(Maybe Text)
    -- ^ The canonical @claude-code@ session UUID minted at spawn time and
    -- injected as @--session-id \<uuid\>@ into the spawned @claude@ argv
    -- (Harness JSONL Capture, WU6 / @docs\/harness-jsonl-capture.md@). It
    -- correlates this harness with its on-disk JSONL session log so a restart
    -- can re-derive the log path (WU2).
    --
    -- NOTE — this is NOT the same identifier as @Registry._he_sessionId@:
    -- @_he_sessionId@ is the PureClaw 'PureClaw.Session.Types.SessionId' (which
    -- session this harness belongs to). '_h_claudeSessionUuid' is the
    -- /claude-code/ tool's own session UUID, used purely for log-file path
    -- derivation. The two are deliberately disambiguated.
    --
    -- ADDITIVE and OPTIONAL: minted ONLY for spawned @claude-code@ harnesses.
    -- Adopted harnesses and non-@claude-code@ flavours carry 'Nothing'. Legacy
    -- @session.json@ files written before this field decode with 'Nothing'
    -- (tolerant @.:? "claudeSessionUuid"@); the key is emitted ONLY when 'Just'.
  , _h_canonicalCwd :: !(Maybe Text)
    -- ^ The canonicalized spawn working directory used to derive the
    -- @claude-code@ JSONL log path (WU2 cross-check\/fallback). This is the
    -- @canonicalizePath@ of the resolved spawn cwd at spawn time, persisted so
    -- a restart can re-derive the log directory without re-resolving symlinks.
    --
    -- ADDITIVE and OPTIONAL, mirroring '_h_claudeSessionUuid': set ONLY for
    -- spawned @claude-code@ harnesses; 'Nothing' for adopted\/other flavours
    -- and for legacy @session.json@ files (tolerant @.:? "canonicalCwd"@,
    -- emit-when-'Just').
  } deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Harness flavour
-- ---------------------------------------------------------------------------

-- | Known harness flavours. 'HCustom' is only constructible via 'mkHCustom'
-- to reject path separators.
data HarnessFlavour
  = HClaudeCode
  | HCodex
  | HOpenCode
  | HHermes
  | HPureClaw
  | HCustom !Text
  deriving stock (Show, Eq, Ord)

-- | Reasons a raw 'Text' cannot become an 'HCustom' flavour.
data HCustomError
  = HCustomEmpty
  | HCustomPathSeparator Text
  deriving stock (Show, Eq)

-- | Smart constructor for 'HCustom'. Accepts bare command names; rejects
-- empty strings and strings containing path separators (@\/@ or @\\@).
mkHCustom :: Text -> Either HCustomError HarnessFlavour
mkHCustom raw
  | T.null raw = Left HCustomEmpty
  | T.any (\c -> c == '/' || c == '\\') raw = Left (HCustomPathSeparator raw)
  | otherwise = Right (HCustom raw)

-- | Map a well-known harness name to its 'HarnessFlavour'. Unknown names
-- fall through to 'HCustom' via 'mkHCustom' (which is infallible for
-- non-empty, separator-free bare names).
fixedFlavourLookup :: Text -> HarnessFlavour
fixedFlavourLookup t = case t of
  "claude-code" -> HClaudeCode
  "codex"       -> HCodex
  "opencode"    -> HOpenCode
  "hermes"      -> HHermes
  "pureclaw"    -> HPureClaw
  other         -> case mkHCustom other of
    Right f -> f
    -- Should not happen for non-empty, separator-free names passed from
    -- config. Defensively fall back to HCustom with the raw text.
    Left _  -> HCustom other

-- ---------------------------------------------------------------------------
-- Terminal backend
-- ---------------------------------------------------------------------------

-- | How the harness process is connected to a terminal.
data TerminalBackend
  = TbLocal
  | TbTmux      !TmuxConfig
  | TbSsh       !SshConfig
  | TbContainer !ContainerSpec
  deriving stock (Show, Eq)

-- | Tmux session/window/pane coordinates.
data TmuxConfig = TmuxConfig
  { _tc_session :: !Text
  , _tc_window  :: !Text
  , _tc_pane    :: !(Maybe Text)
  } deriving stock (Show, Eq)

-- | SSH connection coordinates.
data SshConfig = SshConfig
  { _sc_user :: !Text
  , _sc_host :: !Text
  , _sc_port :: !(Maybe Int)
  } deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Container
-- ---------------------------------------------------------------------------

-- | Container runtime specification.
data ContainerSpec = ContainerSpec
  { _cs_engine :: !ContainerEngine
  , _cs_target :: !ContainerTarget
  } deriving stock (Show, Eq)

-- | Supported container engines (closed set).
data ContainerEngine = Docker | Podman | Kubectl
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | A validated container target name. Only constructible via
-- 'mkContainerTarget'.
newtype ContainerTarget = ContainerTarget { unContainerTarget :: Text }
  deriving stock (Show, Eq, Ord)

-- | Reasons a raw 'Text' cannot become a 'ContainerTarget'.
data ContainerTargetError
  = TargetEmpty
  | TargetInvalidChars Text
  deriving stock (Show, Eq)

-- | Accepts @[a-zA-Z0-9_\\-.\\/:]+@ (supports kubectl @pod\/name:container@
-- format). Rejects empty strings and strings containing shell
-- metacharacters: @; & | \` $ ( ) { } < > ! \\ \" \' @ space/tab/newline.
mkContainerTarget :: Text -> Either ContainerTargetError ContainerTarget
mkContainerTarget raw
  | T.null raw = Left TargetEmpty
  | T.all isValidTargetChar raw = Right (ContainerTarget raw)
  | otherwise = Left (TargetInvalidChars raw)

-- | Character predicate for container target names. Allows alphanumerics,
-- @_@, @-@, @.@, @/@, @:@ only.
isValidTargetChar :: Char -> Bool
isValidTargetChar c =
  Char.isAsciiUpper c
    || Char.isAsciiLower c
    || Char.isDigit c
    || c == '_'
    || c == '-'
    || c == '.'
    || c == '/'
    || c == ':'

-- ---------------------------------------------------------------------------
-- Aeson instances
-- ---------------------------------------------------------------------------

-- ContainerEngine — lowercase string: "docker", "podman", "kubectl"

instance Aeson.ToJSON ContainerEngine where
  toJSON Docker  = Aeson.String "docker"
  toJSON Podman  = Aeson.String "podman"
  toJSON Kubectl = Aeson.String "kubectl"

instance Aeson.FromJSON ContainerEngine where
  parseJSON = Aeson.withText "ContainerEngine" $ \case
    "docker"  -> pure Docker
    "podman"  -> pure Podman
    "kubectl" -> pure Kubectl
    other     -> fail ("unknown ContainerEngine: " ++ show other)

-- ContainerTarget — plain string; FromJSON routes through mkContainerTarget (S1)

instance Aeson.ToJSON ContainerTarget where
  toJSON = Aeson.String . unContainerTarget

instance Aeson.FromJSON ContainerTarget where
  parseJSON = Aeson.withText "ContainerTarget" $ \t ->
    case mkContainerTarget t of
      Right ct -> pure ct
      Left TargetEmpty -> fail "ContainerTarget: empty string"
      Left (TargetInvalidChars raw) ->
        fail ("ContainerTarget: invalid characters in " ++ show raw)

-- ContainerSpec — flat object: { "engine": "docker", "target": "myapp" }

instance Aeson.ToJSON ContainerSpec where
  toJSON cs = Aeson.object
    [ "engine" .= _cs_engine cs
    , "target" .= _cs_target cs
    ]

instance Aeson.FromJSON ContainerSpec where
  parseJSON = Aeson.withObject "ContainerSpec" $ \o ->
    ContainerSpec <$> o .: "engine" <*> o .: "target"

-- TmuxConfig — flat object; pane optional (omitted when Nothing)

instance Aeson.ToJSON TmuxConfig where
  toJSON tc = Aeson.object $
    [ "session" .= _tc_session tc
    , "window"  .= _tc_window tc
    ] ++ maybe [] (\p -> ["pane" .= p]) (_tc_pane tc)

instance Aeson.FromJSON TmuxConfig where
  parseJSON = Aeson.withObject "TmuxConfig" $ \o ->
    -- 'session' is OPTIONAL on decode (default ""): the New-Harness composer
    -- omits it when the user leaves the tmux-session field blank, and an empty
    -- session is resolved to the default ("pureclaw") at spawn time
    -- ('resolveHarnessSession'). Encoded values always carry it, so round-trips
    -- are unaffected.
    TmuxConfig <$> (o .:? "session" .!= "") <*> o .: "window" <*> o .:? "pane"

-- SshConfig — flat object; port optional (omitted when Nothing)

instance Aeson.ToJSON SshConfig where
  toJSON sc = Aeson.object $
    [ "user" .= _sc_user sc
    , "host" .= _sc_host sc
    ] ++ maybe [] (\p -> ["port" .= p]) (_sc_port sc)

instance Aeson.FromJSON SshConfig where
  parseJSON = Aeson.withObject "SshConfig" $ \o ->
    SshConfig <$> o .: "user" <*> o .: "host" <*> o .:? "port"

-- TerminalBackend — tag-discriminated

instance Aeson.ToJSON TerminalBackend where
  toJSON TbLocal = Aeson.object ["tag" .= ("local" :: Text)]
  toJSON (TbTmux tc) = Aeson.object $
    [ "tag"     .= ("tmux" :: Text)
    , "session" .= _tc_session tc
    , "window"  .= _tc_window tc
    ] ++ maybe [] (\p -> ["pane" .= p]) (_tc_pane tc)
  toJSON (TbSsh sc) = Aeson.object $
    [ "tag"  .= ("ssh" :: Text)
    , "user" .= _sc_user sc
    , "host" .= _sc_host sc
    ] ++ maybe [] (\p -> ["port" .= p]) (_sc_port sc)
  toJSON (TbContainer cs) = Aeson.object
    [ "tag"    .= ("container" :: Text)
    , "engine" .= _cs_engine cs
    , "target" .= _cs_target cs
    ]

instance Aeson.FromJSON TerminalBackend where
  parseJSON = Aeson.withObject "TerminalBackend" $ \o -> do
    tag <- o .: "tag" :: Parser Text
    case tag of
      "local"     -> pure TbLocal
      "tmux"      -> TbTmux <$>
        -- 'session' optional (default "") — see the 'TmuxConfig' FromJSON note.
        (TmuxConfig <$> (o .:? "session" .!= "") <*> o .: "window" <*> o .:? "pane")
      "ssh"       -> TbSsh <$>
        (SshConfig <$> o .: "user" <*> o .: "host" <*> o .:? "port")
      "container" -> TbContainer <$>
        (ContainerSpec <$> o .: "engine" <*> o .: "target")
      other -> fail ("unknown TerminalBackend tag: " ++ show other)

-- HarnessFlavour — string; custom: prefix for HCustom
-- FromJSON routes custom:* through mkHCustom to reject path separators (S12)

instance Aeson.ToJSON HarnessFlavour where
  toJSON HClaudeCode = Aeson.String "claude-code"
  toJSON HCodex      = Aeson.String "codex"
  toJSON HOpenCode   = Aeson.String "opencode"
  toJSON HHermes     = Aeson.String "hermes"
  toJSON HPureClaw   = Aeson.String "pureclaw"
  toJSON (HCustom n) = Aeson.String ("custom:" <> n)

instance Aeson.FromJSON HarnessFlavour where
  parseJSON = Aeson.withText "HarnessFlavour" $ \case
    "claude-code" -> pure HClaudeCode
    "codex"       -> pure HCodex
    "opencode"    -> pure HOpenCode
    "hermes"      -> pure HHermes
    "pureclaw"    -> pure HPureClaw
    other
      | Just rest <- T.stripPrefix "custom:" other ->
          case mkHCustom rest of
            Right hf -> pure hf
            Left HCustomEmpty -> fail "HarnessFlavour: custom name is empty"
            Left (HCustomPathSeparator raw) ->
              fail ("HarnessFlavour: path separator in custom name: " ++ show raw)
      | otherwise -> fail ("unknown HarnessFlavour: " ++ show other)

-- ProviderSpec — flat object; agent omitted when Nothing

instance Aeson.ToJSON ProviderSpec where
  toJSON ps = Aeson.object $
    [ "provider" .= unProviderId (_ps_provider ps)
    , "model"    .= unModelId (_ps_model ps)
    ] ++ maybe [] (\a -> ["agent" .= unAgentName a]) (_ps_agent ps)

instance Aeson.FromJSON ProviderSpec where
  parseJSON = Aeson.withObject "ProviderSpec" $ \o ->
    ProviderSpec . ProviderId <$> o .: "provider"
      <*> (ModelId <$> o .: "model")
      <*> o .:? "agent"

-- HarnessSpec — flat object; cwd optional (omitted when Nothing),
-- args defaults to [], harnessId optional (emitted ONLY when Just; absent on
-- decode -> Nothing — the back-compat guarantee for legacy session.json, K4).

instance Aeson.ToJSON HarnessSpec where
  toJSON hs = Aeson.object $
    [ "flavour" .= _h_flavour hs
    , "tmux"    .= _h_tmux hs
    ] ++ maybe [] (\c -> ["cwd" .= c]) (_h_cwd hs)
      ++ ["args" .= _h_args hs | not (null (_h_args hs))]
      ++ maybe [] (\hid -> ["harnessId" .= hid]) (_h_harnessId hs)
      ++ maybe [] (\u -> ["claudeSessionUuid" .= u]) (_h_claudeSessionUuid hs)
      ++ maybe [] (\c -> ["canonicalCwd" .= c]) (_h_canonicalCwd hs)

instance Aeson.FromJSON HarnessSpec where
  parseJSON = Aeson.withObject "HarnessSpec" $ \o ->
    HarnessSpec
      <$> o .: "flavour"
      <*> o .: "tmux"
      <*> o .:? "cwd"
      <*> o .:? "args" .!= []
      <*> o .:? "harnessId"
      <*> o .:? "claudeSessionUuid"
      <*> o .:? "canonicalCwd"

-- SessionKind — tag-discriminated: "provider" or "harness"

instance Aeson.ToJSON SessionKind where
  toJSON (SkProvider ps) = case Aeson.toJSON ps of
    Aeson.Object o -> Aeson.Object (KM.insert (AesonKey.fromText "tag") (Aeson.String "provider") o)
    other -> other  -- should not happen
  toJSON (SkHarness hs) = case Aeson.toJSON hs of
    Aeson.Object o -> Aeson.Object (KM.insert (AesonKey.fromText "tag") (Aeson.String "harness") o)
    other -> other  -- should not happen

instance Aeson.FromJSON SessionKind where
  parseJSON = Aeson.withObject "SessionKind" $ \o -> do
    tag <- o .: "tag" :: Parser Text
    case tag of
      "provider" -> SkProvider <$> Aeson.parseJSON (Aeson.Object o)
      "harness"  -> SkHarness <$> Aeson.parseJSON (Aeson.Object o)
      other -> fail ("unknown SessionKind tag: " ++ show other)

-- ---------------------------------------------------------------------------
-- Provider helpers
-- ---------------------------------------------------------------------------

-- | Infer a 'ProviderId' from a model name prefix.
--
-- * @claude-*@, @opus-*@, @sonnet-*@, @haiku-*@ -> @\"anthropic\"@
-- * @gpt-*@, @o1-*@, @o3-*@, @o4-*@ -> @\"openai\"@
-- * @gemini-*@ -> @\"google\"@
-- * anything else -> @\"anthropic\"@ (default)
inferProviderId :: Text -> ProviderId
inferProviderId model
  | matchesAny ["claude-", "opus-", "sonnet-", "haiku-"] = ProviderId "anthropic"
  | matchesAny ["gpt-", "o1-", "o3-", "o4-"]            = ProviderId "openai"
  | T.isPrefixOf "gemini-" model                         = ProviderId "google"
  | otherwise                                            = ProviderId "anthropic"
  where
    matchesAny :: [Text] -> Bool
    matchesAny = any (`T.isPrefixOf` model)
