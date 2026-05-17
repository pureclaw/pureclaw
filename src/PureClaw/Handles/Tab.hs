-- |
-- Module      : PureClaw.Handles.Tab
-- Description : Tabbed Chat type layer (WU1) — user-facing primitive: a tab.
--
-- A 'TabHandle' is the universal Handle-pattern carrier for one tab in
-- the Tabbed Chat surface. Tabs come in several 'TabKind's
-- ('KindAi' for an AI chat tab, 'KindHarness' for a managed harness,
-- and 'KindShell' \/ 'KindSsh' \/ 'KindTmux' for terminal-backend tabs).
-- The dispatcher routes user input to the focused tab and per-tab
-- output to the channel (focus-gated).
--
-- == Scope of WU1
--
-- This module currently lands the type layer only: 'TabHandle' record
-- shape, smart constructors, error ADTs (with the manually-written
-- redacted 'Show' instance for 'TabError' required by H14), and the
-- per-kind factory signatures. Factory bodies are stubbed with
-- @'error' \"not implemented\"@ — the real bodies land in WU6 ('Tab.Ai'),
-- WU7 ('Tab.Harness'), and WU8 ('Tab.Backend').
--
-- == Field-naming convention
--
-- The handle record uses the @_tabHandle_*@ field-name prefix (NOT the
-- terser @_th_*@ used in some older draft notes). This was decided
-- during WU0 planning to keep the prefix self-describing when the field
-- name is grepped in isolation.
--
-- See @docs\/tabbed-chat.md@ for the full design (sections
-- \"TabHandle abstraction (H-series)\" and \"Channel output\").
module PureClaw.Handles.Tab
  ( -- * Tab index
    TabIndex
  , mkTabIndex
  , unTabIndex
    -- * Tab kind
  , TabKind (..)
    -- * Tab status
  , TabStatus (..)
    -- * Tab handle
  , TabHandle (..)
  , TabName (..)
  , CloseMode (..)
    -- * Tab runner (cancel + wait pair, used by spawn machinery)
  , TabRunner (..)
    -- * Errors
  , TabError (..)
  , NameError (..)
  , PublicTabError (..)
  , toPublicTabError
    -- * Placeholder payload types
    -- These are placeholder ADTs that future WUs will refine \/ promote
    -- to their own modules. They are kept here so 'TabError' compiles
    -- without forward-referencing modules that do not yet exist.
  , SessionError (..)
  , PublicAuthError (..)
    -- * Factory signatures (stubbed in WU1; bodies filled in by WU6\/7\/8)
  , AiSpawnArgs (..)
  , HarnessSpawnArgs (..)
  , BackendSpawnArgs (..)
  , mkTabAi
  , mkTabHarness
  , mkTabBackend
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Handles.Backend qualified as Backend


-- ---------------------------------------------------------------------------
-- TabIndex
-- ---------------------------------------------------------------------------

-- | Validated tab index. The data constructor is intentionally NOT
-- exported; obtain values via 'mkTabIndex' (which bounds-checks against
-- the configured @_rc_maxTabs@ ceiling) or by pattern-matching on the
-- newtype via 'unTabIndex'.
--
-- The underlying 'Int' is non-negative on every value produced by
-- 'mkTabIndex' (@0 <= n@). Bounds-checking against @_rc_maxTabs@ is
-- performed at the parser layer (WU2) using the 'RoutingConfig' in
-- scope; the smart constructor here enforces the floor only.
newtype TabIndex = TabIndex { unTabIndex :: Int }
  deriving stock (Eq, Ord, Show)

-- | The only way to construct a 'TabIndex'. Returns 'Nothing' for
-- negative inputs.
mkTabIndex :: Int -> Maybe TabIndex
mkTabIndex n
  | n < 0     = Nothing
  | otherwise = Just (TabIndex n)


-- ---------------------------------------------------------------------------
-- TabKind
-- ---------------------------------------------------------------------------

-- | Kind of tab. Distinct constructors per backend kind so the parser
-- can dispatch to the right factory without an extra discriminator.
--
-- @KindShell@ \/ @KindSsh@ \/ @KindTmux@ are sub-variants of the
-- conceptual \"KindBackend\" in design narrative; as constructors they
-- are distinct so 'mkTabBackend' can pattern-match.
data TabKind
  = KindAi
  | KindHarness
  | KindShell
  | KindSsh
  | KindTmux
  deriving stock (Eq, Show, Bounded, Enum)


-- ---------------------------------------------------------------------------
-- TabName
-- ---------------------------------------------------------------------------

-- | A redaction-safe, length-capped friendly label for a tab.
--
-- Construction must go through @sanitizeTabName@ (lands in WU2,
-- @PureClaw.Routing.Parse@) — every code path that sets
-- '_tabHandle_name' on a 'TabHandle' routes through that function per
-- H11. The newtype here is the type-level carrier so the contract
-- survives refactoring; the validating constructor itself lives in the
-- parser module so it can share the @NameError@ vocabulary with the
-- @\/tab rename@ handler.
newtype TabName = TabName { unTabName :: Text }
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- TabStatus
-- ---------------------------------------------------------------------------

-- | Runtime status of a tab.
--
-- * 'Active' — a provider call or tool execution is in flight, OR a
--   backend recv is waiting for output. The dashboard does not
--   distinguish these sub-cases.
-- * 'Idle' — the tab is waiting for input; carries the timestamp of
--   the last observed input (for sort / display).
-- * 'Crashed' — the tab loop hit a synchronous exception and exited;
--   the wrapped 'PublicTabError' is the channel-safe summary. The
--   registry entry persists until @\/tab close N@ or
--   @\/tab resume \<session\>@.
data TabStatus
  = Active
  | Idle !UTCTime
  | Crashed !PublicTabError
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- CloseMode
-- ---------------------------------------------------------------------------

-- | Close semantics requested by the caller of '_tabHandle_close'.
--
-- * 'CloseGraceful' — kind-specific graceful close: for 'KindAi'
--   archives the session via @_sh_save@; for non-AI kinds runs the
--   underlying destructive close (e.g. @_bh_close@, @_hh_stop@).
-- * 'CloseForce' — for 'KindAi' skips the archive (transcript deleted
--   from disk); for non-AI kinds is a no-op distinct from
--   'CloseGraceful' because close is already destructive there.
data CloseMode
  = CloseGraceful
  | CloseForce
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- TabRunner
-- ---------------------------------------------------------------------------

-- | The cancel + wait pair returned by the @_env_fork@ test seam.
--
-- Cannot be an 'Control.Concurrent.Async.Async' directly because:
-- (a) the synchronous test variant runs the body inline and has no
-- live async to wrap; (b) the IORef-Bool cancel-observability primitive
-- used by tests needs a uniform shape across sync and async variants.
--
-- See the @TabRunner bootstrapping during spawn@ section of the design
-- doc and the WU0 scaffold in @Test.Fake.TabFactory@.
data TabRunner = TabRunner
  { _trun_cancel :: IO ()
    -- ^ Idempotent cancel. Safe to call multiple times; safe to call
    --   on a runner whose body has already exited.
  , _trun_wait   :: IO ()
    -- ^ Block until the tab loop's body exits. In the synchronous
    --   test variant returns immediately because the body has
    --   already run inline.
  }


-- ---------------------------------------------------------------------------
-- TabHandle
-- ---------------------------------------------------------------------------

-- | Universal Handle-pattern carrier for one tab.
--
-- Pure fields ('_tabHandle_index', '_tabHandle_name', '_tabHandle_kind')
-- are bound at construction time. IO-action fields are kind-specific:
-- 'KindAi' enqueues into a per-tab @TBQueue InputEvent@; non-AI kinds
-- write to a 'PureClaw.Handles.Backend.BackendHandle' or
-- 'PureClaw.Handles.Harness.HarnessHandle'.
--
-- '_tabHandle_close' is idempotent and never throws (parallel to the
-- @_bh_close@ contract on 'PureClaw.Handles.Backend.BackendHandle').
data TabHandle = TabHandle
  { _tabHandle_index         :: !TabIndex
    -- ^ Pure: tab's slot in the registry (H12-adjacent).
  , _tabHandle_name          :: !TabName
    -- ^ Pure: redacted friendly label (H11). Constructed via
    --   @sanitizeTabName@ (WU2) at the factory site.
  , _tabHandle_kind          :: !TabKind
    -- ^ Pure: H12. Read without IO.
  , _tabHandle_status        :: IO TabStatus
    -- ^ H5: returns 'Active' \/ 'Idle' \/ 'Crashed'.
  , _tabHandle_send          :: Text -> IO (Either TabError ())
    -- ^ H4: enqueue a 'UserText' input event. Bounded by
    --   @_rc_inputQueueBound@; overflow returns
    --   'Left' (e.g. 'TabConcurrencyLimit') so the dispatcher never
    --   blocks.
  , _tabHandle_enqueueSlash  :: Slash.SlashCommand -> IO (Either TabError ())
    -- ^ H13: enqueue a 'SlashCmd' input event. For 'KindAi' the tab
    --   loop runs @executeSlashCommand@ against its own per-tab
    --   context; for non-AI kinds the implementation returns
    --   @Left ('TabUnsupportedCommand' cmd)@ immediately without
    --   enqueueing.
  , _tabHandle_close         :: CloseMode -> IO ()
    -- ^ H6 \/ H7 \/ H8 \/ H9 \/ H10: idempotent, never throws,
    --   kind-specific semantics. The 'CloseMode' selects graceful
    --   vs forced archive behaviour for 'KindAi'.
  }


-- ---------------------------------------------------------------------------
-- NameError
-- ---------------------------------------------------------------------------

-- | Why a tab-name sanitization attempt failed.
--
-- A redacted ADT, never raw user input — appears as the payload of
-- 'TabInvalidName'. The actual sanitization function ('sanitizeTabName')
-- lands in WU2 alongside the parser; this enum is here so 'TabError'
-- can refer to it.
data NameError
  = NameTooLong
  | NameContainsControlBytes
  | NameContainsAnsi
  | NameRedactedToEmpty
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- Placeholder error payload types
-- ---------------------------------------------------------------------------

-- | Placeholder for the session-creation error vocabulary. The
-- definitive shape lives with the session machinery in WU6 (the AI tab
-- factory is what creates new sessions). For WU1 we expose a single
-- opaque constructor so 'TabSessionCreateFailed' has somewhere to
-- park its payload while the type layer compiles.
data SessionError = SessionError
  deriving stock (Eq, Show)

-- | Placeholder for the spawn-time authorization-failure vocabulary
-- (channel-safe). The definitive shape lands in WU8 alongside
-- 'mkTabBackend' (which performs the 'authorize' check per S1). For
-- WU1 we expose a single opaque constructor so 'TabSpawnAuthDenied'
-- has somewhere to park its payload while the type layer compiles.
data PublicAuthError = PublicAuthError
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- TabError
-- ---------------------------------------------------------------------------

-- | Construction-time and runtime errors on a tab.
--
-- Every constructor's payload is itself a redaction-safe ADT or a
-- bounded primitive — no constructor carries a free 'Data.Text.Text',
-- a raw 'Control.Exception.SomeException' message, or a raw filesystem
-- path. The hand-written 'Show' below (H14) elides every payload value
-- so accidental @show@ of a 'TabError' in a log line cannot leak
-- hostnames, paths, or stderr fragments.
--
-- The exhaustive constructor list is enforced by H3.
data TabError
  = TabIndexInUse !TabIndex
  | TabIndexOutOfRange !Int
  | TabLimitExceeded !Int
  | TabBackendConstructFailed !Backend.BackendError
  | TabSessionCreateFailed !SessionError
  | TabSpawnAuthDenied !PublicAuthError
  | TabNotFound !Int
  | TabConcurrencyLimit !Int
  | TabInvalidName !NameError
  | TabUnsupportedCommand !Slash.SlashCommand
  deriving stock (Eq)

-- | Hand-written 'Show' for 'TabError' per H14: constructor names only,
-- payload values elided. Adding a new constructor here requires adding
-- a new branch in this 'Show' instance (H3 enumerates the exhaustive
-- set), so accidentally regressing to @deriving Show@ would surface as
-- a build error from the @-Wincomplete-patterns@ flag.
instance Show TabError where
  show e = case e of
    TabIndexInUse{}             -> "TabIndexInUse"
    TabIndexOutOfRange{}        -> "TabIndexOutOfRange"
    TabLimitExceeded{}          -> "TabLimitExceeded"
    TabBackendConstructFailed{} -> "TabBackendConstructFailed"
    TabSessionCreateFailed{}    -> "TabSessionCreateFailed"
    TabSpawnAuthDenied{}        -> "TabSpawnAuthDenied"
    TabNotFound{}               -> "TabNotFound"
    TabConcurrencyLimit{}       -> "TabConcurrencyLimit"
    TabInvalidName{}            -> "TabInvalidName"
    TabUnsupportedCommand{}     -> "TabUnsupportedCommand"


-- ---------------------------------------------------------------------------
-- PublicTabError
-- ---------------------------------------------------------------------------

-- | Channel-safe projection of a 'TabError'.
--
-- The wrapped 'Data.Text.Text' is short, fixed-vocabulary, and
-- contains no hostnames, paths, or secrets. This is what reaches the
-- user via 'PureClaw.Handles.Channel.ChannelHandle' when a tab
-- operation fails.
newtype PublicTabError = PublicTabError { unPublicTabError :: Text }
  deriving stock (Eq, Show)

-- | Project a 'TabError' to its user-visible form.
--
-- The mapping is intentionally coarse: similar failure modes collapse
-- to the same short label so a future audit of channel-bound strings
-- has a small surface to grep.
toPublicTabError :: TabError -> PublicTabError
toPublicTabError e = PublicTabError $ case e of
  TabIndexInUse{}             -> "tab: index already in use"
  TabIndexOutOfRange{}        -> "tab: index out of range"
  TabLimitExceeded{}          -> "tab: maximum tab count reached"
  TabBackendConstructFailed{} -> "tab: backend construction failed"
  TabSessionCreateFailed{}    -> "tab: session creation failed"
  TabSpawnAuthDenied{}        -> "tab: spawn authorization denied"
  TabNotFound{}               -> "tab: not found"
  TabConcurrencyLimit{}       -> "tab: input queue full"
  TabInvalidName{}            -> "tab: invalid name"
  TabUnsupportedCommand{}     -> "tab: command not supported on this tab kind"


-- ---------------------------------------------------------------------------
-- Factory signatures
-- ---------------------------------------------------------------------------

-- | Construction arguments for an AI tab.
--
-- WU1 lands the signature only; the field set is intentionally minimal
-- here and will be extended by WU6 ('PureClaw.Tab.Ai') when the AI tab
-- loop body lands. The record exists so the H2 type-shape test can
-- pin down @mkTabAi :: ... -> IO (Either TabError TabHandle)@ without
-- forward-referencing WU6's full argument list.
data AiSpawnArgs = AiSpawnArgs
  { _ai_requestedName :: !Text
    -- ^ Caller-supplied friendly label before 'sanitizeTabName' (H11).
  }
  deriving stock (Eq, Show)

-- | Construction arguments for a harness tab. See 'AiSpawnArgs' note
-- on WU1 minimality; WU7 will extend.
data HarnessSpawnArgs = HarnessSpawnArgs
  { _harness_requestedName :: !Text
  }
  deriving stock (Eq, Show)

-- | Construction arguments for a backend (shell \/ ssh \/ tmux) tab.
-- WU8 will extend.
data BackendSpawnArgs = BackendSpawnArgs
  { _backend_requestedName :: !Text
  , _backend_args          :: ![Text]
  }
  deriving stock (Eq, Show)

-- | AI tab factory. WU6 fills in the body.
mkTabAi :: TabIndex -> AiSpawnArgs -> IO (Either TabError TabHandle)
mkTabAi _ _ = error "PureClaw.Handles.Tab.mkTabAi: not implemented \
                    \— filled in by WU6 (PureClaw.Tab.Ai)"

-- | Harness tab factory. WU7 fills in the body.
mkTabHarness :: TabIndex -> HarnessSpawnArgs -> IO (Either TabError TabHandle)
mkTabHarness _ _ = error "PureClaw.Handles.Tab.mkTabHarness: not implemented \
                         \— filled in by WU7 (PureClaw.Tab.Harness)"

-- | Backend tab factory. Dispatches at construction time to the
-- 'KindShell' \/ 'KindSsh' \/ 'KindTmux' sub-factory. WU8 fills in the
-- body.
mkTabBackend :: TabIndex -> TabKind -> BackendSpawnArgs
             -> IO (Either TabError TabHandle)
mkTabBackend _ _ _ = error "PureClaw.Handles.Tab.mkTabBackend: not implemented \
                           \— filled in by WU8 (PureClaw.Tab.Backend)"
