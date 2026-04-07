{-# LANGUAGE DerivingStrategies #-}
module Integration.CLISpec (spec) where

import Control.Concurrent
import Data.ByteString.Lazy qualified as LBS
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

    it "shows a helpful message when sending a chat message without a provider" $ do
      bin <- findPureclaw
      -- Send a non-slash message. Without a configured provider, the
      -- binary should tell the user how to configure one, not crash.
      (exitCode, out, err) <- runPureclaw bin "Hello world\n" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Should mention how to configure credentials
      out `shouldContain` "provider"

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

    it "falls back to CLI when --channel signal and signal-cli is not installed" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclawWithArgs bin ["gateway", "run", "--channel", "signal", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      -- Should warn about signal-cli not being installed
      err `shouldContain` "signal-cli"
      -- Should still start and show the banner
      out `shouldContain` "PureClaw"

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
      err `shouldContain` "Agent: zoe"

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
      err `shouldContain` "Agent: zoe"

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
      err `shouldContain` "Agent: bob"

    it "backward-compat: no agent, no SOUL.md → no system prompt, no crash" $ do
      bin <- findPureclaw
      (exitCode, out, err) <- runPureclaw bin "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      out `shouldContain` "PureClaw"
      err `shouldNotContain` "Agent:"

    it "backward-compat: --system is honored when no agent is selected" $ do
      bin <- findPureclaw
      (exitCode, _out, err) <- runPureclawWithArgs
        bin ["--system", "custom-prompt", "--no-vault"] "" 5000000
      annotate err exitCode `shouldBe` annotate err ExitSuccess
      err `shouldNotContain` "Agent:"
