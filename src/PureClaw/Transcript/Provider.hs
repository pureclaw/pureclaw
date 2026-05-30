module PureClaw.Transcript.Provider
  ( -- * Transcript-logging provider wrapper
    mkTranscriptProvider
    -- * Header redaction
  , redactHeaders
  ) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time

import PureClaw.Core.Types
import PureClaw.Handles.Transcript
import PureClaw.Providers.Class
import PureClaw.Transcript.Types

-- | Internal newtype wrapping a provider with transcript logging. The tuple
-- carries the transcript handle, the model name (recorded as @_te_model@),
-- the optional per-message sender (recorded into Request @_te_metadata@
-- under @"source"@), and the wrapped provider.
newtype TranscriptProvider = TranscriptProvider
  { _tp_inner :: (TranscriptHandle, Text, Maybe MessageSource, SomeProvider) }

instance Provider TranscriptProvider where
  complete (TranscriptProvider (th, source, msgSource, inner)) req = do
    corrId <- generateId
    reqId <- generateId
    now <- getCurrentTime
    -- Serialize and redact the request
    let reqBytes = LBS.toStrict (Aeson.encode req)
        redacted = redactHeaders (decodeUtf8Lenient reqBytes)
        reqEntry = TranscriptEntry
          { _te_id            = reqId
          , _te_timestamp     = now
          , _te_harness       = Nothing
          , _te_model         = Just source
          , _te_direction     = Request
          , _te_payload       = encodePayload (encodeUtf8Strict redacted)
          , _te_durationMs    = Nothing
          , _te_correlationId = corrId
          , _te_metadata      = sourceMeta msgSource
          }
    _th_record th reqEntry
    -- Call the inner provider
    resp <- complete inner req
    -- Log the response (not redacted)
    respId <- generateId
    respNow <- getCurrentTime
    let respBytes = LBS.toStrict (Aeson.encode resp)
        respMeta = buildResponseMetadata resp
        respEntry = TranscriptEntry
          { _te_id            = respId
          , _te_timestamp     = respNow
          , _te_harness       = Nothing
          , _te_model         = Just source
          , _te_direction     = Response
          , _te_payload       = encodePayload respBytes
          , _te_durationMs    = Nothing
          , _te_correlationId = corrId
          , _te_metadata      = respMeta
          }
    _th_record th respEntry
    pure resp

  completeStream (TranscriptProvider (th, source, msgSource, inner)) req callback = do
    corrId <- generateId
    reqId <- generateId
    now <- getCurrentTime
    -- Serialize and redact the request
    let reqBytes = LBS.toStrict (Aeson.encode req)
        redacted = redactHeaders (decodeUtf8Lenient reqBytes)
        reqEntry = TranscriptEntry
          { _te_id            = reqId
          , _te_timestamp     = now
          , _te_harness       = Nothing
          , _te_model         = Just source
          , _te_direction     = Request
          , _te_payload       = encodePayload (encodeUtf8Strict redacted)
          , _te_durationMs    = Nothing
          , _te_correlationId = corrId
          , _te_metadata      = sourceMeta msgSource
          }
    _th_record th reqEntry
    -- Wrap the callback to capture StreamDone
    doneRef <- newIORef False
    completeStream inner req $ \ev -> do
      callback ev
      case ev of
        StreamDone resp -> do
          alreadyDone <- readIORef doneRef
          if alreadyDone then pure ()
          else do
            writeIORef doneRef True
            respId <- generateId
            respNow <- getCurrentTime
            let respBytes = LBS.toStrict (Aeson.encode resp)
                respMeta = buildResponseMetadata resp
                respEntry = TranscriptEntry
                  { _te_id            = respId
                  , _te_timestamp     = respNow
                  , _te_harness       = Nothing
                  , _te_model         = Just source
                  , _te_direction     = Response
                  , _te_payload       = encodePayload respBytes
                  , _te_durationMs    = Nothing
                  , _te_correlationId = corrId
                  , _te_metadata      = respMeta
                  }
            _th_record th respEntry
        _ -> pure ()

  listModels (TranscriptProvider (_th, _source, _msgSource, inner)) = listModels inner

-- | Build the Request metadata map from an optional per-message sender.
-- When 'Just', the sender is encoded under the @"source"@ key using the
-- shared 'MessageSource' codec; when 'Nothing', no key is written. This is
-- applied to Request entries ONLY — Response entries describe the reply,
-- not the inbound sender.
sourceMeta :: Maybe MessageSource -> Map.Map Text Aeson.Value
sourceMeta = maybe Map.empty (Map.singleton "source" . Aeson.toJSON)

