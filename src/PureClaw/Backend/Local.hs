-- |
-- Module      : PureClaw.Backend.Local
-- Description : Local subprocess backend factories (WU8).
--
-- == Overview
--
-- Two factories produce a real 'BackendHandle' over an actual local
-- subprocess:
--
-- * 'mkLocalBackendHandle' — 'Pipe' kind. One-shot: stdin is written
--   from '_po_stdinBytes' and then closed; stdout (with stderr merged
--   into it) is read until EOF or until the recv-buffer cap is reached.
-- * 'mkLocalPtyBackendHandle' — 'Pty' kind. Conversational: a real PTY
--   is allocated via the supplied 'PtyIO'; the drainer + STM idle state
--   machine from "PureClaw.Backend.Pty" runs the recv loop.
--
-- == Why 'PtyIO' is a separate parameter
--
-- WU1 deliberately omitted a @_pto_io :: PtyIO@ field from 'PtyOpts' to
-- keep "PureClaw.Handles.Backend" free of any dependency on
-- "PureClaw.Backend.Pty" (the @posix-pty@ firewall lives there). WU7
-- chose not to retrofit, so 'mkLocalPtyBackendHandle' takes the
-- 'PtyIO' as a separate parameter rather than as a field on
-- 'PtyOpts'. Mirrors 'mkDrainerBackendHandle'\'s shape.
module PureClaw.Backend.Local
  ( mkLocalBackendHandle
  , mkLocalPtyBackendHandle
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.IO (Handle, hClose)
import System.Posix.IO qualified as PosixIO
import System.Process.Typed qualified as P

import PureClaw.Backend.Pty
  ( PtyIO (..)
  , PtyOpenSpec (..)
  , mkDrainerBackendHandle
  )
import PureClaw.Core.Types (CommandName (..))
import PureClaw.Handles.Backend
  ( BackendError (..)
  , BackendHandle (..)
  , BackendKind (..)
  , EnvMap
  , EnvValue (..)
  , PipeOpts (..)
  , PtyOpts (..)
  , RecvResult (..)
  , acquireBufferQuota
  , globalBackendBufferQuota
  , localIdle
  , releaseBufferQuota
  , withConcurrentUseGuard
  )
import PureClaw.Security.Command
  ( AuthorizedCommand
  , getCommandArgs
  , getCommandProgram
  )

--------------------------------------------------------------------------------
-- Pipe-kind factory
--------------------------------------------------------------------------------

-- | Construct a 'Pipe'-kind local subprocess backend.
--
-- Semantics:
--
-- * stdin is fed @_po_stdinBytes@ and then closed (via
--   'P.byteStringInput'); after construction, @_bh_send@ is a silent
--   no-op because the OS-level stdin is already gone.
-- * stdout AND stderr are wired to the SAME pipe write-end at the OS
--   level via 'System.Posix.IO.createPipe' + 'P.useHandleOpen' on both
--   stream slots. The child sees fd 1 and fd 2 pointing at the same
--   pipe; byte order is preserved end-to-end (this is the OS-level
--   @2>&1@ pattern; see design doc § "stderr Handling").
-- * @_bh_recv@ reads from the accumulator until EOF or until the
--   per-backend cap @_po_recvBufferCap@ is reached. EOF within the
--   cap yields 'RecvSettled'; cap reached first yields
--   'RecvTruncated'.
-- * @_bh_resize@ is a silent no-op (no PTY exists on a 'Pipe' backend).
-- * @_bh_close@ waits for the subprocess to exit and releases the
--   process-wide buffer quota; idempotent.
--
-- On construction failure (quota oversubscription, spawn exception)
-- the quota is released and the error is propagated as a 'Left'.
mkLocalBackendHandle
  :: AuthorizedCommand
  -> PipeOpts
  -> IO (Either BackendError BackendHandle)
mkLocalBackendHandle cmd opts = do
  let capBytes = _po_recvBufferCap opts
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

      let prog = getCommandProgram cmd
          args = map T.unpack (getCommandArgs cmd)
          stdinLazy = byteStringToLazy (_po_stdinBytes opts)
          envList   = envMapWithDefaults (_po_env opts)

      -- Create a single shared pipe. Both stdout (fd 1) and stderr (fd 2)
      -- in the child are dup'd from the same write-end; the parent reads
      -- from the read-end. This is the OS-level @2>&1@ pattern — byte
      -- order is preserved by the kernel.
      pipeResult <- try @SomeException PosixIO.createPipe
      case pipeResult of
        Left _ -> do
          releaseQuotaOnce
          pure (Left (BackendBinaryNotFound (toCommandName prog)))
        Right (readFd, writeFd) -> do
          readH  <- PosixIO.fdToHandle readFd
          writeH <- PosixIO.fdToHandle writeFd
          let baseConfig =
                  P.setStdin (P.byteStringInput stdinLazy)
                $ P.setStdout (P.useHandleOpen writeH)
                $ P.setStderr (P.useHandleOpen writeH)
                $ P.setEnv envList
                $ P.proc prog args
              withCwd = maybe id P.setWorkingDir (_po_cwd opts)
              config = withCwd baseConfig

          spawnResult <- try @SomeException (P.startProcess config)
          case spawnResult of
            Left _ -> do
              -- Close both ends of our pipe and release quota.
              _ <- try @SomeException (hClose writeH)
              _ <- try @SomeException (hClose readH)
              releaseQuotaOnce
              pure (Left (BackendBinaryNotFound (toCommandName prog)))
            Right proc -> do
              -- After spawn, the parent doesn't need its copy of the
              -- write-end; close it so the reader sees EOF when the
              -- child exits and closes its copies. Critical for EOF
              -- detection.
              _ <- try @SomeException (hClose writeH)

              accRef    <- newIORef BS.empty
              truncRef  <- newIORef False
              reader    <- Async.async (drainHandleInto capBytes accRef truncRef readH)

              closeLock     <- newMVar ()
              closedRef     <- newIORef False
              recvDoneRef   <- newIORef False

              let doSend _ = pure ()

                  doRecv _mIdle = do
                    already <- readIORef recvDoneRef
                    if already
                      then do
                        bs <- readIORef accRef
                        isT <- readIORef truncRef
                        pure (if isT then RecvTruncated bs else RecvSettled bs)
                      else do
                        _ <- Async.waitCatch reader
                        writeIORef recvDoneRef True
                        bs  <- readIORef accRef
                        isT <- readIORef truncRef
                        pure (if isT then RecvTruncated bs else RecvSettled bs)

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

              guarded <- withConcurrentUseGuard BackendHandle
                { _bh_name        = "local-pipe"
                , _bh_kind        = Pipe
                , _bh_defaultIdle = localIdle
                , _bh_send        = doSend
                , _bh_recv        = doRecv
                , _bh_resize      = doResize
                , _bh_close       = doClose
                }
              pure (Right guarded)

-- | Drain a 'Handle' (stdout or stderr pipe) into the shared
-- accumulator, latching @truncRef@ if the per-backend cap is exceeded.
--
-- Best-effort: read exceptions are treated as EOF. Once the cap is
-- reached, the latch is flipped to 'True' and subsequent bytes are
-- dropped (so the accumulator stops growing past the cap).
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
-- Pty-kind factory
--------------------------------------------------------------------------------

-- | Construct a 'Pty'-kind local subprocess backend.
--
-- Composes the 'AuthorizedCommand' + 'PtyOpts' into a 'PtyOpenSpec' and
-- delegates to 'mkDrainerBackendHandle'. The drainer + STM idle state
-- machine from "PureClaw.Backend.Pty" provides @_bh_recv@, @_bh_send@
-- forwards to @_pio_write@, and @_bh_close@ is idempotent (cancels
-- drainer, closes PTY, releases buffer quota).
--
-- The environment passed to the child is 'envMapWithDefaults' of
-- @_pto_env@ — i.e. the caller-supplied map plus minimal defaults for
-- 'TERM' (@xterm-256color@) and 'PATH' (@\/usr\/bin:\/bin:\/usr\/local\/bin@)
-- only when those keys are absent. No inheritance from the parent
-- process.
mkLocalPtyBackendHandle
  :: PtyIO
  -> AuthorizedCommand
  -> PtyOpts
  -> IO (Either BackendError BackendHandle)
mkLocalPtyBackendHandle pio cmd opts = do
  let spec = PtyOpenSpec
        { _pos_program = getCommandProgram cmd
        , _pos_args    = getCommandArgs cmd
        , _pos_env     = envMapWithBackendDefaults (_pto_env opts)
        , _pos_cwd     = _pto_cwd opts
        , _pos_cols    = _pto_cols opts
        , _pos_rows    = _pto_rows opts
        }
  r <- mkDrainerBackendHandle pio opts spec Pty
  case r of
    Left  e  -> pure (Left e)
    Right bh -> Right <$> withConcurrentUseGuard bh

--------------------------------------------------------------------------------
-- Env helpers
--------------------------------------------------------------------------------

-- | Add minimal 'TERM' and 'PATH' defaults to a caller-supplied 'EnvMap'
-- if either is absent. Returns the result in the @[(String, String)]@
-- shape that @typed-process@\'s 'P.setEnv' expects.
--
-- Behaviour:
--
-- * If @TERM@ is missing, set it to @xterm-256color@.
-- * If @PATH@ is missing, set it to @\/usr\/bin:\/bin:\/usr\/local\/bin@.
-- * Caller-supplied entries always win — existing keys are not
--   overwritten.
envMapWithDefaults :: EnvMap -> [(String, String)]
envMapWithDefaults = envToTuples . envMapWithBackendDefaults

-- | The 'EnvMap'-side of 'envMapWithDefaults' — used by the PTY factory
-- which feeds its 'EnvMap' through 'PtyOpenSpec' rather than the
-- @typed-process@ tuple list.
envMapWithBackendDefaults :: EnvMap -> EnvMap
envMapWithBackendDefaults =
    insertIfAbsent "TERM" "xterm-256color"
  . insertIfAbsent "PATH" "/usr/bin:/bin:/usr/local/bin"
  where
    insertIfAbsent k v m
      | Map.member k m = m
      | otherwise      = Map.insert k (EnvValue (stringToByteString v)) m

-- | Render an 'EnvMap' as the @[(String, String)]@ tuple list that
-- @typed-process@\'s 'P.setEnv' expects. Values are decoded
-- byte-for-byte from the underlying 'ByteString' so non-ASCII bytes
-- round-trip 1:1.
envToTuples :: EnvMap -> [(String, String)]
envToTuples = map render . Map.toAscList
  where
    render (k, EnvValue v) = (k, byteStringToString v)

-- | Latin-1 round-trip ('ByteString' → 'String'). The subprocess sees
-- raw bytes; this is the same transform used in
-- "PureClaw.Backend.Pty".
byteStringToString :: ByteString -> String
byteStringToString bs = map (toEnum . fromIntegral) (BS.unpack bs)

-- | Latin-1 round-trip ('String' → 'ByteString'). Inverse of
-- 'byteStringToString'.
stringToByteString :: String -> ByteString
stringToByteString = BS.pack . map (fromIntegral . fromEnum)

-- | Lift a strict 'ByteString' into the lazy 'ByteString' shape that
-- 'P.byteStringInput' expects.
byteStringToLazy :: ByteString -> BL.ByteString
byteStringToLazy = BL.fromStrict

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Round a byte count up to whole MiB (1 MiB == 1_048_576 bytes).
-- Zero or negative byte counts produce @0@. Mirrors the helper in
-- "PureClaw.Backend.Pty"; reimplemented locally to keep that module\'s
-- export surface tight.
bytesToMiBCeil :: Int -> Int
bytesToMiBCeil n
  | n <= 0    = 0
  | otherwise = (n + mib - 1) `div` mib
  where mib = 1024 * 1024

-- | Atomically set an 'IORef' 'Bool' to 'True', returning its previous
-- value. Used to defend against double-release of the buffer quota.
-- Mirrors the helper in "PureClaw.Backend.Pty".
atomicSwapTrue :: IORef Bool -> IO Bool
atomicSwapTrue ref = atomicModifyIORef' ref (True,)

-- | Project an 'AuthorizedCommand'\'s program path to a redaction-safe
-- 'CommandName' for inclusion in 'BackendBinaryNotFound'.
toCommandName :: FilePath -> CommandName
toCommandName = CommandName . T.pack
