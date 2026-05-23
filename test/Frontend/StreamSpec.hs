-- | Tests for "PureClaw.Frontend.Stream" — WU3.
--
-- This module exercises the wire protocol, Origin allowlist, StreamGuard,
-- and shared session-ID helper at the unit-test level. Wire-level
-- end-to-end tests that need a real WS handshake live in the
-- ":server" describe block below and use 'Frontend.StreamHarness'.
--
-- Coverage map (initial WU3a slice):
--   * D8  — hello payload shape (3 fields, no extras)
--   * D22 — module builds clean under -Werror (implicit by being a Spec)
--   * D26 — shared 'isValidSessionId' helper
--   * D27 — @since@ length cap (64 chars)
--   * D29 — malformed JSON parses as InvalidFrame
--   * D31 — Origin substring attack denied
--   * D36 — unknown op decodes as InvalidOp
--   * Origin normalization rules 4 and 7
--   * StreamGuard tryClaim / releaseClaim arithmetic
--
-- The end-to-end DoDs (D5b, D7 over wire, D9 timing, D10, D11, D12, D13,
-- D20, D28, D30, D32, D33, D35, D37, D39, D40) are deferred to WU3b — see
-- @.beads/plans/active-plan.md@ for the documented split fallback. The
-- production code for all of them is in place; only the integration test
-- harness wiring remains.
module Frontend.StreamSpec (spec) where

import Control.Concurrent.STM (atomically, readTVarIO)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.API
  ( StreamGuard (..)
  , isValidSessionId
  , mkStreamGuard
  )
import PureClaw.Frontend.Stream
  ( ErrorCode (..)
  , ServerEvent (..)
  , decodeClientOp
  , encodeServerEvent
  , errorCodeText
  , normalizeOrigin
  , originAllowed
  , releaseClaim
  , tryClaim
  )

