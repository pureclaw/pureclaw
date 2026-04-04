module PureClaw.Handles.Transcript
  ( -- * Handle type
    TranscriptHandle (..)
    -- * Implementations
  , mkFileTranscriptHandle
  , mkNoOpTranscriptHandle
  ) where

import Control.Exception
import Control.Monad
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.IORef
import Data.Text qualified as T
import System.Directory
import System.FilePath
import System.IO.Error
import System.Posix.Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types

import Foreign.C.Error
import Foreign.C.Types

import PureClaw.Handles.Log
import PureClaw.Transcript.Types

-- | POSIX fsync(2) — flush kernel buffers to disk.
foreign import ccall "fsync" c_fsync :: CInt -> IO CInt

fdSync :: Fd -> IO ()
fdSync (Fd fd) = throwErrnoIfMinus1_ "fdSync" (c_fsync fd)

-- | Transcript I/O capability. Append-only JSONL log with query support.
data TranscriptHandle = TranscriptHandle
  { _th_record  :: TranscriptEntry -> IO ()
  , _th_query   :: TranscriptFilter -> IO [TranscriptEntry]
  , _th_getPath :: IO FilePath
  , _th_flush   :: IO ()
  , _th_close   :: IO ()
  }

-- | File-backed transcript handle using JSONL format.
mkFileTranscriptHandle :: LogHandle -> FilePath -> IO TranscriptHandle
mkFileTranscriptHandle logger path = do
  -- Create parent directory with 0700 permissions if it doesn't exist
  let dir = takeDirectory path
  dirExists <- doesDirectoryExist dir
  unless dirExists $ do
    createDirectoryIfMissing True dir
    setFileMode dir 0o700

  -- Open file with 0600 permissions using raw POSIX fd (no GHC file locking)
  fd <- Posix.openFd path
    Posix.ReadWrite
    (Posix.defaultFileFlags { Posix.append = True, Posix.creat = Just 0o600 })

  closedRef <- newIORef False
  fdRef <- newIORef (Just fd)

  pure TranscriptHandle
    { _th_record = \entry -> do
        closed <- readIORef closedRef
        unless closed $ do
          mfd <- readIORef fdRef
          case mfd of
            Nothing -> pure ()
            Just wfd -> do
              let line = LBS.toStrict (Aeson.encode entry) <> "\n"
              void (PosixBS.fdWrite wfd line)

    , _th_query = \tf -> do
        closed <- readIORef closedRef
        if closed
          then pure []
          else do
            -- Read via a separate fd to avoid any conflicts
            contents <- readFileRaw path
            let rawLines = LBC.lines (LBS.fromStrict contents)
            decoded <- decodeLines logger rawLines
            pure (applyFilter tf decoded)

    , _th_getPath = pure path

    , _th_flush = do
        closed <- readIORef closedRef
        unless closed $ do
          mfd <- readIORef fdRef
          case mfd of
            Nothing -> pure ()
            Just wfd -> fdSync wfd

    , _th_close = do
        closed <- readIORef closedRef
        unless closed $ do
          writeIORef closedRef True
          mfd <- readIORef fdRef
          writeIORef fdRef Nothing
          case mfd of
            Nothing -> pure ()
            Just wfd -> do
              fdSync wfd
              Posix.closeFd wfd
    }

-- | Read a file strictly using raw POSIX fd operations, bypassing
-- GHC RTS file locking to avoid conflicts with an already-open fd.
readFileRaw :: FilePath -> IO BS.ByteString
readFileRaw fp = do
  rfd <- Posix.openFd fp Posix.ReadOnly Posix.defaultFileFlags
  let chunkSize :: ByteCount
      chunkSize = 65536
      go acc = do
        result <- try (PosixBS.fdRead rfd chunkSize)
        case result of
          Left e
            | isEOFError e -> pure (BS.concat (reverse acc))
            | otherwise    -> throwIO e
          Right chunk
            | BS.null chunk -> pure (BS.concat (reverse acc))
            | otherwise     -> go (chunk : acc)
  contents <- go []
  Posix.closeFd rfd
  pure contents

-- | Decode JSONL lines, skipping malformed ones and logging warnings.
decodeLines :: LogHandle -> [LBS.ByteString] -> IO [TranscriptEntry]
decodeLines logger = go
  where
    go [] = pure []
    go (line:rest)
      | LBS.null line = go rest
      | otherwise = case Aeson.eitherDecode line of
          Right entry -> (entry :) <$> go rest
          Left err    -> do
            _lh_logWarn logger ("Skipping malformed JSONL line: " <> T.pack err)
            go rest

-- | No-op transcript handle for testing.
mkNoOpTranscriptHandle :: TranscriptHandle
mkNoOpTranscriptHandle = TranscriptHandle
  { _th_record  = \_ -> pure ()
  , _th_query   = \_ -> pure []
  , _th_getPath = pure ""
  , _th_flush   = pure ()
  , _th_close   = pure ()
  }
