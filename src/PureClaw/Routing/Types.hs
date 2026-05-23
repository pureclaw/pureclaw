-- |
-- Module      : PureClaw.Routing.Types
-- Description : Routing-layer types for Tabbed Chat (WU1).
--
-- This module defines the shared ADTs that the routing parser
-- ('PureClaw.Routing.Parse', WU2), the dispatcher
-- ('PureClaw.Routing.Dispatcher', WU5), the channel-out writer
-- ('PureClaw.Routing.ChannelOut', WU4), and the tab factories
-- ('PureClaw.Tab.*', WU6\/7\/8) all depend on.
--
-- == Scope of WU1
--
-- Type declarations only. No parser, no dispatcher, no writer thread —
-- those land in WU2 \/ WU4 \/ WU5. Tests that depend on these types
-- being present stay 'pending' until their respective implementations
-- land.
--
-- See @docs\/tabbed-chat.md@ for the full design (sections
-- \"Routing Grammar (v1)\", \"AgentEnv additions\", \"RoutingConfig\",
-- and \"Channel emission via ChannelOut writer\").
module PureClaw.Routing.Types
  ( -- * Routing configuration
    RoutingConfig (..)
  , AiDefaults (..)
  , ShellDefaults (..)
    -- * Spawn errors (depth limiting)
  , SpawnError (..)
  , checkPureClawDepth
    -- * Routing errors
  , RoutingError (..)
  , ParseError (..)
    -- * Parsed input
  , ParsedInput (..)
    -- * Input events (tab-loop input queue)
  , InputEvent (..)
    -- * Channel output
  , OutputSource (..)
  , StreamId
  , mkStreamId
  , unStreamId
  , ChannelEvent (..)
  ) where

import Data.Text (Text)
import Data.Word (Word64)

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types qualified as Core
import PureClaw.Handles.Tab qualified as Tab


-- ---------------------------------------------------------------------------
-- RoutingConfig
-- ---------------------------------------------------------------------------

-- | Defaults applied when auto-spawning an AI tab.
--
-- WU1 lands the type shape; WU3 loads values from
-- @~\/.pureclaw\/config.toml [routing]@ via 'PureClaw.Routing.Config'.
data AiDefaults = AiDefaults
  { _aid_providerId :: !Core.ProviderId
  , _aid_modelId    :: !Core.ModelId
  }
  deriving stock (Eq, Show)

-- | Defaults applied when auto-spawning a shell tab.
--
-- WU1 lands the type shape; the field set is intentionally minimal
-- here and may be extended by WU8 ('PureClaw.Tab.Backend').
data ShellDefaults = ShellDefaults
  { _sd_command :: !Text
    -- ^ Default shell binary (e.g. @\"bash\"@).
  }
  deriving stock (Eq, Show)

-- | Routing-layer configuration, loaded once at process start.
--
-- All caps are enforced by various WUs: '_rc_maxTabs' by the parser
-- (WU2) and the spawn machinery (WU5\/WU9); '_rc_inputQueueBound' by
-- the AI tab factory (WU6); '_rc_channelOutQBound' by AgentEnv
-- construction (WU3); '_rc_spawnRateLimit' \/ '_rc_maxConcurrentActive'
-- \/ '_rc_maxNameLen' by their respective S-series enforcement points.
--
-- Runtime mutation via @\/config@ is v1.5+.
data RoutingConfig = RoutingConfig
  { _rc_defaultKind         :: !Tab.TabKind
    -- ^ Pre-shipped as @'Tab.TkSession' ('SkProvider' ...)@.
  , _rc_defaultAi           :: !AiDefaults
  , _rc_defaultShell        :: !ShellDefaults
  , _rc_switchRecap         :: !Int
    -- ^ Default 3 recent messages emitted on @\/N@ switch.
  , _rc_maxTabs             :: !Int
    -- ^ Default 36, matching the single-char @[0-9a-z]@ index
    --   alphabet of the @\/N@ routing grammar (10 digits + 26
    --   lowercase letters). Parser bounds-checks against this;
    --   dispatcher refuses to spawn beyond this cap with
    --   'Tab.TabLimitExceeded'. Configuring a value above 36 is
    --   permitted but only the first 36 slots are addressable
    --   through the @\/N@ shortcut; the higher slots remain
    --   reachable through @\/tab focus N@ and the dashboard.
  , _rc_inputQueueBound     :: !Int
    -- ^ Default 64. Per-tab @TBQueue InputEvent@ capacity.
  , _rc_channelOutQBound    :: !Int
    -- ^ Default 1024. Process-wide @TBQueue (OutputSource, ChannelEvent)@
    --   capacity.
  , _rc_spawnRateLimit      :: !Int
    -- ^ Default 10 spawns per minute per chat user.
  , _rc_maxConcurrentActive :: !Int
    -- ^ Default 4. S9 cap on tabs in 'Tab.Active' status simultaneously.
  , _rc_maxNameLen          :: !Int
    -- ^ Default 32. S10 length cap on tab names.
  , _rc_sshIdentityKey      :: !Text
    -- ^ Default @"default-ssh-key"@. Vault slot from which the ssh
    --   identity is loaded (no inline identities permitted per S4).
  , _rc_maxPureClawDepth   :: !Int
    -- ^ Maximum recursion depth for HPureClaw harness sessions.
    --   Default 2. Spawning is refused when
    --   @'_rc_pureClawDepth' >= '_rc_maxPureClawDepth'@.
  , _rc_pureClawDepth      :: !Int
    -- ^ Current recursion depth. 0 at top level. Incremented via
    --   the @--depth@ CLI flag when PureClaw spawns a child process.
  }
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- Spawn errors (depth limiting)
-- ---------------------------------------------------------------------------

-- | Errors that prevent spawning a new HPureClaw harness session.
data SpawnError
  = MaxPureClawDepthExceeded !Int !Int
    -- ^ @MaxPureClawDepthExceeded current max@ — the current recursion
    --   depth equals or exceeds the configured maximum.
  deriving stock (Show, Eq)

-- | Pure guard that checks whether the current recursion depth allows
-- spawning another HPureClaw session. Returns @'Left'
-- 'MaxPureClawDepthExceeded'@ when @'_rc_pureClawDepth' >=
-- '_rc_maxPureClawDepth'@.
checkPureClawDepth :: RoutingConfig -> Either SpawnError ()
checkPureClawDepth cfg
  | _rc_pureClawDepth cfg >= _rc_maxPureClawDepth cfg =
      Left (MaxPureClawDepthExceeded (_rc_pureClawDepth cfg) (_rc_maxPureClawDepth cfg))
  | otherwise = Right ()


-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Parser-level errors produced by @parseInput@ (WU2).
--
-- Constructors carry only bounded primitives — no free 'Text', no raw
-- input — so the redacted-error contract is preserved when these
-- bubble up into 'RoutingError'.
--
-- The legacy 'ParseErrorLeadingZero' code was removed when the
-- routing grammar switched from multi-digit indices to single-char
-- @[0-9a-z]@ indices — multi-char shapes (@\/01@, @\/12@, @\/1a@)
-- now surface as 'ParseErrorMalformed'.
data ParseError
  = ParseErrorIndexOutOfRange !Int
    -- ^ Parsed index @>= _rc_maxTabs@.
  | ParseErrorInvalidSessionId
    -- ^ @\/tab resume \<id\>@ where @\<id\>@ contains @\/@, @\\@,
    --   @..@, NUL, or any character outside @[a-zA-Z0-9_-]@.
  | ParseErrorEmptyInput
    -- ^ Empty or whitespace-only input.
  | ParseErrorMalformed
    -- ^ Catch-all for shapes that match no production in the grammar.
  deriving stock (Eq, Show)

-- | Routing-layer errors. Wraps 'ParseError' for parser failures and
-- carries higher-level dispatcher\/registry failures.
data RoutingError
  = RoutingParseError !ParseError
  | RoutingTabError !Tab.TabError
    -- ^ Bubbled up from the tab layer (e.g. spawn failure).
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- ParsedInput
-- ---------------------------------------------------------------------------

-- | The classification @parseInput@ produces (WU2).
--
-- The 'Switch' \/ 'Inject' \/ 'ParsedSlashCmd' branches do NOT reach
-- a provider — that's the LLM-free invariant P18. Only 'Default' text
-- ever feeds a provider call.
--
-- Note on the constructor name 'ParsedSlashCmd' (vs the design doc's
-- @SlashCmd@): Haskell does not permit two constructors with the same
-- name in the same module, and 'InputEvent' already owns 'SlashCmd'.
-- Both carry the same 'Slash.SlashCommand' payload; the dispatcher
-- maps @ParsedSlashCmd cmd@ to @SlashCmd cmd@ when enqueueing onto a
-- tab's input queue.
data ParsedInput
  = Switch !Tab.TabIndex
    -- ^ @\/N@ — focus the tab at index @N@ (or auto-spawn per A-series).
  | Inject !Tab.TabIndex !Text
    -- ^ @\/N \<payload\>@ — enqueue payload on tab @N@ without
    --   changing focus.
  | Default !Text
    -- ^ Plain text — routed to the current focused tab.
  | ParsedSlashCmd !Slash.SlashCommand
    -- ^ Existing slash command (or the new @\/tab*@ family) parsed by
    --   the shared slash-command grammar.
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- InputEvent
-- ---------------------------------------------------------------------------

-- | One event in a tab's per-tab input queue.
--
-- The dispatcher (WU5) enqueues 'UserText' for free-form text and
-- 'SlashCmd' for Context-mutating commands (per E5). Each tab loop
-- (WU6 for 'Tab.KindAi') is the sole consumer.
data InputEvent
  = UserText !Text
  | SlashCmd !Slash.SlashCommand
  deriving stock (Eq, Show)


-- ---------------------------------------------------------------------------
-- Channel output
-- ---------------------------------------------------------------------------

-- | Origin of a 'ChannelEvent' on the channel-out queue.
--
-- The single writer thread reads 'OutputSource' on dequeue and uses
-- it as the focus gate: 'SrcDispatcher' events emit unconditionally
-- ('PureClaw.Handles.Channel.ChannelHandle' always sees them), while
-- 'SrcTab' events are dropped when '_env_focus' is not @Just n@.
data OutputSource
  = SrcDispatcher
  | SrcTab !Tab.TabIndex
  deriving stock (Eq, Show)

-- | Identifier for one logical multi-chunk message on the channel.
--
-- The data constructor is intentionally NOT exported; obtain values
-- via 'mkStreamId' (a monotonically-increasing allocator lands in WU4
-- alongside the writer thread). The 'Word64' carrier is large enough
-- that wrap-around is not a practical concern.
newtype StreamId = StreamId { unStreamId :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | The only way to construct a 'StreamId'. Callers (typically the
-- 'PureClaw.Routing.ChannelOut' allocator) bump a 'Word64' counter and
-- pass the result here.
mkStreamId :: Word64 -> StreamId
mkStreamId = StreamId

-- | Events that flow through @_env_channelOutQ@ (the single bounded
-- queue feeding the writer thread).
--
-- AI tab loops emit @'StreamStart' sid n@ once per logical message,
-- then a sequence of @'ChunkOf' sid chunk@, then @'StreamEnd' sid@.
-- Non-AI tab loops (KindShell\/Ssh\/Tmux\/Harness) emit one
-- @'FullMsg' n payload@ per @_bh_recv@\/harness-recv return — no
-- streaming, no breadcrumb (per D5 backend rule).
--
-- 'BannerLine' is reserved for one-shot dispatcher messages: switch
-- confirmations, dashboards, command errors, and mid-stream
-- breadcrumbs.
data ChannelEvent
  = StreamStart !StreamId !Tab.TabIndex
  | ChunkOf !StreamId !Text
  | StreamEnd !StreamId
  | FullMsg !Tab.TabIndex !Text
  | BannerLine !Text
  deriving stock (Eq, Show)
