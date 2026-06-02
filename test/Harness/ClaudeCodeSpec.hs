module Harness.ClaudeCodeSpec (spec) where

import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Harness
import PureClaw.Handles.Transcript
import PureClaw.Harness.ClaudeCode
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux (TmuxWindowRow (..))
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Transcript.Types

-- | Helper: assert that a result is a specific Left error.
shouldBeLeft :: Either HarnessError (Reg.HarnessId, HarnessHandle) -> HarnessError -> Expectation
shouldBeLeft (Left err) expected = err `shouldBe` expected
shouldBeLeft (Right _) expected =
  expectationFailure ("expected Left " <> show expected <> ", got Right harness")

-- | A deterministic harness id for tests that need to predict the generated id.
fixedId :: Reg.HarnessId
fixedId = fromMaybe (error "fixedId: bad uuid")
  (Reg.parseHarnessId "abcdabcd-abcd-abcd-abcd-abcdabcdabcd")

-- | A no-op deps record that succeeds at every step but records nothing.
-- Individual tests override the fields they care about.
okDeps :: ClaudeCodeDeps
okDeps = ClaudeCodeDeps
  { _ccd_newId        = pure fixedId
  , _ccd_findClaude   = pure (Just "/usr/bin/claude")
  , _ccd_checkTmux    = pure (Right ())
  , _ccd_addWindow    = \_ _ _ _ _ -> pure (Right ())
  , _ccd_startSession = \_ -> pure (Right ())
  , _ccd_setMarker    = \_ _ _ -> pure ()
  , _ccd_setRemain    = \_ _ -> pure ()
  , _ccd_panePidOf    = \_ _ -> pure Nothing
  , _ccd_harnessPidOf = \_ _ -> pure Nothing
  , _ccd_sweep        = \_ -> pure []
  , _ccd_sendNamed    = \_ _ _ -> pure True
  , _ccd_captureNamed = \_ _ _ -> pure (Just "")
  , _ccd_stopNamed    = \_ _ -> pure ()
  , _ccd_status       = \_ _ -> pure HarnessRunning
  }

