-- |
-- Module      : Handles.BackendSpec
-- Description : WU0 red-phase scaffold for BackendHandle DoDs.
--
-- This module enumerates the cross-backend Definition-of-Done items from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1) as
-- pending Hspec tests. Each test is annotated with the DoD number from the
-- design doc; tests for DoDs not yet covered by landed production code
-- remain @pendingWith@.
--
-- WU3 flips #12, #14 (split per kind), #15, and #24 to green.
--
-- See @.beads/plans/active-plan.md@ WU0 / WU3 for the scaffold contract.
module Handles.BackendSpec (spec) where

import Control.Exception (SomeException, toException, try)
import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Test.Hspec

import PureClaw.Core.Types (CommandName (..))
import PureClaw.Handles.Backend
  ( BackendContext (BcSshDisconnect)
  , BackendError
    ( BackendBinaryNotFound
    , BackendBufferQuotaExceeded
    , BackendSshConnectFailed
    )
  , BackendException (..)
  , BackendHandle (..)
  , BackendKind (..)
  , Cols (..)
  , InMemoryConfig (..)
  , InMemoryState (..)
  , RecvResult (..)
  , Rows (..)
  , SshConnectFailure (..)
  , acquireBufferQuota
  , mkInMemoryBackendHandle
  , mkNoOpBackendHandle
  , newBackendBufferQuota
  , newInMemoryState
  , releaseBufferQuota
  )
import PureClaw.Internal.FakeClock (newFakeClock)
import PureClaw.Security.Policy qualified as Security.Policy

mkExn :: String -> SomeException
mkExn = toException . userError

