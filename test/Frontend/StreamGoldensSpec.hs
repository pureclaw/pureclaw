-- | Wire-protocol golden fixtures — WU3b.
--
-- For every fixture under @test\/Frontend\/fixtures\/stream-events@ we:
--
--   1. Load the JSON file from disk.
--   2. Construct the matching Haskell value ('ServerEvent' or 'ClientOp').
--   3. Encode the Haskell value to an Aeson 'Value'.
--   4. Assert structural equality between the fixture and the encoded
--      value.
--
-- Aeson decodes objects to an unordered 'KeyMap', so the comparison is
-- insensitive to key order and whitespace in the fixture file. The
-- contract anchored here is the JSON shape the production encoder
-- emits — if the encoder regresses, these tests fail before the WS
-- integration tests would catch it.
--
-- These fixtures are the canonical reference for the frontend
-- TypeScript client (WU5) — keep them in sync with @docs\/transcript-streaming.md
-- §Wire Protocol@.
module Frontend.StreamGoldensSpec (spec) where

import Data.Aeson (Value, eitherDecode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime, secondsToDiffTime)
import Test.Hspec

import Frontend.StreamHarness (readGoldenFixture)
import PureClaw.Core.Types (ModelId (..), ProviderId (..), SessionId (..))
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Frontend.Stream
  ( ActivityKind (..)
  , ClientOp (..)
  , ErrorCode (..)
  , ServerEvent (..)
  , encodeServerEvent
  )
import PureClaw.Session.Types
  ( SessionKind (..)
  , ProviderSpec (..)
  , SessionMeta (..)
  )
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  )

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

-- | Load a fixture and decode it as an Aeson 'Value' so the comparison
-- is whitespace- and key-order-insensitive.
loadValue :: FilePath -> IO Value
loadValue name = do
  bs <- readGoldenFixture name
  case eitherDecode bs of
    Left err -> error ("fixture " <> name <> " is not valid JSON: " <> err)
    Right v  -> pure v

-- | Assert that the fixture matches @ev@ when both are reduced to an
-- Aeson 'Value'.
assertMatches :: FilePath -> Value -> IO ()
assertMatches name expected = do
  fixture <- loadValue name
  fixture `shouldBe` expected

-- ---------------------------------------------------------------------------
-- Sample values
-- ---------------------------------------------------------------------------

sid :: SessionId
sid = SessionId "session-abc-123"

helloTime :: UTCTime
helloTime = UTCTime (fromGregorian 2026 5 23) (secondsToDiffTime (18 * 3600))

entryTime :: UTCTime
entryTime = UTCTime (fromGregorian 2026 5 23) (secondsToDiffTime (18 * 3600 + 1))

-- | Timestamp with fractional seconds: @2026-05-23T18:00:01.234Z@.
activityTime :: UTCTime
activityTime =
  UTCTime (fromGregorian 2026 5 23)
    (secondsToDiffTime (18 * 3600 + 1) + picosecondsToDiffTime 234_000_000_000)

sampleEntry :: TranscriptEntry
sampleEntry = TranscriptEntry
  { _te_id            = "te-uuid-1"
  , _te_timestamp     = entryTime
  , _te_harness       = Nothing
  , _te_model         = Nothing
  , _te_direction     = Response
  , _te_payload       = "hello world"
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr-1"
  , _te_metadata      = Map.empty
  }

sampleSessionMeta :: SessionMeta
sampleSessionMeta = SessionMeta
  { _sm_id                = sid
  , _sm_agent             = Nothing
  , _sm_kind              = SkProvider (ProviderSpec (ProviderId "anthropic") (ModelId "claude-3-7-sonnet") Nothing)
  , _sm_model             = "claude-3-7-sonnet"
  , _sm_channel           = "web"
  , _sm_createdAt         = helloTime
  , _sm_lastActive        = helloTime
  , _sm_bootstrapConsumed = True
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  , _sm_source            = Nothing
  }

-- | Client→server focus op (no since).
encodeFocus :: Text -> Value
encodeFocus s = object [ "op" .= ("focus" :: Text), "sessionId" .= s ]

-- | Client→server focus op with since.
encodeFocusWithSince :: Text -> Text -> Value
encodeFocusWithSince s sinceTok = object
  [ "op"        .= ("focus" :: Text)
  , "sessionId" .= s
  , "since"     .= sinceTok
  ]

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "server→client wire fixtures (round-trip via encodeServerEvent)" $ do
    it "hello.json matches encodeServerEvent (SeHello v1 18:00:00Z)" $
      assertMatches "hello"
        (encodeServerEvent (SeHello "v1" helloTime))

    it "entry.json matches encodeServerEvent (SeEntry sample)" $
      assertMatches "entry"
        (encodeServerEvent (SeEntry sid sampleEntry))

    it "activity-entry-at.json matches encodeServerEvent (SeActivity entry-at)" $
      assertMatches "activity-entry-at"
        (encodeServerEvent (SeActivity sid (AkEntryAt activityTime)))

    it "activity-harness-status.json matches (SeActivity harness-status thinking)" $
      assertMatches "activity-harness-status"
        (encodeServerEvent (SeActivity sid (AkHarnessStatus HarnessThinking)))

    it "activity-harness-status-idle.json matches (SeActivity harness-status idle)" $
      assertMatches "activity-harness-status-idle"
        (encodeServerEvent (SeActivity sid (AkHarnessStatus HarnessIdle)))

    it "activity-harness-status-stopped.json matches (SeActivity harness-status stopped)" $
      assertMatches "activity-harness-status-stopped"
        (encodeServerEvent (SeActivity sid (AkHarnessStatus HarnessStopped)))

    it "activity-session-created.json matches (SeActivity session-created)" $
      assertMatches "activity-session-created"
        (encodeServerEvent (SeActivity sid (AkSessionCreated sampleSessionMeta)))

    it "replay-end.json matches (SeReplayEnd (Just te-uuid-42))" $
      assertMatches "replay-end"
        (encodeServerEvent (SeReplayEnd sid (Just "te-uuid-42")))

    it "overflow.json matches SeOverflow" $
      assertMatches "overflow"
        (encodeServerEvent SeOverflow)

    it "error.json matches (SeError session-not-found)" $
      assertMatches "error"
        (encodeServerEvent
          (SeError EcSessionNotFound "invalid session id: session-../etc"))

  describe "client→server wire fixtures" $ do
    it "focus.json matches a {op:focus,sessionId} JSON object" $ do
      fixture <- loadValue "focus"
      fixture `shouldBe` encodeFocus "session-abc-123"

    it "focus-with-since.json matches a focus op with since" $ do
      fixture <- loadValue "focus-with-since"
      fixture `shouldBe` encodeFocusWithSince "session-abc-123" "te-uuid-42"

    -- The client-side decoder is itself exercised by Frontend.StreamSpec
    -- (D29 / D36); here we anchor the wire-shape contract.
    it "focus.json is a valid client op the decoder accepts" $ do
      bs <- readGoldenFixture "focus"
      show (Aeson.decode bs :: Maybe ClientOp) `shouldContain` "CoFocus"

    it "focus-with-since.json carries the since token through the decoder" $ do
      bs <- readGoldenFixture "focus-with-since"
      show (Aeson.decode bs :: Maybe ClientOp) `shouldContain` "te-uuid-42"
