-- |
-- Module      : Backend.PtySpec
-- Description : Drainer + fakePtyIO + buffer-quota DoDs (WU7).
--
-- Flips DoDs from "pending" to green:
--
-- * #13 — Pty backend with oversized read latches 'RecvTruncated'.
-- * #22 — Pty backend with no bytes returns @RecvTimedOut \"\"@ within
--   the configured @idleTimeoutMs@.
-- * #23 — Construction-time oversubscription of the process-wide
--   recv-buffer quota returns @Left (BackendBufferQuotaExceeded n)@.
--
-- See @docs\/terminal-backend-abstractions.md@ § "Idle state machine"
-- and § "Per-process recv buffer cap" for spec.
module Backend.PtySpec (spec) where

import Control.Concurrent.Async qualified as Async
import Data.ByteString qualified as BS
import Test.Hspec

import PureClaw.Backend.Pty
  ( PtyIO (..)
  , PtyOpenSpec (..)
  , drainerRecv
  , mkDrainerBackendHandle
  , newDrainState
  , runDrainerLoop
  )
import PureClaw.Backend.Pty.Fake (FakePtyConfig (..), fakePtyIO)
import PureClaw.Handles.Backend
  ( BackendError (..)
  , BackendHandle (..)
  , BackendKind (..)
  , Cols (..)
  , PtyOpts (..)
  , RecvResult (..)
  , Rows (..)
  , defaultPtyOpts
  , recvBytes
  , recvOutcome
  , RecvOutcome (..)
  , setGlobalBackendBufferQuotaForTest
  , testIdleSpec
  )
import PureClaw.Internal.FakeClock (newFakeClock)

-- | A dummy 'PtyOpenSpec' for tests. fakePtyIO ignores the program/args/env;
-- only geometry would matter for resize tests.
dummySpec :: PtyOpenSpec
dummySpec = PtyOpenSpec
  { _pos_program = "dummy"
  , _pos_args    = []
  , _pos_env     = mempty
  , _pos_cwd     = Nothing
  , _pos_cols    = Cols 80
  , _pos_rows    = Rows 24
  }

