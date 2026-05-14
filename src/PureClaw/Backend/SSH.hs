-- |
-- Module      : PureClaw.Backend.SSH
-- Description : SSH backend factories with hardened defaults (WU9).
--
-- == Overview
--
-- Two factories produce a real 'BackendHandle' over an @ssh@ subprocess:
--
-- * 'mkSshBackendHandle' — 'Pty' kind. Conversational; spawns @ssh -tt@
--   inside a local PTY and delegates to
--   'PureClaw.Backend.Pty.mkDrainerBackendHandle' for the drainer + STM
--   idle state machine.
-- * 'mkSshPipeBackendHandle' — 'Pipe' kind. One-shot; mirrors the pipe
--   spawn pattern in "PureClaw.Backend.Local" (OS-level stderr merge,
--   drain to EOF) but composes the hardened @ssh@ argv around the
--   already-authorized remote 'RemoteCommand'.
--
-- == Hardened argv (callers cannot opt out)
--
-- For both factories the @ssh@ command line includes the security
-- defaults enumerated in
-- @docs\/terminal-backend-abstractions.md@ § "SSH Security Defaults":
-- @-F /dev/null@, @StrictHostKeyChecking=accept-new@, @BatchMode=yes@,
-- @IdentitiesOnly=yes@, @ConnectTimeout=10@, @ServerAliveInterval=30@,
-- @ServerAliveCountMax=3@, @ForwardX11=no@, @ForwardX11Trusted=no@,
-- @ForwardAgent=no@, @PermitLocalCommand=no@.
--
-- The remote program path AND every remote argument are
-- shell-quoted via 'PureClaw.Internal.ShellQuote.shellQuote' before
-- being spliced into the argv — the remote login shell re-parses the
-- combined string, so quoting on the local side is the only line of
-- defense against argument-list injection.
--
-- == v1 credential model
--
-- v1 supports only passphrase-less @ssh@ keys; the caller is
-- responsible for writing the key file at 'SafeKeyPath' (mode 0400)
-- before constructing a backend. The Vault-backed credential helper
-- that decrypts a key into an ephemeral 'SafeKeyPath' is out of scope
-- for WU9 — this module accepts an already-validated 'SafeKeyPath'.
--
-- See @docs\/terminal-backend-abstractions.md@ § "v1 credential model
-- (passphrase-less keys)".
module PureClaw.Backend.SSH
  ( -- * Hosts
    SshHost
  , mkSshHost
  , getSshHost
    -- * Targets
  , SshTarget (..)
    -- * Control-master options
  , ControlOpts (..)
    -- * Construction options
  , SshOpts (..)
  , SshPipeOpts (..)
  , defaultSshOpts
  , defaultSshPipeOpts
    -- * Remote command authorization
  , RemoteCommand
  , authorizeRemote
  , getRemoteProgram
  , getRemoteArgs
    -- * Factories
  , mkSshBackendHandle
  , mkSshPipeBackendHandle
    -- * Control-master lifecycle
  , closeSshMultiplex
    -- * Test seam (argv construction)
  , buildSshArgv
  , buildSshArgvFromParts
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Control.Exception (SomeException, throwIO, toException, try)
import Control.Exception qualified as Exception
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAscii, isDigit, isAlphaNum)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (Handle, hClose)
import System.Posix.IO qualified as PosixIO
import System.Process.Typed qualified as P

import PureClaw.Backend.Pty
  ( PtyIO (..)
  , PtyOpenSpec (..)
  , mkDrainerBackendHandle
  )
import PureClaw.Core.Types (AllowList (..), CommandName (..))
import PureClaw.Handles.Backend
  ( BackendContext (..)
  , BackendError (..)
  , BackendException (..)
  , BackendHandle (..)
  , BackendKind (..)
  , EnvMap
  , EnvValue (..)
  , IdleSpec
  , InvalidOptionDetail (..)
  , PtyOpts (..)
  , RecvResult (..)
  , SshConnectFailure (..)
  , acquireBufferQuota
  , defaultPtyOpts
  , globalBackendBufferQuota
  , releaseBufferQuota
  , sshIdle
  , withConcurrentUseGuard
  )
