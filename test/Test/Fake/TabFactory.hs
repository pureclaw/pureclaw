-- |
-- Module      : Test.Fake.TabFactory
-- Description : T3 — pure tab factories scaffold (filled in by WU1).
--
-- This module is the scaffolded surface for T3. The production types
-- 'TabHandle', 'TabKind' and the factory signatures
-- 'mkTabAi'/'mkTabHarness'/'mkTabBackend' do not yet exist — they land in
-- WU1 ('PureClaw.Handles.Tab'). Once they land, WU1 fills in the bodies
-- below to return pure stand-in 'TabHandle' values for dispatcher/registry
-- specs that do not need real provider/backend resources.
--
-- WU0 chose approach (b) from the WU0 spec — module skeleton with bodies
-- bottomed out at 'undefined' and a haddock note. This compiles under
-- @-Wall -Werror@ but trips at runtime if invoked. No WU0 test actually
-- calls these (every P/H/E/C/D/A/L/X/B/S/K/I/O DoD is 'pending' in WU0),
-- so the runtime bottom is safe until WU1 replaces it.
--
-- See @docs/tabbed-chat.md@ §"Test seams (T-series)" T3 and the WU0/WU1
-- entries in @.beads/plans/active-plan.md@.
module Test.Fake.TabFactory
  ( -- * Factory scaffolds (filled in by WU1)
    mkFakeTabAi
  , mkFakeTabHarness
  , mkFakeTabBackend
    -- * Approach marker
  , t3Approach
    -- * T4 — synchronous-fork helper
    --
    -- The TabRunner-shaped wrapper that T4 mandates lives in WU1; the
    -- IORef-Bool cancel-observability primitive lands here in WU0 so WU1
    -- can wrap it without redefining the synchronous semantics.
  , SyncForkResult (..)
  , syncForkObservable
  ) where

import Data.IORef (IORef, atomicWriteIORef, newIORef)

-- | Identifier of the T3 scaffolding approach chosen in WU0. Keeps the
-- decision discoverable in source so the WU1 implementation knows which
-- contract to honour when filling in the factory bodies.
--
-- Approach (b): module skeleton with @undefined@ bodies — see this
-- module's haddock for rationale.
t3Approach :: String
t3Approach = "b"

-- | Scaffold for @mkFakeTabAi@. WU1 fills in: returns a pure
-- 'TabHandle' impersonating an AI tab for dispatcher/registry specs.
--
-- Runtime bottom — calling this in WU0 is a programmer error; no DoD in
-- WU0 invokes it (all are 'pending').
mkFakeTabAi :: a
mkFakeTabAi = error "Test.Fake.TabFactory.mkFakeTabAi: scaffolded by WU0, filled in by WU1"

-- | Scaffold for @mkFakeTabHarness@. See 'mkFakeTabAi'.
mkFakeTabHarness :: a
mkFakeTabHarness = error "Test.Fake.TabFactory.mkFakeTabHarness: scaffolded by WU0, filled in by WU1"

-- | Scaffold for @mkFakeTabBackend@. See 'mkFakeTabAi'.
mkFakeTabBackend :: a
mkFakeTabBackend = error "Test.Fake.TabFactory.mkFakeTabBackend: scaffolded by WU0, filled in by WU1"

-- ---------------------------------------------------------------------------
-- T4 — synchronous-fork primitive
-- ---------------------------------------------------------------------------

-- | Result of running 'syncForkObservable': the body has already executed
-- inline (synchronously), the 'IORef' flips to 'True' on the first
-- (idempotent) 'srf_cancel' invocation, and 'srf_wait' returns immediately
-- because the body has already completed.
--
-- WU1 will wrap this into a real @TabRunner@ value once the type lands in
-- @PureClaw.Handles.Tab@.
data SyncForkResult = SyncForkResult
  { _srf_cancelFlag :: !(IORef Bool)
    -- ^ Test-observable: flips to 'True' on the first 'srf_cancel' call.
  , _srf_cancel     :: !(IO ())
    -- ^ Idempotent cancel — writes 'True' into '_srf_cancelFlag'.
  , _srf_wait       :: !(IO ())
    -- ^ Wait — no-op for the synchronous variant; the body has already run.
  }

-- | Run an action inline and return a 'SyncForkResult' whose cancel flag
-- the test can observe.
--
-- Cancellation semantics: the body has already completed by the time the
-- caller can invoke '_srf_cancel', so the cancel just records that it was
-- requested (the IORef writes 'True'). This matches T4's contract: tests
-- assert against the cancel flag, not the body's execution path. Where
-- concurrency is essential to the test (C1, C6), the production async
-- fork is used instead.
syncForkObservable :: IO () -> IO SyncForkResult
syncForkObservable body = do
  flag <- newIORef False
  body
  pure SyncForkResult
    { _srf_cancelFlag = flag
    , _srf_cancel     = atomicWriteIORef flag True
    , _srf_wait       = pure ()
    }
