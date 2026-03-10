module PureClaw.Handles.Process
  ( -- * Types
    ProcessId (..)
  , ProcessInfo (..)
  , ProcessStatus (..)
    -- * Handle type
  , ProcessHandle (..)
    -- * Implementations
  , mkProcessHandle
  , mkNoOpProcessHandle
  ) where

import Control.Concurrent.Async qualified as Async
import Control.Exception
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit
import System.IO (Handle, hFlush)
import System.Process.Typed qualified as P

import PureClaw.Handles.Log
import PureClaw.Security.Command

-- | Identifier for a background process.
newtype ProcessId = ProcessId { unProcessId :: Int }
  deriving stock (Show, Eq, Ord)

-- | Lightweight process info for listing.
data ProcessInfo = ProcessInfo
  { _pi_id       :: ProcessId
  , _pi_command  :: Text
  , _pi_running  :: Bool
  , _pi_exitCode :: Maybe ExitCode
  }
  deriving stock (Show, Eq)

-- | Full process status with output, returned by poll.
data ProcessStatus
  = ProcessRunning ByteString ByteString        -- ^ partial stdout, stderr
  | ProcessDone ExitCode ByteString ByteString   -- ^ exit code, final stdout, stderr
  deriving stock (Show, Eq)

-- | Background process management capability.
data ProcessHandle = ProcessHandle
  { _ph_spawn      :: AuthorizedCommand -> IO ProcessId
  , _ph_list       :: IO [ProcessInfo]
  , _ph_poll       :: ProcessId -> IO (Maybe ProcessStatus)
  , _ph_kill       :: ProcessId -> IO Bool
  , _ph_writeStdin :: ProcessId -> ByteString -> IO Bool
  }

-- Internal entry tracking a background process.
data ProcessEntry = ProcessEntry
  { _pe_command   :: Text
  , _pe_stdinH    :: Handle
  , _pe_stdoutRef :: IORef ByteString
  , _pe_stderrRef :: IORef ByteString
  , _pe_exitAsync :: Async.Async ExitCode
  , _pe_cleanup   :: IO ()
  }

data ProcessState = ProcessState
  { _pst_nextId    :: !Int
  , _pst_processes :: Map Int ProcessEntry
  }

-- | Minimal safe environment for subprocesses.
safeEnv :: [(String, String)]
safeEnv = [("PATH", "/usr/bin:/bin:/usr/local/bin")]

-- | Real process handle using typed-process and async.
mkProcessHandle :: LogHandle -> IO ProcessHandle
mkProcessHandle logger = do
  stateRef <- newIORef ProcessState { _pst_nextId = 1, _pst_processes = Map.empty }
  pure ProcessHandle
    { _ph_spawn = \cmd -> do
        let prog = getCommandProgram cmd
            args = map T.unpack (getCommandArgs cmd)
            cmdText = T.pack prog <> " " <> T.unwords (getCommandArgs cmd)
            config = P.setStdin P.createPipe
                   $ P.setStdout P.createPipe
                   $ P.setStderr P.createPipe
                   $ P.setEnv safeEnv
                   $ P.proc prog args
        _lh_logInfo logger $ "Spawning background: " <> cmdText
        proc <- P.startProcess config
        let stdinH  = P.getStdin proc
            stdoutH = P.getStdout proc
            stderrH = P.getStderr proc
        stdoutRef <- newIORef BS.empty
        stderrRef <- newIORef BS.empty
        outReader <- Async.async $ readLoop stdoutH stdoutRef
        errReader <- Async.async $ readLoop stderrH stderrRef
        exitAsync <- Async.async $ P.waitExitCode proc
        let cleanup = do
              Async.cancel outReader
              Async.cancel errReader
              Async.cancel exitAsync
              _ <- try @SomeException (P.stopProcess proc)
              pure ()
        let entry = ProcessEntry
              { _pe_command   = cmdText
              , _pe_stdinH    = stdinH
              , _pe_stdoutRef = stdoutRef
              , _pe_stderrRef = stderrRef
              , _pe_exitAsync = exitAsync
              , _pe_cleanup   = cleanup
              }
        pid <- atomicModifyIORef' stateRef $ \st ->
          let pid = _pst_nextId st
              st' = st { _pst_nextId    = pid + 1
                       , _pst_processes = Map.insert pid entry (_pst_processes st)
                       }
          in (st', pid)
        pure (ProcessId pid)

    , _ph_list = do
        st <- readIORef stateRef
        mapM (toProcessInfo) (Map.toList (_pst_processes st))

    , _ph_poll = \(ProcessId pid) -> do
        st <- readIORef stateRef
        case Map.lookup pid (_pst_processes st) of
          Nothing -> pure Nothing
          Just entry -> do
            status <- getStatus entry
            pure (Just status)

    , _ph_kill = \(ProcessId pid) -> do
        st <- readIORef stateRef
        case Map.lookup pid (_pst_processes st) of
          Nothing -> pure False
          Just entry -> do
            _pe_cleanup entry
            atomicModifyIORef' stateRef $ \s ->
              (s { _pst_processes = Map.delete pid (_pst_processes s) }, ())
            _lh_logInfo logger $ "Killed process " <> T.pack (show pid)
            pure True

    , _ph_writeStdin = \(ProcessId pid) bytes -> do
        st <- readIORef stateRef
        case Map.lookup pid (_pst_processes st) of
          Nothing -> pure False
          Just entry -> do
            result <- try @SomeException $ do
              BS.hPut (_pe_stdinH entry) bytes
              hFlush (_pe_stdinH entry)
            case result of
              Left _ -> pure False
              Right () -> pure True
    }

-- | Read from a handle in a loop, appending to an IORef.
readLoop :: Handle -> IORef ByteString -> IO ()
readLoop h ref = go
  where
    go = do
      chunk <- try @SomeException (BS.hGetSome h 4096)
      case chunk of
        Left _  -> pure ()
        Right bs
          | BS.null bs -> pure ()
          | otherwise  -> do
              atomicModifyIORef' ref $ \old -> (old <> bs, ())
              go

-- | Get current status of a process entry.
getStatus :: ProcessEntry -> IO ProcessStatus
getStatus entry = do
  result <- Async.poll (_pe_exitAsync entry)
  stdout <- readIORef (_pe_stdoutRef entry)
  stderr <- readIORef (_pe_stderrRef entry)
  case result of
    Nothing              -> pure (ProcessRunning stdout stderr)
    Just (Right ec)      -> pure (ProcessDone ec stdout stderr)
    Just (Left _)        -> pure (ProcessDone (ExitFailure (-1)) stdout stderr)

-- | Build a ProcessInfo from a map entry.
toProcessInfo :: (Int, ProcessEntry) -> IO ProcessInfo
toProcessInfo (pid, entry) = do
  result <- Async.poll (_pe_exitAsync entry)
  let running = case result of
        Nothing -> True
        Just _  -> False
      exitCode = case result of
        Just (Right ec) -> Just ec
        _               -> Nothing
  pure ProcessInfo
    { _pi_id       = ProcessId pid
    , _pi_command  = _pe_command entry
    , _pi_running  = running
    , _pi_exitCode = exitCode
    }

-- | No-op process handle for testing.
mkNoOpProcessHandle :: ProcessHandle
mkNoOpProcessHandle = ProcessHandle
  { _ph_spawn      = \_ -> pure (ProcessId 1)
  , _ph_list       = pure []
  , _ph_poll       = \_ -> pure (Just (ProcessDone ExitSuccess "" ""))
  , _ph_kill       = \_ -> pure True
  , _ph_writeStdin = \_ _ -> pure True
  }