import PureClaw.Internal.ShellQuote (shellQuote)
import PureClaw.Security.Command
  ( AuthorizedCommand
  , CommandError (..)
  , getCommandProgram
  )
import PureClaw.Security.Path
  ( SafeKeyPath
  , SafeRuntimePath
  , getSafeKeyPath
  , getSafeRuntimePath
  )
import PureClaw.Security.Policy
  ( SecurityPolicy
  , _sp_allowedRemoteCommands
  , _sp_autonomy
  )
import PureClaw.Core.Types qualified as Core
import Data.Set qualified as Set
import System.FilePath (takeFileName)

--------------------------------------------------------------------------------
-- SshHost
--------------------------------------------------------------------------------

-- | A validated ssh hostname or IP literal.
--
-- The constructor is intentionally NOT exported. Obtain a value only
-- via 'mkSshHost', which rejects leading @-@ (defends against
-- @-oProxyCommand=evil@-style argv injection), whitespace, NUL, and
-- shell metacharacters.
newtype SshHost = SshHost Text
  deriving stock (Eq, Ord)

-- | Show is intentionally redacted: the host string is per-session
-- routing data, not loggable in user-facing surfaces.
instance Show SshHost where
  show _ = "SshHost <redacted>"

-- | Project an 'SshHost' to its underlying 'Text' for use inside argv
-- construction. Not intended for logging.
getSshHost :: SshHost -> Text
getSshHost (SshHost t) = t

-- | The ONLY way to construct an 'SshHost'.
--
-- Accepts:
--
--  * RFC 1123 hostname labels: @[A-Za-z0-9]([A-Za-z0-9-]{0,62})?@,
--    dot-separated, total length <= 253.
--  * Dotted-quad IPv4 literals: e.g. @10.0.0.1@.
--  * Bracketed IPv6 literals: e.g. @[::1]@.
--
-- Rejects (with 'BackendInvalidOption'):
--
--  * Empty input.
--  * Leading @-@ (defends @-oProxyCommand=evil@-style injection).
--  * Whitespace, NUL, or any non-printable / non-ASCII byte.
--  * Shell metacharacters: @; | & $ \` \\ \" \' ( ) < > * ? [ ] { } ! # ~@.
--  * Length > 253.
mkSshHost :: Text -> Either BackendError SshHost
mkSshHost t
  | T.null t =
      reject "empty host"
  | T.length t > 253 =
      reject "host too long"
  | T.head t == '-' =
      reject "leading dash"
  | T.any (\c -> not (isAscii c) || c == '\NUL') t =
      reject "non-ASCII or NUL"
  | T.any isWhitespaceLike t =
      reject "whitespace"
  -- The bracketed IPv6 form legitimately contains '[' and ']', which
  -- would otherwise be caught by 'isShellMeta'. Apply the IPv6 fast-
  -- path BEFORE the generic meta-char rejection. Other shell
  -- metacharacters inside the brackets are rejected by
  -- 'allowedIPv6Char'.
  | isBracketedIPv6 t =
      Right (SshHost t)
  | T.any isShellMeta t =
      reject "shell metacharacter"
  | isDottedIPv4 t =
      Right (SshHost t)
  | isHostnameLabels t =
      Right (SshHost t)
  | otherwise =
      reject "invalid hostname"
  where
    reject :: Text -> Either BackendError SshHost
    reject msg = Left (BackendInvalidOption (InvalidOptionDetail ("SshHost: " <> msg)))

    isWhitespaceLike c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
    isShellMeta c = c `elem` (";|&$`\\\"'()<>*?[]{}!#~" :: String)

    isBracketedIPv6 s =
      T.length s >= 4
        && T.head s == '['
        && T.last s == ']'
        && T.all allowedIPv6Char (T.init (T.tail s))
    allowedIPv6Char c = isAscii c && (isAlphaNum c || c == ':' || c == '.')

    isDottedIPv4 s =
      let parts = T.splitOn "." s
      in length parts == 4 && all isOctet parts
    isOctet p =
      not (T.null p)
        && T.length p <= 3
        && T.all isDigit p
        && case reads (T.unpack p) :: [(Int, String)] of
             [(n, "")] -> n >= 0 && n <= 255
             _         -> False

    isHostnameLabels s =
      let labels = T.splitOn "." s
      in not (null labels)
           && all isLabel labels
           && T.length s <= 253

    isLabel l =
      let n = T.length l
      in n >= 1
           && n <= 63
           && labelHead (T.head l)
           && T.all labelChar l
           && T.last l /= '-'
    labelHead c = isAscii c && isAlphaNum c
    labelChar c = isAscii c && (isAlphaNum c || c == '-')

