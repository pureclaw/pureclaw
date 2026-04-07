module Session.HandleSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..)
  , addUTCTime
  , fromGregorian
  , secondsToDiffTime
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

import PureClaw.Agent.AgentDef (mkAgentName)
import PureClaw.Core.Types
  ( MessageTarget (..)
  , SessionId (..)
  , parseSessionId
  )
import PureClaw.Handles.Harness (HarnessHandle, mkNoOpHarnessHandle)
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  )
import PureClaw.Session.Handle
  ( ResolveError (..)
  , ResolvedRuntime (..)
  , ResumeError (..)
  , SessionHandle (..)
  , listSessions
  , mkNoOpSessionHandle
  , mkSessionHandle
  , resolveSessionRef
  , resumeSession
  , validateRuntime
  )
import PureClaw.Session.Types
  ( RuntimeType (..)
  , SessionMeta (..)
  )
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , encodePayload
  )


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2025 1 1) (secondsToDiffTime 0)

mkMeta :: Text -> UTCTime -> SessionMeta
mkMeta sid t = SessionMeta
  { _sm_id                = parseSessionId sid
  , _sm_agent             = Nothing
  , _sm_runtime           = RTProvider
  , _sm_model             = "test-model"
  , _sm_channel           = "cli"
  , _sm_createdAt         = t
  , _sm_lastActive        = t
  , _sm_bootstrapConsumed = False
  }

-- Convenience: get the low 9 perm bits of a path.
permBits :: FilePath -> IO Int
permBits p = do
  st <- getFileStatus p
  pure (fromIntegral (fileMode st) .&. 0o777)

mkEntry :: Text -> UTCTime -> TranscriptEntry
mkEntry eid ts = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = ts
  , _te_harness       = Nothing
  , _te_model         = Just "test"
  , _te_direction     = Request
  , _te_payload       = encodePayload ("hi" :: BS.ByteString)
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr"
  , _te_metadata      = Map.empty
  }

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "pureclaw-session-handle-spec"

