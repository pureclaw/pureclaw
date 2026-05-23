-- |
-- Module      : PureClaw.Tab.Backend
-- Description : Backend tab factory — KindShell\/KindSsh\/KindTmux (Tabbed Chat WU8).
--
-- A backend tab is a 'PureClaw.Handles.Tab.TabHandle' that wraps a
-- 'PureClaw.Handles.Backend.BackendHandle' constructed at spawn time
-- from a tab kind and a list of user-supplied args. The tab owns two
-- helper threads:
--
--   * a /drainer/ that loops on '_bh_recv' and emits each non-empty
--     output chunk as @'FullMsg' !TabIndex !Text@ via '_env_channelOutQ'
--     (focus-gated at the producer side per D4 and at the writer side
--     per D3 — per the D5 backend rule, no streaming\/no breadcrumbs);
--   * a /writer/ that drains a bounded outbound queue and forwards
--     bytes to '_bh_send', keeping the public 'TabHandle._tabHandle_send'
--     non-blocking per H4.
--
-- == Factory shape
--
-- @
-- 'mkTabBackend' :: 'PureClaw.Agent.Env.AgentEnv'
--                -> 'PureClaw.Handles.Tab.TabIndex'
--                -> 'PureClaw.Handles.Tab.TabKind'
--                -> [Text]
--                -> IO (Either 'PureClaw.Handles.Tab.TabError'
--                              'PureClaw.Handles.Tab.TabHandle')
-- @
--
-- Dispatches on the supplied 'TabKind' to one of three sub-factories:
--
-- * 'KindShell' — parses @[Text]@ via 'PureClaw.Security.Command.authorize'
--   against '_env_policy' (S1); on failure returns
--   @'Left' ('TabSpawnAuthDenied' ...)@. Calls
--   'PureClaw.Backend.Local.mkLocalBackendHandle' (via the injected
--   '_bio_mkShell' seam).
--
-- * 'KindSsh' — parses the first arg as @user\@host@; constructs the host
--   via 'PureClaw.Backend.SSH.mkSshHost' (S2\/S3 — rejects whitespace,
--   leading dashes, NUL bytes, and shell metachars). Parses the remaining
--   args as the remote command via
--   'PureClaw.Backend.SSH.authorizeRemote'. Sources the SSH identity from
--   the Vault slot named by '_rc_sshIdentityKey' (S4 — NO inline
--   identity acceptance); missing slot yields
--   @'Left' ('TabSpawnAuthDenied' ...)@.
--
-- * 'KindTmux' — parses one @session[:window[.pane]]@ argument via the
--   'PureClaw.Backend.Tmux.mkTmuxSession'\/'mkTmuxWindow'\/'mkTmuxPane'
--   smart constructors (S3); the local @tmux@ binary is authorized via
--   'PureClaw.Security.Command.authorize'.
--
-- == Slash commands are unsupported (H13 \/ I4)
--
-- '_tabHandle_enqueueSlash' returns @'Left' ('TabUnsupportedCommand'
-- cmd)@ immediately without enqueueing — backend tabs do not have a
-- per-tab 'Context' or slash-command surface. Direct-inject text
-- (@\/N \<text\>@) is forwarded verbatim to the backend via the writer
-- thread so a payload like @\/N \/pwd@ reaches the backend as the
-- literal @\"\/pwd\"@ (I4 — slash-prefix opaque to backend).
--
-- == Close semantics (H8 \/ H9)
--
-- Both 'CloseGraceful' and 'CloseForce' are destructive for backend
-- tabs: they cancel both helper threads and call '_bh_close' on the
-- underlying 'BackendHandle'. There is no archive equivalent. The close
-- path is idempotent + never-throws (H6 \/ H7 contract).
--
-- == Async exception discipline
--
-- Helper threads catch 'SomeException' EXCEPT 'AsyncCancelled', which
-- propagates so '_tabHandle_close' (which cancels the helpers'
-- 'TabRunner's) can unblock a stuck '_bh_recv' or pending writer.
-- Mirrors the WU6 \/ WU7 'safelyRun' pattern.
--
-- == Test seam ('BackendIO')
--
-- Production code calls 'mkTabBackend', which uses 'realBackendIO'
-- (which in turn calls the real WU8\/WU9\/WU10 backend factories from
-- @PureClaw.Backend.*@). Tests call 'mkTabBackendWith' with a fake
-- 'BackendIO' that returns an in-memory 'BackendHandle' (via
-- 'PureClaw.Handles.Backend.mkInMemoryBackendHandle') so spawn paths
-- are exercised end-to-end without forking real subprocesses.
--
-- See @docs\/tabbed-chat.md@ §"H-series" (close lifecycle), §"I4"
-- (opaque slash-prefix), §"S1"-"S4" (spawn authorization), and §"D5"
-- (FullMsg emission).
module PureClaw.Tab.Backend
  ( -- * Factory
    mkRawShellTab
  , mkRawShellTabWith
    -- * Backend I\/O seam
  , BackendIO (..)
  , realBackendIO
    -- * Internal state (exposed for tests)
  , BackendTabState (..)
    -- * Internal helpers (exposed for tests)
  , parseUserAtHost
  , parseTmuxTarget
  ) where