--------------------------------------------------------------------------------
-- SshTarget
--------------------------------------------------------------------------------

-- | The destination of an ssh connection.
--
-- The 'SafeKeyPath' identifies the (passphrase-less, v1) private key
-- that ssh will be told to use via @-i@. The caller is responsible
-- for writing the key file before constructing a backend — this
-- record only carries the validated path.
data SshTarget = SshTarget
  { _st_user     :: !Text         -- ^ ssh username, e.g. @root@, @deploy@.
  , _st_host     :: !SshHost
  , _st_port     :: !(Maybe Int)  -- ^ Optional port; default 22.
  , _st_identity :: !SafeKeyPath  -- ^ The @-i@ argument (mode 0400).
  } deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- ControlOpts
--------------------------------------------------------------------------------

-- | Options for ssh ControlMaster multiplexing.
--
-- The control-socket path lives under a 'SafeRuntimePath' (typically
-- @~\/.local\/state\/pureclaw\/run@) — never inside the workspace.
data ControlOpts = ControlOpts
  { _co_controlPath :: !SafeRuntimePath
    -- ^ ssh @-S@ socket path; created when the multiplex is opened.
  , _co_persistSecs :: !Int
    -- ^ ssh @ControlPersist=N@ seconds.
  } deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- SshOpts / SshPipeOpts
--------------------------------------------------------------------------------

-- | Construction options for the Pty-kind ssh backend.
--
-- The hostname-pinned @UserKnownHostsFile@ flag is omitted when
-- @_so_knownHostsFile = Nothing@; production callers should always set
-- it (the design doc treats it as a required hardening flag). It is
-- 'Maybe' here so the test argv-builder can construct a minimal
-- target without a real runtime filesystem.
data SshOpts = SshOpts
  { _so_pty            :: !PtyOpts
  , _so_control        :: !(Maybe ControlOpts)
  , _so_knownHostsFile :: !(Maybe SafeRuntimePath)
  }

-- | Construction options for the Pipe-kind ssh backend.
--
-- Mirrors the field naming of 'PureClaw.Handles.Backend.PipeOpts' but
-- carries an 'IdleSpec' (the pipe spawn drains until EOF; the idle
-- spec is propagated for parity with the conversational backend's
-- timeout semantics — see design doc § Factories).
data SshPipeOpts = SshPipeOpts
  { _spo_env            :: !EnvMap
  , _spo_cwd            :: !(Maybe FilePath)
  , _spo_idle           :: !IdleSpec
  , _spo_recvBufferCap  :: !Int
  , _spo_control        :: !(Maybe ControlOpts)
  , _spo_knownHostsFile :: !(Maybe SafeRuntimePath)
  }

-- | Default 'SshOpts': 'defaultPtyOpts', no ControlMaster, no
-- @known_hosts@ pin.
--
-- @PtyOpts@ defaults are inherited (200x50 geometry, 'sshIdle' for
-- the idle policy — caller may override).
defaultSshOpts :: SshOpts
defaultSshOpts = SshOpts
  { _so_pty            = defaultPtyOpts { _pto_idle = sshIdle }
  , _so_control        = Nothing
  , _so_knownHostsFile = Nothing
  }

