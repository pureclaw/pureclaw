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
