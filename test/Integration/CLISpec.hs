module Integration.CLISpec (spec) where

import Control.Concurrent
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit
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
runPureclaw bin stdinContent timeoutUs = do
  withSystemTempDirectory "pureclaw-cli-test" $ \tmpDir -> do
    let pc = setStdin (byteStringInput (LBS.fromStrict (TE.encodeUtf8 (T.pack stdinContent))))
           $ setStdout byteStringOutput
           $ setStderr byteStringOutput
           $ setWorkingDir tmpDir
           $ setEnv
               [ ("HOME", tmpDir)             -- No ~/.pureclaw config
               , ("PATH", "/usr/bin:/bin")     -- Minimal PATH, no API keys in env
               , ("TERM", "dumb")
               ]
           $ proc bin ["--no-vault"]
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

spec :: Spec
spec = do
  describe "CLI startup" $ do

    it "enters the agent loop and accepts commands when no API key is configured" $ do
      bin <- findPureclaw
      -- Send /help then EOF (Ctrl-D). If the binary enters the loop,
      -- it will process /help and print help text. If it dies on startup
      -- (the current bug), we'll get an error exit code and no help output.
      (exitCode, out, _err) <- runPureclaw bin "/help\n" 5000000  -- 5s timeout
      exitCode `shouldBe` ExitSuccess
      out `shouldContain` "Slash commands:"

    it "does not crash on startup without credentials" $ do
      bin <- findPureclaw
      -- Just send EOF immediately. The binary should start up, print
      -- its banner, then exit cleanly on EOF — not die with an error.
      (exitCode, out, _err) <- runPureclaw bin "" 5000000
      exitCode `shouldBe` ExitSuccess
      out `shouldContain` "PureClaw"

    it "shows a helpful message when sending a chat message without a provider" $ do
      bin <- findPureclaw
      -- Send a non-slash message. Without a configured provider, the
      -- binary should tell the user how to configure one, not crash.
      (exitCode, out, _err) <- runPureclaw bin "Hello world\n" 5000000
      exitCode `shouldBe` ExitSuccess
      -- Should mention how to configure credentials
      out `shouldContain` "provider"