-- | Default 'SshPipeOpts': empty env, no cwd, the supplied 'IdleSpec',
-- 4 MiB recv cap, no ControlMaster, no @known_hosts@ pin.
defaultSshPipeOpts :: IdleSpec -> SshPipeOpts
defaultSshPipeOpts idle = SshPipeOpts
  { _spo_env            = Map.empty
  , _spo_cwd            = Nothing
  , _spo_idle           = idle
  , _spo_recvBufferCap  = 4 * 1024 * 1024
  , _spo_control        = Nothing
  , _spo_knownHostsFile = Nothing
  }

--------------------------------------------------------------------------------
-- RemoteCommand
--------------------------------------------------------------------------------

-- | A remote program + args that has been authorized against the
-- policy's '_sp_allowedRemoteCommands' allowlist.
--
-- The constructor is intentionally NOT exported. The only way to
-- obtain a 'RemoteCommand' is via 'authorizeRemote' — mirroring the
-- non-exported-ctor pattern of 'AuthorizedCommand'.
newtype RemoteCommand = RemoteCommand (FilePath, [Text])

-- | Project a 'RemoteCommand' to its remote program path. Used when
-- composing the @ssh user@host -- <program> <args>@ tail.
getRemoteProgram :: RemoteCommand -> FilePath
getRemoteProgram (RemoteCommand (p, _)) = p

-- | Project a 'RemoteCommand' to its remote argument list.
getRemoteArgs :: RemoteCommand -> [Text]
getRemoteArgs (RemoteCommand (_, as)) = as

-- | Authorize a remote command against the policy's remote allowlist.
--
-- Mirrors 'PureClaw.Security.Command.authorize' but consults
-- '_sp_allowedRemoteCommands' instead of '_sp_allowedCommands'. The
-- two allowlists are independent (design doc § Authorization);
-- granting @git@ locally does not silently grant @git@ remotely.
authorizeRemote
  :: SecurityPolicy
  -> FilePath
  -> [Text]
  -> Either CommandError RemoteCommand
authorizeRemote policy cmd args
  | _sp_autonomy policy == Core.Deny =
      Left CommandInAutonomyDeny
  | not (isRemoteAllowed policy (CommandName base)) =
      Left (CommandNotAllowed base)
  | otherwise =
      Right (RemoteCommand (cmd, args))
  where
    base = T.pack (takeFileName cmd)

-- | Local re-implementation of @isRemoteCommandAllowed@ to avoid a
-- cyclical import dance with @Security.Policy@; the field accessor is
-- exported as is.
isRemoteAllowed :: SecurityPolicy -> CommandName -> Bool
isRemoteAllowed policy name = case _sp_allowedRemoteCommands policy of
  AllowAll    -> True
  AllowList s -> Set.member name s

--------------------------------------------------------------------------------
-- ssh argv construction
--------------------------------------------------------------------------------

-- | Build the argv list for an ssh invocation.
--
-- Exported as the test seam for DoD #5 (argv flag hardening): callers
-- can assert that the produced list contains the required hardening
-- flags without spawning a real subprocess.
--
-- Arguments:
--
--   * 'SshTarget'   — user, host, port, identity file.
--   * 'RemoteCommand' — the remote program + args (post-authorization).
--   * 'Maybe' 'SafeRuntimePath' — optional @UserKnownHostsFile@.
--   * 'Maybe' 'ControlOpts' — optional ControlMaster settings.
--   * 'Bool' — whether to request a remote PTY via @-tt@.
--
-- The output is ordered: hardening flags first, then identity (@-i@),
-- then optional port + control-master flags, then the user@host
-- separator, then @--@, then the shell-quoted remote program and
-- args.
buildSshArgv
  :: SshTarget
  -> RemoteCommand
  -> Maybe SafeRuntimePath
  -> Maybe ControlOpts
  -> Bool
  -> [String]
buildSshArgv tgt remote =
  buildSshArgvFromParts tgt (getRemoteProgram remote) (getRemoteArgs remote)

