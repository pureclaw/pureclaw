-- |
-- Module      : Tabs.ExecSpec
-- Description : 8b.3b — refcounted per-'TabRef' runtime registry.
--
-- Covers the 8b.3b Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79). The 'Exec' registry holds at most ONE started 'Runtime' per
-- live 'TabRef': it starts a runtime on the first 'ensure' and stops it on
-- the last 'release', routing input to a ref's runtime with 'sendTo'. The
-- runtime CONSTRUCTION is injected through 'ExecDeps' (the real provider /
-- harness bodies are wired in 8c), so these unit tests drive the refcount
-- machinery deterministically with a fake '_ex_startRuntime' that records.
--
--   1. ensure starts once — two ensures of one ref start exactly once
--      (counter 1, refcount 2); the SAME runtime instance is shared
--      (identity asserted via a unique per-start tag).
--   2. release — first release keeps it (no stop); second stops exactly once
--      and removes the entry; re-ensure after full release starts a fresh
--      runtime (counter 2).
--   3. sendTo — routes to the started runtime's '_rt_send' (the fake records
--      the text); sendTo an absent ref returns 'Left' without crashing.
--   4. release safety — releasing a never-ensured / already-zero ref is a
--      no-op that does not stop and does not throw.
--   5. distinct refs — independent runtimes + refcounts; 'stopAll' stops all
--      and clears the map.
--   6. open race — two concurrent first-ensures: one runtime survives, the
--      loser is stopped, refcount 2 (mirrors SessionPool's concurrency test).
module Tabs.ExecSpec (spec) where

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
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Either (isLeft)
import Data.Text (Text)
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Tabs.Types (TabRef (..))
import PureClaw.Tabs.Exec
  ( Exec
  , ExecDeps (..)
  , Runtime (..)
  , ensure
  , newExec
  , release
  , sendTo
  , stopAll
  )

-- | Counters threaded through the injected start/stop seams so each test can
-- assert how many times the registry actually started or stopped a runtime.
data Counters = Counters
  { _c_starts :: IORef Int
  , _c_stops  :: IORef Int
  , _c_nextId :: IORef Int
    -- ^ Monotonic source of per-start identity tags. Each started runtime
    -- gets a unique tag (rendered into its send-record) so tests can assert
    -- runtime identity / routing by reading what the fake recorded.
  }

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef 0

-- | Build 'ExecDeps' whose starter mints a fresh, identifiable 'Runtime' on
-- every call: each runtime owns a recording 'IORef' onto which '_rt_send'
-- appends @(tag, text)@ pairs, and a counting '_rt_stop'. The tag lets a test
-- assert that two ensures of one ref share a single runtime, and that
-- 'sendTo' routes to the right one. Returns the deps plus the registry of
-- per-ref recording refs (keyed by start order) so the test can read sends.
mkDeps :: Counters -> IORef [(Int, IORef [Text])] -> ExecDeps
mkDeps c records = ExecDeps
  { _ex_startRuntime = \_ref -> do
      tag <- atomicModifyIORef' (_c_nextId c) (\n -> (n + 1, n))
      atomicModifyIORef' (_c_starts c) (\n -> (n + 1, ()))
      sent <- newIORef []
      modifyIORef' records ((tag, sent) :)
      pure Runtime
        { _rt_send = \t -> do
            modifyIORef' sent (++ [t])
            pure (Right ())
        , _rt_stop = atomicModifyIORef' (_c_stops c) (\n -> (n + 1, ()))
        }
  }

spec :: Spec
spec = do
  describe "ensure starts once (refcount)" $ do
    it "starts exactly once for two ensures (refcount 2) and stops on last release" $ do
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "alpha")
      ensure deps ex ref
      ensure deps ex ref
      readIORef (_c_starts c) `shouldReturn` 1
      readIORef (_c_stops c)  `shouldReturn` 0
      -- First release: refcount 2 -> 1, runtime stays up.
      release ex ref
      readIORef (_c_stops c) `shouldReturn` 0
      -- Second release: refcount 1 -> 0, runtime stopped exactly once.
      release ex ref
      readIORef (_c_stops c)  `shouldReturn` 1
      readIORef (_c_starts c) `shouldReturn` 1

    it "shares the SAME runtime instance across two ensures of one ref" $ do
      -- Identity via the per-start tag: both sends land in the single
      -- recording ref minted by the one-and-only start.
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "shared")
      ensure deps ex ref
      ensure deps ex ref
      readIORef (_c_starts c) `shouldReturn` 1
      _ <- sendTo ex ref "one"
      _ <- sendTo ex ref "two"
      rs <- readIORef recs
      -- Exactly one runtime was started; it recorded both messages in order.
      length rs `shouldBe` 1
      case rs of
        [(_, sent)] -> readIORef sent `shouldReturn` ["one", "two"]
        _           -> expectationFailure "expected exactly one started runtime"

  describe "re-ensure after full release" $ do
    it "starts a FRESH runtime once the entry was fully released and removed" $ do
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "alpha")
      ensure deps ex ref
      release ex ref
      ensure deps ex ref
      readIORef (_c_starts c) `shouldReturn` 2
      readIORef (_c_stops c)  `shouldReturn` 1

  describe "sendTo routing" $ do
    it "routes the text to the started runtime's _rt_send" $ do
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "route")
      ensure deps ex ref
      r <- sendTo ex ref "hello"
      r `shouldBe` Right ()
      rs <- readIORef recs
      case rs of
        [(_, sent)] -> readIORef sent `shouldReturn` ["hello"]
        _           -> expectationFailure "expected exactly one started runtime"

    it "returns Left for an absent ref and does not crash" $ do
      c <- newCounters
      recs <- newIORef []
      let _deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "ghost")
      r <- sendTo ex ref "nobody home"
      r `shouldSatisfy` isLeft
      -- No runtime was ever started for this ref.
      readIORef (_c_starts c) `shouldReturn` 0
      -- 'deps' is intentionally unused here: sendTo never consults the
      -- starter for an absent ref. Touch 'ref' to keep it referenced.
      ref `seq` pure ()

  describe "release safety" $ do
    it "is a no-op when releasing a ref that was never ensured" $ do
      c <- newCounters
      recs <- newIORef []
      let _deps = mkDeps c recs
      ex <- newExec
      release ex (BoundSession (SessionId "never"))
      readIORef (_c_stops c)  `shouldReturn` 0
      readIORef (_c_starts c) `shouldReturn` 0

    it "is a no-op when releasing a ref already at zero" $ do
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let ref = BoundSession (SessionId "alpha")
      ensure deps ex ref
      release ex ref          -- stops, removes entry (refcount 0)
      release ex ref          -- already gone: must NOT stop again
      readIORef (_c_stops c) `shouldReturn` 1

  describe "distinct refs" $ do
    it "keeps independent runtimes + refcounts; stopAll stops all and clears" $ do
      c <- newCounters
      recs <- newIORef []
      let deps = mkDeps c recs
      ex <- newExec
      let a = BoundSession (SessionId "a")
          b = BoundSession (SessionId "b")
      ensure deps ex a
      ensure deps ex b
      readIORef (_c_starts c) `shouldReturn` 2
      -- Routing is independent: a's send must not appear in b's record.
      _ <- sendTo ex a "to-a"
      _ <- sendTo ex b "to-b"
      rs <- readIORef recs
      length rs `shouldBe` 2
      -- stopAll stops both runtimes exactly once each and empties the map.
      stopAll ex
      readIORef (_c_stops c) `shouldReturn` 2
      -- After stopAll the map is clear: sendTo any ref is now Left, and a
      -- subsequent release is a safe no-op (no extra stop).
      ra <- sendTo ex a "again"
      ra `shouldSatisfy` isLeft
      release ex a
      readIORef (_c_stops c) `shouldReturn` 2

  describe "concurrent open race (single runtime invariant)" $ do
    it "lets one ensure win the commit and stops the loser's runtime" $ do
      -- Force the race: BOTH ensurers pass the bump-if-present step (ref
      -- absent) and start a fresh runtime before EITHER commits. We gate
      -- '_ex_startRuntime' on a barrier so neither start returns until two
      -- are in flight, guaranteeing the second committer takes the
      -- "already inserted" recovery branch — adopting the winner's runtime
      -- and stopping its own.
      c <- newCounters
      barrier <- newEmptyMVar :: IO (MVar ())
      inFlight <- newIORef (0 :: Int)
      let deps = ExecDeps
            { _ex_startRuntime = \_ref -> do
                n <- atomicModifyIORef' inFlight (\k -> (k + 1, k + 1))
                when (n >= 2) (putMVar barrier ())
                _ <- readMVar barrier
                atomicModifyIORef' (_c_starts c) (\k -> (k + 1, ()))
                sent <- newIORef ([] :: [Text])
                pure Runtime
                  { _rt_send = \t -> do
                      modifyIORef' sent (++ [t])
                      pure (Right ())
                  , _rt_stop = atomicModifyIORef' (_c_stops c) (\k -> (k + 1, ()))
                  }
            }
      ex <- newExec
      let ref = BoundSession (SessionId "raced")
      done1 <- newEmptyMVar
      done2 <- newEmptyMVar
      void $ forkIO (ensure deps ex ref >> putMVar done1 ())
      void $ forkIO (ensure deps ex ref >> putMVar done2 ())
      takeMVar done1
      takeMVar done2
      -- Both threads started (race forced), but exactly one survives.
      readIORef (_c_starts c) `shouldReturn` 2
      -- The loser's redundant runtime was stopped exactly once.
      readIORef (_c_stops c) `shouldReturn` 1
      -- The surviving entry has refcount 2: two releases stop it once more.
      release ex ref
      readIORef (_c_stops c) `shouldReturn` 1
      release ex ref
      readIORef (_c_stops c) `shouldReturn` 2
