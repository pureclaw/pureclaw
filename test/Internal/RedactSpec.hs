-- |
-- Module      : Internal.RedactSpec
-- Description : Property + unit tests for 'PureClaw.Internal.Redact'.
--
-- Covers DoD #17 from @docs/terminal-backend-abstractions.md@ § Acceptance
-- Criteria (v1) — @Show BackendError@ / @Show BackendException@ /
-- @Show SshConnectFailure@ never reveal raw hostnames, paths, or ssh stderr.
--
-- See @.beads/plans/active-plan.md@ WU2.
module Internal.RedactSpec (spec) where

import Control.Exception qualified as Exception
import Control.Exception (SomeException)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import PureClaw.Handles.Backend
  ( BackendContext (BcSend, BcSshDisconnect)
  , BackendError
    ( BackendBinaryNotFound
    , BackendBufferQuotaExceeded
    , BackendInvalidOption
    , BackendPtyAllocFailed
    , BackendSshConnectFailed
    )
  , BackendException (..)
  , InvalidOptionDetail (..)
  , PtyAllocFailure (..)
  , SshConnectFailure (..)
  )
import PureClaw.Core.Types (CommandName (..))
import PureClaw.Internal.Redact qualified as Redact

-- | Wrap a 'String' as a 'SomeException' via 'userError'.
mkExn :: String -> SomeException
mkExn = Exception.toException . userError

-- | A generator for hostname-y strings: 2+ DNS labels separated by
-- dots, each label 3-12 alphanumeric chars, starting and ending with
-- an alnum. Always contains a dot so 'redactHostname' will match.
newtype Hostname = Hostname { unHostname :: Text }
  deriving (Eq, Show)

instance Arbitrary Hostname where
  arbitrary = do
    n <- choose (2, 4)
    labels <- vectorOf n genLabel
    pure (Hostname (T.intercalate "." labels))
    where
      genLabel = do
        len <- choose (3, 12)
        chars <- vectorOf len (elements labelChars)
        pure (T.pack chars)
      labelChars = ['a'..'z'] ++ ['0'..'9']

-- | A generator for absolute-path strings of the form
-- @\/segment(\/segment)*@ with 2-5 segments, each 3-10 chars from
-- the path-safe alnum + @_@ + @-@ + @.@ alphabet (no leading dot).
newtype AbsPath = AbsPath { unAbsPath :: FilePath }
  deriving (Eq, Show)

instance Arbitrary AbsPath where
  arbitrary = do
    n <- choose (2, 5)
    segs <- vectorOf n genSegment
    pure (AbsPath ('/' : drop 1 (concatMap ('/' :) segs)))
    where
      genSegment = do
        len <- choose (3, 10)
        first <- elements (['a'..'z'] ++ ['A'..'Z'])
        rest <- vectorOf (len - 1) (elements segChars)
        pure (first : rest)
      segChars =
        ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_-."

