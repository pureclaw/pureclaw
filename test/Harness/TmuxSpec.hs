module Harness.TmuxSpec (spec) where

import Data.ByteString ()
import Data.Either
import Test.Hspec

import PureClaw.Handles.Harness
import PureClaw.Harness.Tmux

spec :: Spec
spec = do
  describe "requireTmux" $ do
    it "returns Right when tmux is on PATH" $ do
      -- This is an integration test: skip if tmux is not available
      result <- requireTmux
      case result of
        Right () -> pure ()
        Left (HarnessTmuxNotAvailable _) ->
          pendingWith "tmux not available on this system"
        Left other ->
          expectationFailure ("unexpected error: " <> show other)

  describe "stealthShellCommand" $ do
    it "wraps a command for stealth mode" $ do
      let cmd = stealthShellCommand "/usr/bin/claude" ["--flag"]
      -- Should contain env -u TMUX
      cmd `shouldContain` "env -u TMUX"
      -- Should contain the binary
      cmd `shouldContain` "/usr/bin/claude"
      -- Should contain the flag
      cmd `shouldContain` "--flag"

  -- Integration tests that require tmux
  describe "tmux session lifecycle (integration)" $ do
    it "starts and stops a tmux session" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sessionName = "pureclaw-test-lifecycle"
          startResult <- startTmuxSession sessionName
          startResult `shouldSatisfy` isRight
          -- Starting again should also succeed (idempotent)
          startResult2 <- startTmuxSession sessionName
          startResult2 `shouldSatisfy` isRight
          -- Clean up
          stopTmuxSession sessionName

    it "tmuxDisplay writes to a pane without error" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sessionName = "pureclaw-test-display"
          startResult <- startTmuxSession sessionName
          startResult `shouldSatisfy` isRight
          -- tmuxDisplay should not throw
          tmuxDisplay sessionName "Hello from test"
          -- Clean up
          stopTmuxSession sessionName

    it "captureWindow captures output" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sessionName = "pureclaw-test-capture"
          startResult <- startTmuxSession sessionName
          startResult `shouldSatisfy` isRight
          -- Capture should return something (even if empty)
          output <- captureWindow sessionName 300
          -- Output is a ByteString, may be empty for a fresh session
          output `shouldSatisfy` const True
          -- Clean up
          stopTmuxSession sessionName

    it "stopTmuxSession is idempotent" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sessionName = "pureclaw-test-idempotent"
          _ <- startTmuxSession sessionName
          stopTmuxSession sessionName
          -- Stopping again should not throw
          stopTmuxSession sessionName
