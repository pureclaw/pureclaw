{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : PureClaw.Tabs.SessionPool
-- Description : Refcounted SessionId -> SessionHandle resource pool.
--
-- Since tabs no longer own session handles, and §6.5 sharing means two
-- cursors may resolve the same 'SessionId', there must be exactly __one__
-- resolved 'SessionHandle' per live 'SessionId'. This module owns that
-- mapping as a refcounted pool: it opens a handle when a session is first
-- 'acquire'd and closes it when the last holder 'release's it
-- (superseding the old one-handle-per-tab assumption and the
-- @_env_session@ single-session global).
--
-- The pool is __additive__: it is built and unit-tested here in isolation
-- (WU5) with injected open/close seams ('PoolDeps'), and wired into the
-- agent loop / 'AgentEnv' later (WU8). No real session IO happens in this
-- module — the opener and closer are supplied by the caller.
--
-- == Concurrency
--
-- The internal @'Data.Map.Strict.Map' 'SessionId' (Int, 'SessionHandle')@
-- (refcount + handle) lives behind an 'IORef' mutated only with
-- 'atomicModifyIORef''. Crucially, /no IO runs inside the atomic section/:
-- opening and closing a handle are real side effects, so they are
-- performed __outside__ 'atomicModifyIORef''. 'acquire' uses a
-- check-then-open-then-commit pattern:
--
--   1. Atomically: if the id is already present, bump its refcount and
--      return the existing handle (no open needed).
--   2. Otherwise open a fresh handle (IO, outside the lock), then
--      atomically commit it __only if the slot is still empty__. If a
--      racing thread inserted first, discard (close) our just-opened
--      handle and adopt theirs (bumping its refcount).
--
-- 'release' atomically decrements; when the count reaches zero it removes
-- the entry and hands the now-orphaned handle back to be closed outside
-- the atomic section. Releasing an absent or already-zero id is a safe
-- no-op (nothing to close).
--
-- See the Tabs-as-View refactor (GitHub #79) §13 for the design context.
module PureClaw.Tabs.SessionPool
  ( -- * Injected IO seams
    PoolDeps (..)
    -- * The pool
  , SessionPool (..)
  , newSessionPool
    -- * Acquire / release
  , acquire
  , release
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

import PureClaw.Core.Types (SessionId)
import PureClaw.Session.Handle (SessionHandle)

-- | The injected session-IO seams. Real implementations open / close
-- on-disk session handles; tests supply counting stubs so the pool's
-- refcount machinery can be driven without touching the filesystem.
data PoolDeps = PoolDeps
  { _pool_open  :: SessionId -> IO SessionHandle
    -- ^ Open (resolve) a fresh 'SessionHandle' for a 'SessionId'. Called
    -- at most once per live id — on the FIRST 'acquire'.
  , _pool_close :: SessionHandle -> IO ()
    -- ^ Close a 'SessionHandle'. Called exactly once per live id — on the
    -- LAST 'release' (refcount hits zero), and on the loser of an open
    -- race (its redundant handle is discarded).
  }

-- | The refcounted pool: a map from each live 'SessionId' to its current
-- refcount and the single shared 'SessionHandle'. An id is present in the
-- map iff its refcount is @>= 1@; entries are removed when the count
-- reaches zero, so absence is indistinguishable from "never acquired".
newtype SessionPool = SessionPool (IORef (Map SessionId (Int, SessionHandle)))

-- | Create a fresh, empty pool.
newSessionPool :: IO SessionPool
newSessionPool = SessionPool <$> newIORef Map.empty

-- | Acquire the shared 'SessionHandle' for a 'SessionId', opening it on
-- the first acquire and bumping the refcount on every subsequent one.
-- Two acquires of the same id always return the SAME handle.
--
-- The open (a real side effect) is performed outside the atomic section:
-- we first try to bump an existing entry atomically; only if the id is
-- absent do we open a new handle and then atomically commit it, closing a
-- redundant handle if a concurrent acquire won the race.
acquire :: PoolDeps -> SessionPool -> SessionId -> IO SessionHandle
acquire deps (SessionPool ref) sid = do
  -- Step 1: fast path — bump an existing entry's refcount atomically.
  mExisting <- atomicModifyIORef' ref $ \m ->
    case Map.lookup sid m of
      Just (n, h) -> (bump sid n h m, Just h)
      Nothing     -> (m, Nothing)
  case mExisting of
    Just h  -> pure h
    Nothing -> do
      -- Step 2: id absent — open OUTSIDE the atomic section.
      fresh <- _pool_open deps sid
      -- Step 3: commit only if still absent; otherwise adopt the winner's
      -- handle (bumping it) and close our now-redundant fresh one.
      (winner, redundant) <- atomicModifyIORef' ref $ \m ->
        case Map.lookup sid m of
          Just (n, h) -> (bump sid n h m, (h, Just fresh))
          Nothing     -> (bump sid 0 fresh m, (fresh, Nothing))
      mapM_ (_pool_close deps) redundant
      pure winner

-- | Strictly store @sid -> (n + 1, h)@. The refcount and handle are forced
-- (bang patterns) before insertion so the pool never accumulates a chain of
-- refcount thunks and the stored handle is always in WHNF. Used both to add
-- a brand-new entry (@n = 0@) and to increment an existing one.
bump
  :: SessionId
  -> Int
  -> SessionHandle
  -> Map SessionId (Int, SessionHandle)
  -> Map SessionId (Int, SessionHandle)
bump sid !n !h = Map.insert sid (n + 1, h)

-- | Release one hold on a 'SessionId'. Decrements its refcount; when the
-- count reaches zero the entry is removed and its handle closed. Releasing
-- an id that is absent (never acquired, or already fully released) is a
-- safe no-op: nothing is decremented and nothing is closed.
--
-- The close (a real side effect) is performed outside the atomic section.
release :: PoolDeps -> SessionPool -> SessionId -> IO ()
release deps (SessionPool ref) sid = do
  toClose <- atomicModifyIORef' ref $ \m ->
    case Map.lookup sid m of
      Nothing -> (m, Nothing)
      Just (n, h)
        | n <= 1    -> (Map.delete sid m, Just h)
        | otherwise -> (unbump sid n h m, Nothing)
  mapM_ (_pool_close deps) toClose

-- | Strictly store @sid -> (n - 1, h)@ for the not-last release. The decremented
-- refcount and handle are forced before insertion (same rationale as 'bump').
-- Only called on the @n > 1@ path, so the result is always @>= 1@.
unbump
  :: SessionId
  -> Int
  -> SessionHandle
  -> Map SessionId (Int, SessionHandle)
  -> Map SessionId (Int, SessionHandle)
unbump sid !n !h = Map.insert sid (n - 1, h)
