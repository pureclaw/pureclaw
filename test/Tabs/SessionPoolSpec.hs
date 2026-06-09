-- |
-- Module      : Tabs.SessionPoolSpec
-- Description : WU5 — refcounted SessionId -> SessionHandle pool.
--
-- Covers the WU5 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79). The pool resolves at most ONE 'SessionHandle' per live
-- 'SessionId': it opens on the first 'acquire' and closes on the last
-- 'release'. All session IO is injected through 'PoolDeps' so these unit
-- tests drive the refcount machinery deterministically with no real
-- session directories.
--
--   1. Refcount open/close — two acquires of one id open exactly once
--      (refcount 2); first release keeps it open; second release closes
--      exactly once and removes the entry.
--   2. Shared handle — two acquires of the same id return the SAME handle
--      (identity asserted via a unique per-open tag).
--   3. Distinct ids — acquiring two different ids opens two handles with
--      independent refcounts.
--   4. Release safety — releasing an absent / already-zero id is a no-op
--      that does not throw and does not call close.
module Tabs.SessionPoolSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Monad (void, when)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Session.Handle
  ( SessionHandle (..)
  , noOpSessionHandle
  )
import PureClaw.Tabs.SessionPool
  ( PoolDeps (..)
  , acquire
  , newSessionPool
  , release
  )

-- | Counters threaded through the injected open/close seams so each test
-- can assert how many times the pool actually opened or closed a handle.
data Counters = Counters
  { _c_opens  :: IORef Int
  , _c_closes :: IORef Int
  , _c_nextId :: IORef Int
    -- ^ Monotonic source of per-open identity tags. Each opened handle
    -- gets a unique tag (rendered into '_sh_dir') so tests can assert
    -- handle identity by reading it back.
  }

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef 0

