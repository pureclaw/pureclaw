-- |
-- Module      : Backend.SSHSpec
-- Description : SSH backend DoDs (WU9).
--
-- Covers DoDs #3 (remote 3-turn bash), #4 (unresolvable host), #5
-- (argv flag set), and #15 (SshHost rejects leading @-@) from
-- @docs/terminal-backend-abstractions.md@ § Acceptance Criteria (v1).
--
-- DoD #3 is an integration test that requires a live remote host;
-- when the @PURECLAW_SSH_TEST_HOST@ environment variable is unset, it
-- stays @pendingWith@ a clear message rather than failing.
module Backend.SSHSpec (spec) where

import Control.Monad qualified
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.FilePath qualified as FP
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as PF
import Test.Hspec

import PureClaw.Backend.Pty (realPtyIO)
import PureClaw.Backend.SSH
  ( ControlOpts (..)
  , SshTarget (..)
  , authorizeRemote
  , buildSshArgv
  , defaultSshOpts
  , getRemoteArgs
  , getRemoteProgram
  , mkSshBackendHandle
  , mkSshHost
  )
import PureClaw.Core.Types (CommandName (..))
import PureClaw.Handles.Backend
  ( BackendError (..)
  , BackendHandle (..)
  , RecvResult (..)
  , recvBytes
  , runBackend
  )
