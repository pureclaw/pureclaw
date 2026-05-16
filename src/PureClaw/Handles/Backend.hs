-- |
-- Module      : PureClaw.Handles.Backend
-- Description : Unified terminal backend type layer (WU1).
--
-- == Choose-a-kind decision tree
--
-- Use this decision tree to pick a 'BackendKind':
--
-- * 'Pipe' — one-shot, non-conversational. Write stdin, close stdin,
--   read stdout until EOF. Stderr is merged into stdout at the OS
--   level. Use for: @hostname@, @nix build@, one-shot @ssh host hostname@,
--   any program that does its work and exits.
-- * 'Pty' — conversational, PTY-backed, idle-detected. The child sees a
--   real terminal; stdout and stderr are merged (this is how every
--   terminal works). Use for: local @bash@, @ghci@, remote @ssh -tt@
--   shells, and @ssh -tt … tmux attach@ when attaching to a
--   pre-existing tmux window.
-- * @TmuxRpc@ (future) — non-PTY tmux RPC via @send-keys@ /
--   @capture-pane@. Not yet implemented. Will be additive: a new
--   'BackendKind' constructor and a new factory. The decision tree
--   gains: \"if you need to control a tmux window someone else owns
--   without disturbing them, use TmuxRpc.\"
--
-- The trade-off in one line: 'Pipe' is the safest one-shot, 'Pty' is
-- the only conversational kind in v1, and @TmuxRpc@ (future) is the
-- only non-intrusive controller.
--
-- == Field-naming convention
--
-- The handle record uses @_bh_*@; per-kind option records use prefixes
-- that match the project's universal Handle convention
-- (@_pto_*@ for 'PtyOpts', @_po_*@ for 'PipeOpts').
--
-- == Scope of WU1
--
-- This module currently lands the type layer only: types, smart
-- constructors, tiered defaults, and helpers. No-op / in-memory
-- backends, the PTY allocation seam, factory functions, drainer
-- infrastructure, and the process-wide buffer quota live in later
-- work units.
module PureClaw.Handles.Backend
  ( -- * Backend kind
    BackendKind (..)
    -- * Recv outcomes
  , RecvResult (..)
  , recvBytes
  , RecvOutcome (..)
  , recvOutcome
    -- * Terminal geometry
  , Cols (..)
  , Rows (..)
    -- * Idle policy
  , IdleSpec
  , mkIdleSpec
  , idleQuietMs
  , idleTimeoutMs
  , idleMinFirstByte
  , localIdle
  , sshIdle
  , tmuxIdle
  , testIdleSpec
    -- * Subprocess environment
  , EnvValue (..)
  , EnvMap
  , forbiddenEnvVars
  , mkEnvMap
    -- * Credential redaction
  , defaultCredentialRedactor
    -- * Backend context vocabulary
  , BackendContext (..)
  , backendContextLabel
    -- * Failure mode payloads
  , SshConnectFailure (..)
  , PtyAllocFailure (..)
  , InvalidOptionDetail (..)
  , TmuxTargetRef (..)
    -- * Error types
  , BackendError (..)
  , PublicBackendError (..)
  , toPublicError
  , BackendException (..)
  , toPublicException
    -- * Per-kind option records
  , PtyOpts (..)
  , PipeOpts (..)
  , defaultPipeOpts
  , defaultPtyOpts
    -- * Handle
  , BackendHandle (..)
    -- * Top-level helpers
  , runBackend
  , isConversational
  , recv
  , recvWith
    -- * Bracket helpers
  , withBackendHandle
  , withBackendHandleE
    -- * Concurrent-use guard
  , withConcurrentUseGuard
    -- * No-op + in-memory test backends
  , mkNoOpBackendHandle
  , InMemoryConfig (..)
  , InMemoryState (..)
  , newInMemoryState
  , mkInMemoryBackendHandle
    -- * Process-wide recv-buffer quota (WU7)
  , BackendBufferQuota
  , newBackendBufferQuota
  , globalBackendBufferQuota
  , acquireBufferQuota
  , releaseBufferQuota
  , bufferQuotaAvailableMiB
  , setGlobalBackendBufferQuotaForTest
  , defaultAggregateBufferCapMiB
    -- * Re-exports
  , CommandName (..)
  , AutonomyLevel (..)
  , FakeClock
  ) where

import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , putMVar
  , tryTakeMVar
  )