-- ----------------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "mkSessionHandle (create path)" $ do
    it "creates the session directory with mode 0o700" $ withTmp $ \base -> do
      let meta = mkMeta "alpha-1" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      bits <- permBits (_sh_dir sh)
      bits `shouldBe` 0o700

    it "writes session.json with mode 0o600" $ withTmp $ \base -> do
      let meta = mkMeta "alpha-2" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      let metaPath = _sh_dir sh </> "session.json"
      doesFileExist metaPath `shouldReturn` True
      bits <- permBits metaPath
      bits `shouldBe` 0o600

    it "creates transcript.jsonl with mode 0o600" $ withTmp $ \base -> do
      let meta = mkMeta "alpha-3" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      let txPath = _sh_dir sh </> "transcript.jsonl"
      doesFileExist txPath `shouldReturn` True
      bits <- permBits txPath
      bits `shouldBe` 0o600
      _th_close (_sh_transcript sh)

  describe "mkSessionHandle (metadata persistence)" $ do
    it "save round-trips SessionMeta to disk" $ withTmp $ \base -> do
      let meta = mkMeta "beta-1" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      _sh_save sh
      bytes <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      bytes `shouldBe` Right meta
      _th_close (_sh_transcript sh)

    it "subsequent saves persist updated last_active" $ withTmp $ \base -> do
      let meta = mkMeta "beta-2" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      let newTime = addUTCTime 60 t0
      modifyIORef' (_sh_meta sh) (\m -> m { _sm_lastActive = newTime })
      _sh_save sh
      Right loaded <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_lastActive loaded `shouldBe` newTime
      _th_close (_sh_transcript sh)

  describe "resumeSession" $ do
    it "round-trips an existing session and reopens transcript for append" $ withTmp $ \base -> do
      let meta = mkMeta "gamma-1" t0
      sh <- mkSessionHandle mkNoOpLogHandle base meta
      _th_record (_sh_transcript sh) (mkEntry "e1" t0)
      _th_close (_sh_transcript sh)
      result <- resumeSession mkNoOpLogHandle base (parseSessionId "gamma-1")
      case result of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right sh' -> do
          loaded <- readIORef (_sh_meta sh')
          loaded `shouldBe` meta
          _th_record (_sh_transcript sh') (mkEntry "e2" t0)
          _th_close (_sh_transcript sh')

    it "returns ResumeMissingMetadata when session.json is missing" $ withTmp $ \base -> do
      -- Create the session dir but never write session.json
      createDirectoryIfMissing True (base </> "ghost")
      result <- resumeSession mkNoOpLogHandle base (parseSessionId "ghost")
      case result of
        Left (ResumeMissingMetadata p) -> p `shouldBe` (base </> "ghost" </> "session.json")
        Right _ -> expectationFailure "expected MissingMetadata, got: Right _"
        Left e -> expectationFailure ("expected MissingMetadata, got: " <> show e)

    it "returns ResumeCorruptedMetadata when session.json is malformed" $ withTmp $ \base -> do
      let dir = base </> "broken"
      createDirectoryIfMissing True dir
      writeFile (dir </> "session.json") "{ this is not valid json"
      result <- resumeSession mkNoOpLogHandle base (parseSessionId "broken")
      case result of
        Left (ResumeCorruptedMetadata p _) -> p `shouldBe` (dir </> "session.json")
        Right _ -> expectationFailure "expected CorruptedMetadata, got: Right _"
        Left e  -> expectationFailure ("expected CorruptedMetadata, got: " <> show e)

  describe "mkNoOpSessionHandle" $ do
    it "is safe to save and record into" $ do
      sh <- mkNoOpSessionHandle
      _sh_save sh
      _th_record (_sh_transcript sh) (mkEntry "noop" t0)
      _sh_dir sh `shouldBe` ""

  describe "validateRuntime" $ do
    it "RTProvider always returns RuntimeOk TargetProvider" $
      validateRuntime Map.empty RTProvider `shouldBe` RuntimeOk TargetProvider

    it "RTHarness present in map returns RuntimeOk (TargetHarness name)" $ do
      let h = noOpHarness
          m = Map.singleton "cc" h
      case validateRuntime m (RTHarness "cc") of
        RuntimeOk (TargetHarness n) -> n `shouldBe` "cc"
        other -> expectationFailure ("expected RuntimeOk TargetHarness, got: " <> show other)

    it "RTHarness absent returns RuntimeFallback TargetProvider with warning" $
      case validateRuntime Map.empty (RTHarness "dead") of
        RuntimeFallback TargetProvider msg ->
          ("dead" `T.isInfixOf` msg && "falling back" `T.isInfixOf` msg)
            `shouldBe` True
        other ->
          expectationFailure ("expected RuntimeFallback, got: " <> show other)

  describe "listSessions and resolveSessionRef" $ do
    it "listSessions returns all sessions sorted by last_active descending" $ withTmp $ \base -> do
      _ <- writeMeta base "zoe-60759-111" 1
      _ <- writeMeta base "zoe-60759-222" 5
      _ <- writeMeta base "ops-60759-333" 3
      ms <- listSessions base Nothing 20
      map _sm_id ms `shouldBe`
        [ parseSessionId "zoe-60759-222"
        , parseSessionId "ops-60759-333"
        , parseSessionId "zoe-60759-111"
        ]

    it "listSessions filter by agent name returns only matching sessions" $ withTmp $ \base -> do
      _ <- writeMetaWithAgent base "zoe-60759-111" 1 (Just "zoe")
      _ <- writeMetaWithAgent base "zoe-60759-222" 5 (Just "zoe")
      _ <- writeMetaWithAgent base "ops-60759-333" 3 (Just "ops")
      Right zoe <- pure (mkAgentName "zoe")
      ms <- listSessions base (Just zoe) 20
      length ms `shouldBe` 2
      mapM_ (\m -> _sm_agent m `shouldBe` Just zoe) ms

    it "listSessions caps results at the requested limit" $ withTmp $ \base -> do
      mapM_ (\i -> writeMeta base ("s-" <> T.pack (show i)) i)
        [1 .. 25]
      ms <- listSessions base Nothing 20
      length ms `shouldBe` 20

    it "resolveSessionRef returns exact match" $ withTmp $ \base -> do
      _ <- writeMeta base "zoe-60759-111" 1
      _ <- writeMeta base "zoe-60759-222" 5
      result <- resolveSessionRef base "zoe-60759-222"
      result `shouldBe` Right (parseSessionId "zoe-60759-222")

    it "resolveSessionRef returns Ambiguous on prefix collision" $ withTmp $ \base -> do
      _ <- writeMeta base "zoe-60759-111" 1
      _ <- writeMeta base "zoe-60759-222" 5
      _ <- writeMeta base "ops-60759-333" 3
      result <- resolveSessionRef base "zoe-607"
      case result of
        Left (Ambiguous ids) -> do
          length ids `shouldBe` 2
          all (\(SessionId t) -> "zoe-" `T.isPrefixOf` t) ids `shouldBe` True
        other -> expectationFailure ("expected Ambiguous, got: " <> show other)

    it "resolveSessionRef returns the unique prefix match" $ withTmp $ \base -> do
      _ <- writeMeta base "zoe-60759-111" 1
      _ <- writeMeta base "ops-60759-333" 3
      result <- resolveSessionRef base "ops"
      result `shouldBe` Right (parseSessionId "ops-60759-333")

    it "resolveSessionRef returns NotFound when no candidates match" $ withTmp $ \base -> do
      _ <- writeMeta base "zoe-60759-111" 1
      result <- resolveSessionRef base "nothing"
      result `shouldBe` Left NotFound

-- ----------------------------------------------------------------------------
-- Local helpers (used only by listSessions/resolveSessionRef tests)
-- ----------------------------------------------------------------------------

-- | Write a session.json under <base>/<sid>/ with the given last-active offset
-- (in seconds, added to t0). Closes the transcript handle so that file
-- descriptors don't leak across tests.
writeMeta :: FilePath -> Text -> Integer -> IO ()
writeMeta base sid offsetSecs = writeMetaWithAgent base sid offsetSecs Nothing

writeMetaWithAgent :: FilePath -> Text -> Integer -> Maybe Text -> IO ()
writeMetaWithAgent base sid offsetSecs mAgentText = do
  let mAgent = mAgentText >>= \t -> case mkAgentName t of
        Right a -> Just a
        Left _  -> Nothing
      lastActive = addUTCTime (fromIntegral offsetSecs) t0
      meta = (mkMeta sid t0)
        { _sm_agent      = mAgent
        , _sm_lastActive = lastActive
        }
  sh <- mkSessionHandle mkNoOpLogHandle base meta
  _sh_save sh
  _th_close (_sh_transcript sh)

-- | Always-running no-op harness used to populate validateRuntime maps.
noOpHarness :: HarnessHandle
noOpHarness = mkNoOpHarnessHandle
