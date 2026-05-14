-- |
-- Module      : Internal.ShellQuoteSpec
-- Description : Tests for 'PureClaw.Internal.ShellQuote' (WU4).
--
-- Covers the canonical shell-quoter introduced in WU4 of
-- @.beads\/plans\/active-plan.md@:
--
--   * Unit fixtures for the empty string, safe identifiers, embedded
--     spaces, embedded single quotes, and the DoD #11 \"@/opt/my
--     tools/tmux@\" fixture from
--     @docs\/terminal-backend-abstractions.md@.
--
--   * A QuickCheck round-trip property: for arbitrary 'Text' inputs
--     drawn from printable ASCII plus the adversarial set
--     @'@, @\\@, @$@, @\`@, @;@, @\"@, @&@, @|@, @|@, @<@, @>@, @(@,
--     @)@, @*@, @?@, @[@, @]@, @{@, @}@, @!@, @#@, @~@, @ @ — the
--     bytes echoed by @bash -c \"echo \"++shellQuote s@ equal @s@
--     plus a trailing newline. This is the contract a remote shell on
--     the far side of an ssh hop will see.
--
--   * Regression-prevention: 'PureClaw.Harness.Tmux.shellEscape' /
--     'shellEscapeStr' produce byte-identical output to the canonical
--     'shellQuote' / 'shellQuoteString' for several adversarial
--     fixtures, defending the WU4 migration against silent drift.
module Internal.ShellQuoteSpec (spec) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.Process.Typed qualified as P
import Test.Hspec
import Test.QuickCheck

import PureClaw.Harness.Tmux qualified as Tmux
import PureClaw.Internal.ShellQuote (shellQuote, shellQuoteString)

-- | Generator for 'Text' inputs that exercise shell metacharacters
-- alongside ordinary printable ASCII. NUL is excluded — POSIX argv
-- cannot carry it, and including it would mean we'd be testing
-- process-spawning behaviour, not the quoter.
newtype AdversarialText = AdversarialText { unAdversarialText :: Text }
  deriving (Eq, Show)

instance Arbitrary AdversarialText where
  arbitrary = do
    n <- choose (0, 24)
    cs <- vectorOf n (elements adversarialChars)
    pure (AdversarialText (T.pack cs))
    where
      -- Plain printable ASCII (no DEL), plus the explicit
      -- adversarial set called out by the WU4 task spec. The
      -- elements list is intentionally heavily weighted toward the
      -- adversarial side so the generator does not waste runs on
      -- already-safe inputs.
      adversarialChars :: [Char]
      adversarialChars =
        ['a' .. 'z']
          ++ ['A' .. 'Z']
          ++ ['0' .. '9']
          ++ replicate 4 '\''
          ++ replicate 4 '\\'
          ++ replicate 4 '$'
          ++ replicate 4 '`'
          ++ replicate 4 ';'
          ++ replicate 3 '"'
          ++ replicate 3 '&'
          ++ replicate 3 '|'
          ++ replicate 3 '<'
          ++ replicate 3 '>'
          ++ replicate 2 '('
          ++ replicate 2 ')'
          ++ replicate 2 '*'
          ++ replicate 2 '?'
          ++ replicate 2 '['
          ++ replicate 2 ']'
          ++ replicate 2 '{'
          ++ replicate 2 '}'
          ++ replicate 2 '!'
          ++ replicate 2 '#'
          ++ replicate 2 '~'
          ++ replicate 4 ' '

-- | Run @bash -c "echo <q>"@ where @<q>@ is the literal characters
-- of 'shellQuote' applied to the candidate. Returns the raw bytes
-- bash printed on stdout (which is the original string plus a
-- trailing newline if quoting is correct).
runEchoThroughBash :: Text -> IO (ExitCode, Text)
runEchoThroughBash input = do
  let quoted = shellQuote input
      cmd = "echo " <> T.unpack quoted
      config =
        P.setStdin P.closed
          $ P.setStdout P.byteStringOutput
          $ P.setStderr P.nullStream
          $ P.proc "bash" ["-c", cmd]
  (exitCode, out, _err) <- P.readProcess config
  pure (exitCode, TE.decodeUtf8Lenient (LBS.toStrict out))

spec :: Spec
spec = do
  describe "PureClaw.Internal.ShellQuote.shellQuote" $ do
    describe "fixture behaviour" $ do
      it "wraps the empty string as two literal single quotes" $
        shellQuote "" `shouldBe` "''"

      it "leaves an all-safe identifier unchanged" $
        shellQuote "hello" `shouldBe` "hello"

      it "leaves identifiers with safe punctuation (./=:@-_) unchanged" $ do
        shellQuote "user@host" `shouldBe` "user@host"
        shellQuote "/usr/local/bin/tmux" `shouldBe` "/usr/local/bin/tmux"
        shellQuote "KEY=value" `shouldBe` "KEY=value"
        shellQuote "a-b_c.d" `shouldBe` "a-b_c.d"

      it "single-quotes a string containing a space" $
        shellQuote "hello world" `shouldBe` "'hello world'"

      it "escapes an embedded single quote as '\\''" $
        shellQuote "it's" `shouldBe` "'it'\\''s'"

      it "quotes the DoD #11 fixture '/opt/my tools/tmux'" $
        -- docs/terminal-backend-abstractions.md DoD #11 — remote
        -- argv must shell-quote a path containing a space.
        shellQuote "/opt/my tools/tmux" `shouldBe` "'/opt/my tools/tmux'"

      it "shellQuoteString agrees with shellQuote on the DoD #11 fixture" $
        shellQuoteString "/opt/my tools/tmux" `shouldBe` "'/opt/my tools/tmux'"

    describe "round-trip through bash -c" $ do
      it "for ordinary printable ASCII plus shell metacharacters" $
        withMaxSuccess 50 $
          property $ \(AdversarialText s) -> ioProperty $ do
            (exitCode, output) <- runEchoThroughBash s
            let expected = s <> "\n"
            pure $
              counterexample
                ( "input="
                    ++ show s
                    ++ "  quoted="
                    ++ show (shellQuote s)
                    ++ "  exit="
                    ++ show exitCode
                    ++ "  output="
                    ++ show output
                )
                ( exitCode == ExitSuccess
                    && output == expected
                )

  describe "PureClaw.Harness.Tmux delegation (WU4 migration)" $ do
    -- These fixtures defend against silent drift between the
    -- canonical 'shellQuote' and the 'Harness.Tmux' re-exports that
    -- still ship by their original names.
    let adversarial :: [Text]
        adversarial =
          [ ""
          , "hello"
          , "hello world"
          , "it's"
          , "/opt/my tools/tmux"
          , "$(rm -rf /)"
          , "back`tick`"
          , "semi;colon"
          , "pipe|pipe"
          , "amp&er&sand"
          , "<redir>"
          , "quote\"mix'ed"
          , "tab\there"
          , "newline\nhere"
          ]

    it "Tmux.shellEscape matches shellQuote byte-for-byte on adversarial inputs" $
      mapM_
        ( \t -> Tmux.shellEscape t `shouldBe` shellQuote t
        )
        adversarial

    it "Tmux.shellEscapeStr matches shellQuoteString byte-for-byte on adversarial inputs" $
      mapM_
        ( \t ->
            let s = T.unpack t
             in Tmux.shellEscapeStr s `shouldBe` shellQuoteString s
        )
        adversarial
