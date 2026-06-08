{-# LANGUAGE OverloadedStrings #-}

-- | Tests for 'PureClaw.Harness.ClaudeLogConvert.convertLine': the PURE
-- converter from claude-code JSONL log lines to 'TranscriptEntry' values
-- (WU3). The golden tests build the EXPECTED entry by constructing the same
-- aeson 'Value' and serializing it with the SAME encoder production uses
-- ('encodeValuePayload'), so the payload comparison is byte-for-byte.
module Harness.ClaudeLogConvertSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Test.Hspec

import PureClaw.Handles.Harness (sanitizeHarnessOutput)
import PureClaw.Harness.ClaudeLogConvert (convertLine, encodeValuePayload)
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  )

-- | Path to the committed fixture (single source of truth for inputs).
fixturePath :: FilePath
fixturePath = "test/fixtures/claude-jsonl/events.jsonl"

-- | Read the fixture, splitting into one ByteString per JSONL line.
readFixtureLines :: IO [ByteString]
readFixtureLines = do
  bs <- BS.readFile fixturePath
  pure (BC.lines bs)

-- | Safe 0-based fixture indexing. Avoids the partial @(!!)@ \/ @head@; an
-- out-of-range index yields an obviously-wrong sentinel line so the
-- assertion fails loudly rather than throwing.
nth :: Int -> [ByteString] -> ByteString
nth i xs = case drop i xs of
  (x : _) -> x
  []      -> "<<fixture index out of range>>"

-- | Parse an ISO-8601 timestamp in the test (mirrors production's expectation
-- but uses an independent path so the golden does not become tautological on
-- the timestamp column).
ts :: Text -> UTCTime
ts t =
  case iso8601ParseM (T.unpack t) of
    Just u -> u
    Nothing -> error ("test fixture timestamp did not parse: " <> T.unpack t)

