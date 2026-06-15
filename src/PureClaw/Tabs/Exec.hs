{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : PureClaw.Tabs.Exec
-- Description : Refcounted per-'TabRef' runtime registry (8b.3b).
--
-- The Tabs-as-View cutover (GitHub #79) moves the execution unit from
-- /per-tab/ to /per-ground-truth-ref/ (spike §3): a single live 'Runtime'
-- drives each bound 'TabRef', shared by every tab/conversation that resolves
-- it. This module owns that mapping as a refcounted registry — the SAME
-- refcount discipline as "PureClaw.Tabs.SessionPool", only it holds started
-- 'Runtime' values instead of @SessionHandle@s:
--
--   * 'ensure' starts a runtime (via the injected '_ex_startRuntime') on the
--     FIRST bind of a ref and bumps the refcount on every subsequent bind.
--   * 'release' decrements; on the LAST release it '_rt_stop's the runtime
--     and removes the entry. Releasing an absent / already-zero ref is a safe
--     no-op.
--   * 'sendTo' routes one input to a ref's runtime via '_rt_send'; an absent
--     ref returns @'Left' 'TabNotFound'@ (no such runtime) rather than
--     throwing.
--   * 'stopAll' stops every live runtime and clears the registry.
--
-- == Injected construction (8c wires the real bodies)
--
-- Runtime CONSTRUCTION is injected through 'ExecDeps' ('_ex_startRuntime'),
-- so this module is fully unit-testable with a fake. The real provider /
-- harness runtime bodies (enqueue-to-worker for providers, @_hh_send@ for
-- harnesses) are built later in 8c against the live @AgentEnv@; this module
-- only owns the refcount + lifecycle machinery and never performs real
-- provider / tmux IO itself.
--
-- == Concurrency
--
-- The internal @'Data.Map.Strict.Map' 'TabRef' (Int, 'Runtime')@ (refcount +
-- runtime) lives behind an 'IORef' mutated only with 'atomicModifyIORef''.
-- Crucially, /no IO runs inside the atomic section/: starting and stopping a
-- runtime are real side effects (forking workers / drainers, cancelling
-- threads), so they are performed __outside__ 'atomicModifyIORef''. This
-- mirrors 'PureClaw.Tabs.SessionPool' exactly:
--
--   * 'ensure' uses a bump-if-present, else start-outside-the-lock,
--     then-commit-if-still-absent pattern. On a lost race it adopts the
--     winner's runtime and stops its own redundant one.
--   * 'release' atomically decrements; the orphaned runtime (at refcount 0)
--     is captured and stopped outside the lock.
--   * 'sendTo' atomically reads the runtime out (no IO in the atomic
--     section), then calls '_rt_send' outside it.
--   * 'stopAll' atomically swaps the map for empty and stops every captured
--     runtime outside the lock.
--
-- See the Tabs-as-View execution-binding spike (§3/§6) for the design.
module PureClaw.Tabs.Exec
  ( -- * Started runtime
    Runtime (..)
    -- * Injected IO seam
  , ExecDeps (..)
    -- * The registry
  , Exec (..)
  , newExec
    -- * Lifecycle / routing
  , ensure
  , release
  , sendTo
  , stopAll
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import PureClaw.Handles.Tab (TabError (..))
import PureClaw.Tabs.Types (TabRef)

-- | A started runtime: how to feed it input and how to stop it.
--
-- For a provider ref, '_rt_send' enqueues a user message onto the worker
-- queue (the worker serializes turns); for a harness ref it forwards to
-- @_hh_send@. '_rt_stop' is idempotent (cancels worker / drainer threads)
-- and never throws. Both bodies are injected by '_ex_startRuntime' — this
-- module never constructs them itself.
data Runtime = Runtime
  { _rt_send :: Text -> IO (Either TabError ())
    -- ^ Route one input to this runtime.
  , _rt_stop :: IO ()
    -- ^ Idempotent stop; never throws.
  }

-- | The injected runtime-construction seam. The real implementation builds +
-- starts a provider or harness runtime for a ref against the live
-- @AgentEnv@ (wired in 8c); tests supply a recording fake so the registry's
-- refcount machinery can be driven without a live LLM or tmux.
newtype ExecDeps = ExecDeps
  { _ex_startRuntime :: TabRef -> IO Runtime
    -- ^ Build + start a runtime for a ref. Called at most once per live ref
    -- — on the FIRST 'ensure' (and once more on the losing side of a start
    -- race, whose redundant runtime is then stopped).
  }

-- | The refcounted registry: a map from each live 'TabRef' to its current
-- refcount and the single shared 'Runtime'. A ref is present in the map iff
-- its refcount is @>= 1@; entries are removed when the count reaches zero, so
-- absence is indistinguishable from "never ensured".
newtype Exec = Exec (IORef (Map TabRef (Int, Runtime)))

-- | Create a fresh, empty registry.
newExec :: IO Exec
newExec = Exec <$> newIORef Map.empty

-- | Ensure a runtime is live for a 'TabRef': start it on the first 'ensure'
-- and bump the refcount on every subsequent one. Two ensures of the same ref
-- always share the SAME runtime.
--
-- The start (a real side effect — forking workers / drainers) is performed
-- outside the atomic section: we first try to bump an existing entry
-- atomically; only if the ref is absent do we start a new runtime and then
-- atomically commit it, stopping the redundant runtime if a concurrent
-- ensure won the race.
ensure :: ExecDeps -> Exec -> TabRef -> IO ()
ensure deps (Exec ref) tref = do
  -- Step 1: fast path — bump an existing entry's refcount atomically.
  present <- atomicModifyIORef' ref $ \m ->
    case Map.lookup tref m of
      Just (n, rt) -> (bump tref n rt m, True)
      Nothing      -> (m, False)
  if present
    then pure ()
    else do
      -- Step 2: ref absent — start OUTSIDE the atomic section.
      fresh <- _ex_startRuntime deps tref
      -- Step 3: commit only if still absent; otherwise adopt the winner's
      -- runtime (bumping it) and stop our now-redundant fresh one.
      redundant <- atomicModifyIORef' ref $ \m ->
        case Map.lookup tref m of
          Just (n, rt) -> (bump tref n rt m, Just fresh)
          Nothing      -> (bump tref 0 fresh m, Nothing)
      mapM_ _rt_stop redundant

-- | Strictly store @tref -> (n + 1, rt)@. The refcount and runtime are forced
-- (bang patterns) before insertion so the registry never accumulates a chain
-- of refcount thunks and the stored runtime is always in WHNF. Used both to
-- add a brand-new entry (@n = 0@) and to increment an existing one.
bump
  :: TabRef
  -> Int
  -> Runtime
  -> Map TabRef (Int, Runtime)
  -> Map TabRef (Int, Runtime)
bump tref !n !rt = Map.insert tref (n + 1, rt)

-- | Release one hold on a 'TabRef'. Decrements its refcount; when the count
-- reaches zero the entry is removed and its runtime stopped. Releasing a ref
-- that is absent (never ensured, or already fully released) is a safe no-op:
-- nothing is decremented and nothing is stopped.
--
-- The stop (a real side effect) is performed outside the atomic section.
release :: Exec -> TabRef -> IO ()
release (Exec ref) tref = do
  toStop <- atomicModifyIORef' ref $ \m ->
    case Map.lookup tref m of
      Nothing -> (m, Nothing)
      Just (n, rt)
        | n <= 1    -> (Map.delete tref m, Just rt)
        | otherwise -> (unbump tref n rt m, Nothing)
  mapM_ _rt_stop toStop

-- | Strictly store @tref -> (n - 1, rt)@ for the not-last release. The
-- decremented refcount and runtime are forced before insertion (same
-- rationale as 'bump'). Only called on the @n > 1@ path, so the result is
-- always @>= 1@.
unbump
  :: TabRef
  -> Int
  -> Runtime
  -> Map TabRef (Int, Runtime)
  -> Map TabRef (Int, Runtime)
unbump tref !n !rt = Map.insert tref (n - 1, rt)

-- | Route one input to a ref's runtime. The runtime is read out of the map
-- atomically (no IO in the atomic section); '_rt_send' is then called outside
-- it. An absent ref (no live runtime) returns @'Left' ('TabNotFound' 0)@ —
-- the "no such runtime" signal — rather than throwing, so the dispatcher can
-- surface it as a user-visible error and keep routing.
sendTo :: Exec -> TabRef -> Text -> IO (Either TabError ())
sendTo (Exec ref) tref t = do
  mRt <- atomicModifyIORef' ref $ \m ->
    (m, fmap snd (Map.lookup tref m))
  case mRt of
    Nothing -> pure (Left (TabNotFound 0))
    Just rt -> _rt_send rt t

-- | Stop every live runtime and clear the registry. The map is atomically
-- swapped for empty (capturing all runtimes); each captured runtime is then
-- '_rt_stop'ped outside the atomic section. Idempotent: a second 'stopAll'
-- on the now-empty registry stops nothing.
stopAll :: Exec -> IO ()
stopAll (Exec ref) = do
  runtimes <- atomicModifyIORef' ref $ \m ->
    (Map.empty, map snd (Map.elems m))
  mapM_ _rt_stop runtimes
