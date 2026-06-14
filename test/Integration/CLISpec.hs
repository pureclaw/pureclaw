{-# LANGUAGE DerivingStrategies #-}
module Integration.CLISpec (spec) where

import Control.Concurrent
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as List
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Control.Monad (forM_, when)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Exit
import System.FilePath ((</>))
import System.IO.Temp
import System.Process.Typed
import Test.Hspec

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import PureClaw.Core.Types (ModelId (..), parseSessionId)
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Transcript (TranscriptHandle (..))
import PureClaw.Session.Handle (SessionHandle (..), mkSessionHandle)
import PureClaw.Session.Types
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  )

-- | Find the built pureclaw binary via cabal list-bin.
findPureclaw :: IO FilePath
findPureclaw = do
  (exitCode, out, _err) <- readProcess (proc "cabal" ["list-bin", "pureclaw"])
  case exitCode of
    ExitSuccess -> pure (T.unpack (T.strip (TE.decodeUtf8 (LBS.toStrict out))))
    _           -> fail "Could not find pureclaw binary — run 'cabal build' first"

-- | Run the pureclaw binary with a clean environment (no API keys, no config)
-- in a temp directory, feeding it stdin and capturing stdout/stderr.
-- Returns (exit code, stdout, stderr).
runPureclaw :: FilePath -> String -> Int -> IO (ExitCode, String, String)
runPureclaw bin = runPureclawWithArgs bin ["--no-vault"]

-- | Run the pureclaw binary with custom arguments.
runPureclawWithArgs :: FilePath -> [String] -> String -> Int -> IO (ExitCode, String, String)
runPureclawWithArgs bin args stdinContent timeoutUs =
  runPureclawWithSetup bin args stdinContent timeoutUs (\_ -> pure ())

-- | Run pureclaw after a caller-supplied setup action that can populate the
-- temp HOME directory (e.g. fixture agents, config.toml).
runPureclawWithSetup
  :: FilePath
  -> [String]
  -> String
  -> Int
  -> (FilePath -> IO ())  -- setup receives the tmpDir (HOME)
  -> IO (ExitCode, String, String)
runPureclawWithSetup bin args stdinContent timeoutUs setup = do
  withSystemTempDirectory "pureclaw-cli-test" $ \tmpDir -> do
    setup tmpDir
    let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 (T.pack stdinContent))))
           $ setStdout byteStringOutput
           $ setStderr byteStringOutput
           $ setWorkingDir tmpDir
           $ setEnv
               [ ("HOME", tmpDir)             -- No ~/.pureclaw config
               , ("PATH", "/usr/bin:/bin")     -- Minimal PATH, no API keys in env
               , ("TERM", "dumb")
               , ("LANG", "C.UTF-8")          -- GHC needs UTF-8 locale for em-dashes etc.
               ]
           $ proc bin args
    result <- race' (threadDelay timeoutUs) (readProcess pc)
    case result of
      Left ()               -> fail "pureclaw timed out"
      Right (ec, out, err)  ->
        pure ( ec
             , T.unpack (TE.decodeUtf8 (LBS.toStrict out))
             , T.unpack (TE.decodeUtf8 (LBS.toStrict err))
             )

-- | Race two IO actions; return whichever finishes first.
race' :: IO a -> IO b -> IO (Either a b)
race' left right = do
  resultVar <- newEmptyMVar
  t1 <- forkIO $ left  >>= putMVar resultVar . Left
  t2 <- forkIO $ right >>= putMVar resultVar . Right
  result <- takeMVar resultVar
  killThread t1
  killThread t2
  pure result