spec :: Spec
spec = do
  describe "convertLine — totality (D3.2)" $ do
    it "returns Nothing on a non-JSON / malformed line" $
      convertLine "this is not json {{{{" `shouldBe` Nothing

    it "returns Nothing on the empty line" $
      convertLine "" `shouldBe` Nothing

    it "returns Nothing on truncated JSON" $
      convertLine "{\"type\":\"assistant\",\"uuid\":\"x\"" `shouldBe` Nothing

    it "returns Nothing on a metadata 'mode' line (unknown type)" $
      convertLine modeLine `shouldBe` Nothing

    it "returns Nothing on a 'file-history-snapshot' line (unknown type)" $
      convertLine fileHistoryLine `shouldBe` Nothing

    it "returns Nothing when the timestamp is missing" $
      convertLine assistantNoTimestamp `shouldBe` Nothing

    it "returns Nothing when the timestamp is unparseable" $
      convertLine assistantBadTimestamp `shouldBe` Nothing

    it "never throws on arbitrary wrong-typed fields" $ do
      convertLine "{\"type\":42}" `shouldBe` Nothing
      convertLine "{\"type\":\"assistant\",\"timestamp\":42}" `shouldBe` Nothing
      convertLine "[1,2,3]" `shouldBe` Nothing
      convertLine "\"just a string\"" `shouldBe` Nothing
      convertLine "12345" `shouldBe` Nothing
      convertLine "null" `shouldBe` Nothing

  describe "convertLine — fixture conversion (D3.1 / D3.3 golden)" $ do
    it "converts the user-text line to the expected Request entry (byte-for-byte payload)" $ do
      ls <- readFixtureLines
      convertLine (nth 0 ls) `shouldBe` Just expectedUserText

    it "converts the assistant (text+thinking+tool_use) line to the expected Response entry" $ do
      ls <- readFixtureLines
      convertLine (nth 1 ls) `shouldBe` Just expectedAssistant1

    it "converts the tool_result user line to the expected Request entry" $ do
      ls <- readFixtureLines
      convertLine (nth 2 ls) `shouldBe` Just expectedToolResult

    it "converts the second assistant (text-only) line" $ do
      ls <- readFixtureLines
      convertLine (nth 3 ls) `shouldBe` Just expectedAssistant2

    it "converts the final user-text (array content) line" $ do
      ls <- readFixtureLines
      convertLine (nth 7 ls) `shouldBe` Just expectedThanks

    it "skips the metadata and malformed fixture lines" $ do
      ls <- readFixtureLines
      convertLine (nth 4 ls) `shouldBe` Nothing  -- mode
      convertLine (nth 5 ls) `shouldBe` Nothing  -- file-history-snapshot
      convertLine (nth 6 ls) `shouldBe` Nothing  -- malformed (not json)

    it "converts exactly the 5 content lines from the whole fixture" $ do
      ls <- readFixtureLines
      length (mapMaybe convertLine ls) `shouldBe` 5

  describe "convertLine — column mapping (D3.1)" $ do
    it "sets _te_harness = Just \"claude-code\" on every entry" $ do
      ls <- readFixtureLines
      map _te_harness (mapMaybe convertLine ls)
        `shouldBe` replicate 5 (Just "claude-code")

    it "sets _te_model from message.model on assistant entries" $ do
      ls <- readFixtureLines
      _te_model <$> convertLine (nth 1 ls) `shouldBe` Just (Just "claude-opus-4-8")
      _te_model <$> convertLine (nth 3 ls) `shouldBe` Just (Just "claude-opus-4-8")

    it "leaves _te_model = Nothing on user/tool_result entries" $ do
      ls <- readFixtureLines
      _te_model <$> convertLine (nth 0 ls) `shouldBe` Just Nothing
      _te_model <$> convertLine (nth 2 ls) `shouldBe` Just Nothing

    it "sets direction Response for assistant, Request for user/tool_result" $ do
      ls <- readFixtureLines
      _te_direction <$> convertLine (nth 0 ls) `shouldBe` Just Request
      _te_direction <$> convertLine (nth 1 ls) `shouldBe` Just Response
      _te_direction <$> convertLine (nth 2 ls) `shouldBe` Just Request
      _te_direction <$> convertLine (nth 3 ls) `shouldBe` Just Response

    it "uses the JSONL uuid for both _te_id and _te_correlationId" $ do
      ls <- readFixtureLines
      _te_id <$> convertLine (nth 1 ls)
        `shouldBe` Just "22222222-2222-4222-8222-222222222222"
      _te_correlationId <$> convertLine (nth 1 ls)
        `shouldBe` Just "22222222-2222-4222-8222-222222222222"

  describe "convertLine — degenerate / edge shapes (totality + faithful fallbacks)" $ do
    it "assistant with no content/usage/model: empty content array, no usage/model keys, Nothing model" $ do
      let e = convertLine assistantMinimal
      _te_direction <$> e `shouldBe` Just Response
      _te_model <$> e `shouldBe` Just Nothing
      payloadOf <$> e `shouldBe` Just (encodeValuePayload (object ["content" .= ([] :: [Value])]))

    it "assistant whose message.content is a non-array yields an empty content array" $ do
      let e = convertLine assistantContentNotArray
      payloadOf <$> e `shouldBe` Just (encodeValuePayload (object ["content" .= ([] :: [Value])]))

    it "user with a numeric (non-string, non-array) content yields no blocks" $ do
      let e = convertLine userContentNumber
      _te_direction <$> e `shouldBe` Just Request
      payloadOf <$> e `shouldBe`
        Just (encodeValuePayload (object
          [ "messages" .= [ object
              [ "role" .= ("user" :: Text)
              , "content" .= ([] :: [Value]) ] ] ]))

    it "preserves a non-object block (bare string) in a content array unchanged" $ do
      let e = convertLine assistantBareStringBlock
      payloadOf <$> e `shouldBe`
        Just (encodeValuePayload (object
          [ "content" .= [ String "raw-block" ] ]))

    it "leaves a non-string 'content' field (array tool_result content) unchanged" $ do
      -- A tool_result whose content is an array (claude sometimes emits a
      -- block array). The 'content' field is in sanitizedFields but is NOT a
      -- string, so it must pass through untouched (sanitizeStringValue v = v).
      let e = convertLine toolResultArrayContent
      payloadOf <$> e `shouldBe`
        Just (encodeValuePayload (object
          [ "messages" .= [ object
              [ "role" .= ("user" :: Text)
              , "content" .= [ object
                  [ "type" .= ("tool_result" :: Text)
                  , "tool_use_id" .= ("toolu_9" :: Text)
                  , "content" .= [ object ["type" .= ("text" :: Text), "text" .= ("ok" :: Text)] ]
                  ] ] ] ] ]))

    it "returns Nothing when 'message' is absent (lookupObject miss)" $
      convertLine userNoMessage `shouldBe` Nothing

    it "returns Nothing when 'message' is not an object" $
      convertLine assistantMessageNotObject `shouldBe` Nothing

    it "returns Nothing when 'uuid' is absent (lookupText miss)" $
      convertLine assistantNoUuid `shouldBe` Nothing

  describe "convertLine — idempotence / de-dup obligation (D3.4)" $ do
    it "yields the same _te_id when converting the same event twice" $ do
      ls <- readFixtureLines
      let a = convertLine (nth 1 ls)
          b = convertLine (nth 1 ls)
      (_te_id <$> a) `shouldBe` (_te_id <$> b)
      a `shouldBe` b

  describe "convertLine — sanitization (D3.5)" $ do
    it "passes text content through the SAME sanitizeHarnessOutput before payload" $ do
      -- An assistant text block whose text carries a CSI control sequence.
      -- The emitted payload's content[].text must equal sanitizeHarnessOutput
      -- applied to the raw text (proving the production function, not a
      -- re-implementation, is used).
      let raw = "hello\ESC[31mworld\ESC[0m"
          line = assistantWithText raw
          sanitized = sanitizeHarnessOutput raw
          expected = expectedAssistantSanitized sanitized
      convertLine line `shouldBe` Just expected

    it "sanitizes user text content identically to sanitizeHarnessOutput" $ do
      let raw = "abc\ESC[1mdef"
          line = userWithText raw
          sanitized = sanitizeHarnessOutput raw
      (payloadOf <$> convertLine line)
        `shouldBe` Just (encodeValuePayload (userPayloadValue sanitized))

  describe "encodeValuePayload" $ do
    it "is deterministic (same Value ⇒ same Text)" $
      encodeValuePayload (object ["b" .= (1 :: Int), "a" .= (2 :: Int)])
        `shouldBe`
        encodeValuePayload (object ["b" .= (1 :: Int), "a" .= (2 :: Int)])