spec :: Spec
spec = do
  describe "WU3 — No-op + in-memory backends (cross-backend DoDs)" $ do
    -- docs/terminal-backend-abstractions.md line 61: idempotent close
    it "DoD #12: _bh_close is idempotent and never throws (no-op backend)" $ do
      let h = mkNoOpBackendHandle Pty
      r1 <- try @SomeException (_bh_close h)
      r2 <- try @SomeException (_bh_close h)
      case (r1, r2) of
        (Right (), Right ()) -> pure ()
        (Left e, _)          -> expectationFailure $
          "first close threw: " <> show e
        (_, Left e)          -> expectationFailure $
          "second close threw: " <> show e

    -- docs/terminal-backend-abstractions.md line 63: no-op recv (Pty)
    it "DoD #14: mkNoOpBackendHandle Pty returns RecvSettled \"\" on _bh_recv Nothing" $ do
      let h = mkNoOpBackendHandle Pty
      r <- _bh_recv h Nothing
      r `shouldBe` RecvSettled BS.empty

    -- docs/terminal-backend-abstractions.md line 63: no-op recv (Pipe)
    it "DoD #14: mkNoOpBackendHandle Pipe likewise yields RecvSettled \"\"" $ do
      let h = mkNoOpBackendHandle Pipe
      r <- _bh_recv h Nothing
      r `shouldBe` RecvSettled BS.empty

    -- docs/terminal-backend-abstractions.md line 64: in-memory round-trip
    it "DoD #15: mkInMemoryBackendHandle round-trips bytes deterministically" $ do
      clock <- newFakeClock
      st    <- newInMemoryState
      let cfg = InMemoryConfig
            { _imc_clock           = clock
            , _imc_scriptedReplies = ["hello\n", "world\n"]
            , _imc_eofAfter        = Nothing
            , _imc_state           = st
            }
      h  <- mkInMemoryBackendHandle Pty cfg
      _bh_send h "x"
      r1 <- _bh_recv h Nothing
      r2 <- _bh_recv h Nothing
      r3 <- _bh_recv h Nothing
      r1 `shouldBe` RecvSettled "hello\n"
      r2 `shouldBe` RecvSettled "world\n"
      r3 `shouldBe` RecvEof BS.empty
      s  <- readIORef st
      _ims_sentBytes s   `shouldBe` ["x"]
      _ims_recvCalls s   `shouldBe` 3

    it "DoD #15: mkInMemoryBackendHandle honours _imc_eofAfter" $ do
      clock <- newFakeClock
      st    <- newInMemoryState
      let cfg = InMemoryConfig
            { _imc_clock           = clock
            , _imc_scriptedReplies = ["a", "b", "c"]
            , _imc_eofAfter        = Just 1
            , _imc_state           = st
            }
      h  <- mkInMemoryBackendHandle Pipe cfg
      r1 <- _bh_recv h Nothing
      r2 <- _bh_recv h Nothing
      r1 `shouldBe` RecvSettled "a"
      r2 `shouldBe` RecvEof BS.empty

    -- docs/terminal-backend-abstractions.md line 66: show redaction (WU2)
    describe "DoD #17: Show BackendException / BackendError / SshConnectFailure redacts hostnames + paths" $ do
      it "show (BackendBinaryNotFound _) is well-formed" $ do
        let rendered = show (BackendBinaryNotFound (CommandName "tmux"))
        rendered `shouldContain` "BackendBinaryNotFound"
        rendered `shouldContain` "tmux"

      it "show (BackendSshConnectFailed _) does not leak ssh stderr/hostname/path" $ do
        let rendered = show (BackendSshConnectFailed SshAuthRefused)
        rendered `shouldContain` "SshAuthRefused"
        rendered `shouldNotContain` "/"
        rendered `shouldNotContain` "."
        -- No literal IP-octet substring leaks from the underlying ADT.
        rendered `shouldNotContain` "192.168"

      it "show (BackendException ...) does not leak the cause verbatim" $ do
        let cause = mkExn "ssh: connect to host db.prod.example.com port 22: refused"
            rendered = show (BackendException BcSshDisconnect cause)
        rendered `shouldNotContain` "db.prod.example.com"
        rendered `shouldContain` "BackendException"
        rendered `shouldContain` "BcSshDisconnect"
        rendered `shouldContain` "<host>"

    -- docs/terminal-backend-abstractions.md line 73: haddock decision tree
    it "DoD #20: module-level haddock documents Pipe/Pty/decision tree (doctest)" $
      pendingWith "WU1: haddock decision tree in PureClaw.Handles.Backend; doctest asserts presence."

    -- docs/terminal-backend-abstractions.md line 70: process-wide buffer quota
    --
    -- The behavioural coverage of DoD #23 lives in 'Backend.PtySpec' (where
    -- the drainer-backed substrate that exercises the quota is also tested).
    -- Here we only smoke-test the type-layer wiring in 'Handles.Backend'.
    it "DoD #23: quota helpers acquire/release and reject oversubscription" $ do
      q   <- newBackendBufferQuota 4
      r1  <- acquireBufferQuota q 3
      r1 `shouldBe` Right ()
      r2  <- acquireBufferQuota q 2
      case r2 of
        Left (BackendBufferQuotaExceeded n) -> n `shouldBe` 2
        other -> expectationFailure $ "unexpected: " <> show other
      releaseBufferQuota q 3
      r3 <- acquireBufferQuota q 4
      r3 `shouldBe` Right ()

    -- docs/terminal-backend-abstractions.md line 71: no-op resize is a silent no-op
    it "DoD #24: mkNoOpBackendHandle Pipe _bh_resize is a silent no-op" $ do
      let h = mkNoOpBackendHandle Pipe
      r <- try @SomeException (_bh_resize h (Cols 80) (Rows 24))
      case r of
        Right () -> pure ()
        Left e   -> expectationFailure $ "Pipe no-op resize threw: " <> show e

    it "DoD #24: mkNoOpBackendHandle Pty _bh_resize is a silent no-op" $ do
      let h = mkNoOpBackendHandle Pty
      r <- try @SomeException (_bh_resize h (Cols 80) (Rows 24))
      case r of
        Right () -> pure ()
        Left e   -> expectationFailure $ "Pty no-op resize threw: " <> show e

    it "DoD #24: in-memory Pty backend records _bh_resize calls" $ do
      clock <- newFakeClock
      st    <- newInMemoryState
      let cfg = InMemoryConfig
            { _imc_clock           = clock
            , _imc_scriptedReplies = []
            , _imc_eofAfter        = Nothing
            , _imc_state           = st
            }
      h <- mkInMemoryBackendHandle Pty cfg
      _bh_resize h (Cols 100) (Rows 30)
      _bh_resize h (Cols 120) (Rows 40)
      s <- readIORef st
      -- Stored newest-first.
      _ims_resizeCalls s `shouldBe` [(Cols 120, Rows 40), (Cols 100, Rows 30)]

    it "DoD #24: in-memory Pipe backend does NOT record _bh_resize (silent no-op)" $ do
      clock <- newFakeClock
      st    <- newInMemoryState
      let cfg = InMemoryConfig
            { _imc_clock           = clock
            , _imc_scriptedReplies = []
            , _imc_eofAfter        = Nothing
            , _imc_state           = st
            }
      h <- mkInMemoryBackendHandle Pipe cfg
      _bh_resize h (Cols 80) (Rows 24)
      s <- readIORef st
      _ims_resizeCalls s `shouldBe` []

  describe "WU6 — SecurityPolicy migration (DoD #18)" $ do
    -- docs/terminal-backend-abstractions.md line 67: SecurityPolicy construction sites
    --
    -- The migration of every construction site to the new
    -- '_sp_allowedRemoteCommands' field is enforced at COMPILE time by
    -- '-Werror -Wall' (which implies '-Wmissing-fields') across src/,
    -- test/, app/. We cannot test a compile-time error inside a runtime
    -- suite, so this assertion exercises the runtime contract that the
    -- migration is meant to deliver: 'defaultPolicy' is deny-by-default
    -- for remote commands, and 'allowRemoteCommand' / 'denyRemoteCommand'
    -- behave per spec on that default. The compile-time enforcement is
    -- exercised by the rest of the project simply compiling under
    -- '-Werror -Wall'.
    it "DoD #18: defaultPolicy denies remote commands and the helpers work" $ do
      Security.Policy.isRemoteCommandAllowed
        Security.Policy.defaultPolicy
        (CommandName "ssh")
        `shouldBe` False
      let allowed = Security.Policy.allowRemoteCommand
            (CommandName "ssh")
            Security.Policy.defaultPolicy
      Security.Policy.isRemoteCommandAllowed allowed (CommandName "ssh")
        `shouldBe` True
      Security.Policy.isRemoteCommandAllowed allowed (CommandName "bash")
        `shouldBe` False
      Security.Policy.denyRemoteCommand (CommandName "ssh") allowed
        `shouldBe` Security.Policy.defaultPolicy

  describe "WU0 orchestrator-only gates (documented; not run here)" $ do
    -- docs/terminal-backend-abstractions.md line 72: coverage thresholds
    it "DoD #19: coverage on new modules meets .coverage-thresholds.json" $
      pendingWith
        "WU11 / orchestrator-enforced: gated by .coverage-thresholds.json \
        \(100% lines/branches/functions/statements on new modules). Not a runtime test."
