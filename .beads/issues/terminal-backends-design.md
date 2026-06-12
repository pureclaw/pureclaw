# Foundational terminal backends: Local, SSH, Tmux (BackendHandle)

## Summary

Implement the **BackendHandle** abstraction for foundational subprocess I/O: Local, SSH, and Tmux (Attach mode). The tmux backend must attach to pre-existing windows statefully, both locally and over ssh.

Design: `docs/terminal-backend-abstractions.md` on branch `feat/terminal-backends-design` (PR pending). Approved by the metaswarm Design Review Gate (5/5 APPROVED, iteration 3 of 3).

## Scope

### In scope (v1)
- `PureClaw.Handles.Backend` — types (`BackendHandle`, `BackendKind`, `RecvResult`, `BackendError`, `BackendException`, `IdleSpec`, `EnvMap`, `Cols`, `Rows`), constants (`localIdle`, `sshIdle`, `tmuxIdle`, `testIdleSpec`, `forbiddenEnvVars`), helpers (`runBackend`, `withBackendHandle`, `withBackendHandleE`, `recvBytes`, `mkIdleSpec`, `mkEnvMap`, `toPublicError`, `defaultCredentialRedactor`), factories (`mkNoOpBackendHandle`, `mkInMemoryBackendHandle`), and the seven default-Opts top-levels
- `PureClaw.Backend.Pty` — `PtyIO`, `realPtyIO` (only module importing `posix-pty`); opaque `PtyFds` ADT
- `PureClaw.Backend.Pty.Fake` — `fakePtyIO`, `FakePtyConfig`, fake clock helpers
- `PureClaw.Backend.Local` — `mkLocalBackendHandle`, `mkLocalPtyBackendHandle`
- `PureClaw.Backend.SSH` — `mkSshBackendHandle`, `mkSshPipeBackendHandle`, `SshTarget`, `SshHost`, `mkSshHost`, `SshOpts`, `SshPipeOpts`, `ControlOpts`, `closeSshMultiplex`, `RemoteCommand`, `authorizeRemote`
- `PureClaw.Backend.Tmux` — `mkTmuxBackendHandle`, `TmuxTarget`, `TmuxSession`, `TmuxWindow`, `TmuxPane`, smart constructors, `TmuxOpts`, `SshLocation`, internal `TmuxCloseAction`
- `PureClaw.Internal.ShellQuote` — canonical shell-quoter
- `PureClaw.Internal.Redact` — `redactErr`, `redactBackendError`, `redactBackendException`
- `PureClaw.Security.Path` — add `KeysRoot`, `SafeKeyPath`, `mkSafeKeyPath`, `RuntimeRoot`, `SafeRuntimePath`, `mkSafeRuntimePath` (both `Safe*` with redacted `Show` matching existing `SafePath`)
- `PureClaw.Security.Policy` — add `_sp_allowedRemoteCommands :: AllowList CommandName`, `isRemoteCommandAllowed`, `allowRemoteCommand`, `denyRemoteCommand`; migrate every construction site in `src/`, `test/`, `app/`
- New cabal dependency: `posix-pty` (firewalled to `PureClaw.Backend.Pty`; verified by CI grep gate)
- `Harness/Tmux.hs` migration scope: replace local `shellEscape`/`shellEscapeStr` with imports from `Internal.ShellQuote`; `escapeForShell`/`stealthShellCommand` stay
- 100% test coverage (lines, branches, functions, statements) per `.coverage-thresholds.json`

### Out of scope (v2 or later)
- TmuxRpc backend (non-intrusive controller using send-keys/capture-pane)
- `Harness.Tmux` refactor onto `BackendHandle`
- Passphrase-protected ssh keys / ssh-agent / askpass helper
- Login-shell ssh (always requires `RemoteCommand` in v1)
- SSH reconnect-on-network-blip
- Tmux session/window discovery / listing
- `ControlMaster` sharing for tmux-over-ssh
- `posix-pty` replacement (track upstream dormancy)

