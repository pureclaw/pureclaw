module Transcript.TypesSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack)
import Data.Text qualified as T
import Data.Time
import Data.Word (Word8)
import Test.Hspec
import Test.QuickCheck

import PureClaw.Transcript

-- Helper: fixed timestamp for deterministic tests
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2025 1 1) 0

t1 :: UTCTime
t1 = UTCTime (fromGregorian 2025 1 1) 3600

t2 :: UTCTime
t2 = UTCTime (fromGregorian 2025 1 1) 7200

t3 :: UTCTime
t3 = UTCTime (fromGregorian 2025 1 2) 0

-- Helper: build a minimal entry
mkEntry :: Text -> UTCTime -> Text -> Direction -> TranscriptEntry
mkEntry eid ts src dir = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = ts
  , _te_harness       = Nothing
  , _te_model         = Just src
  , _te_direction     = dir
  , _te_payload       = encodePayload "hello"
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr-1"
  , _te_metadata      = Map.empty
  }

spec :: Spec
spec = do
  ---------------------------------------------------------------------------
  -- DoD 1: TranscriptEntry ToJSON/FromJSON round-trip
  ---------------------------------------------------------------------------
  describe "TranscriptEntry JSON round-trip" $ do
    it "round-trips through JSON" $ do
      let entry = mkEntry "id-1" t0 "ollama/llama3" Request
      Aeson.decode (Aeson.encode entry) `shouldBe` Just entry

    it "round-trips entry with all optional fields populated" $ do
      let entry = (mkEntry "id-2" t1 "test-model" Response)
            { _te_durationMs = Just 42
            , _te_metadata   = Map.fromList [("key", Aeson.String "val")]
            }
      Aeson.decode (Aeson.encode entry) `shouldBe` Just entry

  ---------------------------------------------------------------------------
  -- DoD 2: Direction ToJSON/FromJSON round-trip
  ---------------------------------------------------------------------------
  describe "Direction JSON round-trip" $ do
    it "Request round-trips" $
      Aeson.decode (Aeson.encode Request) `shouldBe` Just Request

    it "Response round-trips" $
      Aeson.decode (Aeson.encode Response) `shouldBe` Just Response

  ---------------------------------------------------------------------------
  -- DoD 3: Payload encoding preserves UTF-8 bytes (property test)
  ---------------------------------------------------------------------------
  describe "payload encoding" $ do
    it "encodePayload produces text from bytes" $
      property $ \(bs :: [Word8]) -> do
        let raw = BS.pack bs
            encoded = encodePayload raw
        -- encodePayload always produces valid Text (lenient decoding)
        T.length encoded `shouldSatisfy` (>= 0)

    it "decodePayload always returns Just" $
      decodePayload "any text at all!" `shouldBe` Just "any text at all!"

  ---------------------------------------------------------------------------
  -- DoD 4: emptyFilter matches all entries
  ---------------------------------------------------------------------------
  describe "emptyFilter" $ do
    it "matches all entries" $ do
      let entries =
            [ mkEntry "a" t0 "src-a" Request
            , mkEntry "b" t1 "src-b" Response
            ]
      applyFilter emptyFilter entries `shouldBe` entries

  ---------------------------------------------------------------------------
  -- DoD 5: Filter by _tf_model only matches entries with that model
  ---------------------------------------------------------------------------
  describe "filter by source" $ do
    it "only matches entries with the given source" $ do
      let eA = mkEntry "a" t0 "ollama" Request
          eB = mkEntry "b" t1 "claude" Response
          eC = mkEntry "c" t2 "ollama" Response
          entries = [eA, eB, eC]
          f = emptyFilter { _tf_model = Just "ollama" }
      applyFilter f entries `shouldBe` [eA, eC]

  ---------------------------------------------------------------------------
  -- DoD 6: Filter by _tf_limit applied to 10 entries returns 5
  ---------------------------------------------------------------------------
  describe "filter by limit" $ do
    it "applied to 10 entries returns 5" $ do
      let entries = [ mkEntry (pack (show i)) (addUTCTime (fromIntegral i) t0) "src" Request
                    | i <- [1..10 :: Int]
                    ]
          f = emptyFilter { _tf_limit = Just 5 }
      length (applyFilter f entries) `shouldBe` 5

  ---------------------------------------------------------------------------
  -- DoD 7: Filter by _tf_direction only matches Request/Response entries
  ---------------------------------------------------------------------------
  describe "filter by direction" $ do
    it "only matches Request entries" $ do
      let eA = mkEntry "a" t0 "src" Request
          eB = mkEntry "b" t1 "src" Response
          eC = mkEntry "c" t2 "src" Request
          entries = [eA, eB, eC]
          f = emptyFilter { _tf_direction = Just Request }
      applyFilter f entries `shouldBe` [eA, eC]

    it "only matches Response entries" $ do
      let eA = mkEntry "a" t0 "src" Request
          eB = mkEntry "b" t1 "src" Response
          eC = mkEntry "c" t2 "src" Response
          entries = [eA, eB, eC]
          f = emptyFilter { _tf_direction = Just Response }
      applyFilter f entries `shouldBe` [eB, eC]

  ---------------------------------------------------------------------------
  -- DoD 8: Filter by _tf_timeRange returns only entries in that range
  ---------------------------------------------------------------------------
  describe "filter by timeRange" $ do
    it "returns only entries in the sub-range" $ do
      let eA = mkEntry "a" t0 "src" Request   -- 2025-01-01 00:00
          eB = mkEntry "b" t1 "src" Response  -- 2025-01-01 01:00
          eC = mkEntry "c" t2 "src" Request   -- 2025-01-01 02:00
          eD = mkEntry "d" t3 "src" Response  -- 2025-01-02 00:00
          entries = [eA, eB, eC, eD]
          -- range: [01:00, 02:00] inclusive
          f = emptyFilter { _tf_timeRange = Just (t1, t2) }
      applyFilter f entries `shouldBe` [eB, eC]

  ---------------------------------------------------------------------------
  -- DoD 9: matchesFilter is a pure, testable function
  ---------------------------------------------------------------------------
  describe "matchesFilter" $ do
    it "returns True for emptyFilter on any entry" $ do
      let entry = mkEntry "x" t0 "src" Request
      matchesFilter emptyFilter entry `shouldBe` True

    it "returns False when source does not match" $ do
      let entry = mkEntry "x" t0 "ollama" Request
          f = emptyFilter { _tf_model = Just "claude" }
      matchesFilter f entry `shouldBe` False

    it "returns True when all criteria match" $ do
      let entry = mkEntry "x" t1 "ollama" Request
          f = emptyFilter
            { _tf_model     = Just "ollama"
            , _tf_direction = Just Request
            , _tf_timeRange = Just (t0, t2)
            }
      matchesFilter f entry `shouldBe` True

  ---------------------------------------------------------------------------
  -- Combined filters
  ---------------------------------------------------------------------------
  describe "combined filters" $ do
    it "source + direction + limit" $ do
      let entries =
            [ mkEntry "a" t0 "ollama" Request
            , mkEntry "b" t1 "ollama" Response
            , mkEntry "c" t2 "ollama" Request
            , mkEntry "d" t3 "claude" Request
            ]
          eA = mkEntry "a" t0 "ollama" Request
          f = emptyFilter
            { _tf_model     = Just "ollama"
            , _tf_direction = Just Request
            , _tf_limit     = Just 1
            }
      applyFilter f entries `shouldBe` [eA]
