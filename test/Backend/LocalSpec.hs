-- |
-- Module      : Backend.LocalSpec
-- Description : Local backend DoDs (WU8).
--
-- Covers DoDs #1 (local pipe one-shot @echo hi@) and #2 (local PTY bash
-- three-turn @cd /tmp; pwd@) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- These tests spawn real subprocesses (@echo@, @bash@). They use
-- 'realPtyIO' for the conversational case. The fakePtyIO property
-- tests of the drainer state machine live in 'Backend.PtySpec' (WU7);
-- this file owns the integration-level acceptance.
module Backend.LocalSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Test.Hspec

import PureClaw.Backend.Local
  ( mkLocalBackendHandle
  , mkLocalPtyBackendHandle
  )
import PureClaw.Backend.Pty (realPtyIO)
import PureClaw.Handles.Backend
  ( BackendHandle (..)
  , PtyOpts (..)
  , RecvResult (..)
  , defaultPipeOpts
  , defaultPtyOpts
  , mkIdleSpec
  , recvBytes
  , runBackend
  )
import PureClaw.Core.Types (CommandName (..))
import PureClaw.Security.Command (authorize)
import PureClaw.Security.Policy
  ( allowCommand
  , defaultPolicy
  , withAutonomy
  )
import PureClaw.Core.Types qualified as Core

spec :: Spec
spec = do
  describe "WU8 — local backend factories" $ do

    -- docs/terminal-backend-abstractions.md line 50: local echo hi
    it "DoD #1: runBackend on mkLocalBackendHandle (echo hi) returns RecvSettled \"hi\\n\"" $ do
      let policy = withAutonomy Core.Full
                 . allowCommand (CommandName "echo")
                 $ defaultPolicy
      case authorize policy "echo" ["hi"] of
        Left err -> expectationFailure $
          "echo authorization failed: " <> show err
        Right cmd -> do
          eh <- mkLocalBackendHandle cmd defaultPipeOpts
          case eh of
            Left err -> expectationFailure $
              "construction failed: " <> show err
            Right h -> do
              r <- runBackend h ""
              _bh_close h
              case r of
                RecvSettled bs -> bs `shouldBe` BS8.pack "hi\n"
                other -> expectationFailure $
                  "expected RecvSettled \"hi\\n\", got: " <> show other

    -- docs/terminal-backend-abstractions.md line 51: local bash 3-turn
    it "DoD #2: mkLocalPtyBackendHandle bash survives 'cd /tmp; pwd' across three turns" $ do
      let policy = withAutonomy Core.Full
                 . allowCommand (CommandName "bash")
                 $ defaultPolicy
      -- Local bash is generous: 750ms quiet, 8s hard timeout.
      idle <- case mkIdleSpec 750 8_000 0 of
        Right s -> pure s
        Left e  -> error ("mkIdleSpec: " <> show e)
      let ptyOpts = defaultPtyOpts { _pto_idle = idle }
      case authorize policy "bash" ["--noprofile", "--norc", "-i"] of
        Left err -> expectationFailure $
          "bash authorization failed: " <> show err
        Right cmd -> do
          eh <- mkLocalPtyBackendHandle realPtyIO cmd ptyOpts
          case eh of
            Left err -> expectationFailure $
              "construction failed: " <> show err
            Right h -> do
              -- Turn 0: consume the initial prompt.
              _r0 <- _bh_recv h Nothing
              -- Turn 1: cd /tmp.
              _r1 <- runBackend h (BS8.pack "cd /tmp\n")
              -- Turn 2: pwd. The recv after this should contain /tmp.
              r2 <- runBackend h (BS8.pack "pwd\n")
              -- Turn 3: exit cleanly.
              _r3 <- runBackend h (BS8.pack "exit\n")
              _bh_close h
              let outBytes = recvBytes r2
              -- macOS resolves /tmp to /private/tmp; accept either.
              let containsTmp =
                    BS.isInfixOf (BS8.pack "/tmp") outBytes
                      || BS.isInfixOf (BS8.pack "/private/tmp") outBytes
              if containsTmp
                then pure ()
                else expectationFailure $
                  "expected 'pwd' output to contain /tmp; got: "
                    <> show outBytes
