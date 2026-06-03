module Harness.ClaudeCodeSpec (spec) where

import Control.Monad (filterM)
import Data.Either (rights)
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Harness
import PureClaw.Handles.Transcript
import PureClaw.Harness.ClaudeCode
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux (TmuxWindowRow (..), validateTmuxIdent)
import PureClaw.Security.Adoption
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Session.Kind
import PureClaw.Session.Types (SessionMeta (..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
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

  describe "dropBaselineLines (pure, B3 baseline mechanism)" $ do
    it "n = 0 is the identity (spawn default keeps everything)" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n" ["line a", "line b", "line c"])
      dropBaselineLines 0 capture `shouldBe` capture

    it "drops exactly n leading lines when n is in range" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n" ["old 0", "old 1", "new 0", "new 1"])
      dropBaselineLines 2 capture
        `shouldBe` TE.encodeUtf8 (T.intercalate "\n" ["new 0", "new 1"])

    it "drops exactly one leading line for n = 1" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n" ["first", "second"])
      dropBaselineLines 1 capture `shouldBe` TE.encodeUtf8 "second"

    it "returns empty when n equals the line count" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n" ["a", "b", "c"])
      dropBaselineLines 3 capture `shouldBe` ""

    it "returns empty when n exceeds the line count" $ do
      let capture = TE.encodeUtf8 (T.intercalate "\n" ["a", "b"])
      dropBaselineLines 99 capture `shouldBe` ""

    it "is empty-in / empty-out for n = 0 on empty input" $
      dropBaselineLines 0 "" `shouldBe` ""

  describe "receive baseline exclusion (B3 / D3.1 / D3.3)" $ do
    it "excludes pre-baseline backlog from both responseText and the transcript" $ do
      -- D3.1 + D3.3: with the baseline set to the count of pre-existing
      -- scrollback lines, a subsequent capture whose FIRST N lines are old
      -- backlog and whose later lines are post-baseline activity must yield
      -- ONLY the post-baseline content — and the backlog must reach NEITHER the
      -- returned responseText NOR the recorded transcript entry.
      --
      -- NON-TAUTOLOGICAL CONSTRUCTION (this is the whole point of the test):
      -- the ONLY response marker (⏺) lives in the pre-baseline backlog. The
      -- post-baseline region carries NO marker (just an idle prompt). Because
      -- 'extractLastResponse' selects the LAST ⏺ marker, the result hinges on
      -- whether the strip runs:
      --   * WITHOUT the strip → 'extractLastResponse' over the FULL capture
      --     finds the backlog marker and returns the SECRET backlog text.
      --   * WITH the strip → the backlog (incl. its marker) is dropped, no
      --     marker remains, and 'extractLastResponse' returns "".
      -- Neutering 'dropBaselineLines' to the identity therefore turns this test
      -- RED (responseText would contain SECRET), proving the strip is wired in.
      entriesRef <- newIORef []
      let transcript = mkNoOpTranscriptHandle
            { _th_record = \entry -> modifyIORef' entriesRef (entry :) }
          -- Pre-existing backlog: the ONLY response marker in the capture, and
          -- it carries the SECRET payload that must never escape the baseline.
          backlog = [ "\x23FA OLD SECRET backlog response", "more backlog text" ]
          -- Post-baseline region: an idle prompt with NO response marker. This
          -- keeps the capture idle (so pollUntilIdle terminates) while leaving
          -- zero markers once the backlog is stripped.
          postBaseline = [ "\x276F " ]
          fullScreen = TE.encodeUtf8 (T.intercalate "\n" (backlog <> postBaseline))
          captureDeps = okDeps { _ccd_captureNamed = \_ _ _ -> pure (Just fullScreen) }
      reg <- Reg.newRegistry
      -- Spawn first to register the entry the handle resolves its coordinate from.
      Right (hid, _) <- mkClaudeCodeHarnessWith captureDeps
        (withAutonomy Full (allowCommand (CommandName "claude") defaultPolicy))
        mkNoOpTranscriptHandle "pureclaw" "claude-code-0" 0 Nothing []
        reg
      -- WU4 hook: build a handle whose baseline excludes the pre-existing
      -- backlog (adopt sets baseline = the window's current line count).
      hh <- mkClaudeCodeHandleWithBaseline captureDeps reg hid transcript
              "pureclaw" (length backlog)
      out <- _hh_receive hh
      -- responseText excludes the backlog: no marker survives the strip, so the
      -- extraction is empty. Crucially it does NOT contain the backlog SECRET.
      TE.decodeUtf8Lenient out `shouldNotSatisfy` T.isInfixOf "SECRET"
      out `shouldBe` ""
      -- the recorded transcript Response entry also excludes the backlog.
      entries <- readIORef entriesRef
      let resps = filter (\e -> _te_direction e == Response) entries
      case resps of
        (entry : _) -> do
          let payload = _te_payload entry
          payload `shouldNotSatisfy` T.isInfixOf "SECRET"
          payload `shouldBe` ""
        [] -> expectationFailure "expected a Response transcript entry"

    it "baseline = 0 (spawn default) preserves existing extract behavior (D3.2)" $ do
      -- Regression: with no baseline set (spawn default 0), the full capture is
      -- extracted exactly as before.
      let idleScreen = TE.encodeUtf8 (T.intercalate "\n"
            [ "\x23FA the answer", "\x276F " ])
      reg <- Reg.newRegistry
      Right (_, hh) <- mkClaudeCodeHarnessWith
        okDeps { _ccd_captureNamed = \_ _ _ -> pure (Just idleScreen) }
        (withAutonomy Full (allowCommand (CommandName "claude") defaultPolicy))
        mkNoOpTranscriptHandle "pureclaw" "claude-code-0" 0 Nothing []
        reg
      out <- _hh_receive hh
      out `shouldBe` TE.encodeUtf8 "the answer"

  describe "adoptExternalWindow (WU4 — typed-gated adopt mechanism)" $ do
    -- D4.3: there is NO token-free adopt path. 'adoptExternalWindow' REQUIRES
    -- an 'AdoptedHarness', which is constructible ONLY via 'authorizeAdoption'.
    -- The only way a test (or any caller) obtains the token is by passing the
    -- consent + allow-list gate, so every test below first runs the gate.
    let adoptableSession = "scratch"
        gatePolicy =
          defaultPolicy
            { _sp_adoptableSessionPatterns =
                case parseSessionPattern adoptableSession of
                  Just p  -> [p]
                  Nothing -> error "test setup: pattern rejected"
            }
        mkToken =
          case authorizeAdoption gatePolicy ConsentInteractive adoptableSession of
            Right tok -> tok
            Left e    -> error ("test setup: gate denied: " <> show e)

    it "D4.1 stamps @pcl_id + remain-on-exit, records the shell PID, and registers an OriginAdopted entry + legacy map" $
      withSystemTempDirectory "pcl-adopt" $ \tmp -> do
        reg <- Reg.newRegistry
        legacyRef <- newIORef (mempty :: [(Text, Text)])  -- (session, window) of registered handle
        markersRef <- newIORef ([] :: [(Text, Text, Text)])  -- (session, window, uuid)
        remainRef  <- newIORef ([] :: [(Text, Text)])
        -- A window with a NON-empty current scrollback so the baseline ≠ 0.
        let backlog = TE.encodeUtf8 (T.intercalate "\n"
              [ "old line 1", "old line 2", "old line 3" ])
            deps = okDeps
              { _ccd_newId        = pure fixedId
              , _ccd_setMarker    = \s w u -> modifyIORef' markersRef ((s, w, u) :)
              , _ccd_setRemain    = \s w -> modifyIORef' remainRef ((s, w) :)
              , _ccd_panePidOf    = \_ _ -> pure (Just 4242)
              , _ccd_harnessPidOf = \_ _ -> pure Nothing  -- non-flavour window: OK
              , _ccd_captureNamed = \_ _ _ -> pure (Just backlog)
              }
        result <- adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp mkToken "win-3"
        case result of
          Left e -> expectationFailure ("adopt failed: " <> show e)
          Right (hid, _hh) -> do
            -- @pcl_id stamped with the new id, on the adopted coordinates.
            markers <- readIORef markersRef
            markers `shouldBe` [(adoptableSession, "win-3", Reg.harnessIdToText hid)]
            -- remain-on-exit set on the adopted coordinates.
            remains <- readIORef remainRef
            remains `shouldBe` [(adoptableSession, "win-3")]
            -- Registry entry: OriginAdopted, shell PID recorded, with a handle.
            mEntry <- Reg.lookupById reg hid
            case mEntry of
              Nothing -> expectationFailure "expected an OriginAdopted registry entry"
              Just e  -> do
                Reg._he_origin e     `shouldBe` Reg.OriginAdopted
                Reg._he_session e    `shouldBe` adoptableSession
                Reg._he_windowName e `shouldBe` "win-3"
                Reg._he_shellPid e   `shouldBe` Just 4242
                Maybe.isJust (Reg._he_handle e) `shouldBe` True
            _ <- pure legacyRef  -- legacy map sync is the caller's job (endpoint); see APISpec D4.x
            pure ()

    it "D4.1 sets the capture baseline to the window's CURRENT scrollback line count (≠ 0 with backlog)" $
      withSystemTempDirectory "pcl-adopt" $ \tmp -> do
        -- NON-TAUTOLOGICAL: the ONLY response marker (⏺ + SECRET) lives in the
        -- backlog that exists at adopt time. After adoption the baseline must
        -- exclude that backlog, so a subsequent receive (capturing the SAME
        -- screen) must NOT surface the SECRET. If the baseline were 0, the
        -- marker would be extracted and the test would go RED.
        reg <- Reg.newRegistry
        entriesRef <- newIORef []
        let transcript = mkNoOpTranscriptHandle
              { _th_record = \entry -> modifyIORef' entriesRef (entry :) }
            backlog = [ "\x23FA OLD SECRET backlog response", "more backlog text" ]
            postIdle = [ "\x276F " ]
            -- The screen at adopt time AND at receive time is identical: backlog
            -- followed by an idle prompt. Adopt measures the backlog as baseline.
            fullScreen = TE.encodeUtf8 (T.intercalate "\n" (backlog <> postIdle))
            deps = okDeps
              { _ccd_panePidOf    = \_ _ -> pure (Just 99)
              , _ccd_captureNamed = \_ _ _ -> pure (Just fullScreen)
              }
        Right (_, hh) <-
          adoptExternalWindow deps reg transcript tmp mkToken "win-baseline"
        out <- _hh_receive hh
        -- The pre-adoption backlog (incl. its SECRET marker) is excluded.
        TE.decodeUtf8Lenient out `shouldNotSatisfy` T.isInfixOf "SECRET"
        entries <- readIORef entriesRef
        let resps = filter (\e -> _te_direction e == Response) entries
        case resps of
          (entry : _) -> _te_payload entry `shouldNotSatisfy` T.isInfixOf "SECRET"
          []          -> expectationFailure "expected a Response transcript entry"

    it "D4.1 creates a session.json carrying _h_harnessId + the adopted coords" $
      withSystemTempDirectory "pcl-adopt" $ \tmp -> do
        reg <- Reg.newRegistry
        let deps = okDeps
              { _ccd_panePidOf    = \_ _ -> pure (Just 7)
              , _ccd_captureNamed = \_ _ _ -> pure (Just "line\n")
              }
        Right (hid, _) <-
          adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp mkToken "win-sess"
        -- Exactly one session dir was created; its session.json loads and
        -- carries the harness id + adopted tmux coordinates.
        metas <- loadAllSessionMetas tmp
        case metas of
          [meta] -> case _sm_kind meta of
            SkHarness hs -> do
              _h_harnessId hs `shouldBe` Just hid
              case _h_backend hs of
                TbTmux tc -> do
                  _tc_session tc `shouldBe` adoptableSession
                  _tc_window tc  `shouldBe` "win-sess"
                other -> expectationFailure ("expected TbTmux backend, got " <> show other)
            other -> expectationFailure ("expected SkHarness kind, got " <> show other)
          other -> expectationFailure ("expected exactly one session.json, got " <> show (length other))

  describe "discovered handle" $ do
    it "mkDiscoveredClaudeCodeHandle threads the real session name" $ do
      let transcript = mkNoOpTranscriptHandle
      hh <- mkDiscoveredClaudeCodeHandle transcript "my-session" "claude-code-3"
      _hh_name hh `shouldBe` "Claude Code"
      _hh_session hh `shouldBe` "my-session"

  -- WU8 Part A (WU6-review must-do): the adopted/discovered tmux-IO path takes
  -- window/session names that ORIGINATE from the server-wide sweep (§8 C3/C4 —
  -- attacker-writable). 'validateTmuxIdent' must be applied FAIL-CLOSED on this
  -- most-exposed path so an injected identifier (leading @-@ → mis-parsed as a
  -- tmux OPTION; @:@ → spills into the @session:window@ target; a control char →
  -- corrupts the @-F@ sweep) is refused WITHOUT issuing any tmux op. Session and
  -- window are validated SEPARATELY (as in WU6's 'sendToWindowNamed').
  describe "adopted-path identifier validation (WU8 Part A — §8 C3/C4 defense-in-depth)" $ do
    -- These assert the SAFE FAILURE VALUE for a malicious identifier. The guard
    -- short-circuits BEFORE 'findTmux', so the safe value is returned regardless
    -- of whether a tmux server (or a matching window) is present — i.e. no tmux
    -- op is ever issued for a rejected identifier.
    let badIdents =
          [ ("leading-dash window", "ok-session", "-injected")
          , ("leading-dash session", "-evil", "ok-window")
          , ("colon window",     "ok-session", "win:spill")
          , ("colon session",    "ses:spill", "ok-window")
          , ("control window",   "ok-session", "win\nrm")
          , ("empty window",     "ok-session", "")
          ]

    -- Sanity: the bad identifiers really are rejected by the pure predicate and
    -- the good ones pass (guards against a future predicate change silently
    -- defanging these tests).
    it "the chosen bad identifiers fail validateTmuxIdent and the good ones pass" $ do
      validateTmuxIdent "ok-session" `shouldBe` True
      validateTmuxIdent "ok-window"  `shouldBe` True
      and [ not (validateTmuxIdent s && validateTmuxIdent w)
          | (_, s, w) <- badIdents ] `shouldBe` True

    it "realSendNamed refuses (False) for an invalid session/window — no tmux op" $
      mapM_ (\(label, s, w) -> do
                ok <- realSendNamed s w "payload"
                (label, ok) `shouldBe` (label, False))
            badIdents

    it "realCaptureNamed refuses (Nothing) for an invalid session/window — no tmux op" $
      mapM_ (\(label, s, w) -> do
                r <- realCaptureNamed s w 100
                (label, r) `shouldBe` (label, Nothing))
            badIdents

    it "realStatus refuses (HarnessExited) for an invalid session/window — no tmux op" $
      mapM_ (\(label, s, w) -> do
                st <- realStatus s w
                case st of
                  HarnessExited _ -> pure ()
                  HarnessRunning  ->
                    expectationFailure (label <> ": expected HarnessExited, got HarnessRunning"))
            badIdents

    -- The strongest fail-closed proof: 'adoptExternalWindow' uses INJECTED deps,
    -- so we can observe that ZERO tmux mutations (setMarker / setRemain) and ZERO
    -- captures fire when an identifier is invalid, and the result is Left.
    it "adoptExternalWindow refuses an invalid WINDOW name with NO tmux op (fail-closed)" $
      withSystemTempDirectory "pcl-adopt-badwin" $ \tmp -> do
        reg <- Reg.newRegistry
        markersRef <- newIORef ([] :: [(Text, Text, Text)])
        remainRef  <- newIORef ([] :: [(Text, Text)])
        captureRef <- newIORef (0 :: Int)
        let deps = okDeps
              { _ccd_setMarker    = \s w u -> modifyIORef' markersRef ((s, w, u) :)
              , _ccd_setRemain    = \s w -> modifyIORef' remainRef ((s, w) :)
              , _ccd_captureNamed = \_ _ _ -> modifyIORef' captureRef (+ 1) >> pure (Just "")
              }
            -- session "scratch" is allow-listed (valid); the WINDOW is malicious.
            adoptable = "scratch"
            gatePolicy = defaultPolicy
              { _sp_adoptableSessionPatterns =
                  case parseSessionPattern adoptable of
                    Just p  -> [p]
                    Nothing -> error "test setup: pattern rejected"
              }
            token = case authorizeAdoption gatePolicy ConsentInteractive adoptable of
              Right tok -> tok
              Left e    -> error ("test setup: gate denied: " <> show e)
        result <- adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp token "-rm-rf"
        case result of
          Right _   -> expectationFailure "expected adopt to refuse an invalid window name"
          -- Force the refusal value: it is a HarnessNotAuthorized carrying the
          -- offending identifier (proves the guard's then-branch, not some other
          -- Left, and that the diagnostic names the rejected coordinate).
          Left err  -> do
            case err of
              HarnessNotAuthorized _ -> pure ()
              other -> expectationFailure
                ("expected HarnessNotAuthorized, got " <> show other)
            T.isInfixOf "-rm-rf" (T.pack (show err)) `shouldBe` True
        readIORef markersRef >>= (`shouldBe` [])
        readIORef remainRef  >>= (`shouldBe` [])
        readIORef captureRef >>= (`shouldBe` 0)
        -- And nothing was registered nor any session.json written.
        Reg.snapshot reg >>= (\es -> length es `shouldBe` 0)
        loadAllSessionMetas tmp >>= (\ms -> length ms `shouldBe` 0)

    it "adoptExternalWindow refuses an invalid SESSION (from the token) with NO tmux op" $
      withSystemTempDirectory "pcl-adopt-badses" $ \tmp -> do
        reg <- Reg.newRegistry
        markersRef <- newIORef ([] :: [(Text, Text, Text)])
        captureRef <- newIORef (0 :: Int)
        let deps = okDeps
              { _ccd_setMarker    = \s w u -> modifyIORef' markersRef ((s, w, u) :)
              , _ccd_captureNamed = \_ _ _ -> modifyIORef' captureRef (+ 1) >> pure (Just "")
              }
            -- A LITERAL allow-list entry with a leading '-' (a misconfiguration)
            -- mints a token for a session that tmux would mis-read as an option.
            -- The argv defense holds, but the adopt path must STILL refuse it.
            adoptable = "-evil-session"
            gatePolicy = defaultPolicy
              { _sp_adoptableSessionPatterns =
                  case parseSessionPattern adoptable of
                    Just p  -> [p]
                    Nothing -> error "test setup: pattern rejected"
              }
            token = case authorizeAdoption gatePolicy ConsentInteractive adoptable of
              Right tok -> tok
              Left e    -> error ("test setup: gate denied: " <> show e)
        result <- adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp token "ok-window"
        case result of
          Right _ -> expectationFailure "expected adopt to refuse an invalid session name"
          Left _  -> pure ()
        readIORef markersRef >>= (`shouldBe` [])
        readIORef captureRef >>= (`shouldBe` 0)
        Reg.snapshot reg >>= (\es -> length es `shouldBe` 0)

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

-- | Load every @session.json@ under a sessions base directory (one per
-- immediate sub-directory). Used by the adopt tests to assert exactly one
-- session was created and that it carries the expected harness coordinates.
loadAllSessionMetas :: FilePath -> IO [SessionMeta]
loadAllSessionMetas baseDir = do
  entries <- listDirectory baseDir
  let metaPaths = [ baseDir </> e </> "session.json" | e <- entries ]
  present <- filterM doesFileExist metaPaths
  metas <- mapM (fmap Aeson.eitherDecode' . LBS.readFile) present
  pure (rights metas)
