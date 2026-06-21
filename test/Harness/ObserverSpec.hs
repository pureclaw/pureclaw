module Harness.ObserverSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           PureClaw.Harness.Observer
import           PureClaw.Session.Kind (HarnessFlavour (..))
import           Test.Hspec

loadFix :: FilePath -> IO BS.ByteString
loadFix name = BS.readFile ("test/fixtures/harness/" <> name)

spec :: Spec
spec = do
  describe "claudeObserver._ho_classify" $ do
    it "HasWorking when a spinner/status line is present" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-working.txt"
      _ho_classify claudeObserver t `shouldBe` HasWorking
    it "HasAwaitingInput on an approval prompt" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-approval.txt"
      _ho_classify claudeObserver t `shouldBe` HasAwaitingInput
    it "HasIdle on a bare prompt with no spinner/approval" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-idle.txt"
      _ho_classify claudeObserver t `shouldBe` HasIdle
    it "is NOT HasIdle when the prompt is a menu cursor (❯ N.)" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-menu-cursor.txt"
      _ho_classify claudeObserver t `shouldNotBe` HasIdle

  describe "claudeObserver._ho_extractResponse" $ do
    it "returns the last assistant block, marker + chrome stripped" $ do
      cap <- loadFix "claude-response.txt"
      let out = _ho_extractResponse claudeObserver 0 cap
      out `shouldSatisfy` T.isInfixOf "Applied the change and the tests pass."
      out `shouldNotSatisfy` T.isInfixOf "\x23FA"        -- no ⏺ marker
      out `shouldNotSatisfy` T.isInfixOf "ctrl+o"         -- chrome stripped
      out `shouldNotSatisfy` T.isInfixOf "fix the bug"    -- not the user line
    it "returns the prompt text when awaiting input" $ do
      cap <- loadFix "claude-approval.txt"
      _ho_extractResponse claudeObserver 0 cap
        `shouldSatisfy` T.isInfixOf "Do you want to proceed?"

  describe "claudeObserver._ho_relevantTail" $
    it "returns the last N cleaned lines without box-drawing chrome" $ do
      cap <- loadFix "claude-idle.txt"
      let out = _ho_relevantTail claudeObserver 3 cap
      length (T.lines out) `shouldSatisfy` (<= 3)
      out `shouldNotSatisfy` T.isInfixOf "────"

  describe "genericObserver" $ do
    it "classify is always HasIdle (no markers; stability decides in the loop)" $
      _ho_classify genericObserver "anything at all" `shouldBe` HasIdle
    it "relevantTail returns the last N lines" $
      _ho_relevantTail genericObserver 2 (TE.encodeUtf8 "a\nb\nc\nd")
        `shouldBe` "c\nd"

  describe "observerFor" $ do
    it "maps HClaudeCode to the Claude observer" $
      _ho_classify (observerFor HClaudeCode) "✶ Working… (3s · 1k tokens)"
        `shouldBe` HasWorking
    it "maps non-Claude flavours to the generic observer" $
      _ho_classify (observerFor HCodex) "✶ anything" `shouldBe` HasIdle

  -- Finding 2: response markers (⏺ ● ⬤) must NOT be classified as HasWorking
  -- even when the line contains an ellipsis.  They are NOT spinner glyphs —
  -- they appear as the first character of actual Claude replies (e.g.
  -- "⏺ Let me check the other call sites…").  Before the fix, such a line
  -- would be misclassified HasWorking → the turn would never settle → the
  -- watcher would never record the reply.
  describe "response-marker lines are NOT HasWorking (Finding 2)" $ do
    it "⏺ with an ellipsis + idle prompt classifies as HasIdle, not HasWorking" $ do
      -- Frame: a response line starting with ⏺ that contains an ellipsis,
      -- followed by the bare idle-input prompt.  The whole frame must read
      -- HasIdle (the turn settled), not HasWorking.
      let frame = "\x23FA Let me check the other call sites\x2026\n\x276F"
      _ho_classify claudeObserver frame `shouldBe` HasIdle
    it "● (U+25CF) with an ellipsis + idle prompt classifies as HasIdle" $ do
      let frame = "\x25CF Reviewing the diff\x2026\n\x276F"
      _ho_classify claudeObserver frame `shouldBe` HasIdle
    it "⬤ (U+2B24) with an ellipsis + idle prompt classifies as HasIdle" $ do
      let frame = "\x2B24 Analysing results\x2026\n\x276F"
      _ho_classify claudeObserver frame `shouldBe` HasIdle
    -- Positive regression guard: a genuine spinner glyph STILL reads HasWorking.
    it "✶ (U+2736) with an ellipsis still classifies as HasWorking (spinner glyph)" $ do
      let frame = "\x2736 Smooshing\x2026 (4s)"
      _ho_classify claudeObserver frame `shouldBe` HasWorking

  describe "claudeObserver._ho_extractTurn" $ do
    it "returns ALL assistant blocks since the last user prompt (chrome/tool stripped)" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-multi.txt"
      let out = _ho_extractTurn claudeObserver 0 cap
      out `shouldSatisfy` T.isInfixOf "Looking at the auth module"
      out `shouldSatisfy` T.isInfixOf "Found the bug at auth.ts:42"
      out `shouldSatisfy` T.isInfixOf "Applied the fix; the tests pass."
      out `shouldNotSatisfy` T.isInfixOf "refactor the auth module"  -- not the user line
      out `shouldNotSatisfy` T.isInfixOf "\x23FA"                    -- markers stripped
      out `shouldNotSatisfy` T.isInfixOf "ctrl+o"                    -- chrome stripped
      out `shouldNotSatisfy` T.isInfixOf "Update(auth.ts)"          -- tool line stripped
      out `shouldNotSatisfy` T.isInfixOf "\x2500\x2500"             -- rule stripped
    it "single block: returns just that block's text" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-single.txt"
      _ho_extractTurn claudeObserver 0 cap `shouldBe` "foo validates the session token and returns the user id."
    it "no assistant content yet: returns empty" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-empty.txt"
      T.strip (_ho_extractTurn claudeObserver 0 cap) `shouldBe` ""

  describe "isClaudeUserLine" $ do
    it "a \x276F line WITH text is a user line" $
      isClaudeUserLine "\x276F refactor the auth module" `shouldBe` True
    it "a bare \x276F (idle input box) is NOT a user line" $
      isClaudeUserLine "\x276F" `shouldBe` False
    it "a numbered menu cursor \x276F 1. is NOT a user line" $
      isClaudeUserLine "\x276F 1. Yes" `shouldBe` False

  describe "genericObserver._ho_extractTurn" $
    it "falls back to the cleaned tail (no user-boundary detection)" $
      _ho_extractTurn genericObserver 0 (TE.encodeUtf8 "a\nb\nc") `shouldSatisfy` T.isInfixOf "c"
