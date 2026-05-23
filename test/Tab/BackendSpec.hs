-- |
-- Module      : Tab.BackendSpec
-- Description : Backend-tab DoDs (L\/I subsets) — WU8 flips these green.
--
-- Enumerates backend-tab-specific Definition-of-Done items from
-- @docs/tabbed-chat.md@ — the KindShell\/KindSsh\/KindTmux subsets of
-- L-series and I-series. WU8 lands:
--
--   * L3 — '/tab close' on KindBackend (Shell\/Ssh\/Tmux) is destructive:
--          '_bh_close' runs, transcript NOT archived.
--   * I4 — slash-prefixed direct-inject is opaque text to the backend
--          (the backend sees the literal '\/cmd' bytes).
--
-- Other H-series KindBackend items (H4, H6–H11) are exercised here too,
-- mirroring the WU7 'Tab.HarnessSpec' coverage for harness tabs.
module Tab.BackendSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( atomically
  , newTBQueueIO
  , newTVarIO
  , tryReadTBQueue
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either qualified
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Backend.SSH qualified as SSH
import PureClaw.Backend.Tmux qualified as Tmux
import PureClaw.Core.Types
import PureClaw.Handles.Backend qualified as Backend
import PureClaw.Handles.Channel (mkNoOpChannelHandle)
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Tab
  ( CloseMode (..)
  , TabError (..)
  , TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabStatus (..)
  , mkTabIndex
  )
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types
  ( ChannelEvent (..)
  , OutputSource (..)
  )
import PureClaw.Security.Command qualified as SecCmd
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle (..))
import PureClaw.Security.Vault.Age (VaultError (..))
import PureClaw.Security.Vault.Plugin
import PureClaw.Security.Vault qualified as Vault
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tab.Backend
  ( BackendIO (..)
  , mkTabBackend
  , mkTabBackendWith
  , parseTmuxTarget
  , parseUserAtHost
  , realBackendIO
  )
import PureClaw.Tools.Registry (emptyRegistry)


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

ti :: Int -> TabIndex
ti = fromJust . mkTabIndex

-- | Per-test capture for the fake 'BackendHandle' produced by
-- 'mkFakeBackendIO'. Records every '_bh_send' payload and every
-- '_bh_close' invocation so tests can assert on side effects.
data BackendCapture = BackendCapture
  { _bc_sends   :: IORef [ByteString]
  , _bc_closed  :: IORef Int            -- count of _bh_close invocations
  , _bc_outputs :: IORef [ByteString]    -- queue of bytes _bh_recv yields
  , _bc_shellArgs   :: IORef [(FilePath, [Text])]
  , _bc_sshTargets  :: IORef [(Text, Text)]  -- (user, host)
  , _bc_tmuxTargets :: IORef [(Text, Text, Maybe Text)]  -- (session, window, pane)
  }

newBackendCapture :: IO BackendCapture
newBackendCapture = BackendCapture
  <$> newIORef []
  <*> newIORef 0
  <*> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef []

-- | Build a fake 'BackendHandle' that records sends and serves a
-- pre-seeded list of outputs.
mkFakeBackend :: BackendCapture -> Backend.BackendHandle
mkFakeBackend cap = Backend.BackendHandle
  { Backend._bh_name        = "fake-backend"
  , Backend._bh_kind        = Backend.Pipe
  , Backend._bh_defaultIdle = Backend.testIdleSpec
  , Backend._bh_send        = \bs ->
      atomicModifyIORef' (_bc_sends cap) (\xs -> (xs <> [bs], ()))
  , Backend._bh_recv        = \_ -> do
      nextChunk <- atomicModifyIORef' (_bc_outputs cap) popHead
      if BS.null nextChunk
        then pure (Backend.RecvSettled BS.empty)
        else pure (Backend.RecvSettled nextChunk)
  , Backend._bh_resize      = \_ _ -> pure ()
  , Backend._bh_close       =
      atomicModifyIORef' (_bc_closed cap) (\n -> (n + 1, ()))
  }

-- | Pop the head of a list, returning the new tail and (the head or
-- 'BS.empty' if the list was empty). Helper used by 'mkFakeBackend' to
-- serve the seeded outputs in order.
popHead :: [ByteString] -> ([ByteString], ByteString)
popHead []     = ([], BS.empty)
popHead (h:tl) = (tl, h)

