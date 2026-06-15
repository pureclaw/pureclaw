-- |
-- Module      : PureClaw.Tabs
-- Description : Thin IORef handle over the pure 'TabList' registry.
--
-- 'TabRegistry' is the single mutable cell holding the ordered 'TabList'
-- (invariants I1\/I2 — see "PureClaw.Tabs.Types"). All mutation is delegated
-- to the pure operations in that module; this layer only owns the 'IORef'
-- and re-exports the value types for convenience. There is no global state —
-- the registry is constructed explicitly and passed by the caller (Handle
-- pattern).
--
-- See the Tabs-as-View refactor (GitHub #79) for the design context.
module PureClaw.Tabs
  ( -- * Registry handle
    TabRegistry (..)
  , newTabRegistry
  , readTabs
  , overwriteTabs
  , registryAppend
  , registryRemove
  , registryLookupSlot
  , registryLookupRef
  , registrySetStatus
    -- * Re-exports
  , module PureClaw.Tabs.Types
  ) where

import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Text (Text)

import PureClaw.Handles.Tab (TabIndex)
import PureClaw.Tabs.Types

-- | The mutable tab registry: a single 'IORef' over a pure 'TabList'.
newtype TabRegistry = TabRegistry (IORef TabList)

-- | Create an empty registry.
newTabRegistry :: IO TabRegistry
newTabRegistry = TabRegistry <$> newIORef emptyTabs

-- | Read the current 'TabList' snapshot.
readTabs :: TabRegistry -> IO TabList
readTabs (TabRegistry ref) = readIORef ref

-- | Replace the entire registry contents with @tl@, atomically. Used at boot
-- (WU8) to SEED the live shared registry from the reconciled 'TabList' that
-- 'PureClaw.Tabs.Persist.loadTabs' returns, BEFORE the frontend server or the
-- tabbed loop observe it. The supplied 'TabList' already satisfies the slot
-- invariants (it comes from 'loadTabs'\'s @rebuildTabs@), so this is a direct
-- swap — no per-tab re-append.
overwriteTabs :: TabRegistry -> TabList -> IO ()
overwriteTabs (TabRegistry ref) = atomicWriteIORef ref

-- | Append a tab binding @ref@ with label @name@, atomically. Returns the new
-- slot, or the pure 'TabsError' (dedup\/cap) without mutating on rejection.
registryAppend :: TabRegistry -> TabRef -> Text -> IO (Either TabsError TabIndex)
registryAppend (TabRegistry ref) tabRef name =
  atomicModifyIORef' ref $ \tl ->
    case appendTab tabRef name tl of
      Left err          -> (tl, Left err)
      Right (slot, tl') -> (tl', Right slot)

-- | Remove the tab at @slot@ and compact, atomically (no-op if absent).
registryRemove :: TabRegistry -> TabIndex -> IO ()
registryRemove (TabRegistry ref) slot =
  atomicModifyIORef' ref $ \tl -> (removeSlot slot tl, ())

-- | Look up the tab currently at @slot@.
registryLookupSlot :: TabRegistry -> TabIndex -> IO (Maybe Tab)
registryLookupSlot (TabRegistry ref) slot =
  lookupSlot slot <$> readIORef ref

-- | Look up the slot currently occupied by @ref@.
registryLookupRef :: TabRegistry -> TabRef -> IO (Maybe TabIndex)
registryLookupRef (TabRegistry ref) tabRef =
  lookupRef tabRef <$> readIORef ref

-- | Set the status of the tab bound to @ref@, atomically (no-op if absent).
registrySetStatus :: TabRegistry -> TabRef -> TabStatus -> IO ()
registrySetStatus (TabRegistry ref) tabRef status =
  atomicModifyIORef' ref $ \tl -> (setStatus tabRef status tl, ())
