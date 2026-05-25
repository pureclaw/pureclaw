module Session.HandleSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( UTCTime (..)
  , addUTCTime
  , fromGregorian
  , secondsToDiffTime
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

import PureClaw.Agent.AgentDef (mkAgentName)
import PureClaw.Agent.Compaction (compactionMetadataKey)
import PureClaw.Core.Types
  ( MessageTarget (..)
  , ModelId (..)
  , SessionId (..)
  , parseSessionId
  )
import PureClaw.Handles.Harness (HarnessHandle, mkNoOpHarnessHandle)
import PureClaw.Handles.Log (LogHandle (..), mkNoOpLogHandle)
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  )
import PureClaw.Session.Handle
  ( ResolveError (..)
  , ResolvedRuntime (..)
  , ResumeError (..)
  , SessionHandle (..)
  , SetArchivedError (..)
  , SetDescriptionError (..)
  , listSessions
  , loadRecentMessages
  , markBootstrapConsumed
  , mkNoOpSessionHandle
  , mkSessionHandle
  , resolveResumedTarget
  , resolveSessionRef
  , resumeSession
  , setArchived
  , setDescription
  , validateRuntime
  )
import PureClaw.Providers.Class
  ( ContentBlock (..)
  , Message (..)
  , Role (..)
  )
import PureClaw.Session.Types
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
  , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "test-model") (ModelId "test-model") Nothing)
  , _sm_model             = "test-model"
  , _sm_channel           = "cli"
  , _sm_createdAt         = t
  , _sm_lastActive        = t
  , _sm_bootstrapConsumed = False
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  }

-- Convenience: get the low 9 perm bits of a path.
permBits :: FilePath -> IO Int
permBits p = do
  st <- getFileStatus p
  pure (fromIntegral (fileMode st) .&. 0o777)