-- | Build 'PoolDeps' whose opener mints a fresh, identifiable
-- 'SessionHandle' on every call and whose closer just tallies. The handle's
-- identity tag is stored in '_sh_dir' (e.g. @\"open-0\"@), which the tests
-- read back to assert that two acquires of one id share a single handle.
mkDeps :: Counters -> PoolDeps
mkDeps c = PoolDeps
  { _pool_open = \_sid -> do
      tag <- atomicModifyIORef' (_c_nextId c) (\n -> (n + 1, n))
      atomicModifyIORef' (_c_opens c) (\n -> (n + 1, ()))
      pure (handleWithTag ("open-" <> show tag))
  , _pool_close = \_sh ->
      atomicModifyIORef' (_c_closes c) (\n -> (n + 1, ()))
  }

-- | A minimal 'SessionHandle' whose '_sh_dir' carries an identity tag.
-- Every other field is borrowed from the exported 'noOpSessionHandle'
-- sentinel (shared meta IORef + no-op transcript + no-op save); only
-- '_sh_dir' is overridden, and the tests only ever read '_sh_dir'.
handleWithTag :: String -> SessionHandle
handleWithTag tag = noOpSessionHandle { _sh_dir = tag }

spec :: Spec
spec = do
  describe "acquire / release refcounting" $ do
    it "opens once for two acquires (refcount 2) and closes on the last release" $ do
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      let sid = SessionId "alpha"
      _ <- acquire deps pool sid
      _ <- acquire deps pool sid
      readIORef (_c_opens c)  `shouldReturn` 1
      readIORef (_c_closes c) `shouldReturn` 0
      -- First release: refcount drops 2 -> 1, handle stays open.
      release deps pool sid
      readIORef (_c_closes c) `shouldReturn` 0
      -- Second release: refcount drops 1 -> 0, handle closed exactly once.
      release deps pool sid
      readIORef (_c_closes c) `shouldReturn` 1
      readIORef (_c_opens c)  `shouldReturn` 1

    it "re-opens after the entry was fully released and removed" $ do
      -- Proves the entry is REMOVED at refcount 0: a fresh acquire opens
      -- a brand-new handle rather than resurrecting a zombie entry.
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      let sid = SessionId "alpha"
      _ <- acquire deps pool sid
      release deps pool sid
      _ <- acquire deps pool sid
      readIORef (_c_opens c)  `shouldReturn` 2
      readIORef (_c_closes c) `shouldReturn` 1

  describe "shared handle identity" $ do
    it "returns the SAME handle for two acquires of one SessionId" $ do
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      let sid = SessionId "shared"
      h1 <- acquire deps pool sid
      h2 <- acquire deps pool sid
      -- Identity asserted via the unique per-open tag in '_sh_dir'.
      _sh_dir h1 `shouldBe` _sh_dir h2
      readIORef (_c_opens c) `shouldReturn` 1

  describe "distinct SessionIds" $ do
    it "opens two independent handles with independent refcounts" $ do
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      let a = SessionId "a"
          b = SessionId "b"
      ha <- acquire deps pool a
      hb <- acquire deps pool b
      _sh_dir ha `shouldNotBe` _sh_dir hb
      readIORef (_c_opens c) `shouldReturn` 2
      -- Releasing a closes exactly one handle; b is untouched and still open.
      release deps pool a
      readIORef (_c_closes c) `shouldReturn` 1
      release deps pool b
      readIORef (_c_closes c) `shouldReturn` 2

  describe "release safety" $ do
    it "is a no-op when releasing an id that was never acquired" $ do
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      release deps pool (SessionId "ghost")
      readIORef (_c_closes c) `shouldReturn` 0
      readIORef (_c_opens c)  `shouldReturn` 0

    it "is a no-op when releasing an id that is already at zero" $ do
      c <- newCounters
      let deps = mkDeps c
      pool <- newSessionPool
      let sid = SessionId "alpha"
      _ <- acquire deps pool sid
      release deps pool sid          -- closes, removes entry (refcount 0)
      release deps pool sid          -- already gone: must NOT close again
      readIORef (_c_closes c) `shouldReturn` 1

  describe "concurrent open race (single resolved handle invariant)" $ do
    it "lets one acquire win the commit and closes the loser's redundant handle" $ do
      -- Force the race: BOTH acquirers pass step-1 (id absent) and open a
      -- fresh handle before EITHER commits in step-3. We gate '_pool_open'
      -- on a barrier so neither open returns until two opens are in flight,
      -- guaranteeing the second committer takes the "already inserted"
      -- recovery branch — adopting the winner's handle and closing its own.
      c <- newCounters
      barrier <- newEmptyMVar :: IO (MVar ())
      inFlight <- newIORef (0 :: Int)
      let deps = PoolDeps
            { _pool_open = \_sid -> do
                n <- atomicModifyIORef' inFlight (\k -> (k + 1, k + 1))
                -- The 2nd open to arrive releases the barrier for both.
                when (n >= 2) (putMVar barrier ())
                _ <- readMVar barrier
                tag <- atomicModifyIORef' (_c_nextId c) (\k -> (k + 1, k))
                atomicModifyIORef' (_c_opens c) (\k -> (k + 1, ()))
                pure (handleWithTag ("open-" <> show tag))
            , _pool_close = \_sh ->
                atomicModifyIORef' (_c_closes c) (\k -> (k + 1, ()))
            }
      pool <- newSessionPool
      let sid = SessionId "raced"
      done1 <- newEmptyMVar
      done2 <- newEmptyMVar
      void $ forkIO (acquire deps pool sid >>= putMVar done1)
      void $ forkIO (acquire deps pool sid >>= putMVar done2)
      h1 <- takeMVar done1
      h2 <- takeMVar done2
      -- Both threads opened (race forced), but both see ONE shared handle.
      readIORef (_c_opens c)  `shouldReturn` 2
      _sh_dir h1 `shouldBe` _sh_dir h2
      -- The loser's redundant handle was closed exactly once.
      readIORef (_c_closes c) `shouldReturn` 1
      -- And the surviving entry has refcount 2: two releases close it once.
      release deps pool sid
      readIORef (_c_closes c) `shouldReturn` 1
      release deps pool sid
      readIORef (_c_closes c) `shouldReturn` 2
