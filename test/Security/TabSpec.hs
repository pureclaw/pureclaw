-- |
-- Module      : Security.TabSpec
-- Description : WU0 red-phase scaffold for tabbed-chat security DoDs (S-series).
--
-- Enumerates the S-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Security (S-series)" as 'pending' tests.
-- S-series DoDs are distributed across WUs (not a standalone security
-- WU) because they are cross-cutting; this spec is the single contiguous
-- enumeration for audit traceability.
--
-- /S11 is intentionally omitted from this spec/ — it is a
-- documented-assumption-only invariant (provider connection-pool
-- isolation) enforced by code review, not by a runtime test. See
-- @docs/tabbed-chat.md@ S11 and @.beads/plans/active-plan.md@ for the
-- documented-invariant pattern.
module Security.TabSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck
  ( Gen
  , Property
  , forAll
  , elements
  , listOf1
  , property
  , withMaxSuccess
  , (.&&.)
  , counterexample
  )

import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT


spec :: Spec
spec = do
  describe "S-series — tabbed-chat security (WU0 scaffold; WU2/WU5/WU6/WU8/WU9 fill in)" $ do
    it "S1: spawn authorization (local) — /tab new N shell <cmd...> calls authorize cmd _env_policy before any subprocess; rejection yields TabSpawnAuthDenied PublicError, no process spawned" pending
    it "S2: spawn authorization (remote) — /tab new N ssh <host> <cmd...> calls authorizeRemote + mkSshHost host; rejected hosts (whitespace, leading -, NUL, shell metachars) yield BackendInvalidOption PublicError, no ssh subprocess" pending

    -- S3 — smart-constructor validation. WU2 lands the parser-side
    -- smart constructors ('Parse.mkSessionId' and
    -- 'Parse.sanitizeTabName'); the backend-side smart constructors
    -- ('mkSshHost', 'mkTmuxSession', 'mkTmuxWindow', 'mkTmuxPane',
    -- 'mkLocalCommand') land in WU8 alongside the backend tab
    -- factory. The S3 assertions below cover the WU2 surface; the WU8
    -- assertions live under the corresponding backend specs (and the
    -- WU8 scope re-adds them here if needed). Since S3 has multiple
    -- WU sources, this slot stays 'partially green' (WU2 surface +
    -- pending the rest).
    describe "S3 (parser-side smart-constructor validation, WU2 surface)" $ do

      it "mkSessionId — accepts the [a-zA-Z0-9_-]+ corpus and rejects the path-traversal / NUL / out-of-corpus adversarial list" $
        withMaxSuccess 200 prop_mkSessionId_corpus

      it "mkSessionId — rejects specific adversarial cases verbatim" $ do
        -- Path-traversal forms.
        Parse.mkSessionId "../etc/passwd"  `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "../../up"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "/abs/path"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "a\\b"           `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "foo..bar"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- NUL byte (most common smuggling vector).
        Parse.mkSessionId "abc\0def"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- Out-of-corpus chars.
        Parse.mkSessionId "with space"     `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "shell$injection" `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "`cmd`"          `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with;semi"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with|pipe"      `shouldRejectAs` RT.ParseErrorInvalidSessionId
        Parse.mkSessionId "with&amp"       `shouldRejectAs` RT.ParseErrorInvalidSessionId
        -- Empty / blank.
        Parse.mkSessionId ""               `shouldRejectAs` RT.ParseErrorInvalidSessionId

      it "sanitizeTabName — every Right output satisfies length / control / ANSI / leak invariants (property test)" $
        withMaxSuccess 200 prop_sanitizeTabName_security_invariants

      it "sanitizeTabName — rejects specific adversarial cases verbatim" $ do
        -- Length cap.
        Parse.sanitizeTabName (T.replicate 50 "x")
          `shouldBe` Left Tab.NameTooLong
        -- ANSI / 8-bit CSI.
        Parse.sanitizeTabName "\ESC[31mEVIL"   `shouldBe` Left Tab.NameContainsAnsi
        Parse.sanitizeTabName "boom\x9B\&csi"  `shouldBe` Left Tab.NameContainsAnsi
        -- Control bytes.
        Parse.sanitizeTabName "carriage\rret"  `shouldBe` Left Tab.NameContainsControlBytes
        Parse.sanitizeTabName "tab\there"      `shouldBe` Left Tab.NameContainsControlBytes
        Parse.sanitizeTabName "bell\x07ring"   `shouldBe` Left Tab.NameContainsControlBytes
        -- Empty after trim.
        Parse.sanitizeTabName "    "           `shouldBe` Left Tab.NameRedactedToEmpty

    it "S4: SSH identity sourcing — ssh tabs source SafeKeyPath from Vault slot _rc_sshIdentityKey; identities NEVER typed inline by user; missing Vault slot yields PublicError" pending
    it "S5: Crashed PublicError — Crashed e is internal; channel emit uses toPublicTabError; failure message contains neither host string, nor path, nor ssh stderr" pending
    it "S6: max-tab cap enforced at spawn — covered by A11; this entry exists for security audit traceability" pending
    it "S7: spawn rate limit — token-bucket _rc_spawnRateLimit (default 10 spawns/minute) per chat-user; exceeding yields PublicError, no spawn; defends against close-spawn cycling resource leak" pending
    it "S8: user-allowlist invariant — dispatcher reads from _ch_receive only; non-allowlisted user's messages produce zero handler invocations (runtime test; static-grep is code-review checklist)" pending
    it "S9: concurrent-active-tab cap (atomic, fail-fast) — _rc_maxConcurrentActive (default 4) enforced via TVar _env_activeCount inside atomically; STM retry NOT used (would block dispatcher per H4); N concurrent transitions yield exactly K successes + N-K TabConcurrencyLimit under randomised schedule" pending
    it "S10: /tab rename N <name> input sanitization — passes through sanitizeTabName (length cap, control-byte reject, ANSI reject, hostname/path/ssh-stderr redaction); rename rejected on NameRedactedToEmpty; success notes '(redacted host/path fragment)' when sanitization changed the name" pending


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Assertion combinator: the result must be 'Left' with the given
-- 'RT.ParseError' value.
shouldRejectAs :: Either RT.ParseError a -> RT.ParseError -> Expectation
shouldRejectAs (Left actual) expected =
  actual `shouldBe` expected
shouldRejectAs (Right _)     expected =
  expectationFailure $ "expected Left " <> show expected <> "; got Right"


-- ---------------------------------------------------------------------------
-- Property tests
-- ---------------------------------------------------------------------------

-- | 'Parse.mkSessionId' is total: it accepts any non-empty string in
-- the canonical corpus, and rejects everything else with the dedicated
-- 'RT.ParseErrorInvalidSessionId' error.
prop_mkSessionId_corpus :: Property
prop_mkSessionId_corpus =
  forAll genCorpusOrAdversarial $ \(raw, expectedOk) ->
    let result  = Parse.mkSessionId raw
        isRight = case result of Right _ -> True; Left _ -> False
        agrees  = isRight == expectedOk
        ctx     = "input = " <> T.unpack raw
                <> ", expectedOk = " <> show expectedOk
                <> ", result = " <> show result
    in  counterexample ctx (property agrees)

-- | 'Parse.sanitizeTabName' invariants restated as an S-series
-- security property: any 'Right' output is safe to render verbatim
-- in a chat message (no ANSI, no control bytes, no over-long names,
-- and idempotent under the redaction pipeline).
prop_sanitizeTabName_security_invariants :: Property
prop_sanitizeTabName_security_invariants =
  forAll genAdversarialName $ \raw ->
    case Parse.sanitizeTabName raw of
      Left _     -> property True   -- a Left is always safe (no leak)
      Right name ->
            counterexample ("over-cap: " <> show name)
              (T.length name <= Parse.defaultMaxNameLen)
        .&&. counterexample ("control-byte leak: " <> show name)
              (not (T.any (\c -> c < ' ' && c /= ' ') name))
        .&&. counterexample ("ANSI leak: " <> show name)
              (not ("\ESC[" `T.isInfixOf` name)
               && not (T.any (== '\x9B') name))
        .&&. counterexample ("idempotence violation: " <> show name)
              (case Parse.sanitizeTabName name of
                 Right name' -> name' == name
                 Left _      -> False)


-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

-- | Generate either a corpus-conformant string (label: 'True') or an
-- adversarial string outside the corpus (label: 'False').
genCorpusOrAdversarial :: Gen (Text, Bool)
genCorpusOrAdversarial = do
  pick <- elements [True, False, True, False, True]
  if pick
    then do
      s <- listOf1 (elements ('-' : '_' : ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']))
      pure (T.pack s, True)
    else do
      let badChars = "/\\.\NUL %;:|&$`@()<>!#*"
      bad <- elements badChars
      rest <- listOf1 (elements (badChars ++ ['a'..'z']))
      pure (T.pack (bad : rest), False)

-- | Generate a name that is biased toward triggering at least one of
-- the four 'Parse.sanitizeTabName' rejection arms or one of the
-- redaction stages.
genAdversarialName :: Gen Text
genAdversarialName = T.pack <$> do
  flavour <- elements ['a', 'A', 'C', 'L', 'H', 'P', 'I', 'S', 'W']
  case flavour of
    'a' -> pure "\ESC[31mEVIL"                     -- ANSI
    'A' -> pure "\x9B\&csi"                        -- 8-bit CSI
    'C' -> pure "tab\there"                        -- control byte
    'L' -> pure (replicate 80 'x')                 -- over-long
    'H' -> pure "ssh prod-db.example.com"          -- hostname
    'P' -> pure "edit /etc/nginx/sites.d/x"        -- path
    'I' -> pure "ping 10.0.0.1"                    -- IPv4
    'S' -> pure "Could not resolve hostname xyz"   -- ssh stderr
    'W' -> pure "          "                       -- whitespace only
    _   -> pure "fallback"
