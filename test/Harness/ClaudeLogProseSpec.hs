{-# LANGUAGE OverloadedStrings #-}

-- | Tests for 'PureClaw.Harness.ClaudeLogProse': pure prose fold over
-- claude-code JSONL lines, deterministic namespaced turn-id derivation.
module Harness.ClaudeLogProseSpec (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import PureClaw.Harness.ClaudeLogProse
  ( ProseTurn (..)
  , currentProseTurn
  , deriveTurnId
  , emptyProseState
  , foldProseLine
  )

-- ---------------------------------------------------------------------------
-- Helpers to build minimal JSONL bytes
-- ---------------------------------------------------------------------------

-- | Build an assistant event line with text block(s).  @sr@ is an optional
-- stop_reason value.
asst :: Text -> Maybe Text -> Text
asst t sr =
     "{\"type\":\"assistant\",\"uuid\":\"u1\",\"message\":{\"role\":\"assistant\""
  <> ",\"content\":[{\"type\":\"text\",\"text\":\"" <> t <> "\"}]"
  <> maybe "" (\s -> ",\"stop_reason\":\"" <> s <> "\"") sr
  <> "}}"

-- | A real user event (plain text content — ends the turn).
usr :: Text
usr = "{\"type\":\"user\",\"uuid\":\"u0\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"

-- | A user event whose content is solely a tool_result block — must NOT end
-- the turn (it is a tool-call response, not a real user message).
usrToolResult :: Text
usrToolResult =
  "{\"type\":\"user\",\"uuid\":\"u-tr\",\"message\":{\"role\":\"user\""
  <> ",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"ok\"}]}}"

-- | A user event whose content is a MIXED array: first a tool_result block,
-- then a text block — counts as a real user message (NOT solely tool_result).
usrMixed :: Text
usrMixed =
  "{\"type\":\"user\",\"uuid\":\"u-mx\",\"message\":{\"role\":\"user\""
  <> ",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"ok\"}"
  <> ",{\"type\":\"text\",\"text\":\"also some text\"}]}}"

-- ---------------------------------------------------------------------------
-- Specs
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "ClaudeLogProse" $ do

  it "accumulates assistant text across lines under one pinned source uuid" $ do
    let (s1, _) = foldProseLine (te (asst "Hello" Nothing)) emptyProseState
        (_, m)  = foldProseLine (te (asst " world" Nothing)) s1
    fmap _pt_text      m `shouldBe` Just "Hello world"
    fmap _pt_sourceUuid m `shouldBe` Just "u1"
    fmap _pt_finalized m `shouldBe` Just False

  it "finalizes on stop_reason end_turn" $ do
    let (_, m) = foldProseLine (te (asst "Done." (Just "end_turn"))) emptyProseState
    fmap _pt_finalized m `shouldBe` Just True

  it "finalizes on stop_reason stop_sequence" $ do
    let (_, m) = foldProseLine (te (asst "Stopped." (Just "stop_sequence"))) emptyProseState
    fmap _pt_finalized m `shouldBe` Just True

  it "finalizes on stop_reason max_tokens" $ do
    let (_, m) = foldProseLine (te (asst "Cutoff." (Just "max_tokens"))) emptyProseState
    fmap _pt_finalized m `shouldBe` Just True

  it "does NOT finalize on stop_reason tool_use" $ do
    let (_, m) = foldProseLine (te (asst "calling" (Just "tool_use"))) emptyProseState
    fmap _pt_finalized m `shouldBe` Just False

  it "pins _pt_sourceUuid to the FIRST assistant line, never changes on later lines" $ do
    let line1 = te "{\"type\":\"assistant\",\"uuid\":\"first-uuid\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"A\"}]}}"
        line2 = te "{\"type\":\"assistant\",\"uuid\":\"second-uuid\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"B\"}]}}"
    let (s1, _) = foldProseLine line1 emptyProseState
        (_, m)  = foldProseLine line2 s1
    fmap _pt_sourceUuid m `shouldBe` Just "first-uuid"

  it "a new real user event ends the prior turn and starts fresh" $ do
    let (s1, _) = foldProseLine (te (asst "answer" Nothing)) emptyProseState
        (s2, _) = foldProseLine (te usr) s1
    currentProseTurn s2 `shouldBe` Nothing

  it "a user event that is solely tool_result does NOT end the turn" $ do
    let (s1, _) = foldProseLine (te (asst "pending" Nothing)) emptyProseState
        (s2, _) = foldProseLine (te usrToolResult) s1
    fmap _pt_text (currentProseTurn s2) `shouldBe` Just "pending"

  it "thinking blocks are ignored (not accumulated into prose)" $ do
    let thinkLine = te "{\"type\":\"assistant\",\"uuid\":\"u2\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private\"}]}}"
    let (_, m) = foldProseLine thinkLine emptyProseState
    -- no text, so yields Nothing (no prose change)
    m `shouldBe` Nothing

  it "tool_use blocks are ignored" $ do
    let tuLine = te "{\"type\":\"assistant\",\"uuid\":\"u3\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"bash\",\"input\":{}}]}}"
    let (_, m) = foldProseLine tuLine emptyProseState
    m `shouldBe` Nothing

  it "ignores malformed lines without throwing" $ do
    let (_, m) = foldProseLine "{ not json at all !!!" emptyProseState
    m `shouldBe` Nothing

  it "ignores meta/mode lines without throwing" $ do
    let (s1, m1) = foldProseLine (te "{\"type\":\"mode\"}") emptyProseState
        (_, m2)  = foldProseLine (te "{\"type\":\"system\",\"content\":[]}") s1
    m1 `shouldBe` Nothing
    m2 `shouldBe` Nothing

  it "returns Nothing for an empty assistant message (no text blocks)" $ do
    let emptyContent = te "{\"type\":\"assistant\",\"uuid\":\"u4\",\"message\":{\"role\":\"assistant\",\"content\":[]}}"
    let (_, m) = foldProseLine emptyContent emptyProseState
    m `shouldBe` Nothing

  it "deriveTurnId is deterministic for the same inputs" $
    deriveTurnId "sessA" "u1" `shouldBe` deriveTurnId "sessA" "u1"

  it "deriveTurnId is distinct across sessions for the same uuid" $
    deriveTurnId "sessA" "u1" `shouldNotBe` deriveTurnId "sessB" "u1"

  it "deriveTurnId is distinct for different uuids in the same session" $
    deriveTurnId "sess1" "uuid-a" `shouldNotBe` deriveTurnId "sess1" "uuid-b"

  it "prose text passes through sanitizeHarnessOutput (strips ANSI escape sequences)" $ do
    -- The JSON \\u001b sequences are parsed by aeson as real ESC (U+001B) bytes.
    -- After sanitizeHarnessOutput the ESC bytes are stripped; "red" survives.
    let ansiLine = te
          "{\"type\":\"assistant\",\"uuid\":\"u5\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\\u001b[31mred\\u001b[0m\"}]}}"
    let (_, m) = foldProseLine ansiLine emptyProseState
    case fmap _pt_text m of
      Nothing  -> expectationFailure "expected a ProseTurn with stripped prose"
      Just txt -> do
        T.unpack txt `shouldNotContain` "\ESC"
        T.unpack txt `shouldContain` "red"

  -- -------------------------------------------------------------------------
  -- Backstop finalize: next-user-message ends a turn that had no terminal
  -- stop_reason yet (the turn is emitted finalized as a backstop).
  -- -------------------------------------------------------------------------

  it "backstop finalize: user line emits prior unfinalized turn as finalized" $ do
    -- Feed an assistant line WITHOUT a stop_reason (not yet finalized), then
    -- a real user line.  The user line must yield Just a finalized ProseTurn.
    let (s1, _)  = foldProseLine (te (asst "some prose" Nothing)) emptyProseState
        (s2, mb) = foldProseLine (te usr) s1
    -- The user tick emits the prior turn finalized
    fmap _pt_finalized  mb `shouldBe` Just True
    fmap _pt_text       mb `shouldBe` Just "some prose"
    -- After the user tick, the new state has no active turn
    currentProseTurn s2 `shouldBe` Nothing

  it "no double-finalize: user line after already-finalized turn yields Nothing" $ do
    -- Feed an assistant line WITH stop_reason=end_turn (emits finalized once),
    -- then a real user line.  The user tick must yield Nothing (not re-emitted).
    let (s1, _)  = foldProseLine (te (asst "done." (Just "end_turn"))) emptyProseState
        (_, mb)  = foldProseLine (te usr) s1
    mb `shouldBe` Nothing

  it "mixed-array user content counts as real-user and ends the prior turn" $ do
    -- A user event with [tool_result, text] is NOT solely tool_result, so it
    -- ends the prior turn (backstop finalize if unfinalized).
    let (s1, _)  = foldProseLine (te (asst "prev answer" Nothing)) emptyProseState
        (s2, mb) = foldProseLine (te usrMixed) s1
    fmap _pt_finalized mb `shouldBe` Just True
    fmap _pt_text      mb `shouldBe` Just "prev answer"
    currentProseTurn s2 `shouldBe` Nothing

-- | Convert 'Text' to 'ByteString' via UTF-8 for 'foldProseLine'.
te :: Text -> ByteString
te = TE.encodeUtf8