-- | Lower-level variant of 'buildSshArgv' that takes the remote program
-- and arg list directly, rather than packaged in a 'RemoteCommand'.
--
-- The 'RemoteCommand' constructor is intentionally non-exported, but
-- consumers (notably 'PureClaw.Backend.Tmux') need to splice
-- subcommand-specific argv into the same hardened ssh prefix — e.g.
-- the same authorized remote tmux binary, but with different args for
-- the pin-resolve probe vs the attach. This helper expresses exactly
-- that: take an already-authorized program path and a fresh args list
-- (the caller's responsibility — the auth invariant lives at
-- 'authorizeRemote' time).
--
-- Note: the program path is shell-quoted, so a path like
-- @/opt/my tools/tmux@ round-trips through the remote login shell
-- intact.
buildSshArgvFromParts
  :: SshTarget
  -> FilePath               -- ^ remote program path (already authorized)
  -> [Text]                 -- ^ remote program args
  -> Maybe SafeRuntimePath  -- ^ optional @UserKnownHostsFile@
  -> Maybe ControlOpts      -- ^ optional ControlMaster settings
  -> Bool                   -- ^ request a remote PTY via @-tt@?
  -> [String]
buildSshArgvFromParts tgt remoteProg remoteArgs mKnown mCtl wantPty =
  hardenedFlags
    <> knownHostsFlag
    <> identityFlag
    <> portFlag
    <> controlFlags
    <> ptyFlag
    <> [ userAtHost, "--" ]
    <> remoteQuotedTail
  where
    hardenedFlags :: [String]
    hardenedFlags =
      [ "-F", "/dev/null"
      , "-o", "StrictHostKeyChecking=accept-new"
      , "-o", "BatchMode=yes"
      , "-o", "IdentitiesOnly=yes"
      , "-o", "ConnectTimeout=10"
      , "-o", "ServerAliveInterval=30"
      , "-o", "ServerAliveCountMax=3"
      , "-o", "ForwardX11=no"
      , "-o", "ForwardX11Trusted=no"
      , "-o", "ForwardAgent=no"
      , "-o", "PermitLocalCommand=no"
      ]

    knownHostsFlag :: [String]
    knownHostsFlag = case mKnown of
      Nothing -> []
      Just kh -> [ "-o", "UserKnownHostsFile=" <> getSafeRuntimePath kh ]

    identityFlag :: [String]
    identityFlag = [ "-i", getSafeKeyPath (_st_identity tgt) ]

    portFlag :: [String]
    portFlag = case _st_port tgt of
      Nothing -> []
      Just p  -> [ "-p", show p ]

    controlFlags :: [String]
    controlFlags = case mCtl of
      Nothing -> []
      Just c  ->
        [ "-o", "ControlMaster=auto"
        , "-o", "ControlPath=" <> getSafeRuntimePath (_co_controlPath c)
        , "-o", "ControlPersist=" <> show (_co_persistSecs c)
        ]

    ptyFlag :: [String]
    ptyFlag = [ "-tt" | wantPty ]

    userAtHost :: String
    userAtHost = T.unpack (_st_user tgt) <> "@" <> T.unpack (getSshHost (_st_host tgt))

    remoteQuotedTail :: [String]
    remoteQuotedTail =
      let progQ = T.unpack (shellQuote (T.pack remoteProg))
          argsQ = map (T.unpack . shellQuote) remoteArgs
      in progQ : argsQ

--------------------------------------------------------------------------------
-- Pty-kind factory
--------------------------------------------------------------------------------

-- | Construct a 'Pty'-kind ssh backend.
--
-- Builds the hardened ssh argv from the supplied 'SshTarget' and
-- already-authorized 'RemoteCommand', then delegates to
-- 'mkDrainerBackendHandle' for the drainer + STM idle state machine.
--
-- The local 'AuthorizedCommand' supplies the @ssh@ program path
-- (typically @\/usr\/bin\/ssh@). Its own args are ignored — the
-- factory constructs the full argv via 'buildSshArgv'.
--
-- Construction errors land as @Left BackendError@:
--
--  * @Left BackendBufferQuotaExceeded@ from quota oversubscription;
--  * @Left BackendSshConnectFailed SshConnectTimeout@ \/ similar from
--    a fast-fail at spawn time (any exception during open).
--
-- The factory does not block waiting for the ssh handshake — the
-- drainer surfaces handshake failures via @RecvEof@ on the next
-- @_bh_recv@ (e.g. when ConnectTimeout fires after ~10s and ssh
-- exits).
mkSshBackendHandle
  :: PtyIO
  -> AuthorizedCommand
  -> SshTarget
  -> RemoteCommand
  -> SshOpts
  -> IO (Either BackendError BackendHandle)
