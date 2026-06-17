module Session.TitleSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Agent.AgentDef (mkAgentName)
import PureClaw.Core.Types (ModelId (..), ProviderId (..), SessionId (..))
import PureClaw.Session.Kind (ProviderSpec (..), SessionKind (..))
import PureClaw.Session.Title (sessionTitle)
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Transcript.Types (Direction (..), TranscriptEntry (..))

spec :: Spec
spec = describe "sessionTitle" $ do
  it "uses the description override when set" $
    withSystemTempDirectory "title" $ \dir -> do
      let meta = (baseMeta "s-desc") { _sm_description = Just "My custom name" }
      t <- sessionTitle dir meta
      t `shouldBe` "My custom name"

  it "falls back to the first user message snippet when no description" $
    withSystemTempDirectory "title" $ \dir -> do
      let sid = "s-snip"
      createDirectoryIfMissing True (dir </> sid)
      TIO.writeFile (dir </> sid </> "transcript.jsonl") firstReqLine
      let meta = (baseMeta (T.pack sid)) { _sm_description = Nothing }
      t <- sessionTitle dir meta
      T.unpack t `shouldContain` "hello world"

  it "uses the model auto-summary when there is no description" $
    withSystemTempDirectory "title" $ \dir -> do
      let meta = (baseMeta "s-sum")
                   { _sm_description = Nothing, _sm_autoSummary = Just "model summary" }
      t <- sessionTitle dir meta
      t `shouldBe` "model summary"

  it "falls back to the agent name when no description, summary, or transcript" $
    withSystemTempDirectory "title" $ \dir -> do
      let meta = (baseMeta "s-agent")
                   { _sm_description = Nothing
                   , _sm_autoSummary = Nothing
                   , _sm_agent       = either (const Nothing) Just (mkAgentName "my-agent")
                   }
      t <- sessionTitle dir meta
      t `shouldBe` "my-agent"

  it "falls back to a session-id prefix with no description and no transcript" $
    withSystemTempDirectory "title" $ \dir -> do
      let meta = (baseMeta "abcdef0123456789")
                   { _sm_description = Nothing, _sm_agent = Nothing }
      t <- sessionTitle dir meta
      T.unpack t `shouldSatisfy` (not . null)

-- | A 'SessionMeta' with all fields defaulted; tests override the
-- specific fields they exercise.
baseMeta :: Text -> SessionMeta
baseMeta sid = SessionMeta
  { _sm_id                = SessionId sid
  , _sm_agent             = Nothing
  , _sm_kind              = SkProvider (ProviderSpec (ProviderId "stub") (ModelId "") Nothing)
  , _sm_model             = ""
  , _sm_channel           = "cli"
  , _sm_createdAt         = sampleTime
  , _sm_lastActive        = sampleTime
  , _sm_bootstrapConsumed = False
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  , _sm_source            = Nothing
  }

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 5 23) (secondsToDiffTime 0)

-- | One JSON line decoding to a 'Request' 'TranscriptEntry' whose payload
-- is a provider request whose first user message contains "hello world".
firstReqLine :: Text
firstReqLine = TE.decodeUtf8 (LBS.toStrict (Aeson.encode entry)) <> "\n"
  where
    payload :: Text
    payload = TE.decodeUtf8 (LBS.toStrict (Aeson.encode reqBody))

    reqBody :: Aeson.Value
    reqBody = Aeson.object
      [ "messages" Aeson..=
          [ Aeson.object
              [ "role"    Aeson..= ("user" :: Text)
              , "content" Aeson..= ("hello world from the user" :: Text)
              ]
          ]
      ]

    entry :: TranscriptEntry
    entry = TranscriptEntry
      { _te_id            = "id-1"
      , _te_timestamp     = sampleTime
      , _te_harness       = Nothing
      , _te_model         = Nothing
      , _te_direction     = Request
      , _te_payload       = payload
      , _te_durationMs    = Nothing
      , _te_correlationId = "corr-1"
      , _te_metadata      = Map.empty
      }
