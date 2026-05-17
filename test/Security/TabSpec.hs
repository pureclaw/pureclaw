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

import Test.Hspec

spec :: Spec
spec = do
  describe "S-series — tabbed-chat security (WU0 scaffold; WU2/WU5/WU6/WU8/WU9 fill in)" $ do
    it "S1: spawn authorization (local) — /tab new N shell <cmd...> calls authorize cmd _env_policy before any subprocess; rejection yields TabSpawnAuthDenied PublicError, no process spawned" pending
    it "S2: spawn authorization (remote) — /tab new N ssh <host> <cmd...> calls authorizeRemote + mkSshHost host; rejected hosts (whitespace, leading -, NUL, shell metachars) yield BackendInvalidOption PublicError, no ssh subprocess" pending
    it "S3: smart-constructor validation — every kind-specific spawn arg passes through smart constructor (mkSshHost, mkTmuxSession, mkTmuxWindow, mkTmuxPane, mkLocalCommand); property test enumerates rejected patterns from terminal-backend-abstractions' adversarial list" pending
    it "S4: SSH identity sourcing — ssh tabs source SafeKeyPath from Vault slot _rc_sshIdentityKey; identities NEVER typed inline by user; missing Vault slot yields PublicError" pending
    it "S5: Crashed PublicError — Crashed e is internal; channel emit uses toPublicTabError; failure message contains neither host string, nor path, nor ssh stderr" pending
    it "S6: max-tab cap enforced at spawn — covered by A11; this entry exists for security audit traceability" pending
    it "S7: spawn rate limit — token-bucket _rc_spawnRateLimit (default 10 spawns/minute) per chat-user; exceeding yields PublicError, no spawn; defends against close-spawn cycling resource leak" pending
    it "S8: user-allowlist invariant — dispatcher reads from _ch_receive only; non-allowlisted user's messages produce zero handler invocations (runtime test; static-grep is code-review checklist)" pending
    it "S9: concurrent-active-tab cap (atomic, fail-fast) — _rc_maxConcurrentActive (default 4) enforced via TVar _env_activeCount inside atomically; STM retry NOT used (would block dispatcher per H4); N concurrent transitions yield exactly K successes + N-K TabConcurrencyLimit under randomised schedule" pending
    it "S10: /tab rename N <name> input sanitization — passes through sanitizeTabName (length cap, control-byte reject, ANSI reject, hostname/path/ssh-stderr redaction); rename rejected on NameRedactedToEmpty; success notes '(redacted host/path fragment)' when sanitization changed the name" pending
