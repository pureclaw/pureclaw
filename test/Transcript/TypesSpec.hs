module Transcript.TypesSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack)
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
  , _te_source        = src
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
      let entry = (mkEntry "id-2" t1 "claude-code" Response)
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
  -- DoD 3: Base64 payload encoding preserves arbitrary bytes (property test)
  ---------------------------------------------------------------------------
  describe "Base64 payload encoding" $ do
    it "preserves arbitrary bytes (property)" $
      property $ \(bs :: [Word8]) -> do
        let raw = BS.pack bs
        decodePayload (encodePayload raw) `shouldBe` Just raw

    it "decodePayload returns Nothing on invalid base64" $
      decodePayload "not!valid!base64!!!" `shouldBe` Nothing

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
  -- DoD 5: Filter by _tf_source only matches entries with that source
  ---------------------------------------------------------------------------
  describe "filter by source" $ do
    it "only matches entries with the given source" $ do
      let entries =
            [ mkEntry "a" t0 "ollama" Request
            , mkEntry "b" t1 "claude" Response
            , mkEntry "c" t2 "ollama" Response
            ]
          f = emptyFilter { _tf_source = Just "ollama" }
      applyFilter f entries `shouldBe` [entries !! 0, entries !! 2]

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
      let entries =
            [ mkEntry "a" t0 "src" Request
            , mkEntry "b" t1 "src" Response
            , mkEntry "c" t2 "src" Request
            ]
          f = emptyFilter { _tf_direction = Just Request }
      applyFilter f entries `shouldBe` [entries !! 0, entries !! 2]

    it "only matches Response entries" $ do
      let entries =
            [ mkEntry "a" t0 "src" Request
            , mkEntry "b" t1 "src" Response
            , mkEntry "c" t2 "src" Response
            ]
          f = emptyFilter { _tf_direction = Just Response }
      applyFilter f entries `shouldBe` [entries !! 1, entries !! 2]

  ---------------------------------------------------------------------------
  -- DoD 8: Filter by _tf_timeRange returns only entries in that range
  ---------------------------------------------------------------------------
  describe "filter by timeRange" $ do
    it "returns only entries in the sub-range" $ do
      let entries =
            [ mkEntry "a" t0 "src" Request   -- 2025-01-01 00:00
            , mkEntry "b" t1 "src" Response  -- 2025-01-01 01:00
            , mkEntry "c" t2 "src" Request   -- 2025-01-01 02:00
            , mkEntry "d" t3 "src" Response  -- 2025-01-02 00:00
            ]
          -- range: [01:00, 02:00] inclusive
          f = emptyFilter { _tf_timeRange = Just (t1, t2) }
      applyFilter f entries `shouldBe` [entries !! 1, entries !! 2]

  ---------------------------------------------------------------------------
  -- DoD 9: matchesFilter is a pure, testable function
  ---------------------------------------------------------------------------
  describe "matchesFilter" $ do
    it "returns True for emptyFilter on any entry" $ do
      let entry = mkEntry "x" t0 "src" Request
      matchesFilter emptyFilter entry `shouldBe` True

    it "returns False when source does not match" $ do
      let entry = mkEntry "x" t0 "ollama" Request
          f = emptyFilter { _tf_source = Just "claude" }
      matchesFilter f entry `shouldBe` False

    it "returns True when all criteria match" $ do
      let entry = mkEntry "x" t1 "ollama" Request
          f = emptyFilter
            { _tf_source    = Just "ollama"
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
          f = emptyFilter
            { _tf_source    = Just "ollama"
            , _tf_direction = Just Request
            , _tf_limit     = Just 1
            }
      applyFilter f entries `shouldBe` [entries !! 0]