spec :: Spec
spec = do
  describe "mkClaudeCodeHarness (authorization + lifecycle)" $ do
    -- DoD 1: Deny autonomy returns HarnessNotAuthorized
    it "returns HarnessNotAuthorized when policy has Deny autonomy" $ do
      let policy = defaultPolicy  -- Deny autonomy, empty allow list
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarness policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      result `shouldBeLeft` HarnessNotAuthorized CommandInAutonomyDeny

    -- DoD 2: Policy that doesn't allow claude returns HarnessNotAuthorized
    it "returns HarnessNotAuthorized when policy does not allow claude" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "git") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarness policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      result `shouldBeLeft` HarnessNotAuthorized (CommandNotAllowed "claude")

    -- DoD 3: Missing claude binary returns HarnessBinaryNotFound
    it "returns HarnessBinaryNotFound when claude is not on PATH" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith
        okDeps { _ccd_findClaude = pure Nothing }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      result `shouldBeLeft` HarnessBinaryNotFound "claude"

    -- DoD 4: Missing tmux returns HarnessTmuxNotAvailable
    it "returns HarnessTmuxNotAvailable when tmux is not available" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith
        okDeps { _ccd_checkTmux = pure (Left (HarnessTmuxNotAvailable "test")) }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      result `shouldBeLeft` HarnessTmuxNotAvailable "test"

    -- DoD 5: Successful creation returns the handle with the real session name
    it "returns a handle whose session is the threaded session (not a const)" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith okDeps
        policy transcript "my-session" "claude-code-0" 0 Nothing [] reg
      case result of
        Right (_, hh) -> do
          _hh_name hh `shouldBe` "Claude Code"
          _hh_session hh `shouldBe` "my-session"
        Left err -> expectationFailure ("expected Right, got: " <> show err)

    -- DoD 8: Uses authorized command path (not hardcoded)
    it "uses authorized command path from findExecutable, not hardcoded" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      usedPathRef <- newIORef Nothing
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith
        okDeps
          { _ccd_findClaude = pure (Just "/custom/path/to/claude")
          , _ccd_addWindow = \_ _ binary _ _ -> do
              writeIORef usedPathRef (Just binary)
              pure (Right ())
          }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      case result of
        Right _ -> do
          usedPath <- readIORef usedPathRef
          usedPath `shouldBe` Just "/custom/path/to/claude"
        Left err -> expectationFailure ("expected Right, got: " <> show err)

  describe "spawn identity (D4.2)" $ do
    it "stamps @pcl_id, sets remain-on-exit, records PIDs, and registers a Spawned entry" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      markerRef  <- newIORef ([] :: [(Text, Text, Text)])  -- (session, window, uuid)
      remainRef  <- newIORef ([] :: [(Text, Text)])        -- (session, window)
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith
        okDeps
          { _ccd_setMarker = \s w u -> modifyIORef' markerRef ((s, w, u) :)
          , _ccd_setRemain = \s w -> modifyIORef' remainRef ((s, w) :)
          , _ccd_panePidOf = \_ _ -> pure (Just 4242)
          , _ccd_harnessPidOf = \shellPid _ -> pure (Just (shellPid + 1))
          }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      case result of
        Left err -> expectationFailure ("expected Right, got: " <> show err)
        Right (hid, _) -> do
          -- @pcl_id stamped on the right window with the generated id text
          markers <- readIORef markerRef
          markers `shouldBe` [("pureclaw", "claude-code-0", Reg.harnessIdToText hid)]
          -- remain-on-exit set on the window
          remains <- readIORef remainRef
          remains `shouldBe` [("pureclaw", "claude-code-0")]
          -- entry registered with the PIDs + origin/liveness
          mEntry <- Reg.lookupById reg hid
          case mEntry of
            Nothing -> expectationFailure "expected the spawned entry in the registry"
            Just e -> do
              Reg._he_session e `shouldBe` "pureclaw"
              Reg._he_windowName e `shouldBe` "claude-code-0"
              Reg._he_shellPid e `shouldBe` Just 4242
              Reg._he_harnessPid e `shouldBe` Just 4243
              Reg._he_origin e `shouldBe` Reg.OriginSpawned
              Reg._he_liveness e `shouldBe` Reg.LivenessIdle
              Reg._he_label e `shouldBe` "claude-code-0"

  describe "cached-coordinate re-resolve (D4.3)" $ do
    it "re-resolves the window name on a simulated tmux-not-found and retries the send" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      sentRef <- newIORef ([] :: [(Text, Text)])  -- (window targeted, payload)
      reg <- Reg.newRegistry
      -- The window was renamed out-of-band from "claude-code-0" to "renamed-9",
      -- but still carries our @pcl_id. The sweep returns the moved window so the
      -- handle can re-resolve by matching @pcl_id == fixedId.
      let movedRow = TmuxWindowRow
            { _twr_windowIndex = 9
            , _twr_windowName  = "renamed-9"
            , _twr_pclId       = Reg.harnessIdToText fixedId
            , _twr_panePid     = Just 100
            , _twr_paneDead    = False
            }
      result <- mkClaudeCodeHarnessWith
        okDeps
          { _ccd_sendNamed = \_ win payload ->
              -- The cached name "claude-code-0" is gone (not found); only the
              -- re-resolved "renamed-9" succeeds.
              if win == "renamed-9"
                then do
                  modifyIORef' sentRef ((win, TE.decodeUtf8Lenient payload) :)
                  pure True
                else pure False
          , _ccd_sweep = \_ -> pure [movedRow]
          }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      case result of
        Left err -> expectationFailure ("expected Right, got: " <> show err)
        Right (hid, hh) -> do
          _hh_send hh "hello"
          sent <- readIORef sentRef
          map fst sent `shouldContain` ["renamed-9"]
          map snd sent `shouldContain` ["hello"]
          -- the entry's cached windowName was updated to the new name
          mEntry <- Reg.lookupById reg hid
          (Reg._he_windowName <$> mEntry) `shouldBe` Just "renamed-9"

  describe "status monitoring" $ do
    -- DoD 7: Subprocess death detection via the injected status op
    it "reports HarnessExited when the status op says the window is gone" $ do
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
          transcript = mkNoOpTranscriptHandle
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith
        okDeps { _ccd_status = \_ _ -> pure (HarnessExited (ExitFailure 127)) }
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      case result of
        Right (_, hh) -> do
          status <- _hh_status hh
          status `shouldBe` HarnessExited (ExitFailure 127)
        Left err -> expectationFailure ("expected Right, got: " <> show err)

  describe "transcript integration" $ do
    -- DoD 6: send logs a Request transcript entry
    it "send records a Request transcript entry" $ do
      entriesRef <- newIORef []
      let transcript = mkNoOpTranscriptHandle
            { _th_record = \entry -> modifyIORef' entriesRef (entry :)
            }
          policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
      reg <- Reg.newRegistry
      result <- mkClaudeCodeHarnessWith okDeps
        policy transcript "pureclaw" "claude-code-0" 0 Nothing [] reg
      case result of
        Right (_, hh) -> do
          _hh_send hh "hello"
          entries <- readIORef entriesRef
          let reqs = filter (\e -> _te_direction e == Request) entries
          case reqs of
            (entry : _) -> do
              _te_harness entry `shouldBe` Just "claude-code"
              _te_direction entry `shouldBe` Request
            [] -> expectationFailure "expected a Request transcript entry"
        Left err -> expectationFailure ("expected Right, got: " <> show err)

  describe "handle lifecycle ops (injected seam)" $ do
    it "stop kills the cached window via the injected op" $ do
      stopRef <- newIORef ([] :: [(Text, Text)])
      reg <- Reg.newRegistry
      Right (_, hh) <- spawnOk reg
        okDeps { _ccd_stopNamed = \s w -> modifyIORef' stopRef ((s, w) :) }
      _hh_stop hh
      stops <- readIORef stopRef
      stops `shouldBe` [("pureclaw", "claude-code-0")]

    it "status reads the cached window via the injected op" $ do
      reg <- Reg.newRegistry
      Right (_, hh) <- spawnOk reg
        okDeps { _ccd_status = \_ _ -> pure HarnessRunning }
      status <- _hh_status hh
      status `shouldBe` HarnessRunning

    it "send is a no-op when the entry has vanished from the registry" $ do
      sentRef <- newIORef (0 :: Int)
      reg <- Reg.newRegistry
      Right (hid, hh) <- spawnOk reg
        okDeps { _ccd_sendNamed = \_ _ _ -> modifyIORef' sentRef (+ 1) >> pure True }
      Reg.deleteEntry reg hid
      _hh_send hh "hello"
      count <- readIORef sentRef
      count `shouldBe` 0

    it "status reports Exited when the entry has vanished from the registry" $ do
      reg <- Reg.newRegistry
      Right (hid, hh) <- spawnOk reg okDeps
      Reg.deleteEntry reg hid
      status <- _hh_status hh
      status `shouldBe` HarnessExited (ExitFailure 127)

    it "stop is a no-op when the entry has vanished from the registry" $ do
      stopRef <- newIORef (0 :: Int)
      reg <- Reg.newRegistry
      Right (hid, hh) <- spawnOk reg
        okDeps { _ccd_stopNamed = \_ _ -> modifyIORef' stopRef (+ 1) }
      Reg.deleteEntry reg hid
      _hh_stop hh
      count <- readIORef stopRef
      count `shouldBe` 0

    it "send gives up (no retry) when re-resolve finds no matching window" $ do
      sentRef <- newIORef ([] :: [Text])
      reg <- Reg.newRegistry
      Right (_, hh) <- spawnOk reg
        okDeps
          { _ccd_sendNamed = \_ win _ -> do
              modifyIORef' sentRef (win :)
              pure False  -- always "not found"
          , _ccd_sweep = \_ -> pure []  -- re-resolve finds nothing
          }
      _hh_send hh "hello"
      sent <- readIORef sentRef
      -- exactly one attempt against the cached name; no retry (heal failed)
      sent `shouldBe` ["claude-code-0"]

  describe "receive (injected seam)" $ do
    it "polls to idle, captures, extracts the last response, and logs it" $ do
      entriesRef <- newIORef []
      let transcript = mkNoOpTranscriptHandle
            { _th_record = \entry -> modifyIORef' entriesRef (entry :) }
          -- An idle screen (prompt glyph, no busy marker) with a response block.
          idleScreen = TE.encodeUtf8 (T.intercalate "\n"
            [ "\x23FA the answer", "\x276F " ])
      reg <- Reg.newRegistry
      Right (_, hh) <- mkClaudeCodeHarnessWith
        okDeps
          { _ccd_captureNamed = \_ _ _ -> pure (Just idleScreen) }
        (withAutonomy Full (allowCommand (CommandName "claude") defaultPolicy))
        transcript "pureclaw" "claude-code-0" 0 Nothing []
        reg
      out <- _hh_receive hh
      out `shouldBe` TE.encodeUtf8 "the answer"
      entries <- readIORef entriesRef
      let resps = filter (\e -> _te_direction e == Response) entries
      length resps `shouldSatisfy` (>= 1)

    it "re-resolves before receiving when the probe capture is not found" $ do
      reg <- Reg.newRegistry
      capturedWindows <- newIORef ([] :: [Text])
      let idleScreen = TE.encodeUtf8 "\x276F "
          movedRow = TmuxWindowRow
            { _twr_windowIndex = 9
            , _twr_windowName  = "renamed-9"
            , _twr_pclId       = Reg.harnessIdToText fixedId
            , _twr_panePid     = Just 1
            , _twr_paneDead    = False
            }
      Right (hid, hh) <- mkClaudeCodeHarnessWith
        okDeps
          { _ccd_captureNamed = \_ win _ -> do
              modifyIORef' capturedWindows (win :)
              if win == "renamed-9" then pure (Just idleScreen) else pure Nothing
          , _ccd_sweep = \_ -> pure [movedRow]
          }
        (withAutonomy Full (allowCommand (CommandName "claude") defaultPolicy))
        mkNoOpTranscriptHandle "pureclaw" "claude-code-0" 0 Nothing []
        reg
      _ <- _hh_receive hh
      wins <- readIORef capturedWindows
      wins `shouldContain` ["renamed-9"]
      mEntry <- Reg.lookupById reg hid
      (Reg._he_windowName <$> mEntry) `shouldBe` Just "renamed-9"

  describe "spawn identity edge cases" $ do
    it "records Nothing harness PID when the shell PID is unavailable" $ do
      reg <- Reg.newRegistry
      Right (hid, _) <- spawnOk reg
        okDeps
          { _ccd_panePidOf = \_ _ -> pure Nothing
          , _ccd_harnessPidOf = \_ _ -> error "harnessPidOf must not be called without a shell PID"
          }
      mEntry <- Reg.lookupById reg hid
      (Reg._he_shellPid <$> mEntry) `shouldBe` Just Nothing
      (Reg._he_harnessPid <$> mEntry) `shouldBe` Just Nothing

    it "auto-confirms the safety prompt when --dangerously-skip-permissions is set" $ do
      confirmRef <- newIORef ([] :: [(Text, Text)])
      reg <- Reg.newRegistry
      let policy = withAutonomy Full
                 $ allowCommand (CommandName "claude") defaultPolicy
      result <- mkClaudeCodeHarnessWith
        okDeps { _ccd_sendNamed = \s w _ -> modifyIORef' confirmRef ((s, w) :) >> pure True }
        policy mkNoOpTranscriptHandle "pureclaw" "claude-code-0" 0 Nothing
        ["--dangerously-skip-permissions"] reg
      case result of
        Left err -> expectationFailure ("expected Right, got: " <> show err)
        Right _ -> do
          confirms <- readIORef confirmRef
          confirms `shouldContain` [("pureclaw", "claude-code-0")]

  describe "response extraction (pure)" $ do
    it "isIdle is True when the prompt is present and no busy markers" $
      isIdle "some text \x276F " `shouldBe` True

    it "isIdle is False while Thinking" $
      isIdle "\x276F Thinking..." `shouldBe` False

    it "isIdle is False without the prompt glyph" $
      isIdle "no prompt here" `shouldBe` False

    it "isResponseMarker recognises the ⏺ and ⬤ markers" $ do
      isResponseMarker "\x23FA hello" `shouldBe` True
      isResponseMarker "\x2B24 hello" `shouldBe` True
      isResponseMarker "plain line" `shouldBe` False

    it "isUiBoundary recognises the input prompt and rules" $ do
      isUiBoundary "\x276F " `shouldBe` True
      isUiBoundary "\x2500\x2500\x2500" `shouldBe` True
      isUiBoundary "ordinary line" `shouldBe` False

    it "isUiBoundary recognises the '? for shortcuts' hint line" $ do
      -- Covers the `T.isPrefixOf \"?\" && T.isInfixOf \"shortcut\"` arm.
      isUiBoundary "? for shortcuts" `shouldBe` True
      -- A leading '?' alone (without "shortcut") is NOT a boundary.
      isUiBoundary "? what is this" `shouldBe` False

    it "extractLastResponse strips the alternate ⬤ marker prefix" $ do
      -- A response block whose marker is the alternate glyph (U+2B24, ⬤)
      -- exercises stripMarker's second prefix check.
      let capture = TE.encodeUtf8 (T.intercalate "\n"
            [ "\x2B24 alt-marked response"
            , "\x276F "  -- boundary ends the block
            ])
      extractLastResponse capture `shouldBe` TE.encodeUtf8 "alt-marked response"

    it "extractLastResponse returns empty when there is no marker" $
      extractLastResponse "just\nplain\nlines" `shouldBe` ""

    it "extractLastResponse takes the last marker block up to a UI boundary" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n"
            [ "\x23FA first response"
            , "\x276F "                 -- boundary ends the first block
            , "\x23FA second response"
            , "more of second"
            , "\x276F "                 -- boundary ends the second block
            ])
      extractLastResponse capture `shouldBe`
        TE.encodeUtf8 "second response\nmore of second"

  describe "discovered handle" $ do
    it "mkDiscoveredClaudeCodeHandle threads the real session name" $ do
      let transcript = mkNoOpTranscriptHandle
      hh <- mkDiscoveredClaudeCodeHandle transcript "my-session" "claude-code-3"
      _hh_name hh `shouldBe` "Claude Code"
      _hh_session hh `shouldBe` "my-session"

-- | Spawn a harness with a Full policy that allows claude, returning the result.
-- Individual tests pass the deps they want to observe.
spawnOk
  :: Reg.HarnessRegistry
  -> ClaudeCodeDeps
  -> IO (Either HarnessError (Reg.HarnessId, HarnessHandle))
spawnOk reg deps =
  mkClaudeCodeHarnessWith deps policy mkNoOpTranscriptHandle
    "pureclaw" "claude-code-0" 0 Nothing [] reg
  where
    policy = withAutonomy Full $ allowCommand (CommandName "claude") defaultPolicy
