-- |
-- Module      : PureClaw.Backend.Tmux
-- Description : Tmux Attach backend factory (WU10).
--
-- == Overview
--
-- 'mkTmuxBackendHandle' produces a 'Pty'-kind 'BackendHandle' that
-- attaches to a __pre-existing__ tmux window — either via a local
-- @tmux attach-session@ inside a PTY or via @ssh -tt user\@host tmux
-- attach-session@ inside a PTY. The factory never creates the window;
-- if the target session\/window does not exist at construction time it
-- returns @Left (BackendTmuxTargetMissing _)@ and spawns no further
-- subprocesses.
--
-- == Two phases at construction
--
-- 1. __Pin-resolve__ (TOCTOU mitigation, design doc § "Pinning to
--    stable ids"). Run @tmux display-message -p -t \'sess:win\'
--    \'#{window_id}\'@ as a one-shot (NOT a PTY); validate the stdout
--    against @^@[0-9]+$@. The pinned @@@@ID@ is what subsequent
--    @attach-session@ targets use. If a human later destroys and
--    re-creates the same-named window, the pinned @@@@ID@ will be
--    stale and the optional mid-session probe (DoD #21) surfaces a
--    'BackendBrokenTmuxTarget' rather than silently writing to the
--    new window.
-- 2. __Attach__. Spawn the tmux client inside a PTY via
--    'mkDrainerBackendHandle'. For 'LocalHost' the spawned program is
--    the local tmux binary; for 'RemoteHost' the spawned program is
--    ssh, with the remote tmux argv composed via
--    'PureClaw.Backend.SSH.buildSshArgv'.
--
-- == Detach-only close
--
-- '_bh_close' writes the tmux detach key sequence (Ctrl-B @d@ — bytes
-- @[0x02, 0x64]@) into the existing PTY and then calls the inner
-- handle's close. It does NOT open a new ssh hop, NOT issue
-- @kill-window@\/@kill-session@\/@kill-pane@. A pre-existing window
-- survives close. Idempotent and never throws.
--
-- == Mid-session destruction (DoD #21)
--
-- When '_to_brokenTargetCheck' is 'True', the wrapper around
-- '_bh_recv' re-resolves the pinned @@@@ID@ after a settled recv; if
-- the resolution returns a different @@@@ID@ (window destroyed and
-- re-created by some other actor) the next caller-visible operation
-- raises 'BackendException' with @_be_context = 'BcTmuxDetach'@ whose
-- @_be_cause@ wraps a 'BackendBrokenTmuxTarget' payload (via the
-- internal 'BrokenTmuxTargetException' carrier — recovered by tests
-- via 'fromException').
--
-- The check is OFF by default (the production cost of an extra
-- @display-message@ probe per recv is real); tests turn it on
-- explicitly. See @docs\/terminal-backend-abstractions.md@ DoD #21.
module PureClaw.Backend.Tmux
  ( -- * Smart-constructed name newtypes (constructors NOT exported)
    TmuxSession
  , TmuxWindow
  , TmuxPane
  , mkTmuxSession
  , mkTmuxWindow
  , mkTmuxPane
  , getTmuxSession
  , getTmuxWindow
  , getTmuxPane
    -- * Target + options
  , TmuxTarget (..)
  , TmuxOpts (..)
  , defaultTmuxOpts
    -- * Authorization split (sum type)
  , SshLocation (..)
    -- * Factories
  , mkTmuxBackendHandle
  , mkTmuxBackendHandleWith
    -- * Injection seam for the pin-resolve probe
  , TmuxIO (..)
  , realTmuxIO
    -- * Test seams: argv builders (no I/O)
  , buildPinResolveArgv
  , buildAttachArgv
    -- * Internal exception wrapper for 'BackendBrokenTmuxTarget'
  , BrokenTmuxTargetException (..)
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Control.Exception (Exception, SomeException, throwIO, toException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.Process.Typed qualified as P

import PureClaw.Backend.Pty
  ( PtyIO (..)
  , PtyOpenSpec (..)
  , mkDrainerBackendHandle
  )
import PureClaw.Backend.SSH
  ( RemoteCommand
  , SshTarget (..)
  , buildSshArgvFromParts
  , getRemoteProgram
  )
import PureClaw.Handles.Backend
  ( BackendContext (..)
  , BackendError (..)
  , BackendException (..)
  , BackendHandle (..)
  , BackendKind (..)
  , InvalidOptionDetail (..)
  , PtyOpts (..)
  , RecvResult (..)
  , TmuxTargetRef (..)
  , defaultPtyOpts
  , tmuxIdle
  , withConcurrentUseGuard
  )
import PureClaw.Security.Command
  ( AuthorizedCommand
  , getCommandProgram
  )
import PureClaw.Security.Path
  ( SafeRuntimePath
  , getSafeRuntimePath
  )

--------------------------------------------------------------------------------
-- Smart-constructed name newtypes
--------------------------------------------------------------------------------

-- | A validated tmux session name.
--
-- The constructor is intentionally NOT exported. Obtain a value only
-- via 'mkTmuxSession', which enforces the charset rules below.
--
-- Validation (matches 'mkTmuxWindow' \/ 'mkTmuxPane'):
--
-- 1. Empty rejected.
-- 2. Leading @-@ rejected (defends against argv injection at the tmux
--    binary).
-- 3. NUL byte rejected.
-- 4. Any non-ASCII byte rejected.
-- 5. Length must be <= 200.
-- 6. Permitted charset: @[A-Za-z0-9_./@:=+-]@.
newtype TmuxSession = TmuxSession Text
  deriving stock (Eq, Ord, Show)

-- | A validated tmux window name. See 'TmuxSession' for the validation
-- rules — they are identical.
newtype TmuxWindow = TmuxWindow Text
  deriving stock (Eq, Ord, Show)

-- | A validated tmux pane id (or pane name). See 'TmuxSession' for the
-- validation rules — they are identical.
newtype TmuxPane = TmuxPane Text
  deriving stock (Eq, Ord, Show)

-- | The ONLY way to construct a 'TmuxSession'.
--
-- See the haddock on 'TmuxSession' for the numbered validation rules.
mkTmuxSession :: Text -> Either InvalidOptionDetail TmuxSession
mkTmuxSession t = TmuxSession <$> validateTmuxName "TmuxSession" t

-- | The ONLY way to construct a 'TmuxWindow'.
--
-- See the haddock on 'TmuxSession' for the numbered validation rules.
mkTmuxWindow :: Text -> Either InvalidOptionDetail TmuxWindow
mkTmuxWindow t = TmuxWindow <$> validateTmuxName "TmuxWindow" t

-- | The ONLY way to construct a 'TmuxPane'.
--
-- See the haddock on 'TmuxSession' for the numbered validation rules.
mkTmuxPane :: Text -> Either InvalidOptionDetail TmuxPane
mkTmuxPane t = TmuxPane <$> validateTmuxName "TmuxPane" t

-- | Project a 'TmuxSession' to its 'Text' form for inclusion in tmux
-- argv. Not for logging — the human-readable name is not a secret but
-- the design treats names as routing data, not display surface.
getTmuxSession :: TmuxSession -> Text
getTmuxSession (TmuxSession t) = t

-- | Project a 'TmuxWindow' to its 'Text' form.
getTmuxWindow :: TmuxWindow -> Text
getTmuxWindow (TmuxWindow t) = t

-- | Project a 'TmuxPane' to its 'Text' form.
getTmuxPane :: TmuxPane -> Text
getTmuxPane (TmuxPane t) = t

-- | Shared validator for 'mkTmuxSession' \/ 'mkTmuxWindow' \/
-- 'mkTmuxPane'. The first argument is the prefix used in the
-- 'InvalidOptionDetail' message.
validateTmuxName :: Text -> Text -> Either InvalidOptionDetail Text
validateTmuxName ctx t
  | T.null t =
      reject "empty name"
  | T.head t == '-' =
      reject "leading dash"
  | T.any (== '\NUL') t =
      reject "NUL byte"
  | T.any (not . isAscii) t =
      reject "non-ASCII"
  | T.length t > 200 =
      reject "too long (> 200)"
  | T.any (not . allowed) t =
      reject "disallowed character"
  | otherwise =
      Right t
  where
    reject :: Text -> Either InvalidOptionDetail Text
    reject msg = Left (InvalidOptionDetail (ctx <> ": " <> msg))

    allowed :: Char -> Bool
    allowed c =
      isAsciiLower c
        || isAsciiUpper c
        || isDigit c
        || c == '_'
        || c == '.'
        || c == '/'
        || c == '@'
        || c == ':'
        || c == '='
        || c == '+'
        || c == '-'

--------------------------------------------------------------------------------
-- TmuxTarget / TmuxOpts
--------------------------------------------------------------------------------

-- | The session, window, and optional pane the backend will attach to.
data TmuxTarget = TmuxTarget
  { _tt_session :: !TmuxSession
  , _tt_window  :: !TmuxWindow
  , _tt_pane    :: !(Maybe TmuxPane)
  } deriving stock (Eq, Show)

-- | Construction options for the tmux backend.
--
-- '_to_socketPath' pins the tmux server socket (@tmux -S \<path\>@);
-- when 'Nothing', the system-default socket is used (a v1 limitation on
-- multi-tenant hosts — see design doc § "V1 Known Limitations").
--
-- '_to_brokenTargetCheck' is the opt-in flag for the DoD #21 mid-session
-- destruction probe; default 'False'. When 'True', every @RecvSettled@
-- triggers a fresh pin-resolve probe and a different @@\<id\>@ surfaces
-- as 'BackendException' carrying a 'BackendBrokenTmuxTarget' payload.
--
-- (This field is a v1 superset over the active plan's WU10 spec —
-- needed to gate the cost of the extra @display-message@ probe per
-- recv. Production callers leave it 'False'; the WU10 DoD #21 test
-- enables it explicitly.)
data TmuxOpts = TmuxOpts
  { _to_pty                :: !PtyOpts
  , _to_socketPath         :: !(Maybe SafeRuntimePath)
  , _to_brokenTargetCheck  :: !Bool
  }

-- | Default 'TmuxOpts': 'defaultPtyOpts' with 'tmuxIdle' as the idle
-- policy, no socket pinning, and the mid-session probe disabled.
defaultTmuxOpts :: TmuxOpts
defaultTmuxOpts = TmuxOpts
  { _to_pty                = defaultPtyOpts { _pto_idle = tmuxIdle }
  , _to_socketPath         = Nothing
  , _to_brokenTargetCheck  = False
  }

--------------------------------------------------------------------------------
-- SshLocation
--------------------------------------------------------------------------------

-- | Type-enforced authorization split for the two operating modes.
--
-- * 'LocalHost' carries a local 'AuthorizedCommand' (the @tmux@ binary).
-- * 'RemoteHost' carries: the 'SshTarget' (user, host, identity), the
--   local 'AuthorizedCommand' (the @ssh@ binary, allowlisted via
--   'PureClaw.Security.Command.authorize'), AND the 'RemoteCommand' (the
--   remote @tmux@ binary, allowlisted via
--   'PureClaw.Backend.SSH.authorizeRemote'). Both authorizations are
--   required to construct the value — the factory cannot be called
--   with only one or with a local 'AuthorizedCommand' standing in for
--   the remote tmux.
data SshLocation
  = LocalHost !AuthorizedCommand
  | RemoteHost !SshTarget !AuthorizedCommand !RemoteCommand

-- | The SINGLE permitted close action for a tmux Attach-mode backend
-- handle.
--
-- The constructor is intentionally NOT exported — there is no way (and
-- no API) to ask the handle to @kill-window@, @kill-session@, or
-- @kill-pane@. The close path consumes a 'TmuxCloseAction' value and
-- 'TmuxDetach' is the only inhabitant, so the only thing the close
-- path can do is write the detach key sequence into the existing PTY.
--
-- See @docs\/terminal-backend-abstractions.md@ § "Tmux Attach mode"
-- and the active plan § WU10.
data TmuxCloseAction = TmuxDetach

--------------------------------------------------------------------------------
-- TmuxIO injection seam
--------------------------------------------------------------------------------

-- | Injection seam for the pin-resolve probe.
--
-- Production uses 'realTmuxIO', which shells out to @tmux
-- display-message -p -t ... '#{window_id}'@ (or its remote analogue
-- via @ssh user\@host -- tmux ...@). Tests inject a fake that returns
-- a scripted 'Right' \/ 'Left' for each call.
newtype TmuxIO = TmuxIO
  { _tio_resolvePin :: SshLocation -> TmuxTarget -> Maybe SafeRuntimePath -> IO (Either BackendError Text)
  }

-- | Production 'TmuxIO': spawns the pin-resolve subprocess via
-- @typed-process@'s 'P.readProcessStdout_'.
--
-- For 'LocalHost' the program is the local tmux binary; for
-- 'RemoteHost' it is ssh, with the remote tmux argv built via
-- 'PureClaw.Backend.SSH.buildSshArgv' (shell-quoted on the remote
-- side).
--
-- The pin-resolve probe is NEVER spawned in a PTY — a one-shot pipe
-- is sufficient (and avoids burning a PTY on each construction).
realTmuxIO :: TmuxIO
realTmuxIO = TmuxIO
  { _tio_resolvePin = resolvePinReal
  }

-- | Spawn the pin-resolve probe as a one-shot subprocess and validate
-- the stdout against the expected @@@@\<digits\>@ regex.
--
-- A non-zero exit, an empty stdout, or a stdout that does not match
-- the regex collapses to @Left (BackendTmuxTargetMissing _)@. This is
-- intentional: from the caller\'s point of view, "the window does not
-- exist" and "tmux returned malformed output" are indistinguishable
-- — both mean "do not attach".
resolvePinReal
  :: SshLocation
  -> TmuxTarget
  -> Maybe SafeRuntimePath
  -> IO (Either BackendError Text)
resolvePinReal loc tgt mSock = do
  let (prog, argv) = buildPinResolveArgv loc tgt mSock
      config = P.setStdin (P.byteStringInput BL.empty)
             $ P.setStderr P.nullStream
             $ P.proc prog argv
  r <- try @SomeException (P.readProcessStdout config)
  let missing = Left (BackendTmuxTargetMissing (tmuxTargetRef tgt))
  case r of
    Left _ -> pure missing
    Right (ExitSuccess, bsLazy) ->
      let bs   = BL.toStrict bsLazy
          line = T.strip (TE.decodeUtf8 bs)
      in if isPinId line then pure (Right line) else pure missing
    Right (ExitFailure _, _) -> pure missing

-- | Predicate: does the supplied 'Text' match the @^@[0-9]+$@ regex
-- that tmux\'s @#{window_id}@ format string produces?
--
-- We deliberately accept @@@@<digits>@ rather than the pane-id form
-- @%@<digits>@ — the pin we cache is the window id, even when the
-- caller also specified a pane.
isPinId :: Text -> Bool
isPinId t = case T.unpack t of
  '@' : rest@(_:_) -> all isAsciiDigit rest
  _                -> False
  where
    isAsciiDigit c = isAscii c && isDigit c

--------------------------------------------------------------------------------
-- argv builders
--------------------------------------------------------------------------------

-- | Build the argv list for the pin-resolve subprocess.
--
-- Exported as the test seam. The returned tuple is @(program, args)@,
-- ready to splice into a 'P.proc' call. For 'LocalHost' the program
-- is the local tmux binary path (from the local 'AuthorizedCommand');
-- for 'RemoteHost' the program is ssh, and the tmux invocation is
-- spliced into the argv via 'PureClaw.Backend.SSH.buildSshArgv'
-- (which is also the only legal way to construct the hardened ssh
-- prefix).
--
-- The probe always asks for @#{window_id}@ specifically (NOT pane
-- id), even when '_tt_pane' is set: the pin is the window-level id.
buildPinResolveArgv
  :: SshLocation
  -> TmuxTarget
  -> Maybe SafeRuntimePath
  -> (FilePath, [String])
buildPinResolveArgv loc tgt mSock = case loc of
  LocalHost authCmd ->
    let prog = getCommandProgram authCmd
        argv = socketArgs mSock
            <> [ "display-message"
               , "-p"
               , "-t", T.unpack targetExpr
               , "#{window_id}"
               ]
    in (prog, argv)
  RemoteHost sshTgt sshAuthCmd remoteCmd ->
    let prog       = getCommandProgram sshAuthCmd
        remoteProg = getRemoteProgram remoteCmd
        remoteArgs = map T.pack (socketArgs mSock)
                  <> [ "display-message"
                     , "-p"
                     , "-t", targetExpr
                     , "#{window_id}"
                     ]
        argv = buildSshArgvFromParts sshTgt remoteProg remoteArgs
                 Nothing Nothing False
    in (prog, argv)
  where
    targetExpr :: Text
    targetExpr =
      getTmuxSession (_tt_session tgt)
        <> ":"
        <> getTmuxWindow (_tt_window tgt)

-- | Build the argv for the attach-session step.
--
-- Returned as @(program, args)@ — ready for 'PtyOpenSpec'. The pin
-- argument is the @@@\<id\>@ produced by the pin-resolve step; it is
-- spliced as the @-t@ target so the attach is bound to the stable id,
-- not the user-facing @session:window@ name. (Mid-session window
-- destruction is therefore detectable: the @@@\<id\>@ probe and the
-- attach diverge.)
--
-- For 'RemoteHost' the program path comes from the local @ssh@
-- 'AuthorizedCommand'; the remote tmux invocation is spliced into the
-- ssh argv via 'buildSshArgv', so the program-path and arg quoting
-- (DoD #11) goes through 'PureClaw.Internal.ShellQuote.shellQuote' on
-- the remote half.
buildAttachArgv
  :: SshLocation
  -> Text               -- ^ the pinned @@@\<id\>@
  -> Maybe SafeRuntimePath
  -> (FilePath, [String])
buildAttachArgv loc pinned mSock = case loc of
  LocalHost authCmd ->
    let prog = getCommandProgram authCmd
        argv = socketArgs mSock
            <> [ "attach-session"
               , "-t", T.unpack pinned
               ]
    in (prog, argv)
  RemoteHost sshTgt sshAuthCmd remoteCmd ->
    let prog       = getCommandProgram sshAuthCmd
        remoteProg = getRemoteProgram remoteCmd
        remoteArgs = map T.pack (socketArgs mSock)
                  <> [ "attach-session"
                     , "-t", pinned
                     ]
        argv = buildSshArgvFromParts sshTgt remoteProg remoteArgs
                 Nothing Nothing True
    in (prog, argv)

-- | The @-S \<path\>@ prefix when '_to_socketPath' is set.
socketArgs :: Maybe SafeRuntimePath -> [String]
socketArgs Nothing  = []
socketArgs (Just p) = ["-S", getSafeRuntimePath p]

-- | Build a 'TmuxTargetRef' from a 'TmuxTarget' for error reporting.
--
-- 'TmuxTargetRef' carries 'Text' fields (the design picked the
-- 'Text'-only carrier in WU1 to avoid an import cycle); we project
-- the validated newtypes back to 'Text' here.
tmuxTargetRef :: TmuxTarget -> TmuxTargetRef
tmuxTargetRef tgt = TmuxTargetRef
  (getTmuxSession (_tt_session tgt))
  (getTmuxWindow  (_tt_window  tgt))
  (getTmuxPane <$> _tt_pane tgt)

--------------------------------------------------------------------------------
-- BrokenTmuxTargetException — internal carrier for BackendBrokenTmuxTarget
--------------------------------------------------------------------------------

-- | Internal exception used as the @_be_cause@ when the mid-session
-- destruction probe fires.
--
-- 'BackendException._be_cause' has type 'SomeException', so to embed a
-- structured 'BackendBrokenTmuxTarget' payload we wrap it in this
-- typed exception. Tests recover the payload via
-- 'Control.Exception.fromException' on the outer 'BackendException'\'s
-- cause.
newtype BrokenTmuxTargetException = BrokenTmuxTargetException TmuxTargetRef
  deriving stock (Show, Eq)

instance Exception BrokenTmuxTargetException

--------------------------------------------------------------------------------
-- Factories
--------------------------------------------------------------------------------

-- | Construct a tmux Attach backend, using 'realPtyIO' for the attach
-- step and 'realTmuxIO' for the pin-resolve probe.
--
-- See 'mkTmuxBackendHandleWith' for the full semantics; this is the
-- production entry point.
mkTmuxBackendHandle
  :: PtyIO
  -> SshLocation
  -> TmuxTarget
  -> TmuxOpts
  -> IO (Either BackendError BackendHandle)
mkTmuxBackendHandle = mkTmuxBackendHandleWith realTmuxIO

-- | Construct a tmux Attach backend with caller-supplied 'TmuxIO' and
-- 'PtyIO'. Test seam.
--
-- Steps:
--
-- 1. Run the pin-resolve probe via @_tio_resolvePin@. On failure
--    surface the error as-is (typically
--    @Left (BackendTmuxTargetMissing _)@; the SSH-hop case may surface
--    @Left (BackendSshConnectFailed _)@ from the fake or production
--    'TmuxIO').
-- 2. Compose the attach argv via 'buildAttachArgv' against the pinned
--    @@@\<id\>@ from step 1.
-- 3. Delegate to 'mkDrainerBackendHandle' to spawn the PTY + drainer.
-- 4. Wrap the resulting handle: substitute '_bh_close' for the
--    detach-key write, optionally re-arm the mid-session probe in
--    '_bh_recv', and apply 'withConcurrentUseGuard'.
mkTmuxBackendHandleWith
  :: TmuxIO
  -> PtyIO
  -> SshLocation
  -> TmuxTarget
  -> TmuxOpts
  -> IO (Either BackendError BackendHandle)
mkTmuxBackendHandleWith tio pio loc tgt opts = do
  pinResult <- _tio_resolvePin tio loc tgt (_to_socketPath opts)
  case pinResult of
    Left e -> pure (Left e)
    Right pinned -> do
      let (prog, argv) = buildAttachArgv loc pinned (_to_socketPath opts)
          ptyOpts = _to_pty opts
          spec = PtyOpenSpec
            { _pos_program = prog
            , _pos_args    = map T.pack argv
            , _pos_env     = _pto_env ptyOpts
            , _pos_cwd     = _pto_cwd ptyOpts
            , _pos_cols    = _pto_cols ptyOpts
            , _pos_rows    = _pto_rows ptyOpts
            }
      inner <- mkDrainerBackendHandle pio ptyOpts spec Pty
      case inner of
        Left e   -> pure (Left e)
        Right bh -> do
          wrapped <- wrapTmuxHandle tio loc tgt opts pinned bh
          Right <$> withConcurrentUseGuard wrapped

-- | Wrap a freshly-constructed PTY 'BackendHandle' with the tmux-
-- specific invariants:
--
-- * @_bh_close@ writes Ctrl-B @d@ into the existing PTY, then calls
--   the inner close. Idempotent (MVar-guarded), never throws.
-- * @_bh_recv@ optionally re-runs the pin-resolve probe after a
--   settled recv when @_to_brokenTargetCheck@ is 'True'. If the
--   probe returns a different @@@\<id\>@, the next recv (or send)
--   surfaces 'BackendException' carrying
--   'BrokenTmuxTargetException'.
wrapTmuxHandle
  :: TmuxIO
  -> SshLocation
  -> TmuxTarget
  -> TmuxOpts
  -> Text                     -- ^ the pinned @@@\<id\>@ from construction
  -> BackendHandle
  -> IO BackendHandle
wrapTmuxHandle tio loc tgt opts pinnedAtCtor bh = do
  closeLock <- newMVar ()
  closedRef <- newIORef False
  brokenRef <- newIORef False     -- latches True once probe disagrees
  let trackedRecv mIdle = do
        -- Pre-check: if a prior probe already detected divergence,
        -- raise immediately (don't even talk to the PTY).
        wasBroken <- readIORef brokenRef
        if wasBroken
          then throwBroken
          else do
            res <- _bh_recv bh mIdle
            postCheck res
            pure res

      postCheck :: RecvResult ByteString -> IO ()
      postCheck r
        | _to_brokenTargetCheck opts = case r of
            RecvSettled _ -> do
              probe <- _tio_resolvePin tio loc tgt (_to_socketPath opts)
              case probe of
                Right newPin
                  | newPin /= pinnedAtCtor -> do
                      writeIORef brokenRef True
                      throwBroken
                  | otherwise -> pure ()
                Left _ -> do
                  -- Probe failed entirely — treat as broken.
                  writeIORef brokenRef True
                  throwBroken
            _ -> pure ()
        | otherwise = pure ()

      trackedSend bs = do
        wasBroken <- readIORef brokenRef
        if wasBroken
          then throwBroken
          else _bh_send bh bs

      performClose :: TmuxCloseAction -> IO ()
      performClose TmuxDetach = do
        -- Ctrl-B (0x02) + 'd' (0x64). Tmux's default prefix +
        -- detach-client binding. Write failures are non-fatal:
        -- the transport may already be dead. We swallow the
        -- exception to honour the "_bh_close never throws"
        -- contract.
        _ <- try @SomeException (_bh_send bh (BS.pack [0x02, 0x64]))
        -- Defensive: the inner close is documented total today, but
        -- the contract on this wrapper is "MUST NOT throw". Swallow
        -- any exception escaping the inner close so a future
        -- regression cannot silently break the wrapper contract.
        _ <- try @SomeException (_bh_close bh)
        pure ()

      detachClose = modifyMVar_ closeLock $ \() -> do
        wasClosed <- readIORef closedRef
        if wasClosed
          then pure ()
          else do
            writeIORef closedRef True
            performClose TmuxDetach

      throwBroken :: IO a
      throwBroken = throwIO $ BackendException
        BcTmuxDetach
        (toException (BrokenTmuxTargetException (tmuxTargetRef tgt)))

  pure bh
    { _bh_name  = "tmux-attach"
    , _bh_send  = trackedSend
    , _bh_recv  = trackedRecv
    , _bh_close = detachClose
    }