mkSshBackendHandle pio sshCmd tgt remote opts = do
  let argv = buildSshArgv
               tgt
               remote
               (_so_knownHostsFile opts)
               (_so_control opts)
               True
      ptyOpts = _so_pty opts
      spec = PtyOpenSpec
        { _pos_program = getCommandProgram sshCmd
        , _pos_args    = map T.pack argv
        , _pos_env     = _pto_env ptyOpts
        , _pos_cwd     = _pto_cwd ptyOpts
        , _pos_cols    = _pto_cols ptyOpts
        , _pos_rows    = _pto_rows ptyOpts
        }
  -- ssh failures at spawn time (binary missing, fork failure, etc.)
  -- collapse to a single user-visible error. 'SshConnectTimeout' is
  -- the closest fixed-vocabulary tag for an early-exit ssh — the
  -- drainer + idle timeout cover the mid-handshake hang case via
  -- 'RecvTimedOut'.
  r <- try @SomeException (mkDrainerBackendHandle pio ptyOpts spec Pty)
  case r of
    Right (Left e)   -> pure (Left e)
    Right (Right bh) -> Right <$> wrapSshHandle bh
    Left  _          -> pure (Left (BackendSshConnectFailed SshConnectTimeout))

-- | Wrap a freshly-constructed Pty-kind ssh 'BackendHandle' so it
-- enforces two ssh-specific invariants:
--
-- 1. Once a recv has observed @RecvEof@ (the ssh transport has
--    closed), a subsequent '_bh_send' throws 'BackendException' with
--    @_be_context = 'BcSshWrite'@ rather than silently succeeding
--    against a dead transport. Any @IO@ exception escaping the inner
--    '_bh_send' is also wrapped under 'BcSshWrite'.
-- 2. Concurrent entry into '_bh_send' \/ '_bh_recv' from multiple
--    threads is rejected with 'BcConcurrentUse' (via
--    'withConcurrentUseGuard').
--
-- Wrappers compose: the recv-EOF tracker wraps the underlying handle
-- first; the resulting handle is then passed through
-- 'withConcurrentUseGuard'. The end-user-visible '_bh_send' \/
-- '_bh_recv' therefore goes through both gates.
wrapSshHandle :: BackendHandle -> IO BackendHandle
wrapSshHandle bh = do
  eofRef <- newIORef False
  let trackedRecv mIdle = do
        res <- _bh_recv bh mIdle
        case res of
          RecvEof _ -> writeIORef eofRef True
          _         -> pure ()
        pure res

      sshSend bs = do
        wasEof <- readIORef eofRef
        if wasEof
          then throwIO $ BackendException BcSshWrite
                 (toException (userError "ssh transport closed"))
          else do
            r <- try @SomeException (_bh_send bh bs)
            case r of
              Right ()                                  -> pure ()
              Left e | Just be <- castBackendException e -> throwIO be
                     | otherwise                         -> throwIO $
                         BackendException BcSshWrite e
  withConcurrentUseGuard bh
    { _bh_send = sshSend
    , _bh_recv = trackedRecv
    }

-- | If the supplied 'SomeException' already is a 'BackendException',
-- return it; otherwise 'Nothing'. Used by 'wrapSshHandle' to avoid
-- double-wrapping when an inner layer already threw a structured
-- 'BackendException'.
castBackendException :: SomeException -> Maybe BackendException
castBackendException = Exception.fromException

--------------------------------------------------------------------------------
-- Pipe-kind factory
--------------------------------------------------------------------------------

