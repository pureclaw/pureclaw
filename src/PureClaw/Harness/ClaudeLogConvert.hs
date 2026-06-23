-- | A PURE converter from @claude-code@ JSONL session-log lines to
-- 'TranscriptEntry' values (WU3).
--
-- A spawned @claude-code@ harness records its conversation to an on-disk
-- @<uuid>.jsonl@ file (one JSON object per line; see
-- @docs/harness-jsonl-capture-spike.md@ §D0.5). 'convertLine' turns ONE such
-- line into the 'TranscriptEntry' shape PureClaw's transcript/UI already
-- understands, so a harness session can be surfaced exactly like a native
-- provider session. This module is the data source for WU5's live tailer.
--
-- == Purity & totality
--
-- There is NO IO here — just a total decode-and-map. 'convertLine' NEVER
-- throws on ANY input: malformed JSON, wrong-typed fields, missing fields,
-- unknown event @type@, or an unparseable timestamp all yield 'Nothing'
-- (the line is skipped). Lookups go through 'KeyMap.lookup' / 'fromJSON';
-- no partial functions (@head@, @fromJust@, partial record access) appear.
--
-- == Mapping (matches @frontend\/src\/App.tsx@ — D3.1)
--
--   * An @assistant@ event becomes a 'Response' entry whose payload is an
--     object with top-level @content@ (lifted from @message.content@),
--     @usage@ (from @message.usage@) and @model@ (from @message.model@), and
--     whose '_te_model' column is @Just message.model@. This is exactly what
--     the @App.tsx@ Response parser reads (@parsed.content@ / @parsed.usage@ /
--     @e.model@).
--   * A @user@ event with text\/string content becomes a 'Request' entry whose
--     payload is @{messages:[{role:"user",content:[{type:"text",text}]}]}@.
--     String content is normalized to a single-element @text@ block so the
--     @App.tsx@ @extractTextFromContent@ (which expects an array) reads it.
--   * A @user@ event whose @message.content[]@ holds @tool_result@ blocks
--     becomes a 'Request' entry that preserves those blocks
--     (@type@\/@tool_use_id@\/@content@\/@is_error@) inside
--     @messages[].content[]@, so @App.tsx@ @buildToolResultIndex@ joins them
--     by @tool_use_id@. (Text and tool_result blocks share one code path.)
--   * @thinking@ blocks are carried through into the payload @content@ so
--     WU8's renderer can show them (collapsed).
--   * Every other event @type@ (mode, permission-mode, system,
--     file-history-snapshot, …) and every malformed line yields 'Nothing'.
--
-- == De-dup obligation (D3.4)
--
-- '_te_id' and '_te_correlationId' are both set to the JSONL @uuid@, and
-- conversion is a pure function of the line, so converting the same event
-- twice yields the same '_te_id'. WU5\/WU7 MUST de-duplicate emitted entries
-- by '_te_id' (the on-disk log is read from offset 0 on every view-open, so
-- the same line will be seen more than once).
--
-- == Sanitization (D3.5)
--
-- All text destined for the payload (assistant @text@\/@thinking@, user text,
-- and @tool_result@ @content@) is passed through the SAME
-- 'PureClaw.Handles.Harness.sanitizeHarnessOutput' used for tmux scrollback
-- broadcast — imported, never re-implemented — so control sequences are
-- stripped identically on both paths.
module PureClaw.Harness.ClaudeLogConvert
  ( -- * Conversion
    convertLine
    -- * Payload encoder (exported for golden tests)
  , encodeValuePayload
    -- * Total JSONL helpers (re-used by ClaudeLogProse — do not re-implement)
  , decodeObject
  , lookupText
  , lookupObject
  , sanitizeBlock
  ) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Vector qualified as V

import PureClaw.Handles.Harness (sanitizeHarnessOutput)
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , encodePayload
  )

-- | The harness label stamped on every converted entry's '_te_harness'.
harnessLabel :: Text
harnessLabel = "claude-code"

-- | Convert ONE claude-code JSONL line to a 'TranscriptEntry', or 'Nothing'
-- if the line is malformed, an unknown\/ignored event type, or is missing a
-- parseable timestamp. Total: never throws on any input. (D3.1 / D3.2)
convertLine :: ByteString -> Maybe TranscriptEntry
convertLine raw = do
  obj <- decodeObject raw
  typ <- lookupText "type" obj
  case typ of
    "assistant" -> convertAssistant obj
    "user"      -> convertUser obj
    _           -> Nothing  -- mode, permission-mode, system, snapshots, … (D3.2)

-- | An @assistant@ event → 'Response' entry. (D3.1)
convertAssistant :: KeyMap Value -> Maybe TranscriptEntry
convertAssistant obj = do
  uuid <- lookupText "uuid" obj
  tstamp <- lookupTimestamp obj
  message <- lookupObject "message" obj
  let model = lookupText "model" message
      contentBlocks = case KeyMap.lookup "content" message of
        Just (Array blocks) -> V.toList (V.map sanitizeBlock blocks)
        _                   -> []
      usageField = maybe [] (\u -> [("usage", u)]) (KeyMap.lookup "usage" message)
      modelField = maybe [] (\m -> [("model", String m)]) model
      payload = objectOf $
        [("content", Array (V.fromList contentBlocks))]
          <> usageField
          <> modelField
  pure (mkEntry uuid tstamp model Response payload)