## Definition of Done (19 enumerable, independently testable)

See `docs/terminal-backend-abstractions.md` § Acceptance Criteria for the full list. Summary:

1. `runBackend mkLocalBackendHandle "echo hi"` → `RecvSettled "hi\n"`
2. Local Pty `bash` survives `cd /tmp; pwd` as three turns
3. SSH Pty same three-turn `bash` sequence
4. Unresolvable host → `Left (BackendSshConnectFailed _)`
5. SSH argv contains all required hardened flags
6. Local Tmux: attach, send, capture, detach, window survives
7. Non-existent tmux window → `Left (BackendTmuxTargetMissing _)` (no auto-create)
8. Invalid `TmuxSession` → `Left (BackendInvalidOption _)` at construction
9. Remote tmux requires both `AuthorizedCommand` ssh and `RemoteCommand` tmux (type-enforced); ssh failure surfaces `BackendSshConnectFailed`
10. Remote argv shell-quotes both program path and args (test: `/opt/my tools/tmux`)
11. `_bh_close` idempotent + never throws
12. Pty overflow → `RecvTruncated`; latches across calls
13. `mkNoOpBackendHandle Pty` and `Pipe` behave per spec
14. `mkInMemoryBackendHandle` round-trips deterministically; property-test substrate
15. `SshHost` rejects leading `-`
16. `Show BackendException`/`Show BackendError` redacts hostnames/paths/key basenames (property-test)
17. All `SecurityPolicy` construction sites updated (enforced by `-Werror -Wmissing-fields` for construction, `-Werror -Wincomplete-record-updates` for updates)
18. Coverage hits thresholds in `.coverage-thresholds.json`
19. Haddock in `Handles.Backend` documents the choose-a-kind decision tree

## File Scope

```
NEW:
  src/PureClaw/Handles/Backend.hs
  src/PureClaw/Backend/Pty.hs
  src/PureClaw/Backend/Pty/Fake.hs
  src/PureClaw/Backend/Local.hs
  src/PureClaw/Backend/SSH.hs
  src/PureClaw/Backend/Tmux.hs
  src/PureClaw/Internal/ShellQuote.hs
  src/PureClaw/Internal/Redact.hs
  test/Handles/BackendSpec.hs (+ per-factory specs)

MODIFIED:
  src/PureClaw/Security/Path.hs       (+ SafeKeyPath, SafeRuntimePath + roots)
  src/PureClaw/Security/Policy.hs     (+ _sp_allowedRemoteCommands and helpers)
  src/PureClaw/Harness/Tmux.hs        (replace local shellEscape with Internal.ShellQuote import)
  pureclaw.cabal                      (+ posix-pty dependency; new exposed-modules)
  flake.nix                           (verify posix-pty builds on x86_64-linux + aarch64-darwin)
  Every SecurityPolicy construction site under src/, test/, app/

UNTOUCHED (explicitly):
  src/PureClaw/Handles/Process.hs     (BackendHandle and ProcessHandle are complementary)
  src/PureClaw/Harness/Tmux.hs        (escapeForShell, stealthShellCommand stay)
```

## Human Checkpoints

The plan-writer should propose checkpoints at minimum after:
- (1) `Handles.Backend` types + `mkNoOpBackendHandle` + `mkInMemoryBackendHandle` land with failing tests
- (2) `PtyIO` test seam + `fakePtyIO` is exercised by property tests on idle state machine
- (3) `Security.Path` adds `SafeKeyPath`/`SafeRuntimePath` (security-typed boundary)
- (4) `Security.Policy` migration complete (all construction sites updated, compiles green)
- (5) First real ssh backend lands (network failure modes exercised)
- (6) Tmux backend lands (TOCTOU pin via `@window_id`, detach-only close)
- (7) Final cross-unit review

