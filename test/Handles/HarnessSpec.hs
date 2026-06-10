module Handles.HarnessSpec (spec) where

import Data.ByteString ()
import Data.Text qualified as T
import System.Exit
import Test.Hspec

import PureClaw.Handles.Harness
import PureClaw.Security.Command

spec :: Spec
spec = do
  describe "HarnessStatus" $ do
    it "has Show instance" $ do
      show HarnessRunning `shouldContain` "HarnessRunning"

    it "has Eq instance" $ do
      HarnessRunning `shouldBe` HarnessRunning
      HarnessRunning `shouldNotBe` HarnessExited ExitSuccess

    it "represents exit with code" $ do
      let status = HarnessExited (ExitFailure 1)
      show status `shouldContain` "HarnessExited"
      status `shouldBe` HarnessExited (ExitFailure 1)
      status `shouldNotBe` HarnessExited ExitSuccess

  describe "HarnessError" $ do
    it "has Show instance" $ do
      show (HarnessTmuxNotAvailable "test") `shouldContain` "HarnessTmuxNotAvailable"

    it "has Eq instance" $ do
      HarnessTmuxNotAvailable "test" `shouldBe` HarnessTmuxNotAvailable "test"

    it "constructs HarnessBinaryNotFound" $ do
      let err = HarnessBinaryNotFound "claude"
      show err `shouldContain` "HarnessBinaryNotFound"
      show err `shouldContain` "claude"
      err `shouldBe` HarnessBinaryNotFound "claude"
      err `shouldNotBe` HarnessBinaryNotFound "other"

    it "constructs HarnessNotAuthorized" $ do
      let cmdErr = CommandNotAllowed "tmux"
          err = HarnessNotAuthorized cmdErr
      show err `shouldContain` "HarnessNotAuthorized"
      err `shouldBe` HarnessNotAuthorized cmdErr

  describe "mkNoOpHarnessHandle" $ do
    it "send is a no-op" $ do
      _hh_send mkNoOpHarnessHandle "test data"
      -- Should not throw

    it "receive returns empty ByteString" $ do
      result <- _hh_receive mkNoOpHarnessHandle
      result `shouldBe` ""

    it "name returns empty Text" $ do
      _hh_name mkNoOpHarnessHandle `shouldBe` ""

    it "session returns empty Text" $ do
      _hh_session mkNoOpHarnessHandle `shouldBe` ""

    it "status returns HarnessRunning" $ do
      result <- _hh_status mkNoOpHarnessHandle
      result `shouldBe` HarnessRunning

    it "stop is a no-op" $ do
      _hh_stop mkNoOpHarnessHandle
      -- Should not throw

  describe "prefixHarnessOutput" $ do
    it "prefixes a single line" $
      prefixHarnessOutput "claude-code-0" "hello"
        `shouldBe` "claude-code-0> hello"

    it "prefixes only the first line of multi-line output" $
      prefixHarnessOutput "cc-1" "line1\nline2\nline3"
        `shouldBe` "cc-1> line1\nline2\nline3"

    it "handles empty output" $
      prefixHarnessOutput "name" ""
        `shouldBe` "name> "

    it "preserves blank lines without extra prefixes" $
      prefixHarnessOutput "h" "a\n\nb"
        `shouldBe` "h> a\n\nb"

    it "works with long harness names" $ do
      let name = "claude-code-42"
      T.isPrefixOf (name <> "> ") (prefixHarnessOutput name "test")
        `shouldBe` True

  describe "sanitizeHarnessOutput" $ do
    it "passes through plain text unchanged" $
      sanitizeHarnessOutput "hello world" `shouldBe` "hello world"

    it "strips ANSI escape sequences" $
      sanitizeHarnessOutput "\ESC[32mgreen\ESC[0m" `shouldBe` "green"

    it "strips leading and trailing blank lines" $
      sanitizeHarnessOutput "\n\nhello\n\n" `shouldBe` "hello"

    it "preserves newlines and tabs" $
      sanitizeHarnessOutput "line1\n\tline2\n" `shouldBe` "line1\n\tline2"

    it "strips CSI sequences with parameters" $
      sanitizeHarnessOutput "\ESC[1;31mbold red\ESC[0m" `shouldBe` "bold red"

    it "strips OSC sequences terminated by BEL" $
      sanitizeHarnessOutput "\ESC]0;window title\BELtext" `shouldBe` "text"

    it "strips OSC sequences terminated by ST" $
      sanitizeHarnessOutput "\ESC]0;title\ESC\\text" `shouldBe` "text"

    it "strips DCS sequences" $
      sanitizeHarnessOutput "\ESCP+q\ESC\\text" `shouldBe` "text"

    it "strips cursor movement sequences" $
      sanitizeHarnessOutput "\ESC[2Jhello\ESC[H" `shouldBe` "hello"

    it "removes C0 control characters except newline and tab" $
      sanitizeHarnessOutput ("a\x01\x02\x07\x08\x0C" <> "b") `shouldBe` "ab"

    it "normalizes \\r\\n to \\n" $
      sanitizeHarnessOutput "line1\r\nline2\r\n" `shouldBe` "line1\nline2"

    it "normalizes bare \\r to \\n" $
      sanitizeHarnessOutput "old\rnew" `shouldBe` "old\nnew"

    it "strips charset designator sequences" $
      sanitizeHarnessOutput "\ESC(Btext" `shouldBe` "text"

    it "handles empty input" $
      sanitizeHarnessOutput "" `shouldBe` ""

    it "handles input that is only escape sequences" $
      sanitizeHarnessOutput "\ESC[31m\ESC[0m" `shouldBe` ""

    it "removes DEL (0x7F)" $
      sanitizeHarnessOutput ("ab\x7F" <> "cd") `shouldBe` "abcd"

    -- Trailing blank lines from tmux capture
    it "strips trailing blank lines from capture output" $
      sanitizeHarnessOutput "hello\nworld\n\n\n\n\n\n"
        `shouldBe` "hello\nworld"

    it "strips trailing whitespace-only lines" $
      sanitizeHarnessOutput "content\n   \n  \n\n"
        `shouldBe` "content"

    it "preserves internal blank lines" $
      sanitizeHarnessOutput "para1\n\npara2\n\n\n"
        `shouldBe` "para1\n\npara2"

    it "handles output that is entirely blank lines" $
      sanitizeHarnessOutput "\n\n\n\n"
        `shouldBe` ""

    it "strips leading blank lines" $
      sanitizeHarnessOutput "\n\n\nhello\nworld"
        `shouldBe` "hello\nworld"

    -- Real Claude Code TUI output patterns
    it "strips box-drawing block characters from Claude Code header" $
      -- U+2590 RIGHT HALF BLOCK, U+259B UPPER LEFT AND LOWER RIGHT, etc.
      sanitizeHarnessOutput " \x2590\x259B\x2588\x2588\x2588\x259C\x258C   Claude Code v2.1.75"
        `shouldBe` "    Claude Code v2.1.75"

    it "strips Private Use Area characters (Powerline symbols)" $
      -- U+E0A0 = Powerline git branch symbol
      sanitizeHarnessOutput ("on \xE0A0 main" <> " [$!?]")
        `shouldBe` "on  main [$!?]"

    it "strips line-drawing horizontal bar characters" $
      -- U+2500 BOX DRAWINGS LIGHT HORIZONTAL repeated as a divider
      let divider = T.replicate 40 "\x2500"
      in sanitizeHarnessOutput ("text\n" <> divider <> "\nmore")
        `shouldBe` "text\n\nmore"

    it "strips mixed block elements and keeps ASCII content" $
      -- Simulated Claude Code status line
      sanitizeHarnessOutput "\x259D\x259C\x2588\x2588\x2588\x2588\x2588\x259B\x2598  Opus 4.6"
        `shouldBe` "  Opus 4.6"

    it "preserves standard Latin, punctuation, and common symbols" $
      sanitizeHarnessOutput "Hello, world! Cost: $4.50 \x2014 done."
        `shouldBe` "Hello, world! Cost: $4.50 \x2014 done."

    it "preserves accented and non-Latin text" $
      sanitizeHarnessOutput ("caf\xe9 na\xEFve \x00FCber")
        `shouldBe` "caf\xe9 na\xEFve \x00FCber"

    it "strips full-width block fill (U+2500-U+257F, U+2580-U+259F)" $
      -- A line of block fill characters that Claude Code uses as dividers
      let blockFill = T.replicate 10 "\x2580"
      in sanitizeHarnessOutput ("above\n" <> blockFill <> "\nbelow")
        `shouldBe` "above\n\nbelow"