-- | Wrap a 'SomeProvider' with transcript logging. Every @complete@ and
-- @completeStream@ call records a Request entry (with redacted headers)
-- and a Response entry (with token usage metadata).
--
-- The 'Maybe MessageSource' argument is the per-message sender: when 'Just',
-- it is written into the Request entry's @_te_metadata@ under the @"source"@
-- key (Response entries are never tagged). Pass 'Nothing' for turns with no
-- inbound message (e.g. @\/bg@ and web completions). The sender id lives in
-- the on-disk metadata only and is never broadcast.
mkTranscriptProvider :: TranscriptHandle -> Text -> Maybe MessageSource -> SomeProvider -> SomeProvider
mkTranscriptProvider th source msgSource inner =
  MkProvider (TranscriptProvider (th, source, msgSource, inner))

-- | Build metadata map from a 'CompletionResponse'.
-- Includes model name and token usage when available.
buildResponseMetadata :: CompletionResponse -> Map.Map Text Aeson.Value
buildResponseMetadata resp =
  let modelMeta = Map.singleton "model" (Aeson.String (unModelId (_crsp_model resp)))
      usageMeta = case _crsp_usage resp of
        Nothing -> Map.empty
        Just (Usage inp outp) -> Map.fromList
          [ ("input_tokens",  Aeson.Number (fromIntegral inp))
          , ("output_tokens", Aeson.Number (fromIntegral outp))
          ]
  in Map.union modelMeta usageMeta

-- | Redact sensitive header values from JSON-serialized text.
-- Matches patterns like @"Authorization": "Bearer sk-..."@ and replaces
-- the value portion.
redactHeaders :: Text -> Text
redactHeaders = redactBearer . redactApiKey . redactAnthropicKey

redactBearer :: Text -> Text
redactBearer t =
  let parts = T.breakOnAll "\"Authorization\": \"Bearer " t
  in case parts of
    [] -> t
    _  -> foldParts "\"Authorization\": \"Bearer " "\"Authorization\": \"Bearer <REDACTED>\"" t

redactApiKey :: Text -> Text
redactApiKey t =
  let parts = T.breakOnAll "\"x-api-key\": \"" t
  in case parts of
    [] -> t
    _  -> foldParts "\"x-api-key\": \"" "\"x-api-key\": \"<REDACTED>\"" t

redactAnthropicKey :: Text -> Text
redactAnthropicKey t =
  let parts = T.breakOnAll "\"anthropic-api-key\": \"" t
  in case parts of
    [] -> t
    _  -> foldParts "\"anthropic-api-key\": \"" "\"anthropic-api-key\": \"<REDACTED>\"" t

-- | Replace @prefix<value>"@ with @replacement@ for each occurrence.
-- The value is everything from after the prefix to the next unescaped @"@.
foldParts :: Text -> Text -> Text -> Text
foldParts prefix replacement = go
  where
    go t = case T.breakOn prefix t of
      (before, rest)
        | T.null rest -> before
        | otherwise ->
            let afterPrefix = T.drop (T.length prefix) rest
                -- Find the closing quote (skip the prefix, find next ")
                afterValue = dropToClosingQuote afterPrefix
            in before <> replacement <> go afterValue

-- | Drop characters until we find the closing unescaped double-quote.
dropToClosingQuote :: Text -> Text
dropToClosingQuote t = case T.uncons t of
  Nothing       -> T.empty
  Just ('\\', rest) -> case T.uncons rest of
    Nothing        -> T.empty
    Just (_, rest') -> dropToClosingQuote rest'  -- skip escaped char
  Just ('"', rest) -> rest  -- found closing quote
  Just (_, rest)   -> dropToClosingQuote rest

-- | Generate a simple unique identifier using the current time in picoseconds.
-- Not a true UUID but sufficient for correlation within a single process.
generateId :: IO Text
generateId = do
  now <- getCurrentTime
  let picos = diffTimeToPicoseconds (utctDayTime now)
      dayNum = toModifiedJulianDay (utctDay now)
  pure (T.pack (show dayNum) <> "-" <> T.pack (show picos))

-- | Decode UTF-8 bytes to Text, replacing invalid sequences.
decodeUtf8Lenient :: BS.ByteString -> Text
decodeUtf8Lenient = TE.decodeUtf8Lenient

-- | Encode Text to UTF-8 bytes.
encodeUtf8Strict :: Text -> BS.ByteString
encodeUtf8Strict = TE.encodeUtf8