spec :: Spec
spec = do
  describe "WU7 — drainer + fakePtyIO" $ do

    -- docs/terminal-backend-abstractions.md line 62: RecvTruncated latches
    it "DoD #13: oversized read past recv-buffer cap latches RecvTruncated" $ do
      clock <- newFakeClock
      let bigChunk = BS.replicate 64 0x41 -- 64 bytes of 'A'
          cfg = FakePtyConfig
            { _fpc_clock         = clock
            , _fpc_initialOutput = mempty
            , _fpc_eofAfterBytes = Nothing
            , _fpc_outputScript  = [bigChunk]
            }
      pio <- fakePtyIO cfg
      fds <- _pio_open pio dummySpec
      st  <- newDrainState
      -- recv buffer cap = 16 bytes: 64 > 16, so the very first chunk
      -- trips the truncate latch.
      a   <- runDrainerLoop pio fds 16 st
      r1  <- drainerRecv st testIdleSpec
      r2  <- drainerRecv st testIdleSpec
      Async.cancel a
      recvOutcome r1 `shouldBe` Truncated
      recvOutcome r2 `shouldBe` Truncated -- latch persists

    -- docs/terminal-backend-abstractions.md line 69: RecvTimedOut on no bytes
    it "DoD #22: drainerRecv returns RecvTimedOut \"\" when no bytes arrive" $ do
      -- Direct drainer-level test: no drainer Async is started, so
      -- the queue stays empty and 'drainerRecv' blocks until the
      -- @idleTimeoutMs@ timer fires. Asserts the waiting-for-first-
      -- byte → timed-out edge of the state machine.
      st <- newDrainState
      r  <- drainerRecv st testIdleSpec
      r `shouldBe` RecvTimedOut BS.empty

    it "DoD #22: full Pty backend recv on a silent fake returns RecvTimedOut \"\"" $ do
      clock <- newFakeClock
      -- _fpc_eofAfterBytes = Nothing means the read blocks forever
      -- once the (empty) script is exhausted: no chunks, no EOF.
      let cfg = FakePtyConfig
            { _fpc_clock         = clock
            , _fpc_initialOutput = mempty
            , _fpc_eofAfterBytes = Nothing
            , _fpc_outputScript  = []
            }
      pio <- fakePtyIO cfg
      let opts = defaultPtyOpts
            { _pto_idle          = testIdleSpec
            , _pto_recvBufferCap = 4096
            }
      eh <- mkDrainerBackendHandle pio opts dummySpec Pty
      case eh of
        Left err -> expectationFailure $ "construction failed: " <> show err
        Right h  -> do
          r <- _bh_recv h Nothing
          _bh_close h
          recvOutcome r `shouldBe` TimedOut
          recvBytes r `shouldBe` BS.empty

    -- docs/terminal-backend-abstractions.md line 70: process-wide quota
    describe "DoD #23: process-wide recv-buffer quota" $ do

      it "returns Left BackendBufferQuotaExceeded on oversubscription" $ do
        -- Shrink the process-wide quota to 4 MiB for this test.
        setGlobalBackendBufferQuotaForTest 4
        clock <- newFakeClock
        let cfg = FakePtyConfig
              { _fpc_clock         = clock
              , _fpc_initialOutput = mempty
              , _fpc_eofAfterBytes = Just 1
              , _fpc_outputScript  = []
              }
        pio <- fakePtyIO cfg
        let opts4MiB = defaultPtyOpts
              { _pto_recvBufferCap = 4 * 1024 * 1024 -- 4 MiB
              , _pto_idle          = testIdleSpec
              }
        -- First backend acquires all 4 MiB.
        eh1 <- mkDrainerBackendHandle pio opts4MiB dummySpec Pty
        case eh1 of
          Left e   -> expectationFailure $ "first construction failed: " <> show e
          Right h1 -> do
            -- Second backend at the same size would exceed the quota.
            eh2 <- mkDrainerBackendHandle pio opts4MiB dummySpec Pty
            case eh2 of
              Left (BackendBufferQuotaExceeded n) -> do
                n `shouldBe` 4
                _bh_close h1
              Left other ->
                expectationFailure $ "wrong error: " <> show other
              Right h2 -> do
                _bh_close h1
                _bh_close h2
                expectationFailure "expected BackendBufferQuotaExceeded"
        -- Restore the default quota so subsequent tests aren't affected.
        setGlobalBackendBufferQuotaForTest 64

      it "releases the quota on _bh_close" $ do
        setGlobalBackendBufferQuotaForTest 4
        clock <- newFakeClock
        let cfg = FakePtyConfig
              { _fpc_clock         = clock
              , _fpc_initialOutput = mempty
              , _fpc_eofAfterBytes = Just 1
              , _fpc_outputScript  = []
              }
        pio <- fakePtyIO cfg
        let opts4MiB = defaultPtyOpts
              { _pto_recvBufferCap = 4 * 1024 * 1024
              , _pto_idle          = testIdleSpec
              }
        eh1 <- mkDrainerBackendHandle pio opts4MiB dummySpec Pty
        case eh1 of
          Right h1 -> _bh_close h1
          Left e   -> expectationFailure ("first ctor failed: " <> show e)
        -- After release, a second construction should succeed.
        eh2 <- mkDrainerBackendHandle pio opts4MiB dummySpec Pty
        case eh2 of
          Right h2 -> _bh_close h2
          Left e   -> expectationFailure ("second ctor failed: " <> show e)
        setGlobalBackendBufferQuotaForTest 64

      it "construction with 0-byte recv cap acquires nothing and always succeeds" $ do
        setGlobalBackendBufferQuotaForTest 0 -- empty quota
        clock <- newFakeClock
        let cfg = FakePtyConfig
              { _fpc_clock         = clock
              , _fpc_initialOutput = mempty
              , _fpc_eofAfterBytes = Just 1
              , _fpc_outputScript  = []
              }
        pio <- fakePtyIO cfg
        let opts0 = defaultPtyOpts
              { _pto_recvBufferCap = 0
              , _pto_idle          = testIdleSpec
              }
        eh <- mkDrainerBackendHandle pio opts0 dummySpec Pty
        case eh of
          Right h -> _bh_close h
          Left e  -> expectationFailure ("ctor failed: " <> show e)
        setGlobalBackendBufferQuotaForTest 64

      it "rejects with the correct MiB count on oversubscription" $ do
        setGlobalBackendBufferQuotaForTest 1
        clock <- newFakeClock
        let cfg = FakePtyConfig
              { _fpc_clock         = clock
              , _fpc_initialOutput = mempty
              , _fpc_eofAfterBytes = Just 1
              , _fpc_outputScript  = []
              }
        pio <- fakePtyIO cfg
        let opts5MiB = defaultPtyOpts
              { _pto_recvBufferCap = 5 * 1024 * 1024 -- 5 MiB > 1 MiB quota
              , _pto_idle          = testIdleSpec
              }
        eh <- mkDrainerBackendHandle pio opts5MiB dummySpec Pty
        case eh of
          Left (BackendBufferQuotaExceeded n) -> n `shouldBe` 5
          Left other ->
            expectationFailure $ "wrong error: " <> show other
          Right h -> do
            _bh_close h
            expectationFailure "expected BackendBufferQuotaExceeded"
        setGlobalBackendBufferQuotaForTest 64

