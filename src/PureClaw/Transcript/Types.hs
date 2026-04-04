module PureClaw.Transcript.Types
  ( -- * Direction
    Direction (..)
    -- * Transcript entry
  , TranscriptEntry (..)
    -- * Filter
  , TranscriptFilter (..)
  , emptyFilter
  , matchesFilter
  , applyFilter
    -- * Base64 payload helpers
  , encodePayload
  , decodePayload
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import GHC.Generics (Generic)

-- | Direction of an API call.
data Direction = Request | Response
  deriving stock (Show, Eq, Generic)

instance ToJSON Direction
instance FromJSON Direction

-- | A single transcript entry recording one request or response.
data TranscriptEntry = TranscriptEntry
  { _te_id            :: !Text          -- ^ UUID
  , _te_timestamp     :: !UTCTime
  , _te_source        :: !Text          -- ^ e.g. "ollama/llama3", "claude-code"
  , _te_direction     :: !Direction
  , _te_payload       :: !Text          -- ^ Base64-encoded bytes
  , _te_durationMs    :: !(Maybe Int)   -- ^ present on Response entries only
  , _te_correlationId :: !Text          -- ^ shared UUID linking Request to its Response
  , _te_metadata      :: !(Map Text Value) -- ^ extensible
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON TranscriptEntry
instance FromJSON TranscriptEntry

-- | Record-of-Maybe filter; all fields AND together.
data TranscriptFilter = TranscriptFilter
  { _tf_source    :: !(Maybe Text)
  , _tf_direction :: !(Maybe Direction)
  , _tf_timeRange :: !(Maybe (UTCTime, UTCTime))
  , _tf_limit     :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

-- | A filter that matches all entries with no limit.
emptyFilter :: TranscriptFilter
emptyFilter = TranscriptFilter
  { _tf_source    = Nothing
  , _tf_direction = Nothing
  , _tf_timeRange = Nothing
  , _tf_limit     = Nothing
  }

-- | Pure predicate: does an entry match the non-limit filter criteria?
-- '_tf_limit' is intentionally NOT checked here — it is applied by 'applyFilter'.
matchesFilter :: TranscriptFilter -> TranscriptEntry -> Bool
matchesFilter tf entry = and
  [ maybe True (\s -> _te_source entry == s)    (_tf_source tf)
  , maybe True (\d -> _te_direction entry == d)  (_tf_direction tf)
  , maybe True (\(lo, hi) ->
      let ts = _te_timestamp entry
      in  ts >= lo && ts <= hi)                  (_tf_timeRange tf)
  ]

-- | Apply the filter to a list of entries.
-- First filters by 'matchesFilter', then applies '_tf_limit' (take N).
applyFilter :: TranscriptFilter -> [TranscriptEntry] -> [TranscriptEntry]
applyFilter tf = applyLimit . filter (matchesFilter tf)
  where
    applyLimit = maybe id take (_tf_limit tf)

-- | Encode raw bytes to Base64 text for storage in '_te_payload'.
encodePayload :: ByteString -> Text
encodePayload = TE.decodeUtf8 . B64.encode

-- | Decode Base64 text back to raw bytes. Returns 'Nothing' on invalid input.
decodePayload :: Text -> Maybe ByteString
decodePayload t = case B64.decode (TE.encodeUtf8 t) of
  Right bs -> Just bs
  Left _   -> Nothing