-- | Construct a 'Pipe'-kind ssh backend.
--
-- One-shot: stdin is empty (the caller cannot stream input to a
-- one-shot ssh — use 'mkSshBackendHandle' if you need interactivity);
-- stdout and stderr are merged at the OS level (the OS-level @2>&1@
-- pattern, same as 'PureClaw.Backend.Local.mkLocalBackendHandle'); the
-- accumulator is read until EOF or @_spo_recvBufferCap@.
--
-- Mirrors 'PureClaw.Backend.Local.mkLocalBackendHandle' for the pipe
-- spawn machinery, but composes the hardened ssh argv around the
-- already-authorized remote 'RemoteCommand'.
mkSshPipeBackendHandle
  :: AuthorizedCommand
  -> SshTarget
  -> RemoteCommand
  -> SshPipeOpts
  -> IO (Either BackendError BackendHandle)
mkSshPipeBackendHandle sshCmd tgt remote opts = do
  let argv = buildSshArgv
               tgt
               remote
               (_spo_knownHostsFile opts)
               (_spo_control opts)
               False
  spawnSshArgv sshCmd argv opts

-- | Internal helper: spawn ssh as a pipe-only subprocess.
--
-- Acquires the per-backend recv buffer quota, opens a single shared
-- pipe (write-end dup'd to both child stdout and stderr), spawns ssh
-- via @typed-process@, then drains to EOF (or the cap) into an
-- 'IORef' accumulator.
--
-- This mirrors the pipe spawn pattern in
-- "PureClaw.Backend.Local"; the only divergence is the constructed
-- argv (the hardened ssh prefix already lives in 'buildSshArgv').
spawnSshArgv
  :: AuthorizedCommand
  -> [String]
  -> SshPipeOpts
  -> IO (Either BackendError BackendHandle)
spawnSshArgv sshCmd argv opts = do
  let capBytes = _spo_recvBufferCap opts
      capMiB   = bytesToMiBCeil capBytes
  quotaPtr <- readIORef globalBackendBufferQuota
  acq <- acquireBufferQuota quotaPtr capMiB
  case acq of
    Left e   -> pure (Left e)
    Right () -> do
      releasedRef <- newIORef False
      let releaseQuotaOnce = do
            already <- atomicSwapTrue releasedRef
            if already
              then pure ()
              else releaseBufferQuota quotaPtr capMiB

      let prog = getCommandProgram sshCmd
          envList = envMapToTuples (_spo_env opts)

      pipeResult <- try @SomeException PosixIO.createPipe
      case pipeResult of
        Left _ -> do
          releaseQuotaOnce
          pure (Left (BackendBinaryNotFound (CommandName (T.pack prog))))
        Right (readFd, writeFd) -> do
          readH  <- PosixIO.fdToHandle readFd
          writeH <- PosixIO.fdToHandle writeFd
          let baseConfig =
                  P.setStdin (P.byteStringInput BL.empty)
                $ P.setStdout (P.useHandleOpen writeH)
                $ P.setStderr (P.useHandleOpen writeH)
                $ P.setEnv envList
                $ P.proc prog argv
              withCwd = maybe id P.setWorkingDir (_spo_cwd opts)
              config = withCwd baseConfig

          spawnResult <- try @SomeException (P.startProcess config)
          case spawnResult of
            Left _ -> do
              _ <- try @SomeException (hClose writeH)
              _ <- try @SomeException (hClose readH)
              releaseQuotaOnce
              pure (Left (BackendSshConnectFailed SshOtherFailure))
            Right proc -> do
              _ <- try @SomeException (hClose writeH)

              accRef      <- newIORef BS.empty
              truncRef    <- newIORef False
              reader      <- Async.async (drainHandleInto capBytes accRef truncRef readH)

              closeLock   <- newMVar ()
              closedRef   <- newIORef False
              recvDoneRef <- newIORef False

              let doSend _ = pure ()

                  doRecv _mIdle = do
                    already <- readIORef recvDoneRef
                    if already
                      then resultFromAcc accRef truncRef
                      else do
                        _ <- Async.waitCatch reader
                        writeIORef recvDoneRef True
                        resultFromAcc accRef truncRef

                  doResize _ _ = pure ()

                  doClose = modifyMVar_ closeLock $ \() -> do
                    wasClosed <- readIORef closedRef
                    if wasClosed
                      then pure ()
                      else do
                        writeIORef closedRef True
                        Async.cancel reader
                        _ <- try @SomeException (P.stopProcess proc)
                        _ <- try @SomeException (hClose readH)
                        releaseQuotaOnce
                        pure ()

              pure $ Right BackendHandle
                { _bh_name        = "ssh-pipe"
                , _bh_kind        = Pipe
                , _bh_defaultIdle = _spo_idle opts
                , _bh_send        = doSend
                , _bh_recv        = doRecv
                , _bh_resize      = doResize
                , _bh_close       = doClose
                }
  where
    resultFromAcc accRef truncRef = do
      bs  <- readIORef accRef
      isT <- readIORef truncRef
      pure (if isT then RecvTruncated bs else RecvSettled bs)

-- | Drain a 'Handle' into the accumulator, latching the truncate flag
-- if the per-backend cap is exceeded. Best-effort: read exceptions
-- are treated as EOF.
drainHandleInto :: Int -> IORef ByteString -> IORef Bool -> Handle -> IO ()
drainHandleInto cap accRef truncRef h = go
  where
    go = do
      r <- try @SomeException (BS.hGetSome h 4096)
      case r of
        Left _    -> pure ()
        Right bs
          | BS.null bs -> pure ()
          | otherwise -> do
              acc <- readIORef accRef
              let newSize = BS.length acc + BS.length bs
              if newSize > cap
                then writeIORef truncRef True
                else do
                  atomicModifyIORef' accRef $ \old -> (old <> bs, ())
                  go

--------------------------------------------------------------------------------
-- ControlMaster lifecycle
--------------------------------------------------------------------------------

-- | Tear down an existing ControlMaster multiplex.
--
-- Runs @ssh -S <controlPath> -O exit dummy@dummy@. The user@host is
-- unused by @-O exit@ — only the socket matters — but ssh still
-- requires the positional argument, so we pass a placeholder. The
-- 'AuthorizedCommand' supplies the @ssh@ program path; the caller
-- should reuse the same 'AuthorizedCommand' they used to open the
-- multiplex (preserves the §5.1 authorize-before-execute invariant).
--
-- Best-effort and idempotent: any spawn or wait failure is swallowed.
-- If the socket file does not exist (already closed, never opened),
-- ssh exits with a non-zero status which this function silently
-- ignores.
closeSshMultiplex :: AuthorizedCommand -> ControlOpts -> IO ()
closeSshMultiplex sshCmd opts = do
  let prog = getCommandProgram sshCmd
      argv =
        [ "-S", getSafeRuntimePath (_co_controlPath opts)
        , "-O", "exit"
        , "dummy@dummy"
        ]
      config = P.setStdin P.nullStream
             $ P.setStdout P.nullStream
             $ P.setStderr P.nullStream
             $ P.proc prog argv
  _ <- try @SomeException (P.runProcess config)
  pure ()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Round a byte count up to whole MiB (1 MiB == 1_048_576 bytes).
-- Zero or negative byte counts produce @0@. Mirrors the helper in
-- "PureClaw.Backend.Pty" / "PureClaw.Backend.Local"; reimplemented
-- locally so the export surface of those modules stays tight.
bytesToMiBCeil :: Int -> Int
bytesToMiBCeil n
  | n <= 0    = 0
  | otherwise = (n + mib - 1) `div` mib
  where mib = 1024 * 1024

-- | Atomically set an 'IORef' 'Bool' to 'True', returning its previous
-- value. Used to defend against double-release of the buffer quota.
atomicSwapTrue :: IORef Bool -> IO Bool
atomicSwapTrue ref = atomicModifyIORef' ref (True,)

-- | Render an 'EnvMap' as the @[(String, String)]@ tuple list that
-- @typed-process@\'s 'P.setEnv' expects. Values decode byte-for-byte
-- (Latin-1) so non-ASCII bytes round-trip 1:1 to the subprocess.
envMapToTuples :: EnvMap -> [(String, String)]
envMapToTuples = map render . Map.toAscList
  where
    render (k, EnvValue v) = (k, map (toEnum . fromIntegral) (BS.unpack v))