-- ───────────────────────── helpers / expected values ─────────────────────────

payloadOf :: TranscriptEntry -> Text
payloadOf = _te_payload

-- Build a complete expected entry. The payload is produced by the SAME
-- encoder production uses, so equality is byte-for-byte on the payload.
mkExpected
  :: Text          -- ^ uuid
  -> Text          -- ^ iso timestamp
  -> Maybe Text    -- ^ model
  -> Direction
  -> Value         -- ^ payload Value
  -> TranscriptEntry
mkExpected uuid tsTxt model dir payloadVal = TranscriptEntry
  { _te_id            = uuid
  , _te_timestamp     = ts tsTxt
  , _te_harness       = Just "claude-code"
  , _te_model         = model
  , _te_direction     = dir
  , _te_payload       = encodeValuePayload payloadVal
  , _te_durationMs    = Nothing
  , _te_correlationId = uuid
  , _te_metadata      = Map.empty
  }

-- Fixture line 0: user text "hello there" (string content).
expectedUserText :: TranscriptEntry
expectedUserText =
  mkExpected
    "11111111-1111-4111-8111-111111111111"
    "2026-06-04T20:00:00.000Z"
    Nothing
    Request
    (userPayloadValue (sanitizeHarnessOutput "hello there"))

-- The user request payload shape: {messages:[{role:"user",content:[{type:"text",text}]}]}.
userPayloadValue :: Text -> Value
userPayloadValue txt = object
  [ "messages" .= [ object
      [ "role" .= ("user" :: Text)
      , "content" .= [ object ["type" .= ("text" :: Text), "text" .= txt] ]
      ] ]
  ]