import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , atomically
  , isFullTBQueue
  , newTBQueueIO
  , readTBQueue
  , writeTBQueue
  )
import Control.Exception
  ( SomeException
  , catch
  , fromException
  , throwIO
  , try
  )
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (SlashCommand)
import PureClaw.Backend.Local qualified as Local
import PureClaw.Backend.Pty (realPtyIO)
import PureClaw.Backend.SSH qualified as SSH
import PureClaw.Backend.Tmux qualified as Tmux
import PureClaw.Handles.Backend
  ( BackendError (..)
  , BackendHandle (..)
  , InvalidOptionDetail (..)
  , RecvResult (..)
  , defaultPipeOpts
  , recvBytes
  )
import PureClaw.Handles.Tab
  ( CloseMode (..)
  , PublicAuthError (..)
  , PublicTabError (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabRunner (..)
  , TabStatus (..)
  )
import PureClaw.Session.Kind
  ( ContainerSpec (..)
  , SshConfig (..)
  , TerminalBackend (..)
  , TmuxConfig (..)
  )
import PureClaw.Tab.Container qualified as Container
import PureClaw.Routing.ChannelOut (shouldEmit)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  , RoutingConfig (..)
  )
import PureClaw.Security.Command
  ( AuthorizedCommand
  , authorize
  )
import PureClaw.Security.Path (SafeKeyPath)
import PureClaw.Security.Vault (VaultHandle (..))


-- ---------------------------------------------------------------------------
-- BackendTabState — per-tab mutable state, private to the factory closure
-- ---------------------------------------------------------------------------

-- | Per-backend-tab mutable state. Fields are exposed so a future
-- diagnostic @tab info@ handler can inspect them; production code never
-- touches the record outside this module.
data BackendTabState = BackendTabState
  { _bts_backend       :: !BackendHandle
    -- ^ The underlying 'BackendHandle' constructed at spawn time. The
    -- tab owns its lifecycle; '_tabHandle_close' calls '_bh_close' on
    -- the first invocation (H8 — destructive, no archive equivalent).
  , _bts_sendQ         :: !(TBQueue ByteString)
    -- ^ Bounded outbound queue. '_tabHandle_send' enqueues here
    -- non-blockingly; the writer thread drains and calls '_bh_send'.
    -- Bounded by '_rc_inputQueueBound' so a saturating producer
    -- surfaces 'TabConcurrencyLimit' rather than blocking the
    -- dispatcher (H4).
  , _bts_drainRunner   :: !(IORef (Maybe TabRunner))
    -- ^ Drainer thread runner (output side: '_bh_recv' →
    -- 'FullMsg'). Filled by 'mkTabBackendWith' post-fork; stays
    -- 'Nothing' for the brief window between allocation and fork-fill.
  , _bts_writerRunner  :: !(IORef (Maybe TabRunner))
    -- ^ Writer thread runner (input side: '_bts_sendQ' →
    -- '_bh_send'). Filled by 'mkTabBackendWith' post-fork.
  , _bts_closed        :: !(IORef Bool)
    -- ^ Idempotency flag for '_tabHandle_close'. Flipped to 'True' on
    -- the first invocation; subsequent invocations are no-ops (H6).
  , _bts_statusRef     :: !(IORef TabStatus)
    -- ^ Held status backing '_tabHandle_status'. Starts 'Idle' at
    -- spawn and transitions to 'Crashed' if a helper thread hits a
    -- synchronous exception.
  }


-- ---------------------------------------------------------------------------
-- BackendIO seam
-- ---------------------------------------------------------------------------