## Plan-Writer Inputs (deferred-but-known issues to fold in)

Polish items raised by the 5 design reviewers, marked for plan integration:

**Architect:**
- `mkIdleSpec` also rejects `idleMinFirstByte > idleTimeoutMs`
- `PtyFds` is an opaque sum type (`RealPtyFds | FakePtyFds`) defined in `Backend.Pty` (type-level firewall, not just lint)
- Extend `forbiddenEnvVars`: `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, `SSH_AGENT_PID`
- Drainer pushes final `RsEof` sentinel on close (deterministic STM wake)
- `recvOutcome :: RecvResult a -> RecvOutcome` projection helper

**Designer:**
- Opts records use leading-underscore convention (`_pto_*` not `pto_*`) — matches `_eo_*` / `_pst_*` in existing code
- Top-level helpers `recv`/`recvWith` alongside `_bh_recv` (cheap DX)
- Derive `Ord` on `Cols`/`Rows`
- Add examples: direct ssh Pty (no tmux), `mkSshPipeBackendHandle`, `try @BackendException` recovery
- `mkTmuxSession`/etc. haddock as numbered checklist (matches `mkSafePath` style)
- `toPublicException :: BackendException -> PublicBackendError` (symmetry)

**Security:**
- `mkSafeKeyPath`/`mkSafeRuntimePath` validation: reject `..`, canonicalize, verify containment, mode/ownership checks
- `Show SafeKeyPath`/`Show SafeRuntimePath` redacted (matches existing `SafePath`)
- After writing ephemeral key file, `fstat` and verify `mode == 0400` and `owner uid == geteuid()`; `BackendInvalidOption` otherwise
- Honest doc note: "best-effort overwrite-with-zero before unlink" is theatre on COW/SSD filesystems
- Extend `forbiddenEnvVars`: `BASH_ENV`, `ENV`, `GIT_SSH_COMMAND`, `GIT_SSH`, `PROMPT_COMMAND`, `PS4`
- `SshHost` positive charset (RFC 1123 hostnames + bracketed IPv6)
- Defensive `-o PermitLocalCommand=no` in ssh argv
- Tmux close-time probe (if performed) reuses the same auth tokens
- `mkSshBackendHandle` with `so_control = Just _` fails closed if `co_controlPath` already exists (stale-multiplex defense)
- Property test for redactor includes key path basenames

**CTO:**
- DoD: CI grep gate enforces `posix-pty` import firewall
- DoD: `posix-pty` aarch64-darwin compile smoke test as v1 blocker
- Write 19 failing top-level tests on day 1 (TDD red phase enumerated)
- `mkInMemoryBackendHandle` kind-specific behavior nailed down (resize on `Pipe` vs `Pty`)
- Property test target for redactor explicit in DoD

**PM:**
- Surface "Attach mode shares the screen; bad for autonomous use" higher in the doc (currently only in Known Limitations)
- Add remote-attach window-survival AC parallel to local one

## Test Plan

- TDD red phase: 19 failing top-level tests committed before any factory implementation
- `fakePtyIO` + `mkInMemoryBackendHandle` + `testIdleSpec` (5ms quiet / 50ms total) for property-tests of idle state machine, redactor, truncation latching, BackendException redaction
- Real-system integration tests guarded by env vars (`PURECLAW_SSH_TEST_HOST`, `PURECLAW_TMUX_TEST_SOCKET`) — gated behind explicit invocation
- Coverage gate: `.coverage-thresholds.json` enforced before PR can be created
- CI matrix: `x86_64-linux` + `aarch64-darwin` build smoke + test (per Nix flake)

## Workflow

This Issue is **agent-ready** for the metaswarm orchestrated pipeline:
- Plan-writing phase → Plan Review Gate (3 adversarial reviewers must PASS)
- Choose execution method (orchestrated 4-phase / subagent-driven / parallel session)
- Execute with 100% coverage gate
- Self-reflect → final PR