import Control.Exception
  ( Exception
  , SomeException
  , bracket
  , displayException
  , finally
  , throwIO
  , toException
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

import {-# SOURCE #-} PureClaw.Internal.Redact qualified as Redact
import PureClaw.Core.Types (AutonomyLevel (..), CommandName (..))
import PureClaw.Internal.FakeClock (FakeClock)

-- | The mechanism a 'BackendHandle' uses to talk to its subprocess.
--
-- A future @TmuxRpc@ constructor will be added when non-PTY tmux RPC
-- (send-keys / capture-pane) lands; pattern matches on 'BackendKind'
-- in dependent code should remain exhaustive across the existing
-- constructors and explicitly handle (or @-Wall@-fail-shut) any new
-- one.
data BackendKind
  = Pipe
    -- ^ One-shot, non-conversational: write stdin, close, read until EOF.
  | Pty
    -- ^ Conversational, PTY-backed, idle-detected.
  deriving stock (Eq, Show)

-- | Result of a single recv call.
--
-- Idle-timeout and EOF are reported, not thrown, so callers can decide
-- whether to retry, keep waiting, or move on. 'RecvTruncated' latches
-- across recv calls until '_bh_close'.
data RecvResult a
  = RecvSettled !a
    -- ^ Output settled within @idleQuietMs@.
  | RecvTimedOut !a
    -- ^ @idleTimeoutMs@ reached; bytes accumulated so far returned.
  | RecvEof !a
    -- ^ Subprocess / PTY closed; bytes accumulated so far returned.
  | RecvTruncated !a
    -- ^ Per-backend read-buffer cap reached; subsequent recvs continue
    -- to return 'RecvTruncated' until close.
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | Project a 'RecvResult' to the accumulated bytes regardless of outcome.
recvBytes :: RecvResult a -> a
recvBytes r = case r of
  RecvSettled   a -> a
  RecvTimedOut  a -> a
  RecvEof       a -> a
  RecvTruncated a -> a

-- | Pure projection of a 'RecvResult'\'s outcome flag.
--
-- Useful when callers only need to switch on the outcome without
-- pattern-matching on the payload.
data RecvOutcome
  = Settled
  | TimedOut
  | Eof
  | Truncated
  deriving stock (Eq, Show)

-- | Map a 'RecvResult' to its 'RecvOutcome'.
recvOutcome :: RecvResult a -> RecvOutcome
recvOutcome r = case r of
  RecvSettled   _ -> Settled
  RecvTimedOut  _ -> TimedOut
  RecvEof       _ -> Eof
  RecvTruncated _ -> Truncated

-- | Terminal column count.
newtype Cols = Cols Int
  deriving stock (Eq, Ord, Show)

-- | Terminal row count.
newtype Rows = Rows Int
  deriving stock (Eq, Ord, Show)

-- | Construction-time policy for \"when has output settled?\".
--
-- Constructor is intentionally NOT exported; obtain values via
-- 'mkIdleSpec' or one of the tiered defaults
-- ('localIdle' \/ 'sshIdle' \/ 'tmuxIdle' \/ 'testIdleSpec').
--
-- Invariants enforced by 'mkIdleSpec':
--
-- * Every field is non-negative.
-- * @idleMinFirstByte <= idleTimeoutMs@.
data IdleSpec = IdleSpec
  { _idle_quietMs       :: !Int
  , _idle_timeoutMs     :: !Int
  , _idle_minFirstByte  :: !Int
  }
  deriving stock (Eq, Show)

-- | Quiet-window in milliseconds, measured from the latest byte received.
idleQuietMs :: IdleSpec -> Int
idleQuietMs = _idle_quietMs

-- | Hard ceiling in milliseconds on the total wait per recv.
idleTimeoutMs :: IdleSpec -> Int
idleTimeoutMs = _idle_timeoutMs

-- | Minimum wait in milliseconds for the first byte before treating
-- \"no bytes\" as settled.
idleMinFirstByte :: IdleSpec -> Int
idleMinFirstByte = _idle_minFirstByte

-- | The only way to construct an 'IdleSpec'.
--
-- Arguments are @idleQuietMs@, @idleTimeoutMs@, @idleMinFirstByte@ in
-- that order. Returns @Left 'BackendInvalidOption'@ if any argument is
-- negative or if @idleMinFirstByte > idleTimeoutMs@.
mkIdleSpec :: Int -> Int -> Int -> Either BackendError IdleSpec
mkIdleSpec quietMs timeoutMs minFirstByte
  | quietMs < 0 =
      Left (BackendInvalidOption
              (InvalidOptionDetail "IdleSpec: idleQuietMs must be non-negative"))
  | timeoutMs < 0 =
      Left (BackendInvalidOption
              (InvalidOptionDetail "IdleSpec: idleTimeoutMs must be non-negative"))
  | minFirstByte < 0 =
      Left (BackendInvalidOption
              (InvalidOptionDetail "IdleSpec: idleMinFirstByte must be non-negative"))
  | minFirstByte > timeoutMs =
      Left (BackendInvalidOption
              (InvalidOptionDetail
                "IdleSpec: idleMinFirstByte must be <= idleTimeoutMs"))
  | otherwise =
      Right IdleSpec
        { _idle_quietMs      = quietMs
        , _idle_timeoutMs    = timeoutMs
        , _idle_minFirstByte = minFirstByte
        }

-- | Helper for building compile-time 'IdleSpec' constants. The argument
-- triples are statically known and validated, so a 'mkIdleSpec' failure
-- is a programming error in this module itself, not a runtime
-- condition that callers can recover from.
unsafeMkIdleSpec :: String -> Int -> Int -> Int -> IdleSpec
unsafeMkIdleSpec label quietMs timeoutMs minFirstByte =
  case mkIdleSpec quietMs timeoutMs minFirstByte of
    Right s -> s
    Left _  -> error ("unsafeMkIdleSpec: invalid " ++ label)

-- | Local-process idle defaults: quiet 150ms, total 15s, no minimum first byte.
localIdle :: IdleSpec
localIdle = unsafeMkIdleSpec "localIdle" 150 15_000 0

-- | SSH idle defaults: quiet 750ms, total 60s, 500ms minimum first byte.
sshIdle :: IdleSpec
sshIdle = unsafeMkIdleSpec "sshIdle" 750 60_000 500

-- | Tmux idle defaults: quiet 500ms, total 30s, 200ms minimum first byte.
tmuxIdle :: IdleSpec
tmuxIdle = unsafeMkIdleSpec "tmuxIdle" 500 30_000 200

-- | Test idle defaults: quiet 5ms, total 50ms, no minimum first byte.
testIdleSpec :: IdleSpec
testIdleSpec = unsafeMkIdleSpec "testIdleSpec" 5 50 0

-- | A single environment variable value.
--
-- The hand-written 'Show' instance renders @EnvValue \<redacted\>@ so
-- accidental 'show'ing of an 'EnvMap' (e.g. via 'BackendError' or
-- structured logging) cannot leak secrets.
newtype EnvValue = EnvValue ByteString
  deriving stock (Eq)

-- Hand-written: deliberately does NOT show the underlying bytes.
instance Show EnvValue where
  show _ = "EnvValue <redacted>"

-- | A complete subprocess environment.
--
-- This map is the entire environment the child will see; PureClaw does
-- not inherit from the agent's process environment.
type EnvMap = Map String EnvValue

-- | Environment variable names that must never appear in a caller-supplied
-- 'EnvMap'.
--
-- Includes loader-hijack hooks ('LD_PRELOAD' \/ 'DYLD_INSERT_LIBRARIES' \/
-- the @LIBRARY_PATH@ family), ssh-agent\/askpass channels, shell init
-- hooks ('BASH_ENV', 'ENV', 'PROMPT_COMMAND', 'PS4'), and Git\'s
-- @GIT_SSH_COMMAND@ \/ @GIT_SSH@ overrides.
forbiddenEnvVars :: Set String
forbiddenEnvVars = Set.fromList
  [ "LD_PRELOAD"
  , "DYLD_INSERT_LIBRARIES"
  , "LD_LIBRARY_PATH"
  , "DYLD_LIBRARY_PATH"
  , "DYLD_FALLBACK_LIBRARY_PATH"
  , "SSH_AUTH_SOCK"
  , "SSH_ASKPASS"
  , "SSH_ASKPASS_REQUIRE"
  , "SSH_AGENT_PID"
  , "BASH_ENV"
  , "ENV"
  , "GIT_SSH_COMMAND"
  , "GIT_SSH"
  , "PROMPT_COMMAND"
  , "PS4"
  ]

-- | Build an 'EnvMap' from a key/value list.
--
-- Rejects any key listed in 'forbiddenEnvVars' with a
-- 'BackendInvalidOption' carrying the offending name.
mkEnvMap :: [(String, String)] -> Either BackendError EnvMap
mkEnvMap = go Map.empty
  where
    go acc [] = Right acc
    go acc ((k, v) : rest)
      | Set.member k forbiddenEnvVars =
          Left (BackendInvalidOption
                  (InvalidOptionDetail
                    (T.pack ("EnvMap: forbidden var '" ++ k ++ "'"))))
      | otherwise =
          go (Map.insert k (EnvValue (encodeUtf8Latin1 v)) acc) rest

    -- Latin-1 round-trip ByteString-encode for environment values without
    -- pulling in 'text' \<-\> 'bytestring' overhead. Environment values are
    -- typically ASCII; non-ASCII bytes are preserved 1:1 because the
    -- subprocess sees raw bytes.
    encodeUtf8Latin1 :: String -> ByteString
    encodeUtf8Latin1 s = TE.encodeUtf8 (T.pack s)

-- | Default 'PtyOpts._pto_redactor'.
--
-- Scrubs the known credential prompts @password:@, @passphrase:@,
-- @Sorry, try again@, and @[sudo] password for@ from recv chunks
-- before the caller sees them. The actual scan is implemented in
-- 'PureClaw.Internal.Redact.credentialPromptScrubber'; this is the
-- public name that 'PtyOpts._pto_redactor' defaults to.
--
-- Per-chunk only: the 64-byte overlap-window carry-forward across
-- chunk boundaries lives inside the drainer (WU7).
defaultCredentialRedactor :: ByteString -> ByteString
defaultCredentialRedactor = Redact.credentialPromptScrubber

-- | Fixed-vocabulary context tag attached to a 'BackendException'.
--
-- Adding a new context MUST happen here; throw sites are not allowed
-- to freelance free 'Text'. This keeps the universe of contexts small
-- enough to grep for and to redact safely.
data BackendContext
  = BcSend
  | BcRecv
  | BcClose
  | BcSshWrite
  | BcSshDisconnect
  | BcPtyEof
  | BcConcurrentUse
  | BcTmuxDetach
  | BcBufferOverflow
  deriving stock (Eq, Show)

-- | Render a 'BackendContext' as the short label that appears in
-- structured logs and the redacted 'Show' for 'BackendException'.
backendContextLabel :: BackendContext -> Text
backendContextLabel ctx = case ctx of
  BcSend           -> "send"
  BcRecv           -> "recv"
  BcClose          -> "close"
  BcSshWrite       -> "ssh-write"
  BcSshDisconnect  -> "ssh-disconnect"
  BcPtyEof         -> "pty-eof"
  BcConcurrentUse  -> "concurrent-use"
  BcTmuxDetach     -> "tmux-detach"
  BcBufferOverflow -> "buffer-overflow"

-- | Structured SSH connect-time failure modes.
--
-- No constructor carries free 'Text' \/ raw stderr — that would defeat
-- the redaction guarantee on 'BackendError'\'s 'Show'.
data SshConnectFailure
  = SshNetUnreachable
  | SshAuthRefused
  | SshHostKeyMismatch
  | SshConnectTimeout
  | SshOtherFailure
  deriving stock (Eq, Show)

-- | Structured PTY-allocation failure modes.
data PtyAllocFailure
  = PtyOpenFailed
  | PtyForkFailed
  | PtyExecFailed
  deriving stock (Eq, Show)

-- | The short, redaction-safe message attached to a
-- 'BackendInvalidOption'.
--
-- The constructor is exported so callers (and tests) can pattern-match
-- on the message; the contents are short, fixed-vocabulary strings —
-- never free user input or raw stderr.
newtype InvalidOptionDetail = InvalidOptionDetail Text
  deriving stock (Eq, Show)

-- | Redaction-safe reference to a tmux target.
--
-- WU1 ships the simpler @Text@-only form; the smart-constructor
-- newtypes 'TmuxSession' \/ 'TmuxWindow' \/ 'TmuxPane' (with rejection
-- of leading @-@, whitespace, and shell metacharacters) land in WU10
-- — at which point this becomes the redaction-safe carrier for those
-- typed values inside 'BackendError'.
data TmuxTargetRef = TmuxTargetRef !Text !Text !(Maybe Text)
  deriving stock (Eq, Show)

-- | Construction-time backend errors.
--
-- Every constructor's payload is itself a redaction-safe ADT — no
-- field carries a free 'Text', a raw 'SomeException' message, or a
-- raw filesystem path. The hand-written 'Show' just calls 'show' on
-- the inner payload, so adding a new constructor cannot accidentally
-- regress the redaction guarantee.
data BackendError
  = BackendBinaryNotFound !CommandName
  | BackendPtyAllocFailed !PtyAllocFailure
  | BackendSshConnectFailed !SshConnectFailure
  | BackendTmuxTargetMissing !TmuxTargetRef
  | BackendInvalidOption !InvalidOptionDetail
  | BackendBufferQuotaExceeded !Int
    -- ^ The 'Int' is the requested per-backend cap, in MiB.
  | BackendBrokenTmuxTarget !TmuxTargetRef
    -- ^ The pinned @\@window_id@ no longer matches a live tmux window.
  deriving stock (Eq)

-- Hand-written: routes through 'PureClaw.Internal.Redact.redactedShowString'
-- so the rendered output is always redaction-safe — no raw hostnames,
-- IPv4 addresses, paths, or ssh stderr fragments.
--
-- The constructor-by-constructor case is here (not in @Redact@) to
-- keep @Redact@ outside @Handles.Backend@\'s import cycle: each branch
-- renders a fixed prefix plus 'show' on a leaf ADT, then the whole
-- string is passed through the same pipeline 'redactErr' uses.
instance Show BackendError where
  show e = T.unpack (Redact.redactedShowString (renderBackendError e))

renderBackendError :: BackendError -> String
renderBackendError e = case e of
  BackendBinaryNotFound c ->
    "BackendBinaryNotFound " <> show c
  BackendPtyAllocFailed f ->
    "BackendPtyAllocFailed " <> show f
  BackendSshConnectFailed f ->
    "BackendSshConnectFailed " <> show f
  BackendTmuxTargetMissing t ->
    "BackendTmuxTargetMissing " <> show t
  BackendInvalidOption d ->
    "BackendInvalidOption " <> show d
  BackendBufferQuotaExceeded n ->
    "BackendBufferQuotaExceeded " <> show n
  BackendBrokenTmuxTarget t ->
    "BackendBrokenTmuxTarget " <> show t

-- | User-visible (channel-safe) projection of a 'BackendError'.
--
-- The wrapped 'Text' is short, fixed-vocabulary, and contains no
-- hostnames, paths, or secrets.
newtype PublicBackendError = PublicBackendError Text
  deriving stock (Eq, Show)

-- | Project a 'BackendError' to its user-visible form.
toPublicError :: BackendError -> PublicBackendError
toPublicError e = PublicBackendError $ case e of
  BackendBinaryNotFound _ ->
    "backend: required program not available"
  BackendPtyAllocFailed _ ->
    "backend: failed to allocate a pseudo-terminal"
  BackendSshConnectFailed _ ->
    "backend: ssh connection failed"
  BackendTmuxTargetMissing _ ->
    "backend: tmux target window not found"
  BackendInvalidOption _ ->
    "backend: invalid construction option"
  BackendBufferQuotaExceeded _ ->
    "backend: aggregate recv-buffer quota exceeded"
  BackendBrokenTmuxTarget _ ->
    "backend: tmux target no longer present (window destroyed mid-session)"

-- | Runtime exception raised from inside '_bh_send' \/ '_bh_recv' \/
-- '_bh_close' when something below the abstraction goes wrong (broken
-- pipe, ssh transport drop, kernel error during PTY I\/O, etc.).
--
-- The hand-written 'Show' deliberately does NOT include the inner
-- 'SomeException'\'s message: that message may carry raw hostnames or
-- file paths from a child program. The real redaction-routing
-- replaces this stub in WU2.
data BackendException = BackendException
  { _be_context :: !BackendContext
  , _be_cause   :: !SomeException
  }

-- Hand-written: routes through 'PureClaw.Internal.Redact.redactedShowString'.
-- The wrapped 'SomeException'\'s message is rendered first via
-- 'displayException' and then fed through the redaction pipeline.
instance Show BackendException where
  show be =
    T.unpack
      (Redact.redactedShowString
        ( "BackendException { _be_context = "
            <> show (_be_context be)
            <> ", _be_cause = "
            <> displayException (_be_cause be)
            <> " }"
        ))

instance Exception BackendException

-- | Project a 'BackendException' to its user-visible form.
toPublicException :: BackendException -> PublicBackendError
toPublicException be =
  PublicBackendError
    ("backend exception during "
       <> backendContextLabel (_be_context be))

-- | PTY-backend construction options.
--
-- '_pto_io' (the injectable PTY allocation seam) and the wiring to
-- 'defaultCredentialRedactor' land in 'PureClaw.Backend.Pty' (WU7);
-- putting the @PtyIO@ field here would create a circular import.
-- TODO: WU7 wire PtyIO seam.
data PtyOpts = PtyOpts
  { _pto_cols          :: !Cols
  , _pto_rows          :: !Rows
  , _pto_env           :: !EnvMap
  , _pto_cwd           :: !(Maybe FilePath)
  , _pto_idle          :: !IdleSpec
  , _pto_recvBufferCap :: !Int
  , _pto_redactor      :: ByteString -> ByteString
  }

-- | Pipe-backend construction options.
data PipeOpts = PipeOpts
  { _po_stdinBytes    :: !ByteString
  , _po_env           :: !EnvMap
  , _po_cwd           :: !(Maybe FilePath)
  , _po_recvBufferCap :: !Int
  }

-- | Default 'PipeOpts': empty stdin, empty env, no cwd, 4 MiB recv cap.
defaultPipeOpts :: PipeOpts
defaultPipeOpts = PipeOpts
  { _po_stdinBytes    = mempty
  , _po_env           = Map.empty
  , _po_cwd           = Nothing
  , _po_recvBufferCap = 4 * 1024 * 1024
  }

-- | Default 'PtyOpts': 200x50 geometry, empty env, no cwd, 'localIdle',
-- 4 MiB recv cap, 'defaultCredentialRedactor'.
--
-- Opt-out for the credential scrubber is explicit: set
-- @_pto_redactor = id@ on the constructed record.
defaultPtyOpts :: PtyOpts
defaultPtyOpts = PtyOpts
  { _pto_cols          = Cols 200
  , _pto_rows          = Rows 50
  , _pto_env           = Map.empty
  , _pto_cwd           = Nothing
  , _pto_idle          = localIdle
  , _pto_recvBufferCap = 4 * 1024 * 1024
  , _pto_redactor      = defaultCredentialRedactor
  }

-- | Subprocess I\/O capability: a record of IO actions tagged with its
-- 'BackendKind'.
--
-- Concurrency contract (documented in the design doc): '_bh_send' and
-- '_bh_recv' MUST NOT be called concurrently from multiple caller
-- threads against the same handle. Callers needing shared access wrap
-- in an 'Control.Concurrent.MVar.MVar BackendHandle'.
--
-- '_bh_close' is idempotent and never throws on any backend kind.
data BackendHandle = BackendHandle
  { _bh_name        :: !Text
    -- ^ Human-readable, for logs; not an identity.
  , _bh_kind        :: !BackendKind
    -- ^ Kind tag for introspection.
  , _bh_defaultIdle :: !IdleSpec
    -- ^ The 'IdleSpec' bound at construction.
  , _bh_send        :: ByteString -> IO ()
  , _bh_recv        :: Maybe IdleSpec -> IO (RecvResult ByteString)
    -- ^ Read output. @Nothing@ uses '_bh_defaultIdle';
    -- @Just s@ overrides for this call only.
  , _bh_resize      :: Cols -> Rows -> IO ()
    -- ^ No-op on 'Pipe'-kind backends (and future @TmuxRpc@).
  , _bh_close       :: IO ()
    -- ^ Idempotent; never throws.
  }

-- | Send a request and receive the response with the handle's default
-- idle policy. For 'Pipe' backends this is a true request\/response;
-- for 'Pty' backends the response is whatever the idle policy
-- captures, which may include unrelated background output.
runBackend :: BackendHandle -> ByteString -> IO (RecvResult ByteString)
runBackend b bs = _bh_send b bs *> _bh_recv b Nothing

-- | Whether the handle's kind is conversational
-- ('Pty' — @True@; 'Pipe' — @False@).
isConversational :: BackendHandle -> Bool
isConversational b = case _bh_kind b of
  Pty  -> True
  Pipe -> False

-- | Equivalent to @_bh_recv b Nothing@ as a top-level helper.
recv :: BackendHandle -> IO (RecvResult ByteString)
recv b = _bh_recv b Nothing

-- | Equivalent to @_bh_recv b (Just s)@ as a top-level helper, for the
-- common case of overriding the default idle policy for a single call.
recvWith :: BackendHandle -> IdleSpec -> IO (RecvResult ByteString)
recvWith b s = _bh_recv b (Just s)

-- | Run an action with an already-constructed 'BackendHandle',
-- guaranteeing '_bh_close' runs on success or exception.
--
-- Body exceptions are re-raised after the close action finishes.
-- '_bh_close' is documented as idempotent and never-throwing on every
-- backend kind, so the close phase cannot mask a body exception.
withBackendHandle :: BackendHandle -> (BackendHandle -> IO a) -> IO a
withBackendHandle b = bracket (pure b) (\_ -> _bh_close b)

-- | Combined acquire-and-bracket helper for the common factory pattern
-- @IO (Either BackendError BackendHandle)@.
--
-- On a 'Left' result from @acquire@, no body is run and the error is
-- returned as-is. On a 'Right' result, behaves like 'withBackendHandle'
-- and re-raises any body exception after closing.
withBackendHandleE
  :: IO (Either BackendError BackendHandle)
  -> (BackendHandle -> IO a)
  -> IO (Either BackendError a)
withBackendHandleE acquire body = do
  result <- acquire
  case result of
    Left  e -> pure (Left e)
    Right b -> Right <$> withBackendHandle b body

-- | Wrap a 'BackendHandle' so that concurrent entry into '_bh_send'
-- and '_bh_recv' from multiple threads is detected and rejected.
--
-- The documented concurrency contract on 'BackendHandle' says callers
-- MUST NOT invoke '_bh_send' or '_bh_recv' from two threads at once;
-- this wrapper enforces that contract by gating both actions on a
-- single 'MVar'. The second-entrant observes a 'BackendException' with
-- @_be_context = 'BcConcurrentUse'@ instead of corrupting state.
--
-- '_bh_resize' and '_bh_close' are NOT gated: resize is documented as
-- safe from any thread, and close is documented as idempotent.
withConcurrentUseGuard :: BackendHandle -> IO BackendHandle
withConcurrentUseGuard bh = do
  gate <- newMVar ()
  pure bh
    { _bh_send = guarded gate . _bh_send bh
    , _bh_recv = guarded gate . _bh_recv bh
    }
  where
    guarded :: MVar () -> IO a -> IO a
    guarded gate io = do
      m <- tryTakeMVar gate
      case m of
        Nothing ->
          throwIO $ BackendException
            BcConcurrentUse
            (toException
               (userError "concurrent _bh_send/_bh_recv on a BackendHandle"))
        Just () -> io `finally` putMVar gate ()

--------------------------------------------------------------------------------
-- No-op backend
--------------------------------------------------------------------------------

-- | A purely no-op 'BackendHandle' for both 'Pipe' and 'Pty' kinds.
--
-- * '_bh_send' silently discards its argument.
-- * '_bh_recv' (with or without an idle override) returns 'RecvSettled' on
--   an empty payload.
-- * '_bh_resize' is a silent no-op for both kinds.
-- * '_bh_close' is idempotent and never throws.
mkNoOpBackendHandle :: BackendKind -> BackendHandle
mkNoOpBackendHandle kind = BackendHandle
  { _bh_name        = "noop"
  , _bh_kind        = kind
  , _bh_defaultIdle = testIdleSpec
  , _bh_send        = \_   -> pure ()
  , _bh_recv        = \_   -> pure (RecvSettled BS.empty)
  , _bh_resize      = \_ _ -> pure ()
  , _bh_close       = pure ()
  }

--------------------------------------------------------------------------------
-- In-memory backend
--------------------------------------------------------------------------------

-- | Construction-time configuration for 'mkInMemoryBackendHandle'.
--
-- The caller owns @_imc_state@ — create it with 'newInMemoryState'
-- ahead of time and inspect it via 'readIORef' after exercising the
-- returned handle. This shape keeps the factory's signature
-- @BackendKind -> InMemoryConfig -> IO BackendHandle@ (per the design
-- doc) while still giving tests a way to introspect what was sent /
-- received / resized / closed.
data InMemoryConfig = InMemoryConfig
  { _imc_clock           :: !FakeClock
    -- ^ Deterministic clock used for idle measurement (not yet wired
    -- to the recv path in WU3; required by the design doc for parity
    -- with @fakePtyIO@ and for forward-compatibility with the
    -- property-test seam in WU7).
  , _imc_scriptedReplies :: ![ByteString]
    -- ^ Consumed in order on each '_bh_recv'. Once exhausted,
    -- subsequent recvs return @RecvEof BS.empty@.
  , _imc_eofAfter        :: !(Maybe Int)
    -- ^ Optional cap: after this many '_bh_recv' calls, every
    -- subsequent recv returns @RecvEof BS.empty@ regardless of any
    -- remaining scripted replies.
  , _imc_state           :: !(IORef InMemoryState)
    -- ^ Caller-supplied introspection state. Construct via
    -- 'newInMemoryState'.
  }

-- | Mutable in-memory backend state. Updated in place by the
-- 'BackendHandle' returned from 'mkInMemoryBackendHandle'.
--
-- Lists are stored in reverse-chronological order for cheap @cons@;
-- callers that want chronological order should 'reverse' on read.
data InMemoryState = InMemoryState
  { _ims_sentBytes   :: ![ByteString]
    -- ^ Every payload passed to '_bh_send', most-recent first.
  , _ims_recvCalls   :: !Int
    -- ^ Number of '_bh_recv' invocations issued against the handle.
  , _ims_resizeCalls :: ![(Cols, Rows)]
    -- ^ Every @(cols, rows)@ pair passed to '_bh_resize', most-recent
    -- first. For 'Pipe'-kind handles, this list always stays empty
    -- because '_bh_resize' is a silent no-op on pipes.
  , _ims_closed      :: !Bool
    -- ^ Set to 'True' on first '_bh_close'; remains 'True' on subsequent
    -- (idempotent) calls.
  }
  deriving stock (Eq, Show)

-- | Allocate a fresh, empty 'InMemoryState' for 'InMemoryConfig'.
newInMemoryState :: IO (IORef InMemoryState)
newInMemoryState = newIORef InMemoryState
  { _ims_sentBytes   = []
  , _ims_recvCalls   = 0
  , _ims_resizeCalls = []
  , _ims_closed      = False
  }

-- | A deterministic, scriptable 'BackendHandle' for property tests.
--
-- The handle:
--
-- * records each '_bh_send' payload into '_imc_state' (newest first);
-- * pulls the next scripted reply from '_imc_scriptedReplies' on each
--   '_bh_recv', wrapping it in 'RecvSettled'. Once the script is
--   exhausted — or @_imc_eofAfter@ recvs have occurred, whichever
--   comes first — every subsequent recv returns @RecvEof BS.empty@;
-- * records each '_bh_resize' call into '_imc_state' if @kind == Pty@;
--   for @kind == Pipe@, resize is a silent no-op (nothing recorded);
-- * marks '_ims_closed' on '_bh_close'. Close is idempotent.
mkInMemoryBackendHandle :: BackendKind -> InMemoryConfig -> IO BackendHandle
mkInMemoryBackendHandle kind cfg = do
  scriptRef <- newIORef (_imc_scriptedReplies cfg)
  let stRef    = _imc_state cfg
      eofAfter = _imc_eofAfter cfg

      doRecv :: IO (RecvResult ByteString)
      doRecv = do
        -- Pre-increment so #-of-calls includes the current invocation
        -- when comparing against eofAfter.
        n <- atomicModifyIORef' stRef $ \s ->
          let n' = _ims_recvCalls s + 1
          in (s { _ims_recvCalls = n' }, n')
        let pastCap = case eofAfter of
              Nothing  -> False
              Just cap -> n > cap
        if pastCap
          then pure (RecvEof BS.empty)
          else do
            next <- atomicModifyIORef' scriptRef $ \case
              []     -> ([], Nothing)
              (r:tl) -> (tl, Just r)
            case next of
              Just r  -> pure (RecvSettled r)
              Nothing -> pure (RecvEof BS.empty)

      doResize :: Cols -> Rows -> IO ()
      doResize c r = case kind of
        Pipe -> pure ()
        Pty  -> atomicModifyIORef' stRef $ \s ->
          (s { _ims_resizeCalls = (c, r) : _ims_resizeCalls s }, ())

      doSend :: ByteString -> IO ()
      doSend bs = atomicModifyIORef' stRef $ \s ->
        (s { _ims_sentBytes = bs : _ims_sentBytes s }, ())

      doClose :: IO ()
      doClose = atomicModifyIORef' stRef $ \s ->
        (s { _ims_closed = True }, ())

  pure BackendHandle
    { _bh_name        = "in-memory"
    , _bh_kind        = kind
    , _bh_defaultIdle = testIdleSpec
    , _bh_send        = doSend
    , _bh_recv        = const doRecv
    , _bh_resize      = doResize
    , _bh_close       = doClose
    }

--------------------------------------------------------------------------------
-- Process-wide recv-buffer quota (WU7)
--------------------------------------------------------------------------------

-- | The default process-wide aggregate recv-buffer cap (64 MiB).
--
-- Override at process startup by setting the
-- @PURECLAW_BACKEND_AGGREGATE_CAP_MIB@ environment variable; the
-- 'globalBackendBufferQuota' singleton consults this variable once on
-- first use.
defaultAggregateBufferCapMiB :: Int
defaultAggregateBufferCapMiB = 64

-- | Process-wide recv-buffer quota, in MiB.
--
-- Backed by an 'IORef' counter (not a @QSem@ \/ @QSemN@): the
-- semantics we want are __non-blocking__ @tryAcquire@-style, returning
-- 'Left BackendBufferQuotaExceeded' on oversubscription rather than
-- blocking the calling thread. @QSemN.tryWaitQSemN@ does not exist
-- upstream, and a counter-based 'atomicModifyIORef'' is simpler and
-- equivalent in correctness for a single-process quota.
--
-- The double-release defense in 'releaseBufferQuota' relies on the
-- per-acquisition 'IORef' flag that backend factories thread through
-- their close action; this 'BackendBufferQuota' type itself stores
-- only the running total.
newtype BackendBufferQuota = BackendBufferQuota (IORef Int)

-- | Construct a quota with the given capacity (in MiB). Available
-- units start at the capacity.
newBackendBufferQuota :: Int -> IO BackendBufferQuota
newBackendBufferQuota capMiB = BackendBufferQuota <$> newIORef capMiB

-- | The shared, process-wide 'BackendBufferQuota' used by all real
-- backend factories.
--
-- Sized from the @PURECLAW_BACKEND_AGGREGATE_CAP_MIB@ environment
-- variable at first use; falls back to 'defaultAggregateBufferCapMiB'
-- if the variable is unset or unparseable.
--
-- Tests that need to drive oversubscription deterministically can
-- replace the singleton with 'setGlobalBackendBufferQuotaForTest'.
globalBackendBufferQuota :: IORef BackendBufferQuota
globalBackendBufferQuota = unsafePerformIO $ do
  cap <- readBufferQuotaCap
  q   <- newBackendBufferQuota cap
  newIORef q
{-# NOINLINE globalBackendBufferQuota #-}

readBufferQuotaCap :: IO Int
readBufferQuotaCap = do
  mEnv <- lookupEnv "PURECLAW_BACKEND_AGGREGATE_CAP_MIB"
  case mEnv >>= readMaybe of
    Just n | n > 0 -> pure n
    _              -> pure defaultAggregateBufferCapMiB

-- | Replace the global quota with a fresh one of the given capacity.
-- Test-only helper; production code must not call this.
setGlobalBackendBufferQuotaForTest :: Int -> IO ()
setGlobalBackendBufferQuotaForTest capMiB = do
  q <- newBackendBufferQuota capMiB
  writeIORef globalBackendBufferQuota q

-- | Inspect available MiB in a 'BackendBufferQuota'. Read-only; for
-- tests and diagnostics.
bufferQuotaAvailableMiB :: BackendBufferQuota -> IO Int
bufferQuotaAvailableMiB (BackendBufferQuota ref) = readIORef ref

-- | Try to acquire @n@ MiB. Returns 'Left BackendBufferQuotaExceeded'
-- if the quota is oversubscribed; the caller is expected to surface
-- this as a 'BackendError' on construction. Atomically decrements the
-- running counter on success.
--
-- Pass a negative or zero @n@ to acquire nothing — useful for pipe-
-- kind factories that don\'t carry a recv buffer.
acquireBufferQuota :: BackendBufferQuota -> Int -> IO (Either BackendError ())
acquireBufferQuota (BackendBufferQuota ref) n
  | n <= 0    = pure (Right ())
  | otherwise = atomicModifyIORef' ref $ \avail ->
      if avail >= n
        then (avail - n, Right ())
        else (avail, Left (BackendBufferQuotaExceeded n))

-- | Release @n@ MiB back to the quota.
--
-- Designed to be called inside a backend\'s close action. The double-
-- release defense lives at the call site (a per-backend 'IORef Bool'
-- flag flipped on first release); this function unconditionally
-- increments and is therefore safe to call from a 'bracket' cleanup.
releaseBufferQuota :: BackendBufferQuota -> Int -> IO ()
releaseBufferQuota (BackendBufferQuota ref) n
  | n <= 0    = pure ()
  | otherwise = atomicModifyIORef' ref $ \avail -> (avail + n, ())
