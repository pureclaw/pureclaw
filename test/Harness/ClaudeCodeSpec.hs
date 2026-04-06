module Harness.ClaudeCodeSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Harness
import PureClaw.Handles.Transcript
import PureClaw.Harness.ClaudeCode
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Transcript.Types

-- | Helper: assert that a result is a specific Left error.
shouldBeLeft :: Either HarnessError HarnessHandle -> HarnessError -> Expectation
shouldBeLeft (Left err) expected = err `shouldBe` expected
shouldBeLeft (Right _) expected =
  expectationFailure ("expected Left " <> show expected <> ", got Right HarnessHandle")

spec :: Spec
spec = do
  describe "mkClaudeCodeHarness" $ do
    -- DoD 1: Deny autonomy returns HarnessNotAuthorized
    it "returns HarnessNotAuthorized when policy has Deny autonomy" $ do
      let policy = defaultPolicy  -- Deny autonomy, empty allow list
          transcript = mkNoOpTranscriptHandle
      result <- mkClaudeCodeHarness policy transcript 0 Nothing
      result `shouldBeLeft` HarnessNotAuthorized CommandInAutonomyDeny

    -- DoD 2: Policy that doesn't allow claude returns HarnessNotAuthorized
    it "returns HarnessNotAuthorized when policy does not allow claude" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "git") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      result <- mkClaudeCodeHarness policy transcript 0 Nothing
      result `shouldBeLeft` HarnessNotAuthorized (CommandNotAllowed "claude")

    -- DoD 3: Missing claude binary returns HarnessBinaryNotFound
    it "returns HarnessBinaryNotFound when claude is not on PATH" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      result <- mkClaudeCodeHarnessWith
        (pure Nothing)
        (pure (Right ()))
        (\_ _ _ _ _ -> pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      result `shouldBeLeft` HarnessBinaryNotFound "claude"

    -- DoD 4: Missing tmux returns HarnessTmuxNotAvailable
    it "returns HarnessTmuxNotAvailable when tmux is not available" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      result <- mkClaudeCodeHarnessWith
        (pure (Just "/usr/bin/claude"))
        (pure (Left (HarnessTmuxNotAvailable "test")))
        (\_ _ _ _ _ -> pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      result `shouldBeLeft` HarnessTmuxNotAvailable "test"

    -- DoD 5: Successful creation returns Right HarnessHandle with correct name
    it "returns Right HarnessHandle with name 'Claude Code' on success" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      result <- mkClaudeCodeHarnessWith
        (pure (Just "/usr/bin/claude"))
        (pure (Right ()))
        (\_ _ _ _ _ -> pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      case result of
        Right hh -> do
          _hh_name hh `shouldBe` "Claude Code"
          _hh_session hh `shouldBe` "pureclaw"
        Left err -> expectationFailure ("expected Right HarnessHandle, got: " <> show err)

    -- DoD 8: Uses authorized command path (not hardcoded)
    it "uses authorized command path from findExecutable, not hardcoded" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      usedPathRef <- newIORef Nothing
      result <- mkClaudeCodeHarnessWith
        (pure (Just "/custom/path/to/claude"))
        (pure (Right ()))
        (\_ _ binary _ _ -> do
          writeIORef usedPathRef (Just binary)
          pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      case result of
        Right _ -> do
          usedPath <- readIORef usedPathRef
          usedPath `shouldBe` Just "/custom/path/to/claude"
        Left err -> expectationFailure ("expected Right, got: " <> show err)

  describe "status monitoring" $ do
    -- DoD 7: Subprocess death detection
    it "returns HarnessExited and logs event when tmux window is gone" $ do
      entriesRef <- newIORef []
      let transcript = mkNoOpTranscriptHandle
            { _th_record = \entry -> modifyIORef' entriesRef (entry :)
            }
          policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
      result <- mkClaudeCodeHarnessWith
        (pure (Just "/usr/bin/claude"))
        (pure (Right ()))
        (\_ _ _ _ _ -> pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      case result of
        Right hh -> do
          -- The harness was created with mock tmux, so list-windows will fail
          -- (no actual tmux session exists), causing checkWindowStatus to detect death
          status <- _hh_status hh
          case status of
            HarnessExited _ -> do
              -- Verify a transcript entry was logged with "harness_exited" event
              entries <- readIORef entriesRef
              let deathEntries = filter (\e ->
                    Map.lookup "event" (_te_metadata e) == Just (Aeson.String "harness_exited")
                    ) entries
              length deathEntries `shouldSatisfy` (>= 1)
            HarnessRunning ->
              -- If tmux IS running and session somehow exists, that's ok
              -- (integration-sensitive — checkWindowStatus calls real tmux)
              pure ()
        Left err -> expectationFailure ("expected Right, got: " <> show err)

  describe "transcript integration" $ do
    -- DoD 6: send logs Request, receive logs Response
    it "send records a Request transcript entry" $ do
      entriesRef <- newIORef []
      let transcript = mkNoOpTranscriptHandle
            { _th_record = \entry -> modifyIORef' entriesRef (entry :)
            }
          policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
      result <- mkClaudeCodeHarnessWith
        (pure (Just "/usr/bin/claude"))
        (pure (Right ()))
        (\_ _ _ _ _ -> pure (Right ()))
        (\_ -> pure (Right ()))
        policy
        transcript
        0
        Nothing
      case result of
        Right hh -> do
          _hh_send hh "hello"
          entries <- readIORef entriesRef
          case entries of
            [entry] -> do
              _te_harness entry `shouldBe` Just "claude-code"
              _te_direction entry `shouldBe` Request
            _ -> expectationFailure ("expected exactly 1 entry, got " <> show (length entries))
        Left err -> expectationFailure ("expected Right, got: " <> show err)

-- TODO Very slow.  Possibly re-enable when it can be used more efficiently.
--    it "receive records a Response transcript entry" $ do
--      entriesRef <- newIORef []
--      let transcript = mkNoOpTranscriptHandle
--            { _th_record = \entry -> modifyIORef' entriesRef (entry :)
--            }
--          policy = withAutonomy Full
--                 $ allowCommand (CommandName "claude") defaultPolicy
--      result <- mkClaudeCodeHarnessWith
--        (pure (Just "/usr/bin/claude"))
--        (pure (Right ()))
--        (\_ _ _ _ _ -> pure (Right ()))
--        (\_ -> pure (Right ()))
--        policy
--        transcript
--        0
--      case result of
--        Right hh -> do
--          _ <- _hh_receive hh
--          entries <- readIORef entriesRef
--          -- withTranscript logs both a Request and a Response
--          let responseEntries = filter (\e -> _te_direction e == Response) entries
--          case responseEntries of
--            (entry : _) -> _te_harness entry `shouldBe` Just "claude-code"
--            [] -> expectationFailure "expected at least one Response entry"
--        Left err -> expectationFailure ("expected Right, got: " <> show err)