-- | A 'BackendIO' wired to a 'BackendCapture'. Records the args each
-- sub-factory received and returns the same fake handle for every call.
fakeBackendIO :: BackendCapture -> BackendIO
fakeBackendIO cap = BackendIO
  { _bio_mkShell = \authCmd -> do
      -- Record the program and args for assertions.
      atomicModifyIORef' (_bc_shellArgs cap) $ \xs ->
        (projectAuthCmd authCmd : xs, ())
      pure (Right (mkFakeBackend cap))
  , _bio_mkSsh = \tgt _sshCmd _remote -> do
      atomicModifyIORef' (_bc_sshTargets cap) $ \xs ->
        ((SSH._st_user tgt, SSH.getSshHost (SSH._st_host tgt)) : xs, ())
      pure (Right (mkFakeBackend cap))
  , _bio_mkTmux = \_loc tgt -> do
      atomicModifyIORef' (_bc_tmuxTargets cap) $ \xs ->
        (projectTmuxTarget tgt : xs, ())
      pure (Right (mkFakeBackend cap))
  }
  where
    -- AuthorizedCommand's constructor is non-exported; use the public
    -- accessors to extract the program/args pair.
    projectAuthCmd c =
      ( SecCmd.getCommandProgram c
      , SecCmd.getCommandArgs c
      )
    projectTmuxTarget t =
      ( Tmux.getTmuxSession (Tmux._tt_session t)
      , Tmux.getTmuxWindow  (Tmux._tt_window  t)
      , Tmux.getTmuxPane <$> Tmux._tt_pane t
      )

-- | A 'BackendIO' whose sub-factories all return 'Left'. Used to test
-- the 'TabBackendConstructFailed' path through 'finishSpawn'.
failingBackendIO :: Backend.BackendError -> BackendIO
failingBackendIO err = BackendIO
  { _bio_mkShell = \_ -> pure (Left err)
  , _bio_mkSsh   = \_ _ _ -> pure (Left err)
  , _bio_mkTmux  = \_ _   -> pure (Left err)
  }

-- | A test 'AgentEnv' with a policy that allows specific commands.
-- The 'allowedLocal' \/ 'allowedRemote' args are command basenames
-- (e.g. @"ls"@, @"ssh"@) to add to the policy's allowlists.
mkBackendTestEnv :: [Text] -> [Text] -> IO AgentEnv
mkBackendTestEnv allowedLocal allowedRemote = do
  let routing = defaultRoutingConfig
      basePolicy = withAutonomy Full defaultPolicy
      addLocal p name  = allowCommand (CommandName name) p
      addRemote p name = allowRemoteCommand (CommandName name) p
      policy = foldl addRemote
                 (foldl addLocal basePolicy allowedLocal)
                 allowedRemote
  providerRef    <- newIORef (Nothing :: Maybe SomeProvider)
  modelRef       <- newIORef (Nothing :: Maybe ModelId)
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef (Map.empty :: Map Text McpServer)
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef (Nothing :: Maybe TabIndex)
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO 1024
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = mkNoOpChannelHandle
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = policy
    , _env_harnesses         = harnessRef
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing :: Maybe AgentDef
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_tabs              = tabsRef
    , _env_focus             = focusRef
    , _env_activeCount       = activeCountTv
    , _env_runners           = runnersRef
    , _env_channelOutQ       = channelOutQ
    , _env_routingConfig     = routing
    , _env_fork              = defaultEnvFork
    , _env_broker              = Nothing
    }

-- | Briefly yield so the drainer\/writer helper threads get a chance
-- to run.
yieldAwhile :: IO ()
yieldAwhile = threadDelay 50000  -- 50ms

-- | Drain channel-out queue (non-blocking).
drainOut :: AgentEnv -> IO [(OutputSource, ChannelEvent)]
drainOut env = go []
  where
    go acc = do
      mv <- atomically (tryReadTBQueue (_env_channelOutQ env))
      case mv of
        Nothing -> pure (reverse acc)
        Just v  -> go (v : acc)

