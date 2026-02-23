module PureClaw.Memory.None
  ( -- * Construction
    mkNoneMemoryHandle
  ) where

import PureClaw.Handles.Memory

-- | No-op memory handle. Equivalent to 'mkNoOpMemoryHandle' — exists
-- as a named backend for configuration selection.
mkNoneMemoryHandle :: MemoryHandle
mkNoneMemoryHandle = mkNoOpMemoryHandle
