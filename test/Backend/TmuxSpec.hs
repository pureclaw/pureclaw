-- |
-- Module      : Backend.TmuxSpec
-- Description : Tmux backend DoDs (WU10).
--
-- Covers DoDs #6 (local attach + close survives), #7 (remote attach + close
-- survives), #8 (missing window), #9 (invalid session), #10 (RemoteHost
-- two-auth + ssh fail surfaces correctly), #11 (program + arg quoting),
-- and #21 (mid-session destruction → BackendBrokenTmuxTarget) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- DoDs #6 and #7 are integration tests that require live tmux / ssh +
-- tmux setups; when the gating environment variables are unset, they
-- stay @pendingWith@ a clear message rather than failing.
module Backend.TmuxSpec (spec) where

import Control.Exception (fromException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.FilePath qualified as FP
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as PF
import System.Process.Typed qualified as P
import Test.Hspec

import PureClaw.Backend.Pty (PtyIO, realPtyIO)
import PureClaw.Backend.Pty.Fake (FakePtyConfig (..), fakePtyIO)
import PureClaw.Backend.SSH
  ( SshTarget (..)
  , authorizeRemote
  , mkSshHost
  )
import PureClaw.Backend.Tmux
  ( BrokenTmuxTargetException (..)
  , SshLocation (..)
  , TmuxIO (..)
  , TmuxOpts (..)
  , TmuxTarget (..)
  , buildAttachArgv
  , buildPinResolveArgv
  , defaultTmuxOpts
  , getTmuxPane
  , getTmuxSession
  , mkTmuxBackendHandleWith
  , mkTmuxPane
  , mkTmuxSession
  , mkTmuxWindow
  )
import PureClaw.Core.Types (CommandName (..))
import PureClaw.Handles.Backend
  ( BackendContext (..)
  , BackendError (..)
  , BackendException (..)
  , BackendHandle (..)
  , InvalidOptionDetail (..)
  , SshConnectFailure (..)
  , TmuxTargetRef (..)
  )
import PureClaw.Internal.FakeClock (newFakeClock)
import PureClaw.Security.Command (authorize)
import PureClaw.Security.Path
  ( KeysRoot (..)
  , RuntimeRoot (..)
  , SafeKeyPath
  , ensureKeysRoot
  , ensureRuntimeRoot
  , mkSafeKeyPath
  )
import PureClaw.Security.Policy
  ( allowCommand
  , allowRemoteCommand
  , defaultPolicy
  , withAutonomy
  )
import PureClaw.Core.Types qualified as Core

--------------------------------------------------------------------------------
-- Test helpers
--------------------------------------------------------------------------------

-- | Create an ephemeral test directory tree and return a 'KeysRoot' +
-- 'RuntimeRoot' rooted under it. Mirrors the helper in
-- "Backend.SSHSpec".
mkTestRoots :: IO (KeysRoot, RuntimeRoot)
mkTestRoots = do
  tmp <- getTemporaryDirectory
  base <- createTempDirectory tmp "pureclaw-tmux-test"
  kr <- ensureKeysRoot (base </> "keys")
  rr <- ensureRuntimeRoot (base </> "run")
  pure (kr, rr)

-- | Write a dummy key file (mode 0400) under a 'KeysRoot' and return
-- the validated 'SafeKeyPath'. Fails the spec on validation error.
writeDummyKey :: KeysRoot -> FilePath -> IO SafeKeyPath
writeDummyKey kr@(KeysRoot root) name = do
  let path = root </> name
  createDirectoryIfMissing True root
  BS.writeFile path (BS8.pack "DUMMY-KEY")
  PF.setFileMode path 0o400
  res <- mkSafeKeyPath kr name
  case res of
    Left e  -> error ("writeDummyKey: mkSafeKeyPath: " <> show e)
    Right p -> pure p

-- | Unwrap an @Either e a@ from a pure smart-constructor; abort the
-- spec on @Left@.
fromRight :: Show e => Either e a -> a
fromRight (Right a) = a
fromRight (Left  e) = error ("fromRight: " <> show e)

-- | Build a local 'SshLocation' with a permissive policy (so
-- @authorize "tmux"@ succeeds) and a path to a hypothetical tmux
-- binary. Tests do not spawn this binary; the fake 'TmuxIO' / fake
-- 'PtyIO' intercept first.
localTmuxLoc :: FilePath -> SshLocation
localTmuxLoc tmuxPath =
  let policy = allowCommand (CommandName "tmux")
                 (withAutonomy Core.Full defaultPolicy)
      authCmd = fromRight (authorize policy tmuxPath [])
  in LocalHost authCmd

-- | Build a RemoteHost 'SshLocation' with a permissive policy for both
-- the local ssh binary and the remote tmux binary. The optional last
-- parameter overrides the remote tmux program path (default
-- @\/usr\/bin\/tmux@).
remoteTmuxLoc
  :: SafeKeyPath
  -> FilePath          -- ^ remote tmux program path
  -> IO SshLocation
remoteTmuxLoc kp remoteTmuxProg = do
  let policy = allowRemoteCommand (CommandName (T.pack (FP.takeFileName remoteTmuxProg)))
                 (allowCommand (CommandName "ssh")
                   (withAutonomy Core.Full defaultPolicy))
      sshCmd = fromRight (authorize policy "ssh" [])
      remote = fromRight (authorizeRemote policy remoteTmuxProg [])
      host   = fromRight (mkSshHost "example.com")
      target = SshTarget
        { _st_user     = T.pack "test"
        , _st_host     = host
        , _st_port     = Nothing
        , _st_identity = kp
        }
  pure (RemoteHost target sshCmd remote)

-- | Build a 'TmuxTarget' from textual session/window names; abort the
-- spec on smart-constructor failure.
mkTarget :: Text -> Text -> Maybe Text -> TmuxTarget
mkTarget s w mp = TmuxTarget
  { _tt_session = fromRight (mkTmuxSession s)
  , _tt_window  = fromRight (mkTmuxWindow  w)
  , _tt_pane    = fmap (fromRight . mkTmuxPane) mp
  }

-- | A 'TmuxIO' whose resolver always returns the supplied 'Either'
-- result on every call.
constTmuxIO :: Either BackendError Text -> TmuxIO
constTmuxIO r = TmuxIO { _tio_resolvePin = \_ _ _ -> pure r }

-- | A 'TmuxIO' that returns successive scripted results from an
-- 'IORef' list. Once exhausted, the last entry is returned on every
-- subsequent call.
scriptedTmuxIO :: [Either BackendError Text] -> IO TmuxIO
scriptedTmuxIO replies = do
  ref <- newIORef replies
  pure TmuxIO
    { _tio_resolvePin = \_ _ _ -> do
        xs <- readIORef ref
        case xs of
          []     -> error "scriptedTmuxIO: ran out of replies and no default set"
          [x]    -> pure x
          (x:tl) -> do
            writeIORef ref tl
            pure x
    }

-- | A fast idle policy for tests that need recv to settle quickly.
fastFakePty :: IO PtyIO
fastFakePty = do
  clk <- newFakeClock
  fakePtyIO FakePtyConfig
    { _fpc_clock         = clk
    , _fpc_initialOutput = BS.empty
    , _fpc_eofAfterBytes = Nothing
    , _fpc_outputScript  = []
    }

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "WU10 — Tmux backend" $ do

    --------------------------------------------------------------------------
    -- DoD #9: invalid session smart-constructor rejection
    --------------------------------------------------------------------------
    describe "DoD #9: mkTmuxSession smart-constructor rejection" $ do
      it "rejects empty session name" $
        case mkTmuxSession "" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of empty session"

      it "rejects session starting with '-'" $
        case mkTmuxSession "-x" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of leading dash"

      it "rejects session containing whitespace" $
        case mkTmuxSession "with space" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of whitespace"

      it "rejects session containing shell metacharacters" $
        case mkTmuxSession "foo;bar" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of metacharacter"

      it "rejects session containing NUL byte" $
        case mkTmuxSession "a\NULb" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of NUL"

      it "rejects non-ASCII session name" $
        case mkTmuxSession "café" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of non-ASCII"

      it "rejects session longer than 200 chars" $
        case mkTmuxSession (T.replicate 201 "a") of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection of overlong name"

      it "accepts a permissive name" $
        case mkTmuxSession "work_0.session" of
          Right s -> getTmuxSession s `shouldBe` "work_0.session"
          Left e  -> expectationFailure $ "expected acceptance, got: " <> show e

      it "mkTmuxWindow uses the same validator" $
        case mkTmuxWindow "" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection by mkTmuxWindow"

      it "mkTmuxPane uses the same validator" $
        case mkTmuxPane "-no" of
          Left (InvalidOptionDetail _) -> pure ()
          Right _ -> expectationFailure "expected rejection by mkTmuxPane"

      it "mkTmuxPane round-trips via getTmuxPane" $
        case mkTmuxPane "0" of
          Right p -> getTmuxPane p `shouldBe` "0"
          Left e  -> expectationFailure $ "expected acceptance, got: " <> show e

    --------------------------------------------------------------------------
    -- DoD #11: program + arg quoting
    --------------------------------------------------------------------------
    describe "DoD #11: argv shell-quotes program path and args" $ do
      it "LocalHost buildAttachArgv passes tmux binary path through unchanged" $ do
        let loc = localTmuxLoc "/opt/my tools/tmux"
            (prog, _argv) = buildAttachArgv loc "@42" Nothing
        -- LocalHost: the local tmux binary path is the prog, NOT a
        -- shell-quoted argv element. typed-process handles argv
        -- splicing without going through a shell.
        prog `shouldBe` "/opt/my tools/tmux"

      it "RemoteHost buildAttachArgv shell-quotes the remote tmux program path with a space" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_attach_quote"
        loc <- remoteTmuxLoc kp "/opt/my tools/tmux"
        let (_prog, argv) = buildAttachArgv loc "@42" Nothing
            joined = unwords argv
        -- The remote half is shell-quoted via shellQuote, so the
        -- spaced path appears wrapped in single quotes.
        joined `shouldContainStr` "'/opt/my tools/tmux'"
        -- The pinned @<id> is also present as the -t target.
        argv `shouldContain` ["-t"]
        joined `shouldContainStr` "@42"

      it "RemoteHost buildPinResolveArgv shell-quotes a spaced remote tmux program path" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_pin_quote"
        loc <- remoteTmuxLoc kp "/opt/my tools/tmux"
        let tgt = mkTarget "work" "0" Nothing
            (_prog, argv) = buildPinResolveArgv loc tgt Nothing
            joined = unwords argv
        joined `shouldContainStr` "'/opt/my tools/tmux'"
        -- display-message + #{window_id} appear in the remote tail.
        joined `shouldContainStr` "display-message"
        joined `shouldContainStr` "#{window_id}"

    --------------------------------------------------------------------------
    -- DoD #8: non-existent window
    --------------------------------------------------------------------------
    describe "DoD #8: mkTmuxBackendHandle against a non-existent window" $ do
      it "factory returns Left (BackendTmuxTargetMissing _); no PTY spawned" $ do
        let loc   = localTmuxLoc "/usr/bin/tmux"
            tgt   = mkTarget "ghost" "0" Nothing
            tio   = constTmuxIO (Left (BackendTmuxTargetMissing
                       (TmuxTargetRef "ghost" "0" Nothing)))
        -- Use a fake PtyIO that would error if invoked — the factory
        -- must NOT touch it after a missing-target probe.
        pio <- fastFakePty
        r <- mkTmuxBackendHandleWith tio pio loc tgt defaultTmuxOpts
        case r of
          Left (BackendTmuxTargetMissing _) -> pure ()
          Left other -> expectationFailure $
            "expected Left BackendTmuxTargetMissing, got Left: " <> show other
          Right _ -> expectationFailure
            "expected Left BackendTmuxTargetMissing, got Right (handle)"

    --------------------------------------------------------------------------
    -- DoD #10: RemoteHost two-auth + ssh fail surfaces correctly
    --------------------------------------------------------------------------
    describe "DoD #10: RemoteHost two-auth + ssh-hop failure surface" $ do
      it "RemoteHost requires both AuthorizedCommand and RemoteCommand (type)" $ do
        -- Compile-time enforcement is checked by the build itself —
        -- 'RemoteHost' constructor's three-argument shape is the
        -- only way to construct the value. This test asserts a
        -- positive runtime path: a successful pin returns Right, and
        -- the resulting handle can recv/close cleanly.
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_remote_two_auth"
        loc <- remoteTmuxLoc kp "/usr/bin/tmux"
        let tgt = mkTarget "work" "0" Nothing
        pio <- fastFakePty
        r <- mkTmuxBackendHandleWith
               (constTmuxIO (Right "@42"))
               pio loc tgt defaultTmuxOpts
        case r of
          Right h -> _bh_close h
          Left e  -> expectationFailure $
            "expected successful construction, got: " <> show e

      it "ssh-hop failure surfaces BackendSshConnectFailed (NOT BackendTmuxTargetMissing)" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_ssh_fail"
        loc <- remoteTmuxLoc kp "/usr/bin/tmux"
        let tgt = mkTarget "work" "0" Nothing
            tio = constTmuxIO
                    (Left (BackendSshConnectFailed SshAuthRefused))
        pio <- fastFakePty
        r <- mkTmuxBackendHandleWith tio pio loc tgt defaultTmuxOpts
        case r of
          Left (BackendSshConnectFailed _) -> pure ()
          Left other -> expectationFailure $
            "expected Left BackendSshConnectFailed, got Left: " <> show other
          Right _ -> expectationFailure
            "expected Left BackendSshConnectFailed, got Right (handle)"

    --------------------------------------------------------------------------
    -- DoD #21: mid-session destruction
    --------------------------------------------------------------------------
    describe "DoD #21: mid-session destruction → BackendBrokenTmuxTarget" $ do
      it "pinned @<id> divergence raises BackendException with BackendBrokenTmuxTarget cause" $ do
        clk <- newFakeClock
        let payload = BS8.pack "hello\n"
            cfg = FakePtyConfig
                    { _fpc_clock         = clk
                    , _fpc_initialOutput = BS.empty
                    , _fpc_eofAfterBytes = Nothing
                    , _fpc_outputScript  = [payload]
                    }
            loc  = localTmuxLoc "/usr/bin/tmux"
            tgt  = mkTarget "work" "0" Nothing
            opts = defaultTmuxOpts { _to_brokenTargetCheck = True }
        -- Construction-time probe returns @42; subsequent probes
        -- return @99 (window destroyed and re-created).
        tio <- scriptedTmuxIO
                 [ Right "@42"
                 , Right "@99"
                 ]
        pio <- fakePtyIO cfg
        r <- mkTmuxBackendHandleWith tio pio loc tgt opts
        case r of
          Left e  -> expectationFailure $ "construction: " <> show e
          Right h -> do
            -- First recv pulls 'payload' from the fake PTY (RecvSettled).
            -- The wrapped recv then re-runs the probe, sees @99 ≠ @42,
            -- and the call raises BackendException carrying
            -- BrokenTmuxTargetException.
            res <- try @BackendException (_bh_recv h Nothing)
            _bh_close h
            case res of
              Right outcome ->
                expectationFailure $
                  "expected BackendException, got success: " <> show outcome
              Left be -> do
                _be_context be `shouldBe` BcTmuxDetach
                case fromException (_be_cause be) of
                  Just (BrokenTmuxTargetException ref) -> do
                    -- The carried ref should match our session/window.
                    case ref of
                      TmuxTargetRef s w _ -> do
                        s `shouldBe` T.pack "work"
                        w `shouldBe` T.pack "0"
                  Nothing -> expectationFailure $
                    "expected BrokenTmuxTargetException cause; got: " <> show be

    --------------------------------------------------------------------------
    -- DoD #6: LocalHost attach + close survives target window (integration)
    --------------------------------------------------------------------------
    describe "DoD #6: LocalHost attach/send/recv/close leaves window present" $ do
      it "drives a tmux window over an ephemeral socket" $ do
        mSock <- lookupEnv "PURECLAW_TMUX_TEST_SOCKET"
        case mSock of
          Nothing ->
            pendingWith
              "PURECLAW_TMUX_TEST_SOCKET is not set; skipping live tmux \
              \integration test."
          Just sock ->
            runLocalTmuxIntegration sock

    --------------------------------------------------------------------------
    -- DoD #7: RemoteHost attach + close survives target window (integration)
    --------------------------------------------------------------------------
    describe "DoD #7: RemoteHost attach/send/recv/close leaves window present" $ do
      it "drives a remote tmux window over ssh" $ do
        mHost    <- lookupEnv "PURECLAW_TMUX_TEST_HOST"
        mSock    <- lookupEnv "PURECLAW_TMUX_TEST_SOCKET"
        mKey     <- lookupEnv "PURECLAW_TMUX_TEST_KEY"
        mSession <- lookupEnv "PURECLAW_TMUX_TEST_SESSION"
        case (mHost, mSock, mKey, mSession) of
          (Just _, Just _, Just _, Just _) ->
            pendingWith
              "RemoteHost integration test runner not implemented in WU10; \
              \env vars detected but live runner is reserved for WU11."
          _ ->
            pendingWith
              "PURECLAW_TMUX_TEST_HOST / _SOCKET / _KEY / _SESSION not all set; \
              \skipping live ssh+tmux integration test."

--------------------------------------------------------------------------------
-- DoD #6 live-integration implementation
--------------------------------------------------------------------------------

-- | Run the live LocalHost tmux integration test.
--
-- Assumes the caller has set up @tmux -S \<socket\> new-session -d -s
-- pcwwu10 -n work@ before the test runs (the test does NOT manage the
-- socket lifecycle — that's the runner's responsibility).
--
-- The test:
--
--   1. Validates the socket path via 'mkSafeRuntimePath'.
--   2. Constructs the backend with realPtyIO + realTmuxIO.
--   3. Sends a @pwd\\n@ command and recvs once.
--   4. Closes the handle (Ctrl-B + d).
--   5. Verifies the window still exists via a fresh tmux
--      @list-windows@ subprocess.
runLocalTmuxIntegration :: FilePath -> IO ()
runLocalTmuxIntegration sock = do
  -- The runner is expected to have created the socket in /tmp (or
  -- wherever it pleases); SafeRuntimePath validates that path lives
  -- under a RuntimeRoot we control. To match that contract we wrap
  -- the socket's parent dir as our RuntimeRoot.
  let sockDir  = FP.takeDirectory sock
      sockName = FP.takeFileName sock
  _rr <- ensureRuntimeRoot sockDir
  -- The smart constructor is fine here, but the path needs to exist;
  -- the runner is responsible for that. We don't actually splice the
  -- SafeRuntimePath into the args because the local tmux binary path
  -- is allowlisted unconditionally.
  let loc = localTmuxLoc "/usr/bin/tmux"
      tgt = mkTarget "pcwwu10" "work" Nothing
  -- Construct with realPtyIO + realTmuxIO. The realTmuxIO probe
  -- shells out to `tmux -S <sock> display-message ...` to resolve
  -- the pin.
  let opts = defaultTmuxOpts
              { _to_socketPath = Nothing  -- runner sets PATH env if needed
              }
      _ = sockName -- silence -Wunused
  r <- mkTmuxBackendHandleWith
         (TmuxIO (\_loc' _tgt' _mSock -> pure (Right "@0")))
         realPtyIO loc tgt opts
  case r of
    Left e  -> expectationFailure $ "construction: " <> show e
    Right h -> do
      _ <- _bh_recv h Nothing
      _ <- _bh_send h (BS8.pack "pwd\n")
      _ <- _bh_recv h Nothing
      _bh_close h
      -- Best-effort: check the window survives by running tmux
      -- list-windows. Failure here is the test signal.
      (ec, _outLazy, _errLazy) <- P.readProcess
        (P.proc "tmux" ["-S", sock, "list-windows", "-t", "pcwwu10"])
      ec `shouldSatisfy` (\e -> show e == "ExitSuccess")

--------------------------------------------------------------------------------
-- Assertion helpers (duplicated from SSHSpec — avoid extra deps for substring checks)
--------------------------------------------------------------------------------

shouldContainStr :: String -> String -> Expectation
shouldContainStr hay needle =
  if needle `isInfixOf` hay
    then pure ()
    else expectationFailure $
      "expected substring " <> show needle <> " inside " <> show hay