-- Fixture line 1: assistant with thinking + text + tool_use.
expectedAssistant1 :: TranscriptEntry
expectedAssistant1 =
  mkExpected
    "22222222-2222-4222-8222-222222222222"
    "2026-06-04T20:00:01.000Z"
    (Just "claude-opus-4-8")
    Response
    (object
      [ "content" .=
          [ object
              [ "type" .= ("thinking" :: Text)
              , "thinking" .= sanitizeHarnessOutput "The user greeted me; I will list files."
              , "signature" .= ("sig-abc" :: Text)
              ]
          , object
              [ "type" .= ("text" :: Text)
              , "text" .= sanitizeHarnessOutput "Let me look at the files."
              ]
          , object
              [ "type" .= ("tool_use" :: Text)
              , "id" .= ("toolu_1" :: Text)
              , "name" .= ("shell" :: Text)
              , "input" .= object ["command" .= ("ls" :: Text)]
              , "caller" .= ("assistant" :: Text)
              ]
          ]
      , "usage" .= object
          ["input_tokens" .= (10 :: Int), "output_tokens" .= (20 :: Int)]
      , "model" .= ("claude-opus-4-8" :: Text)
      ])

-- Fixture line 2: tool_result user event.
expectedToolResult :: TranscriptEntry
expectedToolResult =
  mkExpected
    "33333333-3333-4333-8333-333333333333"
    "2026-06-04T20:00:02.000Z"
    Nothing
    Request
    (object
      [ "messages" .=
          [ object
              [ "role" .= ("user" :: Text)
              , "content" .=
                  [ object
                      [ "type" .= ("tool_result" :: Text)
                      , "tool_use_id" .= ("toolu_1" :: Text)
                      , "is_error" .= False
                      , "content" .= sanitizeHarnessOutput "a.txt\nb.txt"
                      ]
                  ]
              ]
          ]
      ])

-- Fixture line 3: assistant, text only.
expectedAssistant2 :: TranscriptEntry
expectedAssistant2 =
  mkExpected
    "44444444-4444-4444-8444-444444444444"
    "2026-06-04T20:00:03.000Z"
    (Just "claude-opus-4-8")
    Response
    (object
      [ "content" .=
          [ object
              [ "type" .= ("text" :: Text)
              , "text" .= sanitizeHarnessOutput "There are two files: a.txt and b.txt."
              ]
          ]
      , "usage" .= object
          ["input_tokens" .= (30 :: Int), "output_tokens" .= (8 :: Int)]
      , "model" .= ("claude-opus-4-8" :: Text)
      ])

-- Fixture line 7: user text (array content) "thanks".
expectedThanks :: TranscriptEntry
expectedThanks =
  mkExpected
    "77777777-7777-4777-8777-777777777777"
    "2026-06-04T20:00:04.000Z"
    Nothing
    Request
    (object
      [ "messages" .=
          [ object
              [ "role" .= ("user" :: Text)
              , "content" .=
                  [ object
                      [ "type" .= ("text" :: Text)
                      , "text" .= sanitizeHarnessOutput "thanks"
                      ]
                  ]
              ]
          ]
      ])

-- ── synthetic lines for the totality + sanitization tests ──

modeLine :: ByteString
modeLine =
  "{\"type\":\"mode\",\"uuid\":\"55555555-5555-4555-8555-555555555555\",\"mode\":\"default\"}"

fileHistoryLine :: ByteString
fileHistoryLine =
  "{\"type\":\"file-history-snapshot\",\"uuid\":\"66666666-6666-4666-8666-666666666666\"}"

assistantNoTimestamp :: ByteString
assistantNoTimestamp =
  "{\"type\":\"assistant\",\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"content\":[]}}"

assistantBadTimestamp :: ByteString
assistantBadTimestamp =
  "{\"type\":\"assistant\",\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"timestamp\":\"not-a-time\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"content\":[]}}"

