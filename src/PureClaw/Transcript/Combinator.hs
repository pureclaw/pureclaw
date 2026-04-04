module PureClaw.Transcript.Combinator
  ( withTranscript
  ) where

import Control.Exception
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID

import PureClaw.Handles.Transcript
import PureClaw.Transcript.Types

-- | Wrap a @ByteString -> IO ByteString@ function with automatic transcript
-- logging. Records a 'Request' entry before the call and a 'Response' entry
-- after, linked by a shared correlation UUID. Exceptions from the wrapped
-- function are caught, logged with @"error"@ metadata, and re-thrown.
-- Transcript write failures are silently dropped so the actual call result
-- always takes priority over logging.
withTranscript
  :: TranscriptHandle
  -> Text                          -- ^ source name
  -> (ByteString -> IO ByteString) -- ^ raw call
  -> ByteString                    -- ^ input
  -> IO ByteString                 -- ^ output (also logged)
withTranscript th source fn input = do
  correlationId <- UUID.toText <$> UUID.nextRandom
  entryId1 <- UUID.toText <$> UUID.nextRandom
  startTime <- getCurrentTime

  let reqEntry = TranscriptEntry
        { _te_id            = entryId1
        , _te_timestamp     = startTime
        , _te_source        = source
        , _te_direction     = Request
        , _te_payload       = encodePayload input
        , _te_durationMs    = Nothing
        , _te_correlationId = correlationId
        , _te_metadata      = Map.empty
        }

  -- Record request; swallow transcript write failures
  safeRecord th reqEntry

  -- Call the wrapped function, catching exceptions
  result <- try (fn input)

  endTime <- getCurrentTime
  let durationMs = utcTimeToDurationMs startTime endTime
  entryId2 <- UUID.toText <$> UUID.nextRandom

  case result of
    Right output -> do
      let respEntry = TranscriptEntry
            { _te_id            = entryId2
            , _te_timestamp     = endTime
            , _te_source        = source
            , _te_direction     = Response
            , _te_payload       = encodePayload output
            , _te_durationMs    = Just durationMs
            , _te_correlationId = correlationId
            , _te_metadata      = Map.empty
            }
      safeRecord th respEntry
      pure output

    Left (ex :: SomeException) -> do
      let respEntry = TranscriptEntry
            { _te_id            = entryId2
            , _te_timestamp     = endTime
            , _te_source        = source
            , _te_direction     = Response
            , _te_payload       = encodePayload mempty
            , _te_durationMs    = Just durationMs
            , _te_correlationId = correlationId
            , _te_metadata      = Map.singleton "error" (Aeson.String (T.pack (show ex)))
            }
      safeRecord th respEntry
      throwIO ex

-- | Record an entry, silently dropping any exceptions from the transcript handle.
safeRecord :: TranscriptHandle -> TranscriptEntry -> IO ()
safeRecord th entry =
  _th_record th entry `catch` \(_ :: SomeException) -> pure ()

-- | Compute duration in milliseconds between two UTCTimes.
utcTimeToDurationMs :: UTCTime -> UTCTime -> Int
utcTimeToDurationMs start end =
  let diffSec = realToFrac (diffUTCTime end start) :: Double
  in  round (diffSec * 1000)
