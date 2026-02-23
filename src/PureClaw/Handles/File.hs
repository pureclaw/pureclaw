module PureClaw.Handles.File
  ( -- * Handle type
    FileHandle (..)
    -- * Implementations
  , mkFileHandle
  , mkNoOpFileHandle
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either
import System.Directory
import System.FilePath

import PureClaw.Core.Types
import PureClaw.Security.Path

-- | File system capability. Functions that only receive a 'FileHandle'
-- cannot shell out or access the network — they can only read and write
-- files within the workspace.
--
-- All operations require a 'SafePath', which guarantees the path has been
-- validated against the workspace root and blocked-path list.
data FileHandle = FileHandle
  { _fh_readFile  :: SafePath -> IO ByteString
  , _fh_writeFile :: SafePath -> ByteString -> IO ()
  , _fh_listDir   :: SafePath -> IO [SafePath]
  }

-- | Real file handle that performs actual filesystem operations.
-- 'listDir' validates each child entry through 'mkSafePath', filtering
-- out any blocked paths (e.g. @.env@).
mkFileHandle :: WorkspaceRoot -> FileHandle
mkFileHandle root = FileHandle
  { _fh_readFile  = BS.readFile . getSafePath
  , _fh_writeFile = \sp bs -> BS.writeFile (getSafePath sp) bs
  , _fh_listDir   = \sp -> do
      let dir = getSafePath sp
      entries <- listDirectory dir
      results <- mapM (mkSafePath root . (dir </>)) entries
      pure (rights results)
  }

-- | No-op file handle. Read returns empty, write is silent, list returns empty.
mkNoOpFileHandle :: FileHandle
mkNoOpFileHandle = FileHandle
  { _fh_readFile  = \_ -> pure BS.empty
  , _fh_writeFile = \_ _ -> pure ()
  , _fh_listDir   = \_ -> pure []
  }