spec :: Spec
spec = do
  describe "PureClaw.Internal.Redact" $ do
    -- docs/terminal-backend-abstractions.md line 66: redaction
    describe "DoD #17: redactErr" $ do
      it "strips hostnames from arbitrary userError messages" $
        property $ \(h :: Hostname) ->
          let host = unHostname h
              msg = "ssh: connect to host " <> T.unpack host <> " port 22: failed"
              out = Redact.redactErr (mkExn msg)
          in counterexample ("host=" <> show host <> "  out=" <> T.unpack out) $
               not (host `T.isInfixOf` out)
                 && "<host>" `T.isInfixOf` out

      it "strips absolute paths from arbitrary userError messages" $
        property $ \(p :: AbsPath) ->
          let path = unAbsPath p
              msg = "open " <> path <> ": no such file or directory"
              out = Redact.redactErr (mkExn msg)
          in counterexample ("path=" <> show path <> "  out=" <> T.unpack out) $
               not (T.pack path `T.isInfixOf` out)
                 && "<path>" `T.isInfixOf` out

      it "strips IPv4 dotted-quad literals" $ do
        let out = T.unpack (Redact.redactErr (mkExn "connect 192.168.42.7: refused"))
        out `shouldNotContain` "192.168.42.7"
        out `shouldContain` "<ipv4>"

      it "strips known ssh stderr fragments" $ do
        let out = T.unpack (Redact.redactErr (mkExn "ssh: Permission denied (publickey)"))
        out `shouldNotContain` "Permission denied"
        out `shouldContain` "<ssh-error>"

      it "leaves single-token non-hostnames (\"tmux\") intact" $ do
        let out = T.unpack (Redact.redactErr (mkExn "tmux: server is running"))
        out `shouldContain` "tmux"

      it "leaves the integer literal \"0\" intact" $ do
        let out = T.unpack (Redact.redactErr (mkExn "exit code 0"))
        out `shouldContain` "0"

    -- docs/terminal-backend-abstractions.md line 66: BackendError Show
    describe "DoD #17: Show BackendError routes through redactBackendError" $ do
      it "renders BackendSshConnectFailed without leaking hostnames or paths" $ do
        let rendered = show (BackendSshConnectFailed SshAuthRefused)
        rendered `shouldContain` "SshAuthRefused"
        rendered `shouldNotContain` "/"
        -- No dotted-quad escape; no embedded hostname-shaped substring.
        not (containsHostnameLike (T.pack rendered)) `shouldBe` True

      it "renders BackendBinaryNotFound with the CommandName" $ do
        let rendered = show (BackendBinaryNotFound (CommandName "tmux"))
        rendered `shouldContain` "BackendBinaryNotFound"
        rendered `shouldContain` "tmux"

      it "renders BackendInvalidOption verbatim (fixed-vocabulary Text)" $ do
        let rendered = show (BackendInvalidOption (InvalidOptionDetail "idle: bad"))
        rendered `shouldContain` "BackendInvalidOption"

      it "renders BackendBufferQuotaExceeded with the requested cap" $ do
        let rendered = show (BackendBufferQuotaExceeded 64)
        rendered `shouldContain` "BackendBufferQuotaExceeded"
        rendered `shouldContain` "64"

      it "renders BackendPtyAllocFailed with the structured failure tag" $ do
        let rendered = show (BackendPtyAllocFailed PtyOpenFailed)
        rendered `shouldContain` "BackendPtyAllocFailed"
        rendered `shouldContain` "PtyOpenFailed"

    -- docs/terminal-backend-abstractions.md line 66: BackendException Show
    describe "DoD #17: Show BackendException routes through redactBackendException" $ do
      it "redacts hostnames inside the wrapped exception" $ do
        let cause = mkExn "ssh: could not resolve hostname db.prod.example.com: timeout"
            rendered = show (BackendException BcSshDisconnect cause)
        rendered `shouldNotContain` "db.prod.example.com"
        rendered `shouldContain` "BackendException"
        rendered `shouldContain` "BcSshDisconnect"

      it "redacts absolute paths inside the wrapped exception" $ do
        let cause = mkExn "open /home/agent/.ssh/id_ed25519: not found"
            rendered = show (BackendException BcSend cause)
        rendered `shouldNotContain` "/home/agent/.ssh/id_ed25519"
        rendered `shouldContain` "<path>"

      it "redacts ssh stderr fragments inside the wrapped exception" $ do
        let cause = mkExn "Host key verification failed for example.com"
            rendered = show (BackendException BcSshDisconnect cause)
        rendered `shouldNotContain` "Host key verification failed"
        rendered `shouldContain` "<ssh-error>"

    describe "credentialPromptScrubber" $ do
      it "replaces password-prompt response with the [REDACTED] sentinel" $ do
        let input = "Password: hunter2\nnext line\n"
            out = Redact.credentialPromptScrubber input
        out `shouldBe` "Password:[REDACTED]\nnext line\n"

      it "replaces passphrase-prompt response with the sentinel" $ do
        let input = "Enter passphrase: secret\n"
            out = Redact.credentialPromptScrubber input
        out `shouldBe` "Enter passphrase:[REDACTED]\n"

      it "scrubs the literal [sudo] password for prompt" $ do
        let input = "[sudo] password for alice: shibboleth\n"
            out = Redact.credentialPromptScrubber input
        out `shouldBe` "[sudo] password for [REDACTED]\n"

      it "preserves a chunk with no credential triggers untouched" $ do
        let input = "regular output line\nanother line\n"
        Redact.credentialPromptScrubber input `shouldBe` input

      it "scrubs multiple prompts in the same chunk" $ do
        let input = "Password: a\nPassword: b\n"
            out = Redact.credentialPromptScrubber input
        out `shouldBe` "Password:[REDACTED]\nPassword:[REDACTED]\n"

      it "scrubs the 'Sorry, try again' retry-prompt response" $ do
        let input = "Sorry, try again. password attempt\n"
            out = Redact.credentialPromptScrubber input
        out `shouldBe` "Sorry, try again[REDACTED]\n"

-- | True if the argument contains a substring that the redactor would
-- consider a hostname (>= 2 dot-separated alnum labels, each non-empty,
-- starts and ends with alnum, at least one dot, length >= 3, not
-- purely numeric).
containsHostnameLike :: Text -> Bool
containsHostnameLike t =
  any looksHostnameish (windows t)
  where
    looksHostnameish s =
      T.length s >= 3
        && T.any (== '.') s
        && not (T.all (\c -> Char.isDigit c || c == '.') s)
        && all labelOk (T.split (== '.') s)
        && T.all (\c -> Char.isAscii c && (Char.isAlphaNum c || c == '.' || c == '-')) s
    labelOk lbl =
      not (T.null lbl)
        && Char.isAlphaNum (T.head lbl)
        && Char.isAlphaNum (T.last lbl)
    windows :: Text -> [Text]
    windows s
      | T.null s = []
      | otherwise =
          let (tok, rest) = T.span tokChar s
              rest'       = T.dropWhile (not . tokChar) rest
          in if T.null tok then windows rest' else tok : windows rest'
    tokChar c = Char.isAscii c && (Char.isAlphaNum c || c == '.' || c == '-')
