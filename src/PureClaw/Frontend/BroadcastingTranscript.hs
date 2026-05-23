-- | Broadcasting transcript decorator — WU2.
--
-- Wraps a 'TranscriptHandle' so that every '_th_record' call publishes
-- @EntryRecorded@ and @ActivityChanged (SaEntryAt _)@ events to a
-- 'StreamBroker' in addition to writing to the inner handle. This is the
-- standard helper for every transcript write-path in PureClaw — direct use
-- of 'mkFileTranscriptHandle' is forbidden outside the allowlist enforced
-- by @scripts/lint-transcript-handles.sh@ (D6).
--
-- /AsyncCancelled discipline./ On 'AsyncCancelled' from the inner handle
-- or the broker publish, the exception is re-raised so that bracket-style
-- cleanup runs (project-wide invariant; see "PureClaw.Tab.Harness" and
-- 'PureClaw.Transcript.Combinator.safeRecord' for the canonical pattern).
-- Non-async exceptions from the inner handle are caught and logged via
-- '_lh_logWarn'; the wrapper still publishes to the broker so subscribers
-- remain consistent with the in-memory observation stream (D34 — the
-- documented divergence from the inner's silent-drop semantics).
--
-- /Payload cap./ Before publish, the transcript entry is passed through
-- 'capPayload' which truncates the payload text if its UTF-8 byte length
-- exceeds the broker's configured @_bc_maxEventBytes@. Truncated entries
-- carry a @"truncated": true@ flag in their metadata so subscribers can
-- render an indicator. The on-disk record is /not/ truncated — only the
-- broker-published view is.
module PureClaw.Frontend.BroadcastingTranscript
  ( mkBroadcastingFileTranscriptHandle
  , mkBroadcastingTranscriptHandle
  ) where

import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.StreamBroker
  ( BrokerConfig (..)
  , BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  )
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  , mkFileTranscriptHandle
  )
import PureClaw.Transcript.Types (TranscriptEntry (..))

-- | Open a new file-backed transcript handle that ALSO publishes to a
-- broker. The standard helper used by every transcript write-path call
-- site ('mkSessionHandle', 'resumeSession', 'handleSend'). When the broker
-- is 'Nothing' no decorator is installed and the result is the bare
-- 'mkFileTranscriptHandle' — the no-broker path is preserved for one-off
-- scripts and tests.
mkBroadcastingFileTranscriptHandle
  :: Maybe StreamBroker
  -> SessionId
  -> LogHandle
  -> FilePath
  -> IO TranscriptHandle
mkBroadcastingFileTranscriptHandle mBroker sid logger path = case mBroker of
  Nothing     -> mkFileTranscriptHandle logger path
  Just broker -> do
    inner <- mkFileTranscriptHandle logger path
    pure (mkBroadcastingTranscriptHandle broker sid logger inner)

-- | Wrap an existing 'TranscriptHandle' to publish broker events on
-- record. See the module Haddock for the full semantics (AsyncCancelled
-- discipline, disk-failure logging, payload capping).
mkBroadcastingTranscriptHandle
  :: StreamBroker
  -> SessionId
  -> LogHandle
  -> TranscriptHandle
  -> TranscriptHandle
mkBroadcastingTranscriptHandle broker sid logger inner = inner
  { _th_record = \entry -> do
      let cap           = _bc_maxEventBytes (_streamBroker_config broker)
          truncatedEntry = capPayload cap entry
      r <- try @SomeException (_th_record inner entry)
      case r of
        Right () -> publishSafely truncatedEntry
        Left e
          | Just AsyncCancelled <- fromException e -> throwIO e
          | otherwise -> do
              _lh_logWarn logger $
                "transcript disk-write failed; in-memory broker still notified "
                  <> "(entry="    <> _te_id entry
                  <> ", session=" <> unSessionId sid
                  <> "): "        <> T.pack (show e)
              publishSafely truncatedEntry
  }
  where
    publishSafely e = do
      r <- try @SomeException $ do
        _streamBroker_publish broker (EntryRecorded   sid e)
        _streamBroker_publish broker
          (ActivityChanged sid (SaEntryAt (_te_timestamp e)))
      case r of
        Right () -> pure ()
        Left ex
          | Just AsyncCancelled <- fromException ex -> throwIO ex
          | otherwise -> _lh_logWarn logger
              ("broker publish failed: " <> T.pack (show ex))

-- | Truncate a 'TranscriptEntry' if its payload's UTF-8 byte length exceeds
-- the broker's per-event cap. On truncation, marks the entry's metadata
-- with @"truncated" -> true@ so subscribers can render a "[truncated]"
-- badge.
--
-- Per-event size capping is enforced at the broker boundary (this
-- decorator) rather than inside the broker itself; see the design doc
-- §Broker for the rationale.
capPayload :: Int -> TranscriptEntry -> TranscriptEntry
capPayload cap entry
  | BS.length payloadBytes <= cap = entry
  | otherwise = entry
      { _te_payload  = truncatedText
      , _te_metadata = Map.insert "truncated" (Aeson.Bool True)
                                  (_te_metadata entry)
      }
  where
    payloadBytes  = TE.encodeUtf8 (_te_payload entry)
    truncatedText = TE.decodeUtf8Lenient (BS.take cap payloadBytes)