-- | A @user@ event → 'Request' entry. Handles both plain text\/string content
-- and @tool_result@ content through one normalization path. (D3.1)
convertUser :: KeyMap Value -> Maybe TranscriptEntry
convertUser obj = do
  uuid <- lookupText "uuid" obj
  tstamp <- lookupTimestamp obj
  message <- lookupObject "message" obj
  let content = KeyMap.lookup "content" message
      normalized = normalizeUserContent content
      payload = objectOf
        [ ("messages", Array (V.singleton (objectOf
            [ ("role", String "user")
            , ("content", Array (V.fromList normalized))
            ])))
        ]
  pure (mkEntry uuid tstamp Nothing Request payload)

-- | Normalize a @user@ event's @message.content@ into a list of content
-- blocks suitable for the payload:
--
--   * a JSON string becomes a single @{type:"text",text:<sanitized>}@ block;
--   * an array is mapped block-by-block through 'sanitizeBlock' (which
--     sanitizes @text@\/@thinking@\/@content@ string fields and preserves
--     @tool_result@ structure so @buildToolResultIndex@ can join it);
--   * anything else (missing\/null\/number) becomes an empty list.
normalizeUserContent :: Maybe Value -> [Value]
normalizeUserContent = \case
  Just (String s) ->
    [ objectOf
        [ ("type", String "text")
        , ("text", String (sanitizeHarnessOutput s))
        ]
    ]
  Just (Array blocks) -> V.toList (V.map sanitizeBlock blocks)
  _ -> []

-- | Sanitize the human-visible string fields of one content block, preserving
-- all other fields (and non-object blocks) untouched. Applies the SAME
-- 'sanitizeHarnessOutput' used for tmux broadcast (D3.5) to @text@,
-- @thinking@, and @content@ string fields. @tool_result@ structure
-- (@type@\/@tool_use_id@\/@is_error@\/@content@) is preserved so
-- @App.tsx buildToolResultIndex@ can join by @tool_use_id@.
sanitizeBlock :: Value -> Value
sanitizeBlock (Object km) = Object (KeyMap.mapWithKey sanitizeField km)
  where
    sanitizeField k v
      | Key.toText k `elem` sanitizedFields = sanitizeStringValue v
      | otherwise                           = v
sanitizeBlock other = other

-- | Field names whose string values are human-visible and must be sanitized.
sanitizedFields :: [Text]
sanitizedFields = ["text", "thinking", "content"]

-- | Apply 'sanitizeHarnessOutput' to a JSON string; leave non-strings as-is.
sanitizeStringValue :: Value -> Value
sanitizeStringValue (String s) = String (sanitizeHarnessOutput s)
sanitizeStringValue v          = v

-- | Assemble a 'TranscriptEntry' with the WU3-fixed columns: '_te_harness' is
-- always @Just "claude-code"@, '_te_id' and '_te_correlationId' are both the
-- JSONL @uuid@ (de-dup key — see module header, D3.4), no duration, empty
-- metadata.
mkEntry :: Text -> UTCTime -> Maybe Text -> Direction -> Value -> TranscriptEntry
mkEntry uuid tstamp model dir payload = TranscriptEntry
  { _te_id            = uuid
  , _te_timestamp     = tstamp
  , _te_harness       = Just harnessLabel
  , _te_model         = model
  , _te_direction     = dir
  , _te_payload       = encodeValuePayload payload
  , _te_durationMs    = Nothing
  , _te_correlationId = uuid
  , _te_metadata      = Map.empty
  }

-- ───────────────────────────── total helpers ─────────────────────────────

-- | Decode a line into a top-level JSON object, or 'Nothing' if it is not
-- valid JSON or not an object (e.g. an array, bare string, number, or the
-- intentionally-malformed fixture line).
decodeObject :: ByteString -> Maybe (KeyMap Value)
decodeObject raw =
  case Aeson.decodeStrict raw of
    Just (Object km) -> Just km
    _                -> Nothing

-- | Total lookup of a string-valued field.
lookupText :: Text -> KeyMap Value -> Maybe Text
lookupText k km =
  case KeyMap.lookup (Key.fromText k) km of
    Just (String t) -> Just t
    _               -> Nothing

-- | Total lookup of an object-valued field.
lookupObject :: Text -> KeyMap Value -> Maybe (KeyMap Value)
lookupObject k km =
  case KeyMap.lookup (Key.fromText k) km of
    Just (Object o) -> Just o
    _               -> Nothing

-- | Parse the event @timestamp@ as an ISO-8601 'UTCTime' via aeson's own
-- 'FromJSON' instance (a total, format-checked path). A missing or
-- unparseable timestamp yields 'Nothing' — a real claude log always carries
-- a parseable timestamp, so an absent one means the line is not a turn we can
-- faithfully place in the transcript and is deliberately skipped. (D3.1)
lookupTimestamp :: KeyMap Value -> Maybe UTCTime
lookupTimestamp km = do
  v <- KeyMap.lookup "timestamp" km
  case Aeson.fromJSON v of
    Aeson.Success u -> Just u
    Aeson.Error _   -> Nothing

-- | Build a JSON object from key\/value pairs. Centralizes the
-- 'Key.fromText' conversion so call sites read in plain 'Text'.
objectOf :: [(Text, Value)] -> Value
objectOf = Object . KeyMap.fromList . map (first Key.fromText)

-- | The production payload encoder: serialize a JSON 'Value' with aeson's
-- 'Aeson.encode' (deterministic, lexicographically-keyed objects) and decode
-- the bytes to '_te_payload' 'Text' via the SAME 'encodePayload' the
-- transcript layer uses. Exported so golden tests can build the EXPECTED
-- payload with this exact encoder, making the comparison byte-for-byte. (D3.3)
encodeValuePayload :: Value -> Text
encodeValuePayload = encodePayload . BL.toStrict . Aeson.encode