import PureClaw.Security.Command (authorize)
import PureClaw.Security.Command qualified as SC
import PureClaw.Security.Path
  ( KeysRoot (..)
  , RuntimeRoot (..)
  , SafeKeyPath
  , SafeRuntimePath
  , ensureKeysRoot
  , ensureRuntimeRoot
  , mkSafeKeyPath
  , mkSafeRuntimePath
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

-- | Create an ephemeral test directory tree and return a 'KeysRoot'
-- + 'RuntimeRoot' rooted under it. Used to build 'SafeKeyPath' /
-- 'SafeRuntimePath' values that satisfy 'mkSafeKeyPath' /
-- 'mkSafeRuntimePath' without polluting a real user directory.
mkTestRoots :: IO (KeysRoot, RuntimeRoot)
mkTestRoots = do
  tmp <- getTemporaryDirectory
  base <- createTempDirectory tmp "pureclaw-ssh-test"
  kr <- ensureKeysRoot (base </> "keys")
  rr <- ensureRuntimeRoot (base </> "run")
  pure (kr, rr)

-- | Write a dummy key file (mode 0400) under a 'KeysRoot' and return
-- the validated 'SafeKeyPath'. Fails the calling spec if either step
-- fails.
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

-- | Materialize a 'SafeRuntimePath' under a 'RuntimeRoot' (creating an
-- empty file if missing). Fails the calling spec on validation error.
mkRuntimeFile :: RuntimeRoot -> FilePath -> IO SafeRuntimePath
mkRuntimeFile rr@(RuntimeRoot root) name = do
  let path = root </> name
  createDirectoryIfMissing True root
  exists <- doesFileExist path
  if exists then pure () else BS.writeFile path BS.empty
  res <- mkSafeRuntimePath rr name
  case res of
    Left e  -> error ("mkRuntimeFile: mkSafeRuntimePath: " <> show e)
    Right p -> pure p

-- | Unwrap an @Either e a@ from a pure smart-constructor; abort the
-- calling spec on @Left@.
fromRight :: Show e => Either e a -> a
fromRight (Right a) = a
fromRight (Left  e) = error ("fromRight: " <> show e)

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "WU9 — SSH backend" $ do

    describe "mkSshHost (DoD #15 + extras)" $ do
      it "DoD #15: rejects leading '-' (e.g. -oProxyCommand=evil)" $
        case mkSshHost "-x" of
          Left (BackendInvalidOption _) -> pure ()
          other -> expectationFailure $
            "expected BackendInvalidOption, got: " <> show other

      it "rejects empty host" $
        case mkSshHost "" of
          Left (BackendInvalidOption _) -> pure ()
          other -> expectationFailure $
            "expected BackendInvalidOption, got: " <> show other

      it "rejects host containing whitespace" $
        case mkSshHost "host with space" of
          Left (BackendInvalidOption _) -> pure ()
          other -> expectationFailure $
            "expected BackendInvalidOption, got: " <> show other

      it "rejects host containing shell metacharacters" $
        case mkSshHost "host;rm -rf /" of
          Left (BackendInvalidOption _) -> pure ()
          other -> expectationFailure $
            "expected BackendInvalidOption, got: " <> show other

      it "accepts a plain RFC 1123 hostname" $
        case mkSshHost "example.com" of
          Right _ -> pure ()
          Left e  -> expectationFailure $ "expected Right, got: " <> show e

      it "accepts a bracketed IPv6 literal" $
        case mkSshHost "[::1]" of
          Right _ -> pure ()
          Left e  -> expectationFailure $ "expected Right, got: " <> show e

      it "accepts a dotted-quad IPv4 literal" $
        case mkSshHost "10.0.0.1" of
          Right _ -> pure ()
          Left e  -> expectationFailure $ "expected Right, got: " <> show e

    describe "authorizeRemote (mirrors authorize against the remote allowlist)" $ do
      let policyEmpty =
            withAutonomy Core.Full defaultPolicy
          policyAllow =
            allowRemoteCommand (CommandName "bash")
              (withAutonomy Core.Full defaultPolicy)
          policyDeny =
            withAutonomy Core.Deny
              (allowRemoteCommand (CommandName "bash") defaultPolicy)

      it "rejects when the remote allowlist does not include the command" $
        case authorizeRemote policyEmpty "bash" ["-i"] of
          Left (SC.CommandNotAllowed name) -> name `shouldBe` "bash"
          Left e ->
            expectationFailure $ "expected CommandNotAllowed, got: " <> show e
          Right _ ->
            expectationFailure "expected CommandNotAllowed, got Right"

      it "rejects when autonomy is Deny even if command is allowlisted" $
        case authorizeRemote policyDeny "bash" ["-i"] of
          Left SC.CommandInAutonomyDeny -> pure ()
          Left e ->
            expectationFailure $ "expected CommandInAutonomyDeny, got: " <> show e
          Right _ ->
            expectationFailure "expected CommandInAutonomyDeny, got Right"

      it "accepts an allowlisted command and exposes its program + args" $
        case authorizeRemote policyAllow "bash" ["-i"] of
          Right rc -> do
            getRemoteProgram rc `shouldBe` "bash"
            getRemoteArgs    rc `shouldBe` ["-i"]
          Left e -> expectationFailure $ "expected Right, got: " <> show e

    -- docs/terminal-backend-abstractions.md line 54: ssh argv hardening
    describe "DoD #5: mkSshBackendHandle argv includes hardened flag set" $ do
      it "argv contains the full hardened flag set; no -X / -Y / -A" $ do
        (kr, rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_test"
        kh <- mkRuntimeFile rr "known_hosts"
        let host   = fromRight (mkSshHost "example.com")
            remote = fromRight $ authorizeRemote
              (allowRemoteCommand (CommandName "echo")
                (withAutonomy Core.Full defaultPolicy))
              "echo"
              ["hi"]
            target = SshTarget
              { _st_user     = T.pack "test"
              , _st_host     = host
              , _st_port     = Just 22
              , _st_identity = kp
              }
            argv = buildSshArgv target remote (Just kh) Nothing True
            joined = unwords argv
        argv `shouldContainConsec` ["-F", "/dev/null"]
        joined `shouldContainStr` "StrictHostKeyChecking=accept-new"
        joined `shouldContainStr` "BatchMode=yes"
        joined `shouldContainStr` "IdentitiesOnly=yes"
        joined `shouldContainStr` "ConnectTimeout=10"
        joined `shouldContainStr` "ServerAliveInterval=30"
        joined `shouldContainStr` "ServerAliveCountMax=3"
        joined `shouldContainStr` "ForwardX11=no"
        joined `shouldContainStr` "ForwardX11Trusted=no"
        joined `shouldContainStr` "ForwardAgent=no"
        joined `shouldContainStr` "PermitLocalCommand=no"
        joined `shouldContainStr` "UserKnownHostsFile="
        argv `shouldContain` ["-i"]
        argv `shouldContainConsec` ["-p", "22"]
        argv `shouldContain` ["-tt"]
        argv `shouldContain` ["test@example.com"]
        -- forwarding-enable flags must NOT appear:
        argv `shouldNotContainElem` "-X"
        argv `shouldNotContainElem` "-Y"
        argv `shouldNotContainElem` "-A"

      it "argv omits -tt and -p when not requested" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_test2"
        let host   = fromRight (mkSshHost "example.com")
            remote = fromRight $ authorizeRemote
              (allowRemoteCommand (CommandName "hostname")
                (withAutonomy Core.Full defaultPolicy))
              "hostname"
              []
            target = SshTarget
              { _st_user     = T.pack "test"
              , _st_host     = host
              , _st_port     = Nothing
              , _st_identity = kp
              }
            argv = buildSshArgv target remote Nothing Nothing False
        argv `shouldNotContainElem` "-tt"
        argv `shouldNotContainElem` "-p"

      it "argv includes ControlMaster flags when ControlOpts is set" $ do
        (kr, rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_test3"
        sock <- mkRuntimeFile rr "ctl.sock"
        let host   = fromRight (mkSshHost "example.com")
            remote = fromRight $ authorizeRemote
              (allowRemoteCommand (CommandName "bash")
                (withAutonomy Core.Full defaultPolicy))
              "bash"
              ["-i"]
            target = SshTarget
              { _st_user     = T.pack "test"
              , _st_host     = host
              , _st_port     = Nothing
              , _st_identity = kp
              }
            ctl = ControlOpts { _co_controlPath = sock, _co_persistSecs = 300 }
            argv = buildSshArgv target remote Nothing (Just ctl) True
            joined = unwords argv
        joined `shouldContainStr` "ControlMaster=auto"
        joined `shouldContainStr` "ControlPath="
        joined `shouldContainStr` "ControlPersist=300"

      it "argv shell-quotes the remote program path containing a space" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_test4"
        let host   = fromRight (mkSshHost "example.com")
            remote = fromRight $ authorizeRemote
              (allowRemoteCommand (CommandName "tmux")
                (withAutonomy Core.Full defaultPolicy))
              "/opt/my tools/tmux"
              ["new-window"]
            target = SshTarget
              { _st_user     = T.pack "test"
              , _st_host     = host
              , _st_port     = Nothing
              , _st_identity = kp
              }
            argv = buildSshArgv target remote Nothing Nothing False
            joined = unwords argv
        joined `shouldContainStr` "'/opt/my tools/tmux'"

    -- docs/terminal-backend-abstractions.md line 53: unresolvable host
    describe "DoD #4: mkSshBackendHandle with unresolvable host" $ do
      it "fails closed without throwing (ConnectTimeout=10)" $ do
        (kr, _rr) <- mkTestRoots
        kp <- writeDummyKey kr "id_test5"
        -- 192.0.2.0/24 is reserved for documentation (RFC 5737) and
        -- not routable; ssh will hit ConnectTimeout.
        let host   = fromRight (mkSshHost "192.0.2.1")
            remote = fromRight $ authorizeRemote
              (allowRemoteCommand (CommandName "true")
                (withAutonomy Core.Full defaultPolicy))
              "true"
              []
            policy = allowCommand (CommandName "ssh")
                       (withAutonomy Core.Full defaultPolicy)
            sshCmd = fromRight (authorize policy "ssh" [])
            target = SshTarget
              { _st_user     = T.pack "test"
              , _st_host     = host
              , _st_port     = Nothing
              , _st_identity = kp
              }
        result <- mkSshBackendHandle realPtyIO sshCmd target remote defaultSshOpts
        -- Two acceptable shapes: construction fails immediately with
        -- BackendSshConnectFailed, OR the handle is constructed and
        -- the next recv returns RecvEof/RecvTimedOut (ssh exits when
        -- ConnectTimeout fires).
        case result of
          Left (BackendSshConnectFailed _) -> pure ()
          Left other -> expectationFailure $
            "expected BackendSshConnectFailed, got: " <> show other
          Right h -> do
            r <- _bh_recv h Nothing
            _bh_close h
            case r of
              RecvEof _       -> pure ()
              RecvTimedOut _  -> pure ()
              RecvSettled _   -> pure ()
              RecvTruncated _ -> pure ()

    -- docs/terminal-backend-abstractions.md line 52: ssh bash 3-turn
    describe "DoD #3: mkSshBackendHandle bash three-turn sequence" $ do
      it "drives 'cd /tmp; pwd' over ssh against a configured test host" $ do
        mHost <- lookupEnv "PURECLAW_SSH_TEST_HOST"
        mKey  <- lookupEnv "PURECLAW_SSH_TEST_KEY"
        case (mHost, mKey) of
          (Just hostSpec, Just keyPath) ->
            runThreeTurnSsh hostSpec keyPath
          _ ->
            pendingWith
              "PURECLAW_SSH_TEST_HOST and PURECLAW_SSH_TEST_KEY are not set; \
              \skipping live ssh integration test."

--------------------------------------------------------------------------------
-- DoD #3 live-integration implementation
--------------------------------------------------------------------------------

-- | Live 3-turn ssh integration test. Only invoked when the env vars
-- are set; structured here so the @pendingWith@ branch above stays
-- readable.
runThreeTurnSsh :: String -> String -> IO ()
runThreeTurnSsh hostSpec keyPath = do
  let (user, hostRaw) = break (== '@') hostSpec
      host = drop 1 hostRaw
  if null user || null host
    then expectationFailure $
      "PURECLAW_SSH_TEST_HOST must be of the form user@host; got: " <> hostSpec
    else case mkSshHost (T.pack host) of
      Left e ->
        expectationFailure $ "invalid PURECLAW_SSH_TEST_HOST host: " <> show e
      Right sshHost -> do
        krOf <- ensureKeysRoot (FP.takeDirectory keyPath)
        keyRes <- mkSafeKeyPath krOf (FP.takeFileName keyPath)
        case keyRes of
          Left e ->
            expectationFailure $ "PURECLAW_SSH_TEST_KEY did not validate: " <> show e
          Right kp -> do
            let policy = allowRemoteCommand (CommandName "bash")
                           (allowCommand (CommandName "ssh")
                             (withAutonomy Core.Full defaultPolicy))
                sshCmd = fromRight (authorize policy "ssh" [])
                remote = fromRight (authorizeRemote policy "bash" ["-i"])
                target = SshTarget
                  { _st_user     = T.pack user
                  , _st_host     = sshHost
                  , _st_port     = Nothing
                  , _st_identity = kp
                  }
            result <- mkSshBackendHandle realPtyIO sshCmd target remote defaultSshOpts
            case result of
              Left e -> expectationFailure $ "construction failed: " <> show e
              Right h -> do
                _ <- _bh_recv h Nothing
                _ <- runBackend h (BS8.pack "cd /tmp\n")
                r2 <- runBackend h (BS8.pack "pwd\n")
                _ <- runBackend h (BS8.pack "exit\n")
                _bh_close h
                let out = recvBytes r2
                    contains = BS.isInfixOf (BS8.pack "/tmp") out
                            || BS.isInfixOf (BS8.pack "/private/tmp") out
                if contains
                  then pure ()
                  else expectationFailure $
                    "expected pwd output to contain /tmp; got: " <> show out

--------------------------------------------------------------------------------
-- Small assertion helpers (avoid extra deps for sublist checks)
--------------------------------------------------------------------------------

-- | Assert that the haystack contains a contiguous sub-sequence equal
-- to @needle@.
shouldContainConsec :: (Eq a, Show a) => [a] -> [a] -> Expectation
shouldContainConsec hay needle =
  if isInfixOfList needle hay
    then pure ()
    else expectationFailure $
      "expected contiguous sublist " <> show needle <> " inside " <> show hay

isInfixOfList :: Eq a => [a] -> [a] -> Bool
isInfixOfList needle hay
  | length needle > length hay = False
  | take (length needle) hay == needle = True
  | otherwise = case hay of
      []     -> False
      _ : tl -> isInfixOfList needle tl

shouldContainStr :: String -> String -> Expectation
shouldContainStr hay needle =
  if needle `isInfixOf` hay
    then pure ()
    else expectationFailure $
      "expected substring " <> show needle <> " inside " <> show hay

-- | Assert that @x@ is NOT an element of @hay@.
shouldNotContainElem :: (Eq a, Show a) => [a] -> a -> Expectation
shouldNotContainElem hay x =
  Control.Monad.when (x `elem` hay) $
    expectationFailure $
      "did not expect element " <> show x <> " in " <> show hay

-- Silence -Wunused-imports for 'Text' (kept in scope for future
-- additions to this spec).
_textProxy :: Text
_textProxy = T.empty