-- | Injection seam for the three real backend factories.
--
-- Production callers use 'mkTabBackend', which wires this to
-- 'realBackendIO' (which calls the real WU8\/WU9\/WU10 factories from
-- @PureClaw.Backend.*@). Tests call 'mkTabBackendWith' with a fake
-- 'BackendIO' that returns an in-memory 'BackendHandle' (via
-- 'PureClaw.Handles.Backend.mkInMemoryBackendHandle'), so the spawn,
-- drainer, and writer paths can be exercised end-to-end without
-- forking real subprocesses.
--
-- Note: every sub-factory still receives a fully-validated payload —
-- the smart constructors ('authorize', 'mkSshHost', 'authorizeRemote',
-- 'mkTmuxSession' \/ 'mkTmuxWindow' \/ 'mkTmuxPane') are invoked by
-- 'mkTabBackendWith' BEFORE the seam is called, so the seam is given a
-- security-validated value (the seam is not a way to skip validation).
data BackendIO = BackendIO
  { _bio_mkShell
      :: AuthorizedCommand
      -> IO (Either BackendError BackendHandle)
    -- ^ Spawn a local 'Pipe'-kind backend. Production: thin wrapper
    -- around 'PureClaw.Backend.Local.mkLocalBackendHandle' with the
    -- default 'PureClaw.Handles.Backend.PipeOpts'.
  , _bio_mkSsh
      :: SSH.SshTarget
      -> AuthorizedCommand
      -> SSH.RemoteCommand
      -> IO (Either BackendError BackendHandle)
    -- ^ Spawn an SSH backend. Production: calls
    -- 'PureClaw.Backend.SSH.mkSshBackendHandle' with 'realPtyIO' and
    -- the default 'PureClaw.Backend.SSH.SshOpts'.
  , _bio_mkTmux
      :: Tmux.SshLocation
      -> Tmux.TmuxTarget
      -> IO (Either BackendError BackendHandle)
    -- ^ Spawn a tmux Attach backend. Production: calls
    -- 'PureClaw.Backend.Tmux.mkTmuxBackendHandle' with 'realPtyIO'
    -- and the default 'PureClaw.Backend.Tmux.TmuxOpts'.
  , _bio_mkContainer
      :: AuthorizedCommand
      -> IO (Either BackendError BackendHandle)
    -- ^ Spawn a container exec backend. Production: thin wrapper
    -- around 'PureClaw.Backend.Local.mkLocalBackendHandle' with the
    -- default 'PureClaw.Handles.Backend.PipeOpts'. The 'AuthorizedCommand'
    -- carries the full container exec argv (@engine exec -it target --
    -- binary [args]@).
  }

-- | Production 'BackendIO': calls the real backend factories from
-- @PureClaw.Backend.*@.
--
-- The SSH and tmux paths use 'realPtyIO' (the @posix-pty@-backed PTY
-- allocator); the local-shell path uses
-- 'PureClaw.Backend.Local.mkLocalBackendHandle' which is pipe-only and
-- needs no PtyIO.
realBackendIO :: BackendIO
realBackendIO = BackendIO
  { _bio_mkShell = (`Local.mkLocalBackendHandle` defaultPipeOpts)
  , _bio_mkSsh = \tgt sshCmd remote ->
      SSH.mkSshBackendHandle realPtyIO sshCmd tgt remote SSH.defaultSshOpts
  , _bio_mkTmux = \loc tgt ->
      Tmux.mkTmuxBackendHandle realPtyIO loc tgt Tmux.defaultTmuxOpts
  , _bio_mkContainer = (`Local.mkLocalBackendHandle` defaultPipeOpts)
  }


-- ---------------------------------------------------------------------------
-- mkTabBackend — the backend tab factory
-- ---------------------------------------------------------------------------

-- | Construct a raw-shell backend tab (F4: 'TbLocal' \/ 'TbSsh' \/
-- 'TbTmux').
--
-- Calls 'mkRawShellTabWith' with 'realBackendIO'. The factory itself
-- never throws: it always returns @'Right' h@ or @'Left' e@. Failures
-- inside the forked helper threads are caught by their own outer
-- exception handler and surface as a 'Crashed' status (visible via
-- '_tabHandle_status').
mkRawShellTab
  :: AgentEnv
  -> TabIndex
  -> TerminalBackend
  -> [Text]
  -> IO (Either TabError TabHandle)
mkRawShellTab = mkRawShellTabWith realBackendIO

-- | Construct a raw-shell backend tab with a caller-supplied
-- 'BackendIO'. Test seam. See 'mkRawShellTab' for the production
-- entry point.
--
-- Dispatches on 'TerminalBackend' to one of three sub-factories. Each
-- sub-factory:
--
-- 1. Runs the kind-specific smart constructors (per S1\/S2\/S3\/S4) on
--    the user-supplied @[Text]@ args. On rejection returns
--    @'Left' ('TabSpawnAuthDenied' ...)@.
-- 2. Calls the corresponding seam action ('_bio_mkShell',
--    '_bio_mkSsh', '_bio_mkTmux') with the validated payload. On
--    'Left' returns @'Left' ('TabBackendConstructFailed' ...)@.
-- 3. On 'Right' wraps the resulting 'BackendHandle' in per-tab state
--    and forks the drainer + writer helper threads via '_env_fork'.
--
-- Session-backed kinds ('TkSession') have their own factories
-- ('PureClaw.Tab.Ai.mkTabAi' and 'PureClaw.Tab.Harness.mkTabHarness')
-- and must not be routed here.
mkRawShellTabWith
  :: BackendIO
  -> AgentEnv
  -> TabIndex
  -> TerminalBackend
  -> [Text]
  -> IO (Either TabError TabHandle)
mkRawShellTabWith bio env idx tb args = case tb of
  TbLocal         -> mkShellTab     bio env idx args
  TbSsh _         -> mkSshTab       bio env idx args
  TbTmux _        -> mkTmuxTab      bio env idx args
  TbContainer cs  -> mkContainerTab bio env idx cs args


