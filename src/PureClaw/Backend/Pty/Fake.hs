-- |
-- Module      : PureClaw.Backend.Pty.Fake
-- Description : Deterministic in-process 'PtyIO' for tests (WU7).
--
-- This module is the second (and final) member of the @posix-pty@
-- firewall — it can import the internal accessors of 'PtyFds' from
-- "PureClaw.Backend.Pty" but, like 'PureClaw.Backend.Pty', the CI gate
-- @scripts\/check-pty-firewall.sh@ keeps the rest of the codebase out.
--
-- A 'fakePtyIO' is driven by a 'FakePtyConfig' that scripts the bytes
-- a PTY read will yield; the write\/resize\/close calls are recorded
-- to 'IORef's for test introspection.
module PureClaw.Backend.Pty.Fake
  ( FakePtyConfig (..)
  , fakePtyIO
  , readFakeWriteLog
  , readFakeResizeLog
  , readFakeClosed
  , readFakeBytesRead
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Control.Concurrent (threadDelay)
import Data.IORef
  ( atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Maybe (fromMaybe)

import PureClaw.Backend.Pty
  ( FakePtyState (..)
  , PtyFds
  , PtyIO (..)
  , PtyOpenSpec
  , mkFakePtyFds
  , withFakePtyState
  )
import PureClaw.Handles.Backend (Cols, Rows)
import PureClaw.Internal.FakeClock (FakeClock)

-- | Construction-time configuration for 'fakePtyIO'.
--
-- '_fpc_outputScript' is the sequence of chunks the next N
-- @_pio_read@ calls will yield, in order. Once the script is
-- exhausted (and '_fpc_eofAfterBytes' is reached, if set), @_pio_read@
-- returns 'BS.empty' to signal EOF — which the drainer turns into an
-- 'RsEof' on its queue.
data FakePtyConfig = FakePtyConfig
  { _fpc_clock         :: !FakeClock
  , _fpc_initialOutput :: !ByteString
    -- ^ A single chunk emitted from the very first @_pio_read@ call
    -- (placed at the head of the read queue at open-time). Empty
    -- means: no initial chunk.
  , _fpc_eofAfterBytes :: !(Maybe Int)
    -- ^ Optional cap: once this many bytes have been read,
    -- subsequent @_pio_read@ calls return 'BS.empty' (EOF) regardless
    -- of any remaining script.
  , _fpc_outputScript  :: ![ByteString]
    -- ^ Subsequent chunks emitted on each @_pio_read@ call.
  }

-- | Allocate a 'PtyIO' backed by in-process 'IORef's.
--
-- Each call to 'fakePtyIO' produces a fresh, independent set of
-- 'IORef' state via 'PtyOpenSpec'-time setup in @_pio_open@. The
-- returned 'PtyIO' is safe to share across multiple opens, but the
-- 'IORef' state is per-open — every @_pio_open@ allocates new refs.
fakePtyIO :: FakePtyConfig -> IO PtyIO
fakePtyIO cfg = pure PtyIO
  { _pio_open   = fakeOpen
  , _pio_read   = fakeRead
  , _pio_write  = fakeWrite
  , _pio_resize = fakeResize
  , _pio_close  = fakeClose
  }
  where
    fakeOpen :: PtyOpenSpec -> IO PtyFds
    fakeOpen _spec = do
      let initial = _fpc_initialOutput cfg
          script  = _fpc_outputScript cfg
          chunks  = if BS.null initial then script else initial : script
      rq <- newIORef chunks
      wl <- newIORef []
      rl <- newIORef []
      cl <- newIORef False
      ea <- newIORef (_fpc_eofAfterBytes cfg)
      br <- newIORef 0
      pure $ mkFakePtyFds FakePtyState
        { _fps_readQueue = rq
        , _fps_writeLog  = wl
        , _fps_resizeLog = rl
        , _fps_closed    = cl
        , _fps_eofAfter  = ea
        , _fps_bytesRead = br
        , _fps_clock     = _fpc_clock cfg
        }

    fakeRead :: PtyFds -> Int -> IO ByteString
    fakeRead fds _ = do
      mResult <- withFakePtyState fds $ \st -> do
        closed <- readIORef (_fps_closed st)
        if closed
          then pure BS.empty
          else do
            mEof  <- readIORef (_fps_eofAfter st)
            sofar <- readIORef (_fps_bytesRead st)
            let pastCap = case mEof of
                  Just cap -> sofar >= cap
                  Nothing  -> False
            if pastCap
              then pure BS.empty
              else do
                next <- atomicModifyIORef' (_fps_readQueue st) $ \case
                  []      -> ([], Nothing)
                  (x:xs)  -> (xs, Just x)
                case next of
                  Just bs -> do
                    atomicModifyIORef' (_fps_bytesRead st) $ \n ->
                      (n + BS.length bs, ())
                    pure bs
                  Nothing ->
                    -- Script exhausted but no EOF cap reached:
                    -- block forever so the drainer\'s read sits
                    -- waiting (mirroring a quiet real PTY). Polled
                    -- on a coarse 50ms tick so cancellation from the
                    -- drainer's 'Async.cancel' lands promptly.
                    case mEof of
                      Just _  -> pure BS.empty -- EOF cap set: signal EOF
                      Nothing -> blockForever
      pure (fromMaybe BS.empty mResult)

    blockForever :: IO ByteString
    blockForever = do
      threadDelay 50_000
      blockForever

    fakeWrite :: PtyFds -> ByteString -> IO ()
    fakeWrite fds bs = do
      _ <- withFakePtyState fds $ \st ->
        atomicModifyIORef' (_fps_writeLog st) $ \xs -> (bs : xs, ())
      pure ()

    fakeResize :: PtyFds -> Cols -> Rows -> IO ()
    fakeResize fds c r = do
      _ <- withFakePtyState fds $ \st ->
        atomicModifyIORef' (_fps_resizeLog st) $ \xs -> ((c, r) : xs, ())
      pure ()

    fakeClose :: PtyFds -> IO ()
    fakeClose fds = do
      _ <- withFakePtyState fds $ \st ->
        writeIORef (_fps_closed st) True
      pure ()

-- | Read the recorded write log (newest-first).
readFakeWriteLog :: FakePtyState -> IO [ByteString]
readFakeWriteLog = readIORef . _fps_writeLog

-- | Read the recorded resize log (newest-first).
readFakeResizeLog :: FakePtyState -> IO [(Cols, Rows)]
readFakeResizeLog = readIORef . _fps_resizeLog

-- | Has @_pio_close@ been called on this state?
readFakeClosed :: FakePtyState -> IO Bool
readFakeClosed = readIORef . _fps_closed

-- | Total bytes ever returned from @_pio_read@.
readFakeBytesRead :: FakePtyState -> IO Int
readFakeBytesRead = readIORef . _fps_bytesRead