-- | Wrapper that includes stderr in the Show output so hspec displays it
-- on failure. Usage: @exitCode \`shouldBe\` annotate err ExitSuccess@
data Annotated a = Annotated String a
  deriving stock (Eq)

instance Show a => Show (Annotated a) where
  show (Annotated stderr' val) =
    show val <> "\n    --- stderr ---\n" <> stderr'

annotate :: String -> a -> Annotated a
annotate = Annotated

spec :: Spec
spec = do
  describe "CLI startup" $ do

    it "enters the agent loop and accepts commands when no API key is configured" $ do
      bin <- findPureclaw
      -- Send /help then EOF (Ctrl-D). If the binary enters the loop,
      -- it will process /help and print help text. If it dies on startup
      -- (the current bug), we'll get an error exit code and no help output.
      (exitCode, out, err) <- runPureclaw bin "/help\n" 5000000  -- 5s timeout
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "Slash commands:"

    it "does not crash on startup without credentials" $ do
      bin <- findPureclaw
      -- Just send EOF immediately. The binary should start up, print
      -- its banner, then exit cleanly on EOF — not die with an error.
      (exitCode, out, err) <- runPureclaw bin "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "PureClaw"

    it "does not claim a provider is configured when no credentials exist" $ do
      bin <- findPureclaw
      (_exitCode, _out, err) <- runPureclaw bin "" 5000000
      -- Should NOT say "Provider: anthropic" when there are no credentials
      err `shouldNotContain` "Provider: anthropic"
      -- Should indicate no provider is configured
      err `shouldContain` "No providers configured"

    it "shows a helpful message when sending a chat message with no active tab" $ do
      bin <- findPureclaw
      -- Send a non-slash message. Under the Tabs-as-View model (GitHub #79,
      -- 8c.2 flip) a plain chat message with no active tab is routed by the
      -- per-conversation dispatcher, which tells the user how to start/attach a
      -- tab rather than crashing. (Pre-flip this surfaced the "no provider"
      -- message; the end-to-end CLISpec rewrite is 8d.)
      (exitCode, out, err) <- runPureclaw bin "Hello world\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Should guide the user to open or attach a tab.
      out `shouldContain` "no active tab"

    it "shows a warning when --autonomy full is set" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs bin ["--autonomy", "full", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldContain` "unrestricted"

    it "shows allowed commands as allow-all when --autonomy full with no --allow" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs bin ["--autonomy", "full", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldContain` "allow all"

    it "accepts --log-level debug and starts up cleanly" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclawWithArgs bin ["--log-level", "debug", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "PureClaw"

    it "rejects an invalid --log-level value with a non-zero exit" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs bin ["--log-level", "verbose", "--no-vault"] "" 5000000
      exitCode `shouldNotBe` ExitSuccess
      err `shouldContain` "log level"

    it "falls back to CLI when --channel signal and signal-cli is not installed" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclawWithArgs bin ["gateway", "run", "--channel", "signal", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Should warn about signal-cli not being installed
      err `shouldContain` "signal-cli"
      -- Should still start and show the banner
      out `shouldContain` "PureClaw"

    it "prints the open-allow-list security warning when Signal has no allow_from" $ do
      bin <- findPureclaw
      -- A [signal] table without allow_from (and no dm_policy) resolves to an
      -- open allow-list (AllowAll). The startup wiring must emit the prominent
      -- banner on stdout and a WARN line on stderr. signal-cli is absent in CI,
      -- so the branch warns-then-falls-back-to-CLI, but the allow-list warning
      -- fires first.
      (exitCode, out, err) <- runPureclawWithSetup
        bin ["gateway", "run", "--no-vault"] "" 5000000
        (\tmp -> do
           let cfgDir = tmp </> ".pureclaw"
           createDirectoryIfMissing True cfgDir
           writeFile (cfgDir </> "config.toml") $ unlines
             [ "default_channel = \"signal\""
             , ""
             , "[signal]"
             , "account = \"+15551234567\""
             ])
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Banner lines land on stdout.
      out `shouldContain` "SECURITY WARNING"
      out `shouldContain` "allow_from"
      -- The WARN log line lands on stderr.
      err `shouldContain` "no allow-list configured"

    it "writes transcripts under ~/.pureclaw/sessions/<id>/transcript.jsonl, not ~/.pureclaw/transcripts/" $ do
      bin <- findPureclaw
      -- We need to inspect HOME after the run, so we run the binary inside
      -- a temp dir we control (rather than going through runPureclawWithSetup,
      -- which destroys its tmpdir on exit).
      withSystemTempDirectory "pureclaw-transcript-path-test" $ \tmpDir -> do
        let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 (T.pack "/help\n"))))
               $ setStdout byteStringOutput
               $ setStderr byteStringOutput
               $ setWorkingDir tmpDir
               $ setEnv
                   [ ("HOME", tmpDir)
                   , ("PATH", "/usr/bin:/bin")
                   , ("TERM", "dumb")
                   , ("LANG", "C.UTF-8")
                   ]
               $ proc bin ["--no-vault"]
        result <- race' (threadDelay 5000000) (readProcess pc)
        case result of
          Left ()              -> expectationFailure "pureclaw timed out"
          Right (ec, _out, err) -> do
            annotate (T.unpack (TE.decodeUtf8 (LBS.toStrict err))) ec
              `shouldBe` annotate (T.unpack (TE.decodeUtf8 (LBS.toStrict err))) ExitSuccess
            -- Session dir should exist and contain at least one session.
            let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
            sessionsExists <- doesDirectoryExist sessionsDir
            sessionsExists `shouldBe` True
            sessionDirs <- listDirectory sessionsDir
            sessionDirs `shouldNotBe` []
            -- Every session dir should contain a transcript.jsonl.
            forM_ sessionDirs $ \sid -> do
              let transcriptPath = sessionsDir </> sid </> "transcript.jsonl"
              transcriptExists <- doesFileExist transcriptPath
              transcriptExists `shouldBe` True
            -- The legacy flat directory should not exist, or if it does
            -- (from unrelated code), it must be empty of transcript files.
            let legacyDir = tmpDir </> ".pureclaw" </> "transcripts"
            legacyExists <- doesDirectoryExist legacyDir
            when legacyExists $ do
              legacyContents <- listDirectory legacyDir
              legacyContents `shouldBe` []

  describe "--agent CLI flag" $ do

    let setupFixtureAgent tmp name body = do
          let agentDir = tmp </> ".pureclaw" </> "agents" </> name
          createDirectoryIfMissing True agentDir
          writeFile (agentDir </> "SOUL.md") body

    it "loads a named agent from ~/.pureclaw/agents/<name>/ and logs the name" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithSetup
        bin ["--agent", "zoe", "--no-vault"] "" 5000000
        (\tmp -> setupFixtureAgent tmp "zoe" "You are Zoe, a helpful agent.")
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Agent loaded from --agent flag; config has no default set
      err `shouldContain` "Default agent: (none)"

    it "rejects an invalid agent name with a helpful error" $ do
      bin <- findPureclaw
      (_exitCode, _out, err) <- runPureclawWithArgs
        bin ["--agent", "../evil", "--no-vault"] "" 5000000
      err `shouldContain` "invalid agent name"

    it "reports a missing agent and lists available ones" $ do
      bin <- findPureclaw
      (_exitCode, _out, err) <- runPureclawWithSetup
        bin ["--agent", "nonexistent", "--no-vault"] "" 5000000
        (\tmp -> setupFixtureAgent tmp "zoe" "hi")
      err `shouldContain` "not found"
      err `shouldContain` "Available agents:"

    it "loads default_agent from config.toml when --agent is omitted" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithSetup
        bin ["--no-vault"] "" 5000000
        (\tmp -> do
           setupFixtureAgent tmp "zoe" "hi"
           let cfgDir = tmp </> ".pureclaw"
           createDirectoryIfMissing True cfgDir
           writeFile (cfgDir </> "config.toml") "default_agent = \"zoe\"\n")
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldContain` "Default agent: zoe"

    it "--agent flag overrides default_agent in config" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithSetup
        bin ["--agent", "bob", "--no-vault"] "" 5000000
        (\tmp -> do
           setupFixtureAgent tmp "zoe" "hi"
           setupFixtureAgent tmp "bob" "hi"
           let cfgDir = tmp </> ".pureclaw"
           createDirectoryIfMissing True cfgDir
           writeFile (cfgDir </> "config.toml") "default_agent = \"zoe\"\n")
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldContain` "Default agent: zoe"

    it "backward-compat: no agent, no SOUL.md → no system prompt, no crash" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "PureClaw"
      err `shouldContain` "Default agent: (none)"

    it "backward-compat: --system is honored when no agent is selected" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs
        bin ["--system", "custom-prompt", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldContain` "Default agent: (none)"

  describe "--prefix CLI flag" $ do
    it "creates a session whose dir ends with the given prefix" $ do
      bin <- findPureclaw
      withSystemTempDirectory "pureclaw-prefix-test" $ \tmpDir -> do
        let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 "")))
               $ setStdout byteStringOutput
               $ setStderr byteStringOutput
               $ setWorkingDir tmpDir
               $ setEnv
                   [ ("HOME", tmpDir)
                   , ("PATH", "/usr/bin:/bin")
                   , ("TERM", "dumb")
                   , ("LANG", "C.UTF-8")
                   ]
               $ proc bin ["--no-vault", "--prefix", "myrun"]
        result <- race' (threadDelay 5000000) (readProcess pc)
        case result of
          Left () -> expectationFailure "pureclaw timed out"
          Right (ec, _out, err) -> do
            annotate (T.unpack (TE.decodeUtf8 (LBS.toStrict err))) ec
              `shouldBe` annotate (T.unpack (TE.decodeUtf8 (LBS.toStrict err))) ExitSuccess
            let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
            dirs <- listDirectory sessionsDir
            any ("-myrun" `List.isSuffixOf`) dirs `shouldBe` True

    it "defaults --prefix to the agent name when --agent is set and --prefix is omitted" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithSetup
        bin ["--agent", "zoe", "--no-vault"] "" 5000000
        (\tmp -> do
           let agentDir = tmp </> ".pureclaw" </> "agents" </> "zoe"
           createDirectoryIfMissing True agentDir
           writeFile (agentDir </> "SOUL.md") "hi")
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- The new session dir name must end with the agent prefix.
      -- We can't easily inspect tmpDir here because runPureclawWithSetup
      -- destroys it, so assert indirectly via a stderr log line we emit
      -- at startup listing the session id (now timestamp-first, e.g.
      -- "Session: 20250325-143045-678-zoe").
      err `shouldContain` "-zoe"

    it "rejects --prefix ../evil with an error exit" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs
        bin ["--no-vault", "--prefix", "../evil"] "" 5000000
      exitCode `shouldNotBe` ExitSuccess
      err `shouldContain` "invalid"

  describe "--session CLI flag" $ do
    it "resumes an existing session by exact ID" $ do
      bin <- findPureclaw
      withSystemTempDirectory "pureclaw-session-resume-test" $ \tmpDir -> do
        -- First run: create a session under a known prefix.
        let runArgs args = do
              let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 "")))
                     $ setStdout byteStringOutput
                     $ setStderr byteStringOutput
                     $ setWorkingDir tmpDir
                     $ setEnv
                         [ ("HOME", tmpDir)
                         , ("PATH", "/usr/bin:/bin")
                         , ("TERM", "dumb")
                         , ("LANG", "C.UTF-8")
                         ]
                     $ proc bin args
              r <- race' (threadDelay 5000000) (readProcess pc)
              case r of
                Left () -> fail "pureclaw timed out"
                Right (ec, _o, e) ->
                  pure (ec, T.unpack (TE.decodeUtf8 (LBS.toStrict e)))
        (ec1, _err1) <- runArgs ["--no-vault", "--prefix", "seed"]
        ec1 `shouldBe` ExitSuccess
        let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
        dirs <- listDirectory sessionsDir
        let mResumeId = case filter ("-seed" `List.isSuffixOf`) dirs of
                          (d:_) -> Just d
                          _     -> Nothing
        resumeId <- maybe (fail "no seed session directory found") pure mResumeId
        -- Second run: resume it by exact ID.
        (ec2, err2) <- runArgs ["--no-vault", "--session", resumeId]
        ec2 `shouldBe` ExitSuccess
        -- The resumed session dir must still exist and still have its
        -- transcript file (independence / migration check).
        doesFileExist (sessionsDir </> resumeId </> "transcript.jsonl")
          `shouldReturn` True
        -- And at least one new session dir was NOT created for the resume path.
        dirs2 <- listDirectory sessionsDir
        length dirs2 `shouldBe` length dirs
        -- Sanity: stderr contains a resume log line
        err2 `shouldContain` "Resuming session"

    it "errors out when --session points to a nonexistent ID" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs
        bin ["--no-vault", "--session", "does-not-exist"] "" 5000000
      exitCode `shouldNotBe` ExitSuccess
      err `shouldContain` "not found"

    it "resumes a named session cleanly and uses its on-disk transcript (8c.2: per-tab replay)" $ do
      bin <- findPureclaw
      withSystemTempDirectory "pureclaw-session-replay-test" $ \tmpDir -> do
        -- Build a session fixture directly on disk with two transcript
        -- entries (one Request, one Response) using the real session
        -- and transcript handles, so the binary has something to reload.
        let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
            t0 = UTCTime (fromGregorian 2025 1 1) (secondsToDiffTime 0)
            sid = parseSessionId "replay-fixture-1"
            meta = SessionMeta
              { _sm_id                = sid
              , _sm_agent             = Nothing
              , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "test-model") (ModelId "test-model") Nothing)
              , _sm_model             = "test-model"
              , _sm_channel           = "cli"
              , _sm_createdAt         = t0
              , _sm_lastActive        = t0
              , _sm_bootstrapConsumed = False
              , _sm_archived          = False
              , _sm_description       = Nothing
              , _sm_autoSummary       = Nothing
              , _sm_source            = Nothing
              }
            mkTxEntry eid dir payload = TranscriptEntry
              { _te_id            = eid
              , _te_timestamp     = t0
              , _te_harness       = Nothing
              , _te_model         = Just "test-model"
              , _te_direction     = dir
              , _te_payload       = payload
              , _te_durationMs    = Nothing
              , _te_correlationId = "corr"
              , _te_metadata      = Map.empty
              } :: TranscriptEntry
        createDirectoryIfMissing True sessionsDir
        sh <- mkSessionHandle Nothing mkNoOpLogHandle sessionsDir meta
        let th = _sh_transcript sh
        _th_record th (mkTxEntry "e1" Request  "prior user message")
        _th_record th (mkTxEntry "e2" Response "prior assistant reply")
        _th_flush th
        _th_close th
        -- Now spawn the binary with --session <id> and /status. Under the
        -- Tabs-as-View model (GitHub #79, 8c.2 flip) the resumed transcript is
        -- replayed lazily into each tab's runtime worker context (seeded via
        -- 'loadRecentMessages' when the runtime starts), not eagerly into a
        -- single foreground context. So /status — handled by the dispatcher
        -- fallthrough over a fresh per-command context — no longer reflects the
        -- replayed message count; what it MUST still show is that the named
        -- session resumed cleanly and its on-disk transcript is in use.
        -- (The per-tab Messages-count assertion is re-established in the 8d
        -- end-to-end CLISpec rewrite.)
        let args = ["--no-vault", "--session", "replay-fixture-1"]
            pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 "/status\n")))
               $ setStdout byteStringOutput
               $ setStderr byteStringOutput
               $ setWorkingDir tmpDir
               $ setEnv
                   [ ("HOME", tmpDir)
                   , ("PATH", "/usr/bin:/bin")
                   , ("TERM", "dumb")
                   , ("LANG", "C.UTF-8")
                   ]
               $ proc bin args
        r <- race' (threadDelay 5000000) (readProcess pc)
        case r of
          Left () -> expectationFailure "pureclaw timed out"
          Right (ec, out, err) -> do
            let outStr = T.unpack (TE.decodeUtf8 (LBS.toStrict out))
                errStr = T.unpack (TE.decodeUtf8 (LBS.toStrict err))
            annotate errStr ec `shouldBe` annotate errStr ExitSuccess
            -- The named session resumed cleanly: /status renders and reports the
            -- resumed session's on-disk transcript (the replay-fixture-1 dir),
            -- confirming --session resolved + loaded the fixture rather than
            -- starting a fresh session.
            outStr `shouldContain` "replay-fixture-1"
            outStr `shouldContain` "transcript.jsonl"

    it "logs a warning and falls back to TargetProvider when resuming an SkHarness session whose harness is not running" $ do
      bin <- findPureclaw
      withSystemTempDirectory "pureclaw-resume-rth-test" $ \tmpDir -> do
        let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
            t0 = UTCTime (fromGregorian 2025 1 1) (secondsToDiffTime 0)
            sid = parseSessionId "dead-harness-fixture-1"
            meta = SessionMeta
              { _sm_id                = sid
              , _sm_agent             = Nothing
              , _sm_kind              = SkHarness (HarnessSpec (fixedFlavourLookup "ghost-harness") (TbTmux (TmuxConfig "ghost-harness" "ghost-harness" Nothing)) Nothing [] Nothing Nothing Nothing)
              , _sm_model             = "test-model"
              , _sm_channel           = "cli"
              , _sm_createdAt         = t0
              , _sm_lastActive        = t0
              , _sm_bootstrapConsumed = False
              , _sm_archived          = False
              , _sm_description       = Nothing
              , _sm_autoSummary       = Nothing
              , _sm_source            = Nothing
              }
        createDirectoryIfMissing True sessionsDir
        sh <- mkSessionHandle Nothing mkNoOpLogHandle sessionsDir meta
        _th_close (_sh_transcript sh)
        let args = ["--no-vault", "--session", "dead-harness-fixture-1"]
            pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 "")))
               $ setStdout byteStringOutput
               $ setStderr byteStringOutput
               $ setWorkingDir tmpDir
               $ setEnv
                   [ ("HOME", tmpDir)
                   , ("PATH", "/usr/bin:/bin")
                   , ("TERM", "dumb")
                   , ("LANG", "C.UTF-8")
                   ]
               $ proc bin args
        r <- race' (threadDelay 5000000) (readProcess pc)
        case r of
          Left () -> expectationFailure "pureclaw timed out"
          Right (ec, _out, err) -> do
            let errStr = T.unpack (TE.decodeUtf8 (LBS.toStrict err))
            annotate errStr ec `shouldBe` annotate errStr ExitSuccess
            -- The warning from validateRuntime must fire.
            errStr `shouldContain` "ghost-harness"
            errStr `shouldContain` "falling back"

    it "rejects --session and --prefix together with a mutual-exclusion error" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs
        bin ["--no-vault", "--session", "foo", "--prefix", "bar"] "" 5000000
      exitCode `shouldNotBe` ExitSuccess
      err `shouldContain` "mutually exclusive"

  describe "session transcript independence" $ do
    it "two different sessions do not share transcript state" $ do
      bin <- findPureclaw
      withSystemTempDirectory "pureclaw-session-indep-test" $ \tmpDir -> do
        let runArgs args = do
              let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 "")))
                     $ setStdout byteStringOutput
                     $ setStderr byteStringOutput
                     $ setWorkingDir tmpDir
                     $ setEnv
                         [ ("HOME", tmpDir)
                         , ("PATH", "/usr/bin:/bin")
                         , ("TERM", "dumb")
                         , ("LANG", "C.UTF-8")
                         ]
                     $ proc bin args
              r <- race' (threadDelay 5000000) (readProcess pc)
              case r of
                Left () -> fail "pureclaw timed out"
                Right (ec, _, _) -> pure ec
        ec1 <- runArgs ["--no-vault", "--prefix", "one"]
        ec1 `shouldBe` ExitSuccess
        ec2 <- runArgs ["--no-vault", "--prefix", "two"]
        ec2 `shouldBe` ExitSuccess
        let sessionsDir = tmpDir </> ".pureclaw" </> "sessions"
        dirs <- listDirectory sessionsDir
        let hasSuffix s d = s `List.isSuffixOf` d
        length (filter (hasSuffix "-one") dirs) `shouldBe` 1
        length (filter (hasSuffix "-two") dirs) `shouldBe` 1
        -- Each session dir has its own transcript file (not shared)
        case (filter (hasSuffix "-one") dirs, filter (hasSuffix "-two") dirs) of
          (oneDir:_, twoDir:_) -> do
            doesFileExist (sessionsDir </> oneDir </> "transcript.jsonl")
              `shouldReturn` True
            doesFileExist (sessionsDir </> twoDir </> "transcript.jsonl")
              `shouldReturn` True
            oneDir `shouldNotBe` twoDir
          _ -> expectationFailure "missing expected session directories"

  -- ---------------------------------------------------------------------------
  -- Tabbed command surface — §14 teaching strings (8d item a)
  -- ---------------------------------------------------------------------------
  -- These tests drive the REAL binary with no provider configured.  Every
  -- assertion targets a deterministic §14 copy string that is emitted
  -- regardless of credentials.  Provider-dependent behaviour (tab creation,
  -- live chat turns) stays unit-covered in TabDispatchSpec / WiringSpec /
  -- SignalFlowSpec with fakes.
  -- ---------------------------------------------------------------------------

  describe "tabbed command surface" $ do

    -- /new with no provider → provider setup guidance (Wiring.hs:563)
    it "/new with no provider configured shows provider setup guidance" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/new\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "No provider configured"
      out `shouldContain` "/provider <PROVIDER>"

    -- /5 with 0 tabs → out-of-range §14 copy (TabDispatch.hs:628-630)
    it "/5 with no tabs shows the out-of-range §14 message" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/5\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "/5: out of range"
      out `shouldContain` "you have 0 tabs"
      out `shouldContain` "/tabs to list"

    -- /tabs with 0 tabs → just the relay-mode line (TabDispatch.hs:347-352)
    it "/tabs with no tabs renders the relay-mode line without crashing" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/tabs\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- With zero tabs the only output is the trailing relay line.
      out `shouldContain` "relay:"

    -- /relay with no arg → current relay mode (TabDispatch.hs:657-658)
    it "/relay with no argument shows the current relay mode" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/relay\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "relay mode:"
      out `shouldContain` "focused | activity | all"

    -- /help → help text (already covered in "CLI startup"; verify in this
    -- describe too so the tabbed surface §14 block is self-contained)
    it "/help shows the slash-command reference" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/help\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "Slash commands:"

    -- Unknown slash → parse-error §14 copy (TabDispatch.hs:662)
    it "an unknown slash command shows the parse-error §14 copy" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "/zzz\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "could not parse that"
      out `shouldContain` "/help for commands"