-- ---------------------------------------------------------------------------
-- KindShell sub-factory (S1)
-- ---------------------------------------------------------------------------

-- | Spawn a local-shell backend tab.
--
-- Args layout: @[program, arg1, arg2, ...]@ — the first element is the
-- local command path; the rest are passed verbatim as the argv tail.
-- Empty arg list is rejected (no command to run).
--
-- Authorization (S1): the program path is passed to
-- 'PureClaw.Security.Command.authorize' against '_env_policy' BEFORE
-- the seam is invoked. Rejection yields
-- @'Left' ('TabSpawnAuthDenied' ...)@; no subprocess is spawned (the
-- factory short-circuits at the smart-constructor call).
mkShellTab
  :: BackendIO -> AgentEnv -> TabIndex -> [Text]
  -> IO (Either TabError TabHandle)
mkShellTab bio env idx args = case args of
  [] -> pure (Left (TabSpawnAuthDenied PublicAuthError))
  (prog : rest) -> case authorize (_env_policy env) (T.unpack prog) rest of
    Left _err -> authDenied
    Right authCmd -> do
      let nameRaw = defaultBackendName "shell" args
      case Parse.sanitizeTabName nameRaw of
        Left nameErr -> pure (Left (TabInvalidName nameErr))
        Right nameTxt -> do
          mkResult <- _bio_mkShell bio authCmd
          finishSpawn env idx (TabName nameTxt) (TkRawShell TbLocal) mkResult


-- ---------------------------------------------------------------------------
-- KindSsh sub-factory (S2 \/ S3 \/ S4)
-- ---------------------------------------------------------------------------

-- | Spawn an SSH backend tab.
--
-- Args layout: @[\"user\@host\", program, arg1, ...]@. The first arg is
-- @user\@host@; the remaining args are the remote command (program +
-- argv).
--
-- Validation pipeline:
--
-- 1. The first arg must contain exactly one @\@@ separating a
--    non-empty user from a non-empty host.
-- 2. The host portion passes through
--    'PureClaw.Backend.SSH.mkSshHost' (S2 \/ S3 — rejects whitespace,
--    leading dashes, NUL bytes, shell metacharacters, etc.).
-- 3. The local @ssh@ binary path is hardcoded to @\"ssh\"@ (the
--    'PureClaw.Security.Command.authorize' check confirms it is in
--    '_sp_allowedCommands').
-- 4. The remote command (head + tail) is authorized via
--    'PureClaw.Backend.SSH.authorizeRemote' against
--    '_sp_allowedRemoteCommands' (S2 — independent allowlist).
-- 5. The SSH identity is sourced from the Vault slot named by
--    '_rc_sshIdentityKey' (S4 — NO inline identity acceptance). The
--    Vault returns raw bytes; we materialise them at a 'SafeKeyPath'
--    via 'PureClaw.Security.Path.mkSafeKeyPath'.
--
-- /Implementation note (v1 minimal):/ the v1 Vault → 'SafeKeyPath'
-- translation is currently a missing-feature stub. v1 requires the
-- caller to supply the key path via configuration rather than the
-- Vault payload; the Vault slot lookup happens for S4 audit
-- compliance (the missing-slot path yields
-- @'Left' ('TabSpawnAuthDenied' ...)@ as the design mandates) and
-- the path materialisation is deferred to WU9. For WU8 we surface a
-- clean PublicError; the production path lands in WU9 alongside the
-- auto-spawn UX.
mkSshTab
  :: BackendIO -> AgentEnv -> TabIndex -> [Text]
  -> IO (Either TabError TabHandle)
mkSshTab bio env idx args = case args of
  [] -> authDenied
  (userHost : remoteCmd) ->
    case parseUserAtHost userHost of
      Left _ -> authDenied
      Right (user, hostText) ->
        case SSH.mkSshHost hostText of
          Left _ -> authDenied
          Right host -> case remoteCmd of
            [] -> authDenied
            (remoteProg : remoteArgs) ->
              case SSH.authorizeRemote (_env_policy env) (T.unpack remoteProg) remoteArgs of
                Left _ -> authDenied
                Right remote ->
                  case authorize (_env_policy env) "ssh" [] of
                    Left _ -> authDenied
                    Right sshCmd -> do
                      mIdent <- resolveSshIdentity env
                      case mIdent of
                        Left _ -> authDenied
                        Right identityPath -> do
                          let tgt = SSH.SshTarget
                                { SSH._st_user     = user
                                , SSH._st_host     = host
                                , SSH._st_port     = Nothing
                                , SSH._st_identity = identityPath
                                }
                              nameRaw = "ssh tab"
                          case Parse.sanitizeTabName nameRaw of
                            Left nameErr -> pure (Left (TabInvalidName nameErr))
                            Right nameTxt -> do
                              mkResult <- _bio_mkSsh bio tgt sshCmd remote
                              let sshCfg = SshConfig
                                    { _sc_user = user
                                    , _sc_host = hostText
                                    , _sc_port = Nothing
                                    }
                              finishSpawn env idx (TabName nameTxt) (TkRawShell (TbSsh sshCfg)) mkResult