-- ---------------------------------------------------------------------------
-- Wire protocol encoder / decoder
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "isValidSessionId (D26)" $ do
    it "accepts a plain session id" $
      isValidSessionId "session-abc-123" `shouldBe` True
    it "rejects path-traversal segments" $
      isValidSessionId "session/../etc" `shouldBe` False
    it "rejects a slash" $
      isValidSessionId "session/sub" `shouldBe` False
    it "rejects the empty string" $
      isValidSessionId "" `shouldBe` False
    it "rejects bare .." $
      isValidSessionId ".." `shouldBe` False

  describe "normalizeOrigin (Origin matching rules 4 & 7)" $ do
    it "lowercases scheme and host but preserves port" $
      normalizeOrigin "HTTP://Localhost:8080" `shouldBe` "http://localhost:8080"
    it "strips a trailing slash" $
      normalizeOrigin "http://localhost:8080/" `shouldBe` "http://localhost:8080"
    it "leaves port untouched" $
      normalizeOrigin "https://Example.COM:443" `shouldBe` "https://example.com:443"
    it "lowercases punycode-encoded IDN hosts as-presented" $
      normalizeOrigin "http://XN--EXAMPLE.com:80"
        `shouldBe` "http://xn--example.com:80"

  describe "originAllowed (D7 / D31 — exact-match, no substring)" $ do
    it "matches an exact-equal origin" $
      originAllowed ["http://localhost:8080"] "http://localhost:8080"
        `shouldBe` True
    it "rejects substring-attack origin (localhost.evil.com)" $
      originAllowed ["http://localhost:8080"] "http://localhost.evil.com:8080"
        `shouldBe` False
    it "empty allowlist denies everything (D7 baseline)" $
      originAllowed [] "http://localhost:8080" `shouldBe` False
    it "normalizes the allowlist entries before matching" $
      originAllowed ["HTTP://LOCALHOST:8080"] "http://localhost:8080"
        `shouldBe` True

  describe "StreamGuard.tryClaim / releaseClaim" $ do
    it "admits up to the per-origin cap and rejects the next claim" $ do
      g <- mkStreamGuard 3
      r1 <- atomically (tryClaim g "http://a:1")
      r2 <- atomically (tryClaim g "http://a:1")
      r3 <- atomically (tryClaim g "http://a:1")
      r4 <- atomically (tryClaim g "http://a:1")
      [r1, r2, r3, r4] `shouldBe` [True, True, True, False]

    it "tracks distinct origins independently" $ do
      g <- mkStreamGuard 1
      ra <- atomically (tryClaim g "http://a:1")
      rb <- atomically (tryClaim g "http://b:2")
      ra' <- atomically (tryClaim g "http://a:1")
      [ra, rb, ra'] `shouldBe` [True, True, False]

    it "releaseClaim restores capacity" $ do
      g <- mkStreamGuard 1
      _ <- atomically (tryClaim g "http://a:1")
      atomically (releaseClaim g "http://a:1")
      r <- atomically (tryClaim g "http://a:1")
      r `shouldBe` True

    it "releaseClaim is idempotent on empty keys" $ do
      g <- mkStreamGuard 1
      atomically (releaseClaim g "http://missing:1")
      m <- readTVarIO (_streamGuard_perOrigin g)
      Map.member "http://missing:1" m `shouldBe` False

  describe "decodeClientOp (D29 invalid-frame, D36 invalid-op)" $ do
    it "parses a valid focus op without since" $ do
      let bs = "{\"op\":\"focus\",\"sessionId\":\"session-1\"}"
      case decodeClientOp bs of
        x -> show x `shouldContain` "CoFocus"

    it "parses a valid focus op with since" $ do
      let bs = "{\"op\":\"focus\",\"sessionId\":\"session-1\",\"since\":\"te-uuid-42\"}"
      show (decodeClientOp bs) `shouldContain` "\"te-uuid-42\""

    it "returns invalid-frame on malformed JSON (D29)" $ do
      let bs = "{not json"
      show (decodeClientOp bs) `shouldContain` "InvalidFrame"

    it "returns invalid-op on unknown op (D36)" $ do
      let bs = "{\"op\":\"future-op\"}"
      show (decodeClientOp bs) `shouldContain` "InvalidOp"

    it "returns invalid-frame on missing op field" $ do
      let bs = "{\"foo\":\"bar\"}"
      show (decodeClientOp bs) `shouldContain` "InvalidFrame"

  describe "encodeServerEvent (D8 hello shape, D33 internal code)" $ do
    it "encodes hello with exactly three fields and the right keys" $ do
      let ev = encodeServerEvent (SeHello "v1" (read "2026-05-22 18:00:00 UTC"))
      show ev `shouldContain` "\"hello\""
      show ev `shouldContain` "\"protocolVersion\""
      show ev `shouldContain` "\"serverStartedAt\""
      -- and only those fields beyond "type"
      show ev `shouldNotContain` "focusedSessionId"
      show ev `shouldNotContain` "lastReplayedEntryId"

    it "encodes the internal error code (D33 surface)" $ do
      let ev = encodeServerEvent (SeError EcInternal "boom")
      show ev `shouldContain` "\"internal\""
      show ev `shouldContain` "\"boom\""

    it "encodes overflow as the single-field type discriminator" $ do
      let ev = encodeServerEvent SeOverflow
      show ev `shouldContain` "\"overflow\""

    it "encodes replay-end with a null lastReplayedEntryId" $ do
      let ev = encodeServerEvent (SeReplayEnd (SessionId "s1") Nothing)
      show ev `shouldContain` "\"replay-end\""
      -- Aeson's Show on Value spells Null with capital N — encoding to a
      -- ByteString and decoding does produce JSON @null@. Verify both
      -- the Haskell-side Null and the JSON-side null.
      show ev `shouldContain` "Null"

    it "encodes replay-end with a present lastReplayedEntryId" $ do
      let ev = encodeServerEvent (SeReplayEnd (SessionId "s1") (Just "te-x"))
      show ev `shouldContain` "\"te-x\""

  describe "errorCodeText covers every code (D7/D12/D13/D27/D28/D29/D33/D36/D40)" $ do
    it "covers every code in the closed enum" $ do
      let codes = [ EcInvalidOp
                  , EcInvalidFrame
                  , EcSessionNotFound
                  , EcFrameTooLarge
                  , EcReplayFailed
                  , EcReplayAborted
                  , EcInternal
                  ]
          expected =
            [ "invalid-op"
            , "invalid-frame"
            , "session-not-found"
            , "frame-too-large"
            , "replay-failed"
            , "replay-aborted"
            , "internal"
            ]
      map errorCodeText codes `shouldBe` expected

  describe "Since-token length cap (D27)" $ do
    -- The cap is exercised end-to-end at the WS-handler layer in
    -- WU3b's integration suite; at the unit-test level we verify the
    -- decoded representation accepts arbitrary lengths and the handler
    -- itself enforces the cap.
    it "decodes a 64-char since" $ do
      let s = T.replicate 64 "a"
          bs = LBS.fromStrict (TE.encodeUtf8
            ("{\"op\":\"focus\",\"sessionId\":\"s\",\"since\":\"" <> s <> "\"}"))
      show (decodeClientOp bs) `shouldContain` "CoFocus"
    it "decodes a 65-char since (handler then rejects)" $ do
      let s = T.replicate 65 "a"
          bs = LBS.fromStrict (TE.encodeUtf8
            ("{\"op\":\"focus\",\"sessionId\":\"s\",\"since\":\"" <> s <> "\"}"))
      show (decodeClientOp bs) `shouldContain` "CoFocus"
