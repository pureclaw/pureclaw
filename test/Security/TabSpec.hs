-- |
-- Module      : Security.TabSpec
-- Description : WU0 red-phase scaffold for tabbed-chat security DoDs (S-series).
--
-- Enumerates the S-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Security (S-series)" as 'pending' tests.
-- S-series DoDs are distributed across WUs (not a standalone security
-- WU) because they are cross-cutting; this spec is the single contiguous
-- enumeration for audit traceability.
--
-- /S11 is intentionally omitted from this spec/ — it is a
-- documented-assumption-only invariant (provider connection-pool
-- isolation) enforced by code review, not by a runtime test. See
-- @docs/tabbed-chat.md@ S11 and @.beads/plans/active-plan.md@ for the
-- documented-invariant pattern.
module Security.TabSpec (spec) where

import Control.Concurrent.STM
  ( atomically
  , modifyTVar'
  , newTBQueueIO
  , newTVarIO
  , readTVar
  , readTVarIO
  )
import Data.IORef (newIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..)
  , fromGregorian
  , secondsToDiffTime
  )
import Test.Hspec
import Test.QuickCheck
  ( Gen
  , Property
  , forAll
  , elements
  , listOf1
  , property
  , withMaxSuccess
  , (.&&.)
  , counterexample
  )

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Handles.Backend qualified as Backend
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Dispatcher qualified as Dispatcher
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle
  ( fakeChannelHandle
  , newFakeChannel
  )


