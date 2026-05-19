-- |
-- Module      : PureClaw.Routing.Registry
-- Description : Pure tab CRUD over the AgentEnv's tab map (Tabbed Chat WU3).
--
-- This module owns the in-memory tab registry — an
-- @'IORef' ('IntMap' 'TabHandle')@ stored as
-- 'PureClaw.Agent.Env._env_tabs'. Functions here are deliberately
-- minimal: lookup, insert (rejecting the in-use case), remove, and a
-- @lowestFreeIndex@ helper used by the auto-spawn path.
--
-- No factory dispatch (that belongs to 'PureClaw.Routing.Dispatcher',
-- WU5), no spawning, no async exception discipline, no side effects
-- beyond reading\/writing the supplied 'IORef'.
--
-- See @docs\/tabbed-chat.md@ §\"Registry & AgentEnv (E-series)\" for
-- the design context.
module PureClaw.Routing.Registry
  ( -- * Pure tab CRUD
    lookupTab
  , insertTab
  , removeTab
  , lowestFreeIndex
    -- * tmux-style packing helper
  , packAfterRemove
  ) where

import Data.IORef (IORef, atomicModifyIORef', readIORef)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap

import PureClaw.Handles.Tab (TabError (..), TabHandle, TabIndex, mkTabIndex, unTabIndex)

-- | Look up a tab by index. Returns 'Nothing' if no tab is registered
-- at that slot.
lookupTab :: IORef (IntMap TabHandle) -> TabIndex -> IO (Maybe TabHandle)
lookupTab ref idx = do
  m <- readIORef ref
  pure (IntMap.lookup (unTabIndex idx) m)

-- | Insert a tab handle at the given index. Returns
-- @'Left' ('TabIndexInUse' idx)@ if the slot is already occupied
-- (callers must explicitly call 'removeTab' first if they want to
-- replace an existing tab).
insertTab :: IORef (IntMap TabHandle) -> TabIndex -> TabHandle
          -> IO (Either TabError ())
insertTab ref idx h =
  atomicModifyIORef' ref $ \m ->
    case IntMap.lookup (unTabIndex idx) m of
      Just _  -> (m, Left (TabIndexInUse idx))
      Nothing -> (IntMap.insert (unTabIndex idx) h m, Right ())

-- | Remove the tab at the given index. Returns the removed handle (or
-- 'Nothing' if no tab was present). The caller is responsible for
-- running any kind-specific close logic on the returned handle.
removeTab :: IORef (IntMap TabHandle) -> TabIndex -> IO (Maybe TabHandle)
removeTab ref idx =
  atomicModifyIORef' ref $ \m ->
    case IntMap.lookup (unTabIndex idx) m of
      Nothing -> (m, Nothing)
      Just h  -> (IntMap.delete (unTabIndex idx) m, Just h)

-- | Find the smallest non-negative 'TabIndex' that is strictly less
-- than the supplied @maxN@ ceiling AND is not currently occupied.
-- Returns 'Nothing' when every slot @0 .. maxN-1@ is taken (or when
-- @maxN <= 0@).
--
-- The expected caller is the auto-spawn path (WU9): given the
-- routing config's @_rc_maxTabs@, find a slot for a new tab.
lowestFreeIndex :: IORef (IntMap TabHandle) -> Int -> IO (Maybe TabIndex)
lowestFreeIndex ref maxN
  | maxN <= 0 = pure Nothing
  | otherwise = do
      m <- readIORef ref
      pure (firstFree m 0 maxN)
  where
    firstFree m n limit
      | n >= limit         = Nothing
      | IntMap.member n m  = firstFree m (n + 1) limit
      | otherwise          = mkTabIndex n

-- | Pure variant of the tmux-style \"renumber-windows\" pass: given a
-- map whose entry at index @k@ has already been removed, shift every
-- entry strictly greater than @k@ down by one key. Keys @\< k@ are
-- left untouched.
--
-- This is a no-op when no key exceeds @k@. The pass is value-preserving
-- (only keys are remapped); duplicates cannot arise because the
-- pre-shift map has unique keys and the shift is monotone.
packAfterRemove :: Int -> IntMap a -> IntMap a
packAfterRemove k =
  -- Walk in ascending order so the destination key for an entry is
  -- always free by the time we write it (the previous entry at that
  -- key was either removed or also shifted down).
  IntMap.foldlWithKey'
    (\acc i v ->
       if i > k
         then IntMap.insert (i - 1) v acc
         else IntMap.insert i v acc)
    IntMap.empty