-- | Parse a @user\@host@ string into its components.
--
-- Accepts exactly one @\@@ separating a non-empty user from a non-empty
-- host. Multi-@\@@ inputs (e.g. @\"a\@b\@c\"@) are rejected as
-- malformed — there is no scenario where a user identifier legitimately
-- contains an @\@@.
parseUserAtHost :: Text -> Either () (Text, Text)
parseUserAtHost t = case T.splitOn "@" t of
  [u, h] | not (T.null u) && not (T.null h) -> Right (u, h)
  _                                          -> Left ()

-- | Look up the SSH identity from the configured Vault slot.
--
-- Returns @'Right' path@ when the slot exists and the byte payload was
-- successfully materialised to a 'SafeKeyPath'; otherwise 'Left'.
--
-- The v1 path-materialisation step is intentionally a clean failure:
-- 'PureClaw.Security.Path.mkSafeKeyPath' requires a 'KeysRoot' and an
-- on-disk file with mode @0400@, which the v1 Vault payload doesn't
-- yet produce. The WU9 work item that delivers production SSH spawns
-- is the right place to add the materialisation (write-to-temp +
-- chmod + 'mkSafeKeyPath'). For WU8 we focus on the S4 audit invariant
-- (the slot lookup) and surface @'Left' ('TabSpawnAuthDenied' ...)@
-- when materialisation can't complete.
resolveSshIdentity :: AgentEnv -> IO (Either () SafeKeyPath)
resolveSshIdentity env = do
  let slot = _rc_sshIdentityKey (_env_routingConfig env)
  mVault <- readIORef (_env_vault env)
  case mVault of
    Nothing    -> pure (Left ())  -- S4: no vault configured
    Just vault -> do
      r <- _vh_get vault slot
      case r of
        Left _      -> pure (Left ())  -- S4: missing slot
        Right _bytes ->
          -- v1 minimal: surface a clean S4-shaped failure rather than
          -- materialising the byte payload to disk. The Vault lookup
          -- itself happened (S4 audit invariant satisfied — we did
          -- read the slot named by _rc_sshIdentityKey). The on-disk
          -- materialisation (write-to-temp + chmod + 'mkSafeKeyPath')
          -- lands in WU9 alongside the production SSH spawn UX.
          pure (Left ())


-- ---------------------------------------------------------------------------
-- KindTmux sub-factory (S3)
-- ---------------------------------------------------------------------------

-- | Spawn a tmux Attach backend tab.
--
-- Args layout: @[\"session:window[.pane]\"]@. The first arg encodes
-- the tmux target; remaining args are ignored (tmux Attach has no
-- argv tail — the attach key spec is implicit).
--
-- Validation (S3):
--
-- 1. The single arg is split on @\":\"@ and @\".\"@ to extract
--    session, window, and optional pane.
-- 2. Each component passes through its corresponding smart constructor
--    ('mkTmuxSession', 'mkTmuxWindow', 'mkTmuxPane') which reject
--    empty inputs, leading dashes, NUL bytes, non-ASCII, and
--    out-of-charset characters.
-- 3. The local @tmux@ binary is authorized via 'authorize' (with the
--    static @\"tmux\"@ program path).
mkTmuxTab
  :: BackendIO -> AgentEnv -> TabIndex -> [Text]
  -> IO (Either TabError TabHandle)
mkTmuxTab bio env idx args = case args of
  [] -> pure (Left (TabSpawnAuthDenied PublicAuthError))
  (targetSpec : _ignored) ->
    case parseTmuxTarget targetSpec of
      Left _ -> pure (Left (TabSpawnAuthDenied PublicAuthError))
      Right tgt ->
        case authorize (_env_policy env) "tmux" [] of
          Left _ -> authDenied
          Right tmuxCmd -> do
            let loc = Tmux.LocalHost tmuxCmd
                nameRaw = "tmux tab"
            case Parse.sanitizeTabName nameRaw of
              Left nameErr -> pure (Left (TabInvalidName nameErr))
              Right nameTxt -> do
                mkResult <- _bio_mkTmux bio loc tgt
                let tmuxCfg = tmuxTargetToConfig tgt
                finishSpawn env idx (TabName nameTxt) (TkRawShell (TbTmux tmuxCfg)) mkResult

-- | Parse a tmux target spec of the form
-- @\"session\"@, @\"session:window\"@, or @\"session:window.pane\"@.
--
-- Each component is validated via its smart constructor; on any
-- rejection the entire parse fails. The window component is required
-- (a bare session has no attachable window in tmux's Attach-mode
-- model); the pane component is optional.
parseTmuxTarget :: Text -> Either InvalidOptionDetail Tmux.TmuxTarget
parseTmuxTarget spec = case T.splitOn ":" spec of
  [sessTxt, winSpec] -> do
    session <- Tmux.mkTmuxSession sessTxt
    case T.splitOn "." winSpec of
      [winTxt] -> do
        window <- Tmux.mkTmuxWindow winTxt
        Right Tmux.TmuxTarget
          { Tmux._tt_session = session
          , Tmux._tt_window  = window
          , Tmux._tt_pane    = Nothing
          }
      [winTxt, paneTxt] -> do
        window <- Tmux.mkTmuxWindow winTxt
        pane   <- Tmux.mkTmuxPane paneTxt
        Right Tmux.TmuxTarget
          { Tmux._tt_session = session
          , Tmux._tt_window  = window
          , Tmux._tt_pane    = Just pane
          }
      _ -> Left (InvalidOptionDetail "tmux target: malformed window.pane")
  _ -> Left (InvalidOptionDetail "tmux target: expected session:window[.pane]")


-- ---------------------------------------------------------------------------
-- KindContainer sub-factory (S9)
-- ---------------------------------------------------------------------------

-- | Spawn a container exec backend tab.
--
-- Validation pipeline:
--
-- 1. The @args@ list is checked against 'Container.containerArgsDenylist'
--    (S9 — rejects @--privileged@, @--cap-add@, @--volume@, etc.).
-- 2. The container engine binary name (from 'ContainerSpec._cs_engine')
--    is authorized via 'authorize' against '_env_policy'.
-- 3. The full exec argv is constructed via
--    'Container.buildContainerExecArgv' with a mandatory @--@ separator
--    between the container target and the harness binary (S9 — prevents
--    argument injection).
-- 4. The authorized command is passed to '_bio_mkContainer' (which in
--    production spawns a local pipe via
--    'PureClaw.Backend.Local.mkLocalBackendHandle').
mkContainerTab
  :: BackendIO -> AgentEnv -> TabIndex -> ContainerSpec -> [Text]
  -> IO (Either TabError TabHandle)
mkContainerTab bio env idx cs args = do
  -- S9: check args against denylist before any subprocess spawn.
  case Container.checkContainerArgs args of
    Left _denied -> authDenied
    Right () ->
      let engineBin = T.unpack (Container.containerEngineBinary (_cs_engine cs))
      in case authorize (_env_policy env) engineBin [] of
           Left _ -> authDenied
           Right authCmd -> do
             let nameRaw = "container " <> Container.containerEngineBinary (_cs_engine cs)
             case Parse.sanitizeTabName nameRaw of
               Left nameErr -> pure (Left (TabInvalidName nameErr))
               Right nameTxt -> do
                 mkResult <- _bio_mkContainer bio authCmd
                 finishSpawn env idx (TabName nameTxt)
                   (TkRawShell (TbContainer cs)) mkResult


-- ---------------------------------------------------------------------------
-- Shared spawn finishing logic (drainer + writer)
-- ---------------------------------------------------------------------------

-- | Wrap a freshly-constructed 'BackendHandle' in per-tab state, fork
-- the drainer + writer threads, and build the public 'TabHandle'.
--
-- Shared by all three sub-factories (KindShell \/ KindSsh \/ KindTmux)
-- because the post-construction wiring is identical.
finishSpawn
  :: AgentEnv -> TabIndex -> TabName -> TabKind
  -> Either BackendError BackendHandle
  -> IO (Either TabError TabHandle)
finishSpawn _env _idx _name _kind (Left err) =
  pure (Left (TabBackendConstructFailed err))
finishSpawn env idx name kind (Right bh) = do
  state <- allocState env bh
  now <- getCurrentTime
  writeIORef (_bts_statusRef state) (Idle now)
  drainRunner  <- _env_fork env (drainerLoop env idx state)
  writeIORef (_bts_drainRunner state) (Just drainRunner)
  writerRunner <- _env_fork env (writerLoop state)
  writeIORef (_bts_writerRunner state) (Just writerRunner)
  pure (Right (mkHandle env idx name kind state))

-- | Allocate the per-tab state. The bounded outbound queue's capacity
-- comes from '_rc_inputQueueBound' so the H4 \"non-blocking send\"
-- contract is configurable.
allocState :: AgentEnv -> BackendHandle -> IO BackendTabState
allocState env bh = do
  let rc = _env_routingConfig env
  sendQ      <- newTBQueueIO (fromIntegral (_rc_inputQueueBound rc))
  drainRef   <- newIORef Nothing
  writerRef  <- newIORef Nothing
  closedRef  <- newIORef False
  -- Sentinel: status starts 'Active' at allocation; the spawn finisher
  -- writes 'Idle now' before mkTabBackend returns.
  statRef    <- newIORef Active
  pure BackendTabState
    { _bts_backend      = bh
    , _bts_sendQ        = sendQ
    , _bts_drainRunner  = drainRef
    , _bts_writerRunner = writerRef
    , _bts_closed       = closedRef
    , _bts_statusRef    = statRef
    }

-- | Build the public 'TabHandle' record from the per-tab state.
mkHandle :: AgentEnv -> TabIndex -> TabName -> TabKind -> BackendTabState -> TabHandle
mkHandle env idx name kind state = TabHandle
  { _tabHandle_index        = idx
  , _tabHandle_name         = name
  , _tabHandle_kind         = kind
  , _tabHandle_status       = readIORef (_bts_statusRef state)
  , _tabHandle_send         = sendBytes state
  , _tabHandle_enqueueSlash = enqueueSlashUnsupported
  , _tabHandle_close        = closeTabBackend env state
  }


-- ---------------------------------------------------------------------------
-- _tabHandle_send / _tabHandle_enqueueSlash
-- ---------------------------------------------------------------------------

-- | Enqueue a 'Text' payload onto the outbound queue. Non-blocking:
-- returns @'Left' ('TabConcurrencyLimit' 0)@ if the queue is full so
-- the dispatcher's send loop never blocks (H4).
--
-- The text is UTF-8 encoded and forwarded verbatim — including any
-- leading @\/@ — so a direct-inject like @\/N \/pwd@ reaches the
-- backend as the literal @\"\/pwd\"@ (I4: slash-prefix opaque to the
-- backend).
sendBytes :: BackendTabState -> Text -> IO (Either TabError ())
sendBytes state t = atomically (tryEnqueueSTM (_bts_sendQ state) (TE.encodeUtf8 t))

-- | STM body of 'sendBytes', factored out so tests can drive it inside
-- a larger transaction if needed.
tryEnqueueSTM :: TBQueue ByteString -> ByteString -> STM (Either TabError ())
tryEnqueueSTM q bs = do
  full <- isFullTBQueue q
  if full
    then pure (Left (TabConcurrencyLimit 0))
    else writeTBQueue q bs >> pure (Right ())

-- | '_tabHandle_enqueueSlash' for a backend tab: slash commands are
-- not supported, so we return @'Left' ('TabUnsupportedCommand' cmd)@
-- immediately without enqueueing (H13 \/ I4 contract).
enqueueSlashUnsupported :: SlashCommand -> IO (Either TabError ())
enqueueSlashUnsupported cmd = pure (Left (TabUnsupportedCommand cmd))


-- ---------------------------------------------------------------------------
-- _tabHandle_close — destructive close for backend tabs
-- ---------------------------------------------------------------------------

-- | Close a backend tab. Idempotent + never throws (H6, H7).
--
-- Both 'CloseGraceful' and 'CloseForce' are destructive (H9 — close is
-- already destructive for non-AI tabs, so @--force@ is a no-op
-- distinct from graceful only at the pattern-match level). The triad
-- below cancels both helper threads and then calls '_bh_close'. Each
-- step is wrapped in 'safeIgnore' so a misbehaving backend can't leak
-- an exception out of the never-throws contract.
closeTabBackend :: AgentEnv -> BackendTabState -> CloseMode -> IO ()
closeTabBackend _env state mode = do
  alreadyClosed <- atomicModifyIORef' (_bts_closed state) (True,)
  unless alreadyClosed $ do
    safeIgnore (cancelMaybeRunner (_bts_drainRunner state))
    safeIgnore (cancelMaybeRunner (_bts_writerRunner state))
    case mode of
      CloseGraceful -> safeIgnore (_bh_close (_bts_backend state))
      CloseForce    -> safeIgnore (_bh_close (_bts_backend state))

-- | Read the captured 'TabRunner' (set by 'mkTabBackendWith' after
-- fork) and invoke its cancel. Tolerant of the brief allocation\/fork
-- window when the IORef is still 'Nothing'.
cancelMaybeRunner :: IORef (Maybe TabRunner) -> IO ()
cancelMaybeRunner ref = do
  mRunner <- readIORef ref
  for_ mRunner _trun_cancel

-- | Best-effort: run an IO action and swallow synchronous failures.
-- The close path MUST be never-throws (H7), so every step is wrapped
-- defensively. 'AsyncCancelled' is also swallowed here because the
-- close handler is invoked from outside the helper threads; any
-- AsyncCancelled bubbling up through cancel itself is benign (the
-- target thread has already received the cancel).
safeIgnore :: IO () -> IO ()
safeIgnore m = do
  _ <- try @SomeException m
  pure ()


-- ---------------------------------------------------------------------------
-- Drainer thread — _bh_recv → FullMsg via _env_channelOutQ
-- ---------------------------------------------------------------------------

-- | Drainer-thread top-level. Wraps 'drainerStep' in 'safelyRun' so a
-- synchronous exception transitions the tab to 'Crashed' rather than
-- killing the parent thread, and so 'AsyncCancelled' propagates per
-- the C5 contract.
drainerLoop :: AgentEnv -> TabIndex -> BackendTabState -> IO ()
drainerLoop env idx state = safelyRun state loop
  where
    loop = do
      keepGoing <- drainerStep env idx state
      when keepGoing loop

-- | One iteration of the drainer. Reads '_bh_recv' (blocking on the
-- handle's default idle policy), emits a 'FullMsg' if the result is
-- non-empty and the tab is focused (D4 producer-side skip), then
-- returns whether the loop should continue.
--
-- The drainer terminates on 'RecvEof' (the backend's underlying pipe
-- closed) or 'RecvTruncated' (the recv-buffer cap was exceeded — the
-- caller cannot pull more bytes through this handle even if more are
-- queued). 'RecvSettled' and 'RecvTimedOut' continue the loop.
drainerStep :: AgentEnv -> TabIndex -> BackendTabState -> IO Bool
drainerStep env idx state = do
  result <- _bh_recv (_bts_backend state) Nothing
  let bs = recvBytes result
  unless (BS.null bs) $ do
    let txt = TE.decodeUtf8 bs
    unless (T.null (T.strip txt)) $ do
      -- D4 producer-side focus check: skip the enqueue work when the
      -- tab is not focused. The writer thread re-applies the predicate
      -- on dequeue (D3), so this is an optimisation only; correctness
      -- comes from the writer.
      curFocus <- readIORef (_env_focus env)
      when (shouldEmit curFocus (SrcTab idx)) $
        atomically $ writeTBQueue (_env_channelOutQ env)
                       (SrcTab idx, FullMsg idx txt)
  pure $ case result of
    RecvSettled   _ -> True
    RecvTimedOut  _ -> True
    RecvEof       _ -> False
    RecvTruncated _ -> False


-- ---------------------------------------------------------------------------
-- Writer thread — _bts_sendQ → _bh_send
-- ---------------------------------------------------------------------------

-- | Writer-thread top-level. Drains '_bts_sendQ' forever, forwarding
-- each chunk to '_bh_send'. Wrapped in 'safelyRun' for the same
-- AsyncCancelled \/ Crashed semantics as the drainer.
writerLoop :: BackendTabState -> IO ()
writerLoop state = safelyRun state loop
  where
    loop = do
      bs <- atomically (readTBQueue (_bts_sendQ state))
      -- '_bh_send' may block. We tolerate the block because the
      -- bounded '_bts_sendQ' keeps the producer side non-blocking;
      -- the writer is a single-purpose drainer and nothing else
      -- depends on its progress.
      _bh_send (_bts_backend state) bs
      loop


-- ---------------------------------------------------------------------------
-- safelyRun — shared exception handler for drainer + writer
-- ---------------------------------------------------------------------------

-- | Outer exception handler shared by both helper threads.
--
-- * 'AsyncCancelled' propagates (re-raised) so '_tabHandle_close'
--   semantics work correctly per C5.
-- * Other 'SomeException' transitions the tab to 'Crashed' (carrying
--   a redacted short label) and the helper thread exits.
safelyRun :: BackendTabState -> IO () -> IO ()
safelyRun state body = body `catch` handler
  where
    handler :: SomeException -> IO ()
    handler e
      | Just AsyncCancelled <- fromException e =
          throwIO e  -- propagate AsyncCancelled (C5)
      | otherwise =
          writeIORef (_bts_statusRef state)
                     (Crashed (PublicTabError "tab: backend loop crashed"))


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Compose a default friendly tab name for a backend tab.
--
-- 'mkShellTab' calls this with the first user-supplied arg as the
-- suffix, producing labels like @\"shell ls\"@. The empty-arg case is
-- handled at the call site, so the function only sees a non-empty
-- arg list.
defaultBackendName :: Text -> [Text] -> Text
defaultBackendName prefix args = case args of
  (a : _) -> prefix <> " " <> a
  -- Dead arm: callers short-circuit before reaching here. We keep the
  -- pattern total so a future call-site change can't silently produce
  -- a partial-match runtime crash.
  []      -> prefix <> " tab"

-- | Common authorization-denied short-circuit.
authDenied :: IO (Either TabError TabHandle)
authDenied = pure (Left (TabSpawnAuthDenied PublicAuthError))

-- | Project a parsed 'Tmux.TmuxTarget' to a serialisation-safe
-- 'TmuxConfig' for storage in 'TkRawShell'.
tmuxTargetToConfig :: Tmux.TmuxTarget -> TmuxConfig
tmuxTargetToConfig tgt = TmuxConfig
  { _tc_session = Tmux.getTmuxSession (Tmux._tt_session tgt)
  , _tc_window  = Tmux.getTmuxWindow  (Tmux._tt_window  tgt)
  , _tc_pane    = Tmux.getTmuxPane <$> Tmux._tt_pane tgt
  }