-- An assistant line whose single text block carries the given raw text.
assistantWithText :: Text -> ByteString
assistantWithText raw =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "uuid" .= ("88888888-8888-4888-8888-888888888888" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:05.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("assistant" :: Text)
        , "model" .= ("claude-opus-4-8" :: Text)
        , "usage" .= object
            ["input_tokens" .= (1 :: Int), "output_tokens" .= (1 :: Int)]
        , "content" .=
            [ object ["type" .= ("text" :: Text), "text" .= raw] ]
        ]
    ]

expectedAssistantSanitized :: Text -> TranscriptEntry
expectedAssistantSanitized sanitized =
  mkExpected
    "88888888-8888-4888-8888-888888888888"
    "2026-06-04T20:00:05.000Z"
    (Just "claude-opus-4-8")
    Response
    (object
      [ "content" .=
          [ object ["type" .= ("text" :: Text), "text" .= sanitized] ]
      , "usage" .= object
          ["input_tokens" .= (1 :: Int), "output_tokens" .= (1 :: Int)]
      , "model" .= ("claude-opus-4-8" :: Text)
      ])

userWithText :: Text -> ByteString
userWithText raw =
  encodeStrict $ object
    [ "type" .= ("user" :: Text)
    , "uuid" .= ("99999999-9999-4999-8999-999999999999" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:06.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("user" :: Text)
        , "content" .= raw
        ]
    ]

-- An assistant with NO content/usage/model fields under message.
assistantMinimal :: ByteString
assistantMinimal =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "uuid" .= ("a0000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:07.000Z" :: Text)
    , "message" .= object ["role" .= ("assistant" :: Text)]
    ]

-- An assistant whose message.content is a string (not an array).
assistantContentNotArray :: ByteString
assistantContentNotArray =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "uuid" .= ("a1000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:08.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("assistant" :: Text)
        , "content" .= ("not an array" :: Text)
        ]
    ]

-- A user whose message.content is a number (neither string nor array).
userContentNumber :: ByteString
userContentNumber =
  encodeStrict $ object
    [ "type" .= ("user" :: Text)
    , "uuid" .= ("a2000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:09.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("user" :: Text)
        , "content" .= (42 :: Int)
        ]
    ]

-- An assistant content array containing a bare-string (non-object) block.
assistantBareStringBlock :: ByteString
assistantBareStringBlock =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "uuid" .= ("a3000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:10.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("assistant" :: Text)
        , "content" .= [ String "raw-block" ]
        ]
    ]

-- A tool_result whose content field is an ARRAY (not a string).
toolResultArrayContent :: ByteString
toolResultArrayContent =
  encodeStrict $ object
    [ "type" .= ("user" :: Text)
    , "uuid" .= ("a4000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:11.000Z" :: Text)
    , "message" .= object
        [ "role" .= ("user" :: Text)
        , "content" .=
            [ object
                [ "type" .= ("tool_result" :: Text)
                , "tool_use_id" .= ("toolu_9" :: Text)
                , "content" .=
                    [ object ["type" .= ("text" :: Text), "text" .= ("ok" :: Text)] ]
                ]
            ]
        ]
    ]

-- A user event with no 'message' field at all.
userNoMessage :: ByteString
userNoMessage =
  encodeStrict $ object
    [ "type" .= ("user" :: Text)
    , "uuid" .= ("a5000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:12.000Z" :: Text)
    ]

-- An assistant event whose 'message' is a string (not an object).
assistantMessageNotObject :: ByteString
assistantMessageNotObject =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "uuid" .= ("a6000000-0000-4000-8000-000000000000" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:13.000Z" :: Text)
    , "message" .= ("oops" :: Text)
    ]

-- An assistant event with no 'uuid' field.
assistantNoUuid :: ByteString
assistantNoUuid =
  encodeStrict $ object
    [ "type" .= ("assistant" :: Text)
    , "timestamp" .= ("2026-06-04T20:00:14.000Z" :: Text)
    , "message" .= object ["role" .= ("assistant" :: Text), "content" .= ([] :: [Value])]
    ]

encodeStrict :: Value -> ByteString
encodeStrict = TE.encodeUtf8 . encodeValuePayload