mkTextEntry :: Text -> UTCTime -> Direction -> Text -> TranscriptEntry
mkTextEntry eid ts dir payload = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = ts
  , _te_harness       = Nothing
  , _te_model         = Just "test"
  , _te_direction     = dir
  , _te_payload       = encodePayload (TE.encodeUtf8 payload)
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr"
  , _te_metadata      = Map.empty
  }

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
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      bits <- permBits (_sh_dir sh)
      bits `shouldBe` 0o700

    it "writes session.json with mode 0o600" $ withTmp $ \base -> do
      let meta = mkMeta "alpha-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let metaPath = _sh_dir sh </> "session.json"
      doesFileExist metaPath `shouldReturn` True
      bits <- permBits metaPath
      bits `shouldBe` 0o600

    it "creates transcript.jsonl with mode 0o600" $ withTmp $ \base -> do
      let meta = mkMeta "alpha-3" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let txPath = _sh_dir sh </> "transcript.jsonl"
      doesFileExist txPath `shouldReturn` True
      bits <- permBits txPath
      bits `shouldBe` 0o600
      _th_close (_sh_transcript sh)

  describe "mkSessionHandle (metadata persistence)" $ do
    it "save round-trips SessionMeta to disk" $ withTmp $ \base -> do
      let meta = mkMeta "beta-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _sh_save sh
      bytes <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      bytes `shouldBe` Right meta
      _th_close (_sh_transcript sh)

    it "subsequent saves persist updated last_active" $ withTmp $ \base -> do
      let meta = mkMeta "beta-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let newTime = addUTCTime 60 t0
      modifyIORef' (_sh_meta sh) (\m -> m { _sm_lastActive = newTime })
      _sh_save sh
      Right loaded <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_lastActive loaded `shouldBe` newTime
      _th_close (_sh_transcript sh)

  describe "mkSessionHandle (touchLastActive)" $ do
    it "bumps _sm_lastActive after _th_record and persists to disk" $ withTmp $ \base -> do
      let meta = mkMeta "touch-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      -- Confirm initial lastActive is t0.
      metaBefore <- readIORef (_sh_meta sh)
      _sm_lastActive metaBefore `shouldBe` t0
      -- Record a transcript entry.
      _th_record (_sh_transcript sh) (mkEntry "e1" t0)
      -- The IORef must have been bumped past t0.
      metaAfter <- readIORef (_sh_meta sh)
      _sm_lastActive metaAfter `shouldSatisfy` (> t0)
      -- The on-disk session.json must reflect the bumped time.
      Right onDisk <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_lastActive onDisk `shouldSatisfy` (> t0)
      _th_close (_sh_transcript sh)

    it "bumps _sm_lastActive on resumed sessions too" $ withTmp $ \base -> do
      let meta = mkMeta "touch-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      Right sh' <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "touch-2")
      _th_record (_sh_transcript sh') (mkEntry "e2" t0)
      metaAfter' <- readIORef (_sh_meta sh')
      _sm_lastActive metaAfter' `shouldSatisfy` (> t0)
      Right onDisk <- Aeson.eitherDecodeFileStrict' (_sh_dir sh' </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_lastActive onDisk `shouldSatisfy` (> t0)
      _th_close (_sh_transcript sh')

  describe "resumeSession" $ do
    it "round-trips an existing session and reopens transcript for append" $ withTmp $ \base -> do
      let meta = mkMeta "gamma-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_record (_sh_transcript sh) (mkEntry "e1" t0)
      _th_close (_sh_transcript sh)
      result <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "gamma-1")
      case result of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right sh' -> do
          loaded <- readIORef (_sh_meta sh')
          -- _sm_lastActive was bumped by the _th_record above, so compare
          -- all fields except lastActive and verify lastActive >= t0.
          loaded { _sm_lastActive = t0 } `shouldBe` meta
          _sm_lastActive loaded `shouldSatisfy` (>= t0)
          _th_record (_sh_transcript sh') (mkEntry "e2" t0)
          _th_close (_sh_transcript sh')

    it "returns ResumeMissingMetadata when session.json is missing" $ withTmp $ \base -> do
      -- Create the session dir but never write session.json
      createDirectoryIfMissing True (base </> "ghost")
      result <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "ghost")
      case result of
        Left (ResumeMissingMetadata p) -> p `shouldBe` (base </> "ghost" </> "session.json")
        Right _ -> expectationFailure "expected MissingMetadata, got: Right _"
        Left e -> expectationFailure ("expected MissingMetadata, got: " <> show e)

    it "returns ResumeCorruptedMetadata when session.json is malformed" $ withTmp $ \base -> do
      let dir = base </> "broken"
      createDirectoryIfMissing True dir
      writeFile (dir </> "session.json") "{ this is not valid json"
      result <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "broken")
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
    it "SkProvider always returns RuntimeOk TargetProvider" $
      validateRuntime Map.empty (SkProvider (ProviderSpec (inferProviderId "") (ModelId "") Nothing)) `shouldBe` RuntimeOk TargetProvider

    it "SkHarness present in map returns RuntimeOk (TargetHarness name)" $ do
      let h = noOpHarness
          m = Map.singleton "cc" h
          hSpec = HarnessSpec (fixedFlavourLookup "cc") (TbTmux (TmuxConfig "cc" "cc" Nothing)) Nothing []
      case validateRuntime m (SkHarness hSpec) of
        RuntimeOk (TargetHarness n) -> n `shouldBe` "cc"
        other -> expectationFailure ("expected RuntimeOk TargetHarness, got: " <> show other)

    it "SkHarness absent returns RuntimeFallback TargetProvider with warning" $
      let hSpec = HarnessSpec (fixedFlavourLookup "dead") (TbTmux (TmuxConfig "dead" "dead" Nothing)) Nothing []
      in case validateRuntime Map.empty (SkHarness hSpec) of
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

  describe "markBootstrapConsumed" $ do
    it "flips _sm_bootstrapConsumed to True and persists to session.json" $ withTmp $ \base -> do
      let meta = mkMeta "bc-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _sm_bootstrapConsumed <$> readIORef (_sh_meta sh) `shouldReturn` False
      markBootstrapConsumed sh
      -- IORef reflects the change.
      updated <- readIORef (_sh_meta sh)
      _sm_bootstrapConsumed updated `shouldBe` True
      -- Persisted to disk.
      Right onDisk <- Aeson.eitherDecodeFileStrict' (_sh_dir sh </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_bootstrapConsumed onDisk `shouldBe` True
      _th_close (_sh_transcript sh)

    it "is idempotent on repeated invocations" $ withTmp $ \base -> do
      let meta = mkMeta "bc-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      markBootstrapConsumed sh
      markBootstrapConsumed sh
      markBootstrapConsumed sh
      updated <- readIORef (_sh_meta sh)
      _sm_bootstrapConsumed updated `shouldBe` True
      _th_close (_sh_transcript sh)

    it "survives resumeSession (flag preserved on reload)" $ withTmp $ \base -> do
      let meta = mkMeta "bc-3" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      markBootstrapConsumed sh
      _th_close (_sh_transcript sh)
      Right sh' <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "bc-3")
      loaded <- readIORef (_sh_meta sh')
      _sm_bootstrapConsumed loaded `shouldBe` True
      _th_close (_sh_transcript sh')

  describe "setArchived" $ do
    it "writes the archive flag back to session.json without touching anything else" $ withTmp $ \base -> do
      let meta = mkMeta "arch-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      result <- setArchived base (parseSessionId "arch-1") True
      result `shouldBe` Right ()
      Right onDisk <- Aeson.eitherDecodeFileStrict' (base </> "arch-1" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_archived onDisk `shouldBe` True
      -- Bootstrap state and other fields must be untouched.
      _sm_bootstrapConsumed onDisk `shouldBe` _sm_bootstrapConsumed meta
      _sm_id onDisk `shouldBe` _sm_id meta

    it "is reversible — archive then unarchive restores the flag" $ withTmp $ \base -> do
      let meta = mkMeta "arch-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      _ <- setArchived base (parseSessionId "arch-2") True
      _ <- setArchived base (parseSessionId "arch-2") False
      Right onDisk <- Aeson.eitherDecodeFileStrict' (base </> "arch-2" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_archived onDisk `shouldBe` False

    it "leaves the transcript and session directory in place after archive" $ withTmp $ \base -> do
      let meta = mkMeta "arch-3" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      _ <- setArchived base (parseSessionId "arch-3") True
      doesDirectoryExist (base </> "arch-3") `shouldReturn` True
      doesFileExist (base </> "arch-3" </> "session.json") `shouldReturn` True

    it "returns SetArchivedSessionMissing for an unknown session" $ withTmp $ \base -> do
      result <- setArchived base (parseSessionId "nope-1") True
      result `shouldBe` Left SetArchivedSessionMissing

  describe "setDescription" $ do
    it "writes the description back to session.json" $ withTmp $ \base -> do
      let meta = mkMeta "desc-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      result <- setDescription base (parseSessionId "desc-1") (Just "kernel build pipeline")
      result `shouldBe` Right ()
      Right onDisk <- Aeson.eitherDecodeFileStrict' (base </> "desc-1" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_description onDisk `shouldBe` Just "kernel build pipeline"

    it "trims surrounding whitespace and treats all-whitespace as a clear" $ withTmp $ \base -> do
      let meta = mkMeta "desc-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      _ <- setDescription base (parseSessionId "desc-2") (Just "  hello world  ")
      Right d1 <- Aeson.eitherDecodeFileStrict' (base </> "desc-2" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_description d1 `shouldBe` Just "hello world"
      _ <- setDescription base (parseSessionId "desc-2") (Just "   ")
      Right d2 <- Aeson.eitherDecodeFileStrict' (base </> "desc-2" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_description d2 `shouldBe` Nothing

    it "Nothing clears a previously-set description" $ withTmp $ \base -> do
      let meta = mkMeta "desc-3" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      _th_close (_sh_transcript sh)
      _ <- setDescription base (parseSessionId "desc-3") (Just "first attempt")
      _ <- setDescription base (parseSessionId "desc-3") Nothing
      Right onDisk <- Aeson.eitherDecodeFileStrict' (base </> "desc-3" </> "session.json")
        :: IO (Either String SessionMeta)
      _sm_description onDisk `shouldBe` Nothing

    it "returns SetDescriptionSessionMissing for an unknown session" $ withTmp $ \base -> do
      result <- setDescription base (parseSessionId "nope-2") (Just "x")
      result `shouldBe` Left SetDescriptionSessionMissing

  describe "loadRecentMessages" $ do
    it "returns all messages when fewer than maxCount exist" $ withTmp $ \base -> do
      let meta = mkMeta "lr-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      _th_record th (mkTextEntry "e1" t0 Request  "hello")
      _th_record th (mkTextEntry "e2" t0 Response "hi there")
      _th_flush th
      ms <- loadRecentMessages th 50 100000
      length ms `shouldBe` 2
      -- Oldest first; first entry is User.
      case ms of
        [Message User [TextBlock a], Message Assistant [TextBlock b]] -> do
          a `shouldBe` "hello"
          b `shouldBe` "hi there"
        _ -> expectationFailure ("unexpected shape: " <> show ms)
      _th_close th

    it "caps at maxCount and returns the MOST RECENT window (oldest-first)" $ withTmp $ \base -> do
      let meta = mkMeta "lr-2" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      mapM_ (\i -> _th_record th
                     (mkTextEntry (T.pack ("e" <> show i)) t0 Request
                                  (T.pack ("msg-" <> show i))))
            [1 .. 100 :: Int]
      _th_flush th
      ms <- loadRecentMessages th 50 1000000
      length ms `shouldBe` 50
      -- The window must be the LAST 50 (msg-51 .. msg-100), oldest first.
      case ms of
        (Message _ [TextBlock first] : _) -> first `shouldBe` "msg-51"
        _ -> expectationFailure "unexpected first message"
      case reverse ms of
        (Message _ [TextBlock lastT] : _) -> lastT `shouldBe` "msg-100"
        _ -> expectationFailure "unexpected last message"
      _th_close th

    it "truncates by token budget (chars `div` 4) when budget smaller than count" $ withTmp $ \base -> do
      let meta = mkMeta "lr-3" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      -- Each payload is 400 chars → ~100 tokens; budget of 250 tokens → 2 messages fit.
      let big = T.replicate 400 "x"
      mapM_ (\i -> _th_record th (mkTextEntry (T.pack ("big" <> show i)) t0 Request big))
            [1 .. 10 :: Int]
      _th_flush th
      ms <- loadRecentMessages th 50 250
      length ms `shouldSatisfy` (<= 3)
      length ms `shouldSatisfy` (>= 1)
      _th_close th

    it "preserves compaction summary across session resume" $ withTmp $ \base -> do
      -- Set up a session with several messages in the transcript
      let meta = mkMeta "compact-resume-1" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      -- Record 5 request/response pairs — simulating a conversation
      mapM_ (\i -> do
        _th_record th (mkTextEntry (T.pack ("req" <> show i)) t0 Request
                        (T.pack ("user message " <> show i)))
        _th_record th (mkTextEntry (T.pack ("res" <> show i)) t0 Response
                        (T.pack ("assistant reply " <> show i)))
        ) [1 .. 5 :: Int]
      _th_flush th
      -- Simulate compaction: record a compaction boundary entry with
      -- the summary text and the compaction metadata marker, then
      -- record the kept-recent messages (last 2 pairs) after it.
      let summaryPayload = "[Context summary] The user discussed topics 1-3. Key decisions were made about X."
          compactionEntry = (mkTextEntry "compaction-summary" t0 Request summaryPayload)
            { _te_metadata = Map.singleton compactionMetadataKey (Aeson.Bool True) }
      _th_record th compactionEntry
      -- The 2 most recent pairs would continue as normal conversation
      -- entries after the compaction point — they were already in the
      -- transcript before compaction.  New messages after compaction
      -- would be appended here too.
      _th_flush th
      _th_close th
      -- Resume the session and load recent messages
      Right sh' <- resumeSession Nothing mkNoOpLogHandle base (parseSessionId "compact-resume-1")
      ms <- loadRecentMessages (_sh_transcript sh') 50 100000
      -- The resumed context should contain the compaction summary
      -- plus only entries AFTER the compaction boundary.
      let isSummary (Message User [TextBlock t]) = "[Context summary]" `T.isPrefixOf` t
          isSummary _                              = False
          summaryMessages = filter isSummary ms
      -- Exactly one summary message
      length summaryMessages `shouldBe` 1
      -- Only the compaction entry itself (no pre-compaction messages)
      length ms `shouldBe` 1
      _th_close (_sh_transcript sh')

    it "returns [] on an empty transcript" $ withTmp $ \base -> do
      let meta = mkMeta "lr-4" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      ms <- loadRecentMessages th 50 100000
      ms `shouldBe` []
      _th_close th

    -- The next four tests regression-cover the "context recursion" bug
    -- where loadRecentMessages was embedding the entire provider API
    -- payload (full envelope: messages array, system_prompt, max_tokens,
    -- ...) as message TEXT in the next turn's request. After 2 turns the
    -- LLM saw deeply nested escape-encoded JSON instead of the actual
    -- conversation; tokens exploded and responses degraded.
    --
    -- The fix extracts only the NEW message text from the payload (the
    -- last element of `messages` for a Request, or the `content` array
    -- for a Response). These tests pin both the Anthropic-style typed-
    -- content shape AND the OpenAI-style string-content shape, plus
    -- the plain-text fallback that the older tests above depend on.
    it "extracts the NEW user text from an Anthropic-style request envelope" $ withTmp $ \base -> do
      let meta = mkMeta "lr-extract-anthr" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
          payload = "{\"max_tokens\":4096,\
                    \\"messages\":[\
                      \{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"first turn\"}]},\
                      \{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"got it\"}]},\
                      \{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"second turn\"}]}\
                    \],\"system_prompt\":\"be helpful\",\"model\":\"claude\"}"
      _th_record th (mkTextEntry "req-anthr" t0 Request payload)
      _th_flush th
      ms <- loadRecentMessages th 50 100000
      case ms of
        [Message User [TextBlock t]] -> t `shouldBe` "second turn"
        _ -> expectationFailure ("expected single user message with 'second turn', got: " <> show ms)
      _th_close th

    it "extracts the assistant text from an Anthropic-style response payload" $ withTmp $ \base -> do
      let meta = mkMeta "lr-extract-resp" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
          payload = "{\"content\":[{\"type\":\"text\",\"text\":\"FPV joke\"}],\
                    \\"model\":\"gemma4:26b\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
      _th_record th (mkTextEntry "resp-anthr" t0 Response payload)
      _th_flush th
      ms <- loadRecentMessages th 50 100000
      case ms of
        [Message Assistant [TextBlock t]] -> t `shouldBe` "FPV joke"
        _ -> expectationFailure ("expected single assistant message with 'FPV joke', got: " <> show ms)
      _th_close th

    it "extracts text from an OpenAI-style string-content message" $ withTmp $ \base -> do
      let meta = mkMeta "lr-extract-openai" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
          payload = "{\"model\":\"gpt-4\",\
                    \\"messages\":[{\"role\":\"user\",\"content\":\"plain string content\"}]}"
      _th_record th (mkTextEntry "req-openai" t0 Request payload)
      _th_flush th
      ms <- loadRecentMessages th 50 100000
      case ms of
        [Message User [TextBlock t]] -> t `shouldBe` "plain string content"
        _ -> expectationFailure ("expected single user message, got: " <> show ms)
      _th_close th

    it "falls back to the raw payload when JSON does not match a known shape" $ withTmp $ \base -> do
      -- Custom-harness transcripts and the older test fixtures record plain
      -- text. Those entries must continue to round-trip verbatim.
      let meta = mkMeta "lr-extract-fb" t0
      sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
      let th = _sh_transcript sh
      _th_record th (mkTextEntry "p1" t0 Request "this is a plain-text request, not JSON")
      _th_record th (mkTextEntry "p2" t0 Response "{\"not_a_known\":\"shape\"}")
      _th_flush th
      ms <- loadRecentMessages th 50 100000
      case ms of
        [Message User [TextBlock a], Message Assistant [TextBlock b]] -> do
          a `shouldBe` "this is a plain-text request, not JSON"
          b `shouldBe` "{\"not_a_known\":\"shape\"}"
        _ -> expectationFailure ("unexpected shape: " <> show ms)
      _th_close th

  describe "resolveResumedTarget" $ do
    it "SkProvider resolves to TargetProvider without logging a warning" $ do
      (logger, warnRef) <- mkCaptureLogger
      tgt <- resolveResumedTarget logger Map.empty (SkProvider (ProviderSpec (inferProviderId "") (ModelId "") Nothing))
      tgt `shouldBe` TargetProvider
      readIORef warnRef `shouldReturn` []

    it "SkHarness present resolves to TargetHarness without a warning" $ do
      (logger, warnRef) <- mkCaptureLogger
      let harnesses = Map.singleton "cc" noOpHarness
          hSpec = HarnessSpec (fixedFlavourLookup "cc") (TbTmux (TmuxConfig "cc" "cc" Nothing)) Nothing []
      tgt <- resolveResumedTarget logger harnesses (SkHarness hSpec)
      tgt `shouldBe` TargetHarness "cc"
      readIORef warnRef `shouldReturn` []

    it "SkHarness missing logs a warning and falls back to TargetProvider" $ do
      (logger, warnRef) <- mkCaptureLogger
      let hSpec = HarnessSpec (fixedFlavourLookup "dead") (TbTmux (TmuxConfig "dead" "dead" Nothing)) Nothing []
      tgt <- resolveResumedTarget logger Map.empty (SkHarness hSpec)
      tgt `shouldBe` TargetProvider
      warnings <- readIORef warnRef
      case warnings of
        [msg] -> do
          ("dead" `T.isInfixOf` msg) `shouldBe` True
          ("falling back" `T.isInfixOf` msg) `shouldBe` True
        other -> expectationFailure ("expected 1 warning, got: " <> show other)

-- ----------------------------------------------------------------------------
-- Local helpers (used only by listSessions/resolveSessionRef tests)
-- ----------------------------------------------------------------------------

-- | Create a LogHandle that captures warn-level messages into an IORef.
mkCaptureLogger :: IO (LogHandle, IORef [Text])
mkCaptureLogger = do
  ref <- newIORef []
  let logger = LogHandle
        { _lh_logInfo  = \_ -> pure ()
        , _lh_logWarn  = \m -> modifyIORef' ref (<> [m])
        , _lh_logError = \_ -> pure ()
        , _lh_logDebug = \_ -> pure ()
        }
  pure (logger, ref)

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
  sh <- mkSessionHandle Nothing mkNoOpLogHandle base meta
  _sh_save sh
  _th_close (_sh_transcript sh)

-- | Always-running no-op harness used to populate validateRuntime maps.
noOpHarness :: HarnessHandle
noOpHarness = mkNoOpHarnessHandle
