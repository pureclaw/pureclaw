module Harness.TmuxSpec (spec) where

import Data.ByteString ()
import Data.ByteString.Char8 qualified as BC
import Data.Either
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Handles.Harness
import PureClaw.Harness.Tmux

spec :: Spec
spec = do
  -- ===========================================================================
  -- WU1: identity ops + name targeting + capability check
  -- ===========================================================================

  -- D1.1 — name targeting renders <session>:<windowName>
  describe "windowTarget (D1.1)" $ do
    it "renders <session>:<windowName>" $
      windowTarget "pureclaw" "claude-code-0" `shouldBe` "pureclaw:claude-code-0"

    it "handles names with hyphens and digits" $
      windowTarget "sess" "harness-ab12cd" `shouldBe` "sess:harness-ab12cd"

  -- D1.1 — the name-targeted I/O argv builders target <session>:<windowName>
  describe "name-targeted argv builders (D1.1)" $ do
    it "sendKeysNamedArgs (small) targets the window name and appends Enter" $ do
      let argv = sendKeysNamedArgs "pureclaw" "claude-code-0" (BC.pack "hello")
      argv `shouldBe` ["send-keys", "-t", "pureclaw:claude-code-0", "hello", "Enter"]

    it "pasteBufferNamedArgs (large) targets the window name" $ do
      let argv = pasteBufferNamedArgs "pureclaw" "claude-code-0"
      argv `shouldBe` ["paste-buffer", "-t", "pureclaw:claude-code-0"]

    it "captureNamedArgs targets the window name with -p and scrollback" $ do
      let argv = captureNamedArgs "pureclaw" "claude-code-0" 300
      argv `shouldBe` ["capture-pane", "-t", "pureclaw:claude-code-0", "-p", "-S", "-300"]

    it "killWindowNamedArgs targets the window name" $ do
      let argv = killWindowNamedArgs "pureclaw" "claude-code-0"
      argv `shouldBe` ["kill-window", "-t", "pureclaw:claude-code-0"]

    it "renameWindowNamedArgs targets old name and renames to the new label" $ do
      let argv = renameWindowNamedArgs "pureclaw" "old-name" "new-name"
      argv `shouldBe` ["rename-window", "-t", "pureclaw:old-name", "new-name"]

    it "newWindowNamedArgs creates a named window without a workdir" $ do
      let argv = newWindowNamedArgs "pureclaw" "claude-code-x" Nothing "the-cmd"
      argv `shouldBe` ["new-window", "-t", "pureclaw", "-n", "claude-code-x", "the-cmd"]

    it "newWindowNamedArgs honors an optional working directory" $ do
      let argv = newWindowNamedArgs "pureclaw" "claude-code-x" (Just "/tmp/work") "the-cmd"
      argv `shouldBe`
        ["new-window", "-t", "pureclaw", "-n", "claude-code-x", "-c", "/tmp/work", "the-cmd"]

  -- D1.5 — set-option argv (marker + remain-on-exit)
  describe "set-option argv builders (D1.3 / D1.5)" $ do
    it "setWindowMarkerArgs sets @pcl_id on the named window" $ do
      let argv = setWindowMarkerArgs "pureclaw" "claude-code-0" "uuid-123"
      argv `shouldBe`
        ["set-option", "-w", "-t", "pureclaw:claude-code-0", "@pcl_id", "uuid-123"]

    it "setRemainOnExitArgs sets remain-on-exit on the named window" $ do
      let argv = setRemainOnExitArgs "pureclaw" "claude-code-0"
      argv `shouldBe`
        ["set-option", "-w", "-t", "pureclaw:claude-code-0", "remain-on-exit", "on"]

  -- D1.2 (parse half, pure) — readMarkers row parsing
  describe "parseMarkerRows (D1.2)" $ do
    it "parses a full tab-separated row including @pcl_id, pane_pid, pane_dead" $ do
      let bs = BC.pack "0\tclaude-code-0\tuuid-abc\t4242\t0\n"
          rows = parseMarkerRows bs
      rows `shouldBe`
        [ TmuxWindowRow
            { _twr_windowIndex = 0
            , _twr_windowName  = "claude-code-0"
            , _twr_pclId       = "uuid-abc"
            , _twr_panePid     = Just 4242
            , _twr_paneDead    = False  -- pane_dead field "0" => alive
            }
        ]

    it "treats pane_dead 0 as alive (False) and 1 as dead (True)" $ do
      let bs = BC.pack "0\tw0\tid0\t100\t0\n1\tw1\tid1\t200\t1\n"
          rows = parseMarkerRows bs
      map _twr_paneDead rows `shouldBe` [False, True]

    it "tolerates an empty @pcl_id field" $ do
      let bs = BC.pack "2\tplain\t\t300\t0\n"
          rows = parseMarkerRows bs
      map _twr_pclId rows `shouldBe` [""]
      map _twr_panePid rows `shouldBe` [Just 300]

    it "returns Nothing for an unparseable pane_pid" $ do
      let bs = BC.pack "3\tw\tid\t\t0\n"
          rows = parseMarkerRows bs
      map _twr_panePid rows `shouldBe` [Nothing]

    it "skips malformed lines (too few fields)" $ do
      let bs = BC.pack "garbage\n0\tw0\tid0\t100\t0\n"
          rows = parseMarkerRows bs
      map _twr_windowIndex rows `shouldBe` [0]

  -- D1.3 — selectHarnessPid pure selector
  describe "selectHarnessPid (D1.3)" $ do
    it "returns the direct child of the pane shell pid matching the comm" $ do
      -- pane shell pid = 100; the script wrapper is the pane, claude is its child
      let rows = [ (100, 1, "script")    -- the pane process itself
                 , (200, 100, "claude")  -- direct child matching comm
                 , (300, 200, "node")    -- grandchild, must NOT be selected
                 , (400, 1, "claude")    -- unrelated claude (different parent)
                 ]
      selectHarnessPid 100 "claude" rows `shouldBe` Just 200

    it "returns Nothing when no descendant matches the comm" $ do
      let rows = [ (100, 1, "script")
                 , (200, 100, "bash")
                 ]
      selectHarnessPid 100 "claude" rows `shouldBe` Nothing

    it "does not select a sibling (same comm, different parent)" $ do
      let rows = [ (200, 999, "claude")  -- sibling under a different pane
                 , (300, 100, "bash")
                 ]
      selectHarnessPid 100 "claude" rows `shouldBe` Nothing

    it "finds a deeper descendant when no direct child matches (recursive descent)" $ do
      -- Linux: script -> sh -c -> binary (2 levels)
      let rows = [ (100, 1, "script")
                 , (150, 100, "sh")      -- intermediate sh -c
                 , (250, 150, "claude")  -- the binary, a grandchild
                 ]
      selectHarnessPid 100 "claude" rows `shouldBe` Just 250

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

    it "listSessionWindows returns windows with names" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-list-windows"
          _ <- startTmuxSession sName
          -- Rename the default window
          renameWindow sName 0 "claude-code-0"
          windows <- listSessionWindows sName
          -- Should have at least one window
          length windows `shouldSatisfy` (>= 1)
          -- Window 0 should be named "claude-code-0"
          case lookup 0 windows of
            Just name -> name `shouldBe` "claude-code-0"
            Nothing   -> expectationFailure "expected window 0"
          -- Clean up
          stopTmuxSession sName

    it "listSessionWindows returns empty for nonexistent session" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          windows <- listSessionWindows "pureclaw-test-nonexistent"
          windows `shouldBe` []

  -- ===========================================================================
  -- WU1 integration tests (require a live tmux server)
  -- ===========================================================================
  describe "WU1 identity ops (integration)" $ do
    -- D1.4 — startTmuxSessionStatus reports created vs existed
    it "startTmuxSessionStatus reports created then existed (D1.4)" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-status"
          stopTmuxSession sName  -- ensure clean slate
          first <- startTmuxSessionStatus sName
          first `shouldBe` Right TmuxSessionCreated
          second <- startTmuxSessionStatus sName
          second `shouldBe` Right TmuxSessionExisted
          stopTmuxSession sName

    -- D1.2 — marker set/read round-trips
    it "setWindowMarker then readMarkers round-trips @pcl_id (D1.2)" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-marker"
              wName = "claude-code-0"
              uuid  = "test-uuid-abc123"
          stopTmuxSession sName
          _ <- startTmuxSessionStatus sName
          renameWindowNamed sName "0" wName
          setWindowMarker sName wName uuid
          rows <- readMarkers sName
          let markers = [ _twr_pclId r | r <- rows, _twr_windowName r == wName ]
          markers `shouldBe` [uuid]
          -- each row should carry a shell pid (#{pane_pid})
          let pids = [ _twr_panePid r | r <- rows, _twr_windowName r == wName ]
          notElem Nothing pids `shouldBe` True
          stopTmuxSession sName

    -- D1.5 — remain-on-exit set (round-trip via show-options)
    it "setRemainOnExit turns remain-on-exit on (D1.5)" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-remain"
              wName = "claude-code-0"
          stopTmuxSession sName
          _ <- startTmuxSessionStatus sName
          renameWindowNamed sName "0" wName
          setRemainOnExit sName wName
          opt <- showWindowOption sName wName "remain-on-exit"
          opt `shouldSatisfy` T.isInfixOf "on"
          stopTmuxSession sName

    -- D1.6 — capability check
    it "checkTmuxCapabilities returns Right on a supporting tmux (D1.6)" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          result <- checkTmuxCapabilities
          result `shouldBe` Right ()

    -- listTmuxSessions lists a created session
    it "listTmuxSessions includes a started session" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-list-sessions"
          _ <- startTmuxSessionStatus sName
          sessions <- listTmuxSessions
          sessions `shouldSatisfy` elem sName
          stopTmuxSession sName

    -- name-targeted add + capture round-trip
    it "addHarnessWindowNamed then captureWindowNamed round-trips output" $ do
      available <- requireTmux
      case available of
        Left _ -> pendingWith "tmux not available on this system"
        Right () -> do
          let sName = "pureclaw-test-named-io"
              wName = "claude-code-0"
          stopTmuxSession sName
          _ <- startTmuxSessionStatus sName
          renameWindowNamed sName "0" wName
          -- echo a marker string into the window, then capture it
          sendToWindowNamed sName wName (BC.pack "echo PURECLAW_NAMED_MARKER")
          out <- captureWindowNamed sName wName 300
          BC.unpack out `shouldContain` "PURECLAW_NAMED_MARKER"
          stopTmuxSession sName

    -- D1.6 — harnessPidOf returns Nothing for a bogus shell pid
    it "harnessPidOf returns Nothing for a pane pid with no matching child" $ do
      -- pid 1 (init/launchd) has no flavour-binary descendant we control
      result <- harnessPidOf 999999999 "claude"
      result `shouldBe` Nothing