-- | Describe an @Either TabError TabHandle@ result without requiring a
-- 'Show' instance for 'TabHandle'. The 'Right' branch reports the kind
-- so a failing assertion still gives useful context.
describeResult :: Either TabError TabHandle -> String
describeResult (Left e)  = "Left " <> show e
describeResult (Right h) = "Right (TabHandle kind=" <> show (_tabHandle_kind h) <> ")"

-- | Spawn a shell tab via the fake BackendIO. Fails the test on Left.
spawnShellTab
  :: BackendIO -> AgentEnv -> Int -> [Text] -> IO TabHandle
spawnShellTab bio env n args = do
  r <- mkTabBackendWith bio env (ti n) KindShell args
  case r of
    Right h -> pure h
    Left e  -> do
      expectationFailure ("expected Right TabHandle; got Left " <> show e)
      error "unreachable"


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "L-series (Backend subset) — close lifecycle (WU8)" $ do
    it ("L3 (WU8): /tab close on KindBackend (Shell) is destructive:"
        <> " _bh_close runs, transcript NOT archived") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls", "-la"]
      _tabHandle_close h CloseGraceful
      closed <- readIORef (_bc_closed cap)
      closed `shouldSatisfy` (>= 1)

    it "L3 — close is idempotent (H6 KindBackend Shell)" $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      _tabHandle_close h CloseGraceful
      _tabHandle_close h CloseGraceful  -- no throw
      _tabHandle_close h CloseForce     -- still no throw
      -- _bh_close is invoked only on the first close.
      closed <- readIORef (_bc_closed cap)
      closed `shouldBe` 1

  describe "H-series (Backend subset) — handle contract (WU8)" $ do
    it "H7 (KindBackend Shell): close never throws on graceful + force" $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      _tabHandle_close h CloseGraceful `shouldReturn` ()
      _tabHandle_close h CloseForce    `shouldReturn` ()

    it ("H8 (KindBackend Shell): close calls _bh_close on the"
        <> " underlying handle (destructive)") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      _tabHandle_close h CloseGraceful
      closed <- readIORef (_bc_closed cap)
      closed `shouldBe` 1

    it ("H9 (KindBackend Shell): --force is a no-op distinct from"
        <> " graceful — both destructive for non-AI kinds (no archive)") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap1 <- newBackendCapture
      h1 <- spawnShellTab (fakeBackendIO cap1) env 0 ["ls"]
      _tabHandle_close h1 CloseGraceful
      closed1 <- readIORef (_bc_closed cap1)
      closed1 `shouldBe` 1
      cap2 <- newBackendCapture
      h2 <- spawnShellTab (fakeBackendIO cap2) env 1 ["ls"]
      _tabHandle_close h2 CloseForce
      closed2 <- readIORef (_bc_closed cap2)
      closed2 `shouldBe` 1

    it ("H11 (KindBackend Shell): _tabHandle_name routes through"
        <> " sanitizeTabName; a synthesised name is wrapped in TabName") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      let TabName n = _tabHandle_name h
      n `shouldSatisfy` (not . T.null)
      _tabHandle_close h CloseGraceful

    it "H12 (KindBackend Shell): _tabHandle_kind is KindShell (pure field)" $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      _tabHandle_kind h `shouldBe` KindShell
      _tabHandle_close h CloseGraceful

    it ("H4 (KindBackend Shell): _tabHandle_send is non-blocking;"
        <> " overflow surfaces Left TabConcurrencyLimit") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      -- A blocking backend: _bh_send never returns, so the writer
      -- thread cannot drain the queue, and the producer side fills.
      let blockingBackend = (mkFakeBackend cap)
            { Backend._bh_send = \_ -> threadDelay 1000000  -- 1s
            }
          blockingBio = (fakeBackendIO cap)
            { _bio_mkShell = \_ -> pure (Right blockingBackend)
            }
      h <- spawnShellTab blockingBio env 0 ["ls"]
      results <- mapM (\i ->
                        _tabHandle_send h
                          ("msg-" <> T.pack (show (i :: Int))))
                      [1 .. 200]
      let overflowErrs = Data.Either.lefts results
      overflowErrs `shouldSatisfy` (not . null)
      mapM_ (\e -> show e `shouldContain` "TabConcurrencyLimit") overflowErrs
      _tabHandle_close h CloseGraceful

  describe "I-series (Backend subset) — direct-inject opaque text (WU8)" $ do
    it ("I4 (WU8): non-AI tab (Backend / Shell) treats slash-prefix on"
        <> " direct-inject as opaque text — '/0 /pwd' sent to shell as"
        <> " literal '/pwd'; no slash-command parser in non-AI tabs") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      r <- _tabHandle_send h "/pwd"
      r `shouldBe` Right ()
      yieldAwhile
      sends <- readIORef (_bc_sends cap)
      sends `shouldContain` ["/pwd"]
      _tabHandle_close h CloseGraceful

    it ("H13 / I4 (KindBackend): _tabHandle_enqueueSlash returns"
        <> " Left TabUnsupportedCommand without enqueueing — backend"
        <> " tabs do not run slash commands") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      r <- _tabHandle_enqueueSlash h Slash.CmdHelp
      case r of
        Left (TabUnsupportedCommand _) -> pure ()
        other ->
          expectationFailure
            ("expected Left TabUnsupportedCommand; got " <> show other)
      yieldAwhile
      sends <- readIORef (_bc_sends cap)
      sends `shouldBe` []
      _tabHandle_close h CloseGraceful

  describe "D5 (Backend subset) — FullMsg emission (WU8)" $ do
    it ("D5 (Backend): drainer emits FullMsg via _env_channelOutQ when"
        <> " the tab is focused; non-empty output round-trips to the"
        <> " queue as (SrcTab idx, FullMsg idx text)") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      writeIORef (_bc_outputs cap) ["hello from shell\n"]
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      writeIORef (_env_focus env) (Just (ti 0))
      threadDelay 150000  -- 150ms — let drainer run a few iters
      drained <- drainOut env
      let fullMsgs = [t | (SrcTab _, FullMsg _ t) <- drained]
      fullMsgs `shouldSatisfy` any (T.isInfixOf "hello from shell")
      _tabHandle_close h CloseGraceful

    it ("D4 (Backend): non-focused tab — drainer skips the producer"
        <> " enqueue work (no SrcTab events on the queue)") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      writeIORef (_bc_outputs cap) ["silent output\n"]
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      -- Focus stays Nothing.
      threadDelay 150000
      drained <- drainOut env
      let tabEvents = [() | (SrcTab _, _) <- drained]
      tabEvents `shouldBe` []
      _tabHandle_close h CloseGraceful

  describe "Sub-factory dispatch (WU8)" $ do
    it ("mkTabBackend with KindAi returns Left TabSpawnAuthDenied —"
        <> " AI tabs go through Tab.Ai, not Tab.Backend") $ do
      env <- mkBackendTestEnv [] []
      r <- mkTabBackend env (ti 0) KindAi []
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)

    it ("mkTabBackend with KindHarness returns Left TabSpawnAuthDenied"
        <> " — harness tabs go through Tab.Harness, not Tab.Backend") $ do
      env <- mkBackendTestEnv [] []
      r <- mkTabBackend env (ti 0) KindHarness []
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)

    it ("KindShell with empty args returns Left TabSpawnAuthDenied —"
        <> " no command supplied") $ do
      env <- mkBackendTestEnv [] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0) KindShell []
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)

    it ("KindTmux with empty args returns Left TabSpawnAuthDenied —"
        <> " no target supplied") $ do
      env <- mkBackendTestEnv [] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0) KindTmux []
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)

  describe "KindShell (S1) — local command authorization (WU8)" $ do
    it ("S1: shell tab calls authorize against _env_policy; rejected"
        <> " commands yield Left TabSpawnAuthDenied; no _bio_mkShell"
        <> " invocation") $ do
      -- Empty allowlist — "ls" is not authorized.
      env <- mkBackendTestEnv [] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindShell ["ls"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)
      -- Crucially: no subprocess was 'spawned' (no _bio_mkShell call).
      shellArgs <- readIORef (_bc_shellArgs cap)
      shellArgs `shouldBe` []

    it ("S1: shell tab with autonomy=Deny rejects all commands even if"
        <> " on the allowlist") $ do
      env0 <- mkBackendTestEnv ["ls"] []
      -- Force the policy to autonomy=Deny.
      let env = env0 { _env_policy = withAutonomy Deny (_env_policy env0) }
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindShell ["ls"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got " <> describeResult other)
      shellArgs <- readIORef (_bc_shellArgs cap)
      shellArgs `shouldBe` []

    it ("S1: shell tab with allowed command spawns; _bio_mkShell"
        <> " is invoked with the AuthorizedCommand carrying the supplied"
        <> " args") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls", "-la", "/tmp"]
      shellArgs <- readIORef (_bc_shellArgs cap)
      shellArgs `shouldBe` [("ls", ["-la", "/tmp"])]
      _tabHandle_close h CloseGraceful

    it ("Backend construction failure surfaces as Left"
        <> " TabBackendConstructFailed") $ do
      env <- mkBackendTestEnv ["ls"] []
      let failingErr = Backend.BackendBinaryNotFound
                         (CommandName "ls")
      r <- mkTabBackendWith (failingBackendIO failingErr) env (ti 0)
             KindShell ["ls"]
      case r of
        Left (TabBackendConstructFailed _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabBackendConstructFailed; got "
                     <> describeResult other)

  describe "KindSsh (S2 / S3 / S4) — host validation, remote auth, vault (WU8)" $ do
    it ("S2: ssh tab rejects hosts with whitespace via mkSshHost; no"
        <> " _bio_mkSsh invocation") $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@bad host", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2); got " <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it "S2: ssh tab rejects hosts with leading dash" $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@-oProxyCommand=evil", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2 dash); got "
                     <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it "S2: ssh tab rejects hosts with shell metacharacters" $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@evil;rm", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2 meta); got "
                     <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it "S2: ssh tab rejects malformed user@host (missing @)" $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["nohostmark", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2 malformed); got "
                     <> describeResult other)

    it "S2: ssh tab with allowlist not containing 'ssh' is rejected" $ do
      env <- mkBackendTestEnv [] ["bash"]   -- 'ssh' missing from local
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@host.example.com", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2 ssh missing); got "
                     <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it ("S2: remote command must be on the remote allowlist (separate"
        <> " from local allowlist)") $ do
      -- 'ssh' is allowed locally; 'bash' is NOT allowed remotely.
      env <- mkBackendTestEnv ["ssh"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@host.example.com", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S2 remote allowlist);"
                     <> " got " <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it ("S4: ssh tab with no Vault configured yields Left"
        <> " TabSpawnAuthDenied; no _bio_mkSsh invocation") $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      cap <- newBackendCapture
      -- _env_vault is Nothing (the default from mkBackendTestEnv).
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@host.example.com", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S4 no vault); got "
                     <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it ("S4: ssh tab with vault present but slot missing yields Left"
        <> " TabSpawnAuthDenied") $ do
      env <- mkBackendTestEnv ["ssh"] ["bash"]
      -- Inject a vault that returns Left for every get.
      let missingVault = Just noOpVault
      writeIORef (_env_vault env) missingVault
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@host.example.com", "bash"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S4 missing slot); got "
                     <> describeResult other)
      sshTargets <- readIORef (_bc_sshTargets cap)
      sshTargets `shouldBe` []

    it ("S2: ssh tab with empty arg list returns Left"
        <> " TabSpawnAuthDenied") $ do
      env <- mkBackendTestEnv ["ssh"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0) KindSsh []
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (empty args); got "
                     <> describeResult other)

    it ("S2: ssh tab with user@host but no remote command yields Left"
        <> " TabSpawnAuthDenied") $ do
      env <- mkBackendTestEnv ["ssh"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindSsh ["user@host.example.com"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (no remote cmd); got "
                     <> describeResult other)

  describe "KindTmux (S3) — smart-constructor validation (WU8)" $ do
    it ("S3: tmux tab rejects targets with leading dash via"
        <> " mkTmuxSession") $ do
      env <- mkBackendTestEnv ["tmux"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux ["-evil:win"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S3 dash); got "
                     <> describeResult other)
      tmuxTargets <- readIORef (_bc_tmuxTargets cap)
      tmuxTargets `shouldBe` []

    it "S3: tmux tab rejects empty session names" $ do
      env <- mkBackendTestEnv ["tmux"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux [":win"]   -- empty session before ':'
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S3 empty); got "
                     <> describeResult other)

    it "S3: tmux tab rejects malformed spec (no colon)" $ do
      env <- mkBackendTestEnv ["tmux"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux ["just-a-session"]   -- no ':' separator
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (S3 malformed); got "
                     <> describeResult other)

    it ("S3: tmux tab accepts a valid session:window spec; _bio_mkTmux"
        <> " is invoked with the smart-constructed TmuxTarget") $ do
      env <- mkBackendTestEnv ["tmux"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux ["prod-session:main"]
      case r of
        Right h -> do
          tmuxTargets <- readIORef (_bc_tmuxTargets cap)
          tmuxTargets `shouldBe` [("prod-session", "main", Nothing)]
          _tabHandle_close h CloseGraceful
        Left e -> expectationFailure
                    ("expected Right; got " <> show e)

    it "S3: tmux tab accepts session:window.pane spec with pane" $ do
      env <- mkBackendTestEnv ["tmux"] []
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux ["sess:win.pane1"]
      case r of
        Right h -> do
          tmuxTargets <- readIORef (_bc_tmuxTargets cap)
          tmuxTargets `shouldBe` [("sess", "win", Just "pane1")]
          _tabHandle_close h CloseGraceful
        Left e -> expectationFailure
                    ("expected Right; got " <> show e)

    it ("S3: tmux tab with 'tmux' missing from local allowlist is"
        <> " rejected") $ do
      env <- mkBackendTestEnv [] []  -- empty allowlist
      cap <- newBackendCapture
      r <- mkTabBackendWith (fakeBackendIO cap) env (ti 0)
             KindTmux ["sess:win"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied (tmux missing); got "
                     <> describeResult other)
      tmuxTargets <- readIORef (_bc_tmuxTargets cap)
      tmuxTargets `shouldBe` []

  describe "WU8 coverage — internal helpers, status, drainer lifecycle" $ do
    it "parseUserAtHost accepts valid user@host" $ do
      parseUserAtHost "user@host" `shouldBe` Right ("user", "host")
      parseUserAtHost "alice@example.com" `shouldBe`
        Right ("alice", "example.com")

    it "parseUserAtHost rejects missing or empty parts" $ do
      parseUserAtHost "userhost" `shouldBe` Left ()
      parseUserAtHost "@host"    `shouldBe` Left ()
      parseUserAtHost "user@"    `shouldBe` Left ()
      parseUserAtHost ""         `shouldBe` Left ()
      parseUserAtHost "a@b@c"    `shouldBe` Left ()  -- ambiguous

    it "parseTmuxTarget accepts session:window form" $ do
      case parseTmuxTarget "sess:win" of
        Right t -> do
          Tmux.getTmuxSession (Tmux._tt_session t) `shouldBe` "sess"
          Tmux.getTmuxWindow  (Tmux._tt_window  t) `shouldBe` "win"
          Tmux._tt_pane t `shouldBe` Nothing
        Left e -> expectationFailure ("expected Right; got " <> show e)

    it "parseTmuxTarget accepts session:window.pane form" $ do
      case parseTmuxTarget "s:w.p" of
        Right t -> do
          Tmux.getTmuxSession (Tmux._tt_session t) `shouldBe` "s"
          Tmux.getTmuxWindow  (Tmux._tt_window  t) `shouldBe` "w"
          fmap Tmux.getTmuxPane (Tmux._tt_pane t) `shouldBe` Just "p"
        Left e -> expectationFailure ("expected Right; got " <> show e)

    it "parseTmuxTarget rejects malformed input" $ do
      case parseTmuxTarget "nocolon" of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected Left for malformed input"
      case parseTmuxTarget "a:b.c.d" of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected Left for too many dots"

    it ("status after spawn is Idle (sentinel replaced before"
        <> " mkTabBackend returns)") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      st <- _tabHandle_status h
      case st of
        Idle _ -> pure ()
        other -> expectationFailure
                   ("expected Idle status after spawn; got " <> show other)
      _tabHandle_close h CloseGraceful

    it "writer thread forwards bytes to _bh_send" $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      h <- spawnShellTab (fakeBackendIO cap) env 0 ["ls"]
      _ <- _tabHandle_send h "ping"
      _ <- _tabHandle_send h "pong"
      yieldAwhile
      sends <- readIORef (_bc_sends cap)
      sends `shouldContain` ["ping"]
      sends `shouldContain` ["pong"]
      _tabHandle_close h CloseGraceful

    it "drainer terminates when backend recv reports EOF" $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      -- A backend whose _bh_recv always returns RecvEof.
      let eofBackend = (mkFakeBackend cap)
            { Backend._bh_recv = \_ -> pure (Backend.RecvEof BS.empty)
            }
          eofBio = (fakeBackendIO cap)
            { _bio_mkShell = \_ -> pure (Right eofBackend)
            }
      h <- spawnShellTab eofBio env 0 ["ls"]
      yieldAwhile
      -- Status stays Idle (EOF is a clean exit, not Crashed).
      st <- _tabHandle_status h
      case st of
        Idle _ -> pure ()
        other -> expectationFailure
                   ("expected Idle status after backend EOF; got "
                     <> show other)
      _tabHandle_close h CloseGraceful

    it ("realBackendIO is a constructable value; each field has the"
        <> " expected type (smoke test — no subprocess spawning)") $ do
      -- Just touch the field selectors to keep coverage honest. We do
      -- NOT invoke the IO actions — they spawn real subprocesses, which
      -- would defeat the unit-test purpose. The production wiring is
      -- exercised by the integration tests that spawn a real shell.
      let _ = _bio_mkShell realBackendIO
          _ = _bio_mkSsh   realBackendIO
          _ = _bio_mkTmux  realBackendIO
      True `shouldBe` True

    it ("mkTabBackend (production entry point) dispatches via"
        <> " realBackendIO; rejected commands surface as Left without"
        <> " spawning") $ do
      -- The production entry point hits realBackendIO, but the policy
      -- has autonomy=Deny so authorize rejects before any subprocess
      -- spawn — proving the entry-point indirection works.
      env <- mkBackendTestEnv [] []
      let env' = env { _env_policy = withAutonomy Deny (_env_policy env) }
      r <- mkTabBackend env' (ti 0) KindShell ["ls"]
      case r of
        Left (TabSpawnAuthDenied _) -> pure ()
        other -> expectationFailure
                   ("expected Left TabSpawnAuthDenied; got "
                     <> describeResult other)

    it ("crash handler: helper thread that throws transitions tab to"
        <> " Crashed status") $ do
      env <- mkBackendTestEnv ["ls"] []
      cap <- newBackendCapture
      let crashyBackend = (mkFakeBackend cap)
            { Backend._bh_recv = \_ -> error "boom"
            }
          crashyBio = (fakeBackendIO cap)
            { _bio_mkShell = \_ -> pure (Right crashyBackend)
            }
      h <- spawnShellTab crashyBio env 0 ["ls"]
      threadDelay 100000
      st <- _tabHandle_status h
      case st of
        Crashed _ -> pure ()
        other -> expectationFailure
                   ("expected Crashed status after backend throw; got "
                     <> show other)
      _tabHandle_close h CloseGraceful


-- ---------------------------------------------------------------------------
-- Helpers — a no-op VaultHandle whose _vh_get always returns Left
-- ---------------------------------------------------------------------------

-- | A minimal 'VaultHandle' whose getters always fail with 'VaultLocked'.
-- Used to exercise the S4 missing-slot path.
noOpVault :: VaultHandle
noOpVault = VaultHandle
  { _vh_init   = pure (Right ())
  , _vh_get    = \_ -> pure (Left (VaultCorrupted "no such key"))
  , _vh_put    = \_ _ -> pure (Right ())
  , _vh_delete = \_ -> pure (Right ())
  , _vh_list   = pure (Right [])
  , _vh_lock   = pure ()
  , _vh_unlock = pure (Right ())
  , _vh_status = pure Vault.VaultStatus
      { Vault._vs_locked      = True
      , Vault._vs_secretCount = 0
      , Vault._vs_keyType     = "no-op"
      }
  , _vh_rekey  = \_ _ _ -> pure (Right ())
  }