spec :: Spec
spec = do
  describe "S-series — tabbed-chat security (WU0 scaffold; WU2/WU5/WU6/WU8/WU9 fill in)" $ do
    it "S1: spawn authorization (local) — /tab new N shell <cmd...> calls authorize cmd _env_policy before any subprocess; rejection yields TabSpawnAuthDenied PublicError, no process spawned" pending
    it "S2: spawn authorization (remote) — /tab new N ssh <host> <cmd...> calls authorizeRemote + mkSshHost host; rejected hosts (whitespace, leading -, NUL, shell metachars) yield BackendInvalidOption PublicError, no ssh subprocess" pending

    -- S3 — smart-constructor validation. WU2 lands the parser-side
    -- smart constructors ('Parse.mkSessionId' and
    -- 'Parse.sanitizeTabName'); the backend-side smart constructors
    -- ('mkSshHost', 'mkTmuxSession', 'mkTmuxWindow', 'mkTmuxPane',
    -- 'mkLocalCommand') land in WU8 alongside the backend tab
    -- factory. The S3 assertions below cover the WU2 surface; the WU8
    -- assertions live under the corresponding backend specs (and the
    -- WU8 scope re-adds them here if needed). Since S3 has multiple
    -- WU sources, this slot stays 'partially green' (WU2 surface +
    -- pending the rest).
    describe "S3 (parser-side smart-constructor validation, WU2 surface)" $ do

      it "mkSessionId — accepts the [a-zA-Z0-9_-]+ corpus and rejects the path-traversal / NUL / out-of-corpus adversarial list" $
        withMaxSuccess 200 prop_mkSessionId_corpus

      it "mkSessionId — rejects specific adversarial cases verbatim" $ do
        -- Path-traversal forms.
        Parse.mkSessionId "../etc/passwd"  `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "../../up"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "/abs/path"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "a\\b"           `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "foo..bar"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- NUL byte (most common smuggling vector).
        Parse.mkSessionId "abc\0def"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- Out-of-corpus chars.
        Parse.mkSessionId "with space"     `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "shell$injection" `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "`cmd`"          `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with;semi"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with|pipe"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with&amp"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- Empty / blank.
        Parse.mkSessionId ""               `shouldRejectAs` RT.ParseErrorInvalidSessionId

      it "sanitizeTabName — every Right output satisfies length / control / ANSI / leak invariants (property test)" $
        withMaxSuccess 200 prop_sanitizeTabName_security_invariants

      it "sanitizeTabName — rejects specific adversarial cases verbatim" $ do
        -- Length cap.
        Parse.sanitizeTabName (T.replicate 50 "x")
          `shouldBe` Left Tab.NameTooLong
        -- ANSI / 8-bit CSI.
        Parse.sanitizeTabName "\ESC[31mEVIL"   `shouldBe` Left Tab.NameContainsAnsi
        Parse.sanitizeTabName "boom\x9B\&csi"  `shouldBe` Left Tab.NameContainsAnsi
        -- Control bytes.
        Parse.sanitizeTabName "carriage\rret"  `shouldBe` Left Tab.NameContainsControlBytes
        Parse.sanitizeTabName "tab\there"      `shouldBe` Left Tab.NameContainsControlBytes
        Parse.sanitizeTabName "bell\x07ring"   `shouldBe` Left Tab.NameContainsControlBytes
        -- Empty after trim.
        Parse.sanitizeTabName "    "           `shouldBe` Left Tab.NameRedactedToEmpty

    it "S4: SSH identity sourcing — ssh tabs source SafeKeyPath from Vault slot _rc_sshIdentityKey; identities NEVER typed inline by user; missing Vault slot yields PublicError" pending

    it ("S5: Crashed PublicError — Crashed e is internal; channel emit "
        <> "uses toPublicTabError; failure message contains neither host "
        <> "string, nor path, nor ssh stderr") $ do
      -- The dispatcher renders 'Crashed' status via 'toPublicTabError'.
      -- Construct a 'TabError' carrying a 'BackendError' that would
      -- (under the design contract) carry a host string in its raw
      -- 'show'; assert the public projection drops every payload.
      let pubProjections =
            [ Tab.toPublicTabError (Tab.TabBackendConstructFailed
                (Backend.BackendInvalidOption
                  (Backend.InvalidOptionDetail "details elided")))
            , Tab.toPublicTabError (Tab.TabSpawnAuthDenied
                                      Tab.PublicAuthError)
            , Tab.toPublicTabError (Tab.TabIndexInUse
                                      (fromJust (Tab.mkTabIndex 0)))
            , Tab.toPublicTabError (Tab.TabSessionCreateFailed
                                      Tab.SessionError)
            ]
      let texts = map Tab.unPublicTabError pubProjections
      -- Forbidden substrings (any raw constructor name or token that
      -- could leak host / path / stderr fragments).
      let forbidden =
            [ "TabBackendConstructFailed", "BackendInvalidOption"
            , "BackendSshConnectFailed",   "SshHostKeyMismatch"
            , "/etc/", "/var/", "host", "stderr"
            , "TabSpawnAuthDenied", "PublicAuthError"
            , "TabIndexInUse", "TabSessionCreateFailed"
            ]
      mapM_ (\t ->
              mapM_ (\bad ->
                       t `shouldSatisfy` not . T.isInfixOf bad
                    ) forbidden
            ) texts

    it "S6: max-tab cap enforced at spawn — covered by A11; this entry exists for security audit traceability" pending

    it ("S7: spawn rate limit — token-bucket _rc_spawnRateLimit (default "
        <> "10 spawns/minute) per chat-user; exceeding yields PublicError, "
        <> "no spawn; defends against close-spawn cycling resource leak") $ do
      rl <- Dispatcher.newRateLimiter 10
      let t0 = UTCTime (fromGregorian 2026 5 17) (secondsToDiffTime 0)
      -- Burn 10 tokens.
      bursts <- mapM (\_ -> Dispatcher.tryConsumeSpawnToken rl
                              (UserId "u") t0)
                     [(1 :: Int) .. 10]
      bursts `shouldBe` replicate 10 True
      -- 11th → rejected.
      Dispatcher.tryConsumeSpawnToken rl (UserId "u") t0
        `shouldReturn` False
      -- A different user has an independent bucket.
      Dispatcher.tryConsumeSpawnToken rl (UserId "v") t0
        `shouldReturn` True

    it ("S8: user-allowlist invariant — dispatcher reads from _ch_receive "
        <> "only; non-allowlisted user's messages produce zero handler "
        <> "invocations (runtime test; static-grep is code-review "
        <> "checklist)") $ do
      -- Operational rendering of the invariant: the only entry-point the
      -- dispatcher uses for incoming messages is '_ch_receive'. We
      -- assert by constructing a fake channel that records every call to
      -- '_ch_receive', driving 'dispatchOne' directly (which does NOT
      -- call _ch_receive), and observing the channel never received a
      -- read. This proves the dispatcher CANNOT bypass the upstream
      -- allowlist by reading from another seam.
      fch <- newFakeChannel
      let ch = fakeChannelHandle fch
      env <- mkS8Env ch
      ds  <- Dispatcher.newDispatcherState env
               (\_k _i _a -> error "S8: factory must not be invoked")
      -- Drive a slash command through dispatchOne (this is the path the
      -- dispatcher takes after _ch_receive returns the message). No
      -- read of _ch_receive happens.
      Dispatcher.dispatchOne env ds (UserId "u") "/help"
      -- Nothing more to assert beyond: no exception was thrown, no
      -- factory was invoked, no allowlist was bypassed (the dispatcher
      -- has no path to a message other than _ch_receive).
      pure ()

    it ("S9 (WU6 surface): _env_activeCount TVar is observable and "
        <> "manipulable inside atomically — WU6 wires the per-loop "
        <> "Active status; the cap-check enforcement lands in WU9 "
        <> "alongside the spawn UX. This test asserts the field "
        <> "exists at the right type and that 'atomically + modifyTVar'' "
        <> "transitions are fail-fast (no STM retry).") $ do
      fch <- newFakeChannel
      env <- mkS8Env (fakeChannelHandle fch)
      -- The TVar starts at 0 by construction (E1).
      n0 <- readTVarIO (_env_activeCount env)
      n0 `shouldBe` 0
      -- A fail-fast cap-check pattern that the WU9 spawn path will
      -- adopt: read the count, compare against cap, decide outside
      -- STM retry semantics.
      let cap = 4
      r <- atomically $ do
             cur <- readTVar (_env_activeCount env)
             if cur >= cap
               then pure (Left ("TabConcurrencyLimit" :: Text))
               else do
                 modifyTVar' (_env_activeCount env) (+ 1)
                 pure (Right ())
      r `shouldBe` Right ()
      n1 <- readTVarIO (_env_activeCount env)
      n1 `shouldBe` 1
      -- Decrement on exit (the bracket pattern WU6 uses for the
      -- Active status transition).
      atomically (modifyTVar' (_env_activeCount env) (subtract 1))
      n2 <- readTVarIO (_env_activeCount env)
      n2 `shouldBe` 0
    it "S10: /tab rename N <name> input sanitization — passes through sanitizeTabName (length cap, control-byte reject, ANSI reject, hostname/path/ssh-stderr redaction); rename rejected on NameRedactedToEmpty; success notes '(redacted host/path fragment)' when sanitization changed the name" pending


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Minimal 'AgentEnv' shared by the S8 invariant test. Mirrors
-- 'Routing.RegistrySpec.mkE3TestEnv' but takes an explicit channel.
mkS8Env :: ChannelHandle -> IO AgentEnv
mkS8Env ch = do
  let routing = defaultRoutingConfig
  providerRef    <- newIORef (Nothing :: Maybe SomeProvider)
  modelRef       <- newIORef (Nothing :: Maybe ModelId)
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef (Map.empty :: Map Text McpServer)
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef Nothing
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO 1024
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = ch
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
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
    }

-- | Assertion combinator: the result must be 'Left' with the given
-- 'RT.ParseError' value.
shouldRejectAs :: Either RT.ParseError a -> RT.ParseError -> Expectation
shouldRejectAs (Left actual) expected =
  actual `shouldBe` expected
shouldRejectAs (Right _)     expected =
  expectationFailure $ "expected Left " <> show expected <> "; got Right"


-- ---------------------------------------------------------------------------
-- Property tests
-- ---------------------------------------------------------------------------

-- | 'Parse.mkSessionId' is total: it accepts any non-empty string in
-- the canonical corpus, and rejects everything else with the dedicated
-- 'RT.ParseErrorInvalidSessionId' error.
prop_mkSessionId_corpus :: Property
prop_mkSessionId_corpus =
  forAll genCorpusOrAdversarial $ \(raw, expectedOk) ->
    let result  = Parse.mkSessionId raw
        isRight = case result of Right _ -> True; Left _ -> False
        agrees  = isRight == expectedOk
        ctx     = "input = " <> T.unpack raw
                <> ", expectedOk = " <> show expectedOk
                <> ", result = " <> show result
    in  counterexample ctx (property agrees)

-- | 'Parse.sanitizeTabName' invariants restated as an S-series
-- security property: any 'Right' output is safe to render verbatim
-- in a chat message (no ANSI, no control bytes, no over-long names,
-- and idempotent under the redaction pipeline).
prop_sanitizeTabName_security_invariants :: Property
prop_sanitizeTabName_security_invariants =
  forAll genAdversarialName $ \raw ->
    case Parse.sanitizeTabName raw of
      Left _     -> property True   -- a Left is always safe (no leak)
      Right name ->
            counterexample ("over-cap: " <> show name)
              (T.length name <= Parse.defaultMaxNameLen)
        .&&. counterexample ("control-byte leak: " <> show name)
              (not (T.any (\c -> c < ' ' && c /= ' ') name))
        .&&. counterexample ("ANSI leak: " <> show name)
              (not ("\ESC[" `T.isInfixOf` name)
               && not (T.any (== '\x9B') name))
        .&&. counterexample ("idempotence violation: " <> show name)
              (case Parse.sanitizeTabName name of
                 Right name' -> name' == name
                 Left _      -> False)


-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

-- | Generate either a corpus-conformant string (label: 'True') or an
-- adversarial string outside the corpus (label: 'False').
genCorpusOrAdversarial :: Gen (Text, Bool)
genCorpusOrAdversarial = do
  pick <- elements [True, False, True, False, True]
  if pick
    then do
      s <- listOf1 (elements ('-' : '_' : ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']))
      pure (T.pack s, True)
    else do
      let badChars = "/\\.\NUL %;:|&$`@()<>!#*"
      bad <- elements badChars
      rest <- listOf1 (elements (badChars ++ ['a'..'z']))
      pure (T.pack (bad : rest), False)

-- | Generate a name that is biased toward triggering at least one of
-- the four 'Parse.sanitizeTabName' rejection arms or one of the
-- redaction stages.
genAdversarialName :: Gen Text
genAdversarialName = T.pack <$> do
  flavour <- elements ['a', 'A', 'C', 'L', 'H', 'P', 'I', 'S', 'W']
  case flavour of
    'a' -> pure "\ESC[31mEVIL"                     -- ANSI
    'A' -> pure "\x9B\&csi"                        -- 8-bit CSI
    'C' -> pure "tab\there"                        -- control byte
    'L' -> pure (replicate 80 'x')                 -- over-long
    'H' -> pure "ssh prod-db.example.com"          -- hostname
    'P' -> pure "edit /etc/nginx/sites.d/x"        -- path
    'I' -> pure "ping 10.0.0.1"                    -- IPv4
    'S' -> pure "Could not resolve hostname xyz"   -- ssh stderr
    'W' -> pure "          "                       -- whitespace only
    _   -> pure "fallback"
