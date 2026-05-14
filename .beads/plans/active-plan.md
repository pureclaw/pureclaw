---
issue: 49
pr: 48
design_doc: docs/terminal-backend-abstractions.md
status: draft
date_drafted: 2026-05-14
---

# Implementation Plan — Foundational Terminal Backends

**Issue:** [#49](https://github.com/pureclaw/pureclaw/issues/49)
**Design PR:** [#48](https://github.com/pureclaw/pureclaw/pull/48)
**Design doc:** `docs/terminal-backend-abstractions.md` (5/5 APPROVED, gate iter 3)

## Strategy

13 work units (WU0–WU11, plus WU9.5 cross-cutting), ordered by
dependency. The plan front-loads the type layer (`Handles.Backend`,
`Redact`, no-op/in-memory backends, PtyIO seam, `Security.Path`
additions, `Security.Policy` migration) before any concrete backend
factory, so each factory ships against a stable foundation. Work units
WU2 / WU4 / WU5 / WU6 are parallelisable once WU1 lands.

**Critical TDD discipline:** WU0 commits the 24 enumerated failing tests
(one per DoD in the design doc's Acceptance Criteria) before any
production code. Subsequent work units flip them green one by one. No
work unit is "done" until its DoDs in the test suite are green AND
coverage thresholds are met for the modules it adds.

## Pre-Flight (Plan Validation)

- [x] Architecture aligned with codebase (`Handles.*` pattern, no effect system, ReaderT AppEnv IO)
- [x] Dependency graph acyclic (WU1 is the root; all others depend on it transitively)
- [x] API contracts spelled out in the design doc (types, signatures, examples)
- [x] Security review passed (Security agent APPROVED iter 3)
- [x] UI/UX (none — library-level work; no end-user UI surface)
- [x] External dependencies identified: **`posix-pty`** (new cabal dep; firewalled to `PureClaw.Backend.Pty`)
- [ ] **Pre-flight blocker to clear before WU0**: verify `posix-pty` builds under Nix flake on **both** `x86_64-linux` and `aarch64-darwin`. Doc lists this as DoD-eligible; the plan elevates it to a pre-flight gate because failure makes the entire SSH/Pty branch dead-on-arrival.

## Work Units

### WU0 — TDD red-phase scaffold

**Purpose:** Enumerate every DoD as a failing top-level test so progress is trackable from day 1.

**Spec:** Create `test/Handles/BackendSpec.hs` plus per-factory spec stubs. Write one failing `it` per DoD item (**24 total** — re-count the design doc's `## Acceptance Criteria (v1)` checklist; if the count differs at WU0 commit time, scaffold for whatever the doc currently enumerates), marked `pending` if the production-code dependency hasn't landed yet. The test file structure mirrors the module layout (one Spec per factory module).

**File scope (write):**
- `test/Handles/BackendSpec.hs` (new)
- `test/Backend/PtySpec.hs` (new)
- `test/Backend/LocalSpec.hs` (new)
- `test/Backend/SSHSpec.hs` (new)
- `test/Backend/TmuxSpec.hs` (new)
- `test/Internal/ShellQuoteSpec.hs` (new)
- `test/Internal/RedactSpec.hs` (new)
- `pureclaw.cabal` (test-suite stanza updates)

**DoDs covered:** scaffolding for 1–24 (all 24 DoDs appear as a pending `it`).

**Dependencies:** Pre-flight (posix-pty build verification).

**Human checkpoint:** **No.**

---

### WU1 — `PureClaw.Handles.Backend` core types

**Purpose:** Land the type layer that every subsequent work unit depends on.

**Spec:**
- Define: `BackendHandle`, `BackendKind`, `RecvResult` (with `Functor`/`Foldable`/`Traversable`/`Ord`), `IdleSpec` (smart-constructor, non-negative + `idleMinFirstByte ≤ idleTimeoutMs`), `Cols`/`Rows` (with `Ord`), `EnvMap`, `EnvValue` (redacted `Show`), `BackendError` (including `BackendBufferQuotaExceeded !Int` and `BackendBrokenTmuxTarget !TmuxTargetRef`), `BackendException`, `PublicBackendError`, `SshConnectFailure`, `PtyAllocFailure`, `TmuxTargetRef`, `InvalidOptionDetail`, `CommandName` re-export.
- Enumerate the fixed `_be_context` vocabulary as a `BackendContext` newtype with a closed set of constructors / named pattern-matchable strings: `"send"`, `"recv"`, `"close"`, `"ssh-write"`, `"ssh-disconnect"`, `"pty-eof"`, `"concurrent-use"`, `"tmux-detach"`, `"buffer-overflow"`. Document in haddock that new contexts MUST be added here (not freelanced at throw sites).
- Constants/defaults: `forbiddenEnvVars`, `localIdle`, `sshIdle`, `tmuxIdle`, `testIdleSpec`, `defaultCredentialRedactor`, `defaultPipeOpts`, `defaultPtyOpts`, `defaultSshOpts`, `defaultSshPipeOpts`, `defaultTmuxOpts`.
- Helpers: `runBackend`, `recvBytes`, `recvOutcome`, `mkIdleSpec`, `mkEnvMap`, `withBackendHandle`, `withBackendHandleE`, top-level `recv`/`recvWith`.
- Hand-written `Show` instances for `BackendError` / `BackendException` route through `redactErr` (a stub for now, real impl in WU2).
- Field naming: `_bh_*` (handle), `_pto_*` / `_po_*` / `_so_*` / `_spo_*` / `_co_*` / `_to_*` / `_imc_*` / `_fpc_*` / `_tt_*` (opts records — leading underscore consistent with `_eo_*`/`_pst_*` in existing code).
- Module-level haddock includes the choose-a-kind decision tree (Pipe vs Pty vs future TmuxRpc).

**File scope (write):**
- `src/PureClaw/Handles/Backend.hs` (new)
- `pureclaw.cabal` (expose the module)

**File scope (read-only):**
- `src/PureClaw/Handles/{Process,File,Shell,Harness}.hs` (style reference)
- `src/PureClaw/Security/Command.hs`

**DoDs covered:** 19 (haddock decision tree); foundations for all others.

**Dependencies:** WU0.

**Human checkpoint:** **Yes.** Types are the most-touched surface; pause for sign-off.

---

### WU2 — `PureClaw.Internal.Redact`

**Purpose:** Property-tested redaction helpers powering hand-written `Show` instances.

**Spec:**
- `redactErr :: SomeException -> Text` — strips workspace paths, key paths, runtime paths, hostnames, identity-file basenames, ssh stderr fragments.
- `redactBackendError :: BackendError -> Text`, `redactBackendException :: BackendException -> Text`.
- QuickCheck property tests: fuzz with byteString-embedded hostnames + key path basenames; assert none of the input substrings appear in the rendered output.
- Wire into the `Show` instances declared in WU1 (replace stubs).

**File scope (write):**
- `src/PureClaw/Internal/Redact.hs` (new)
- `src/PureClaw/Handles/Backend.hs` (replace `Show` stubs with real `redactErr` calls)
- `test/Internal/RedactSpec.hs` (move from WU0 pending to green)
- `pureclaw.cabal`

**DoDs covered:** 16 (Show redaction).

**Dependencies:** WU1.

**Human checkpoint:** **No.**

---

### WU3 — No-op + in-memory backends

**Purpose:** Provide the test seam every downstream factory uses.

**Spec:**
- `mkNoOpBackendHandle :: BackendKind -> BackendHandle` — pure. `Pty` recv yields `RecvSettled ""`; `_bh_resize` silent no-op for BOTH kinds (verified by separate `Pipe` and `Pty` tests asserting `_bh_resize (Cols 0) (Rows 0)` returns without throwing — DoD added in plan-review-iter-2 revision).
- `mkInMemoryBackendHandle :: BackendKind -> InMemoryConfig -> IO BackendHandle` — IORef-backed; deterministic; supports scripted replies + fake clock + simulated EOF. Resize behaviour: silent no-op on `Pipe`, IORef-recorded on `Pty` (for test introspection).
- `FakeClock` lives in `PureClaw.Internal.FakeClock` (new internal module) so it's reusable across `fakePtyIO` (WU7) and `mkInMemoryBackendHandle`.
- `toPublicError`, `toPublicException` (symmetry).

**File scope (write):**
- `src/PureClaw/Handles/Backend.hs` (extend with `mkNoOpBackendHandle`, `mkInMemoryBackendHandle`, `toPublicError`, `toPublicException`)
- `src/PureClaw/Internal/FakeClock.hs` (new)
- `test/Handles/BackendSpec.hs` (move DoD #11, #13, #14 from pending to green)
- `pureclaw.cabal`

**DoDs covered:** 11 (idempotent close), 13 (no-op shapes), 14 (in-memory round-trip).

**Dependencies:** WU1, WU2.

**Human checkpoint:** **No.**

---

### WU4 — `PureClaw.Internal.ShellQuote` (canonical quoter)

**Purpose:** Single source of truth for shell quoting, ahead of any caller that needs it.

**Spec:**
- `shellQuote :: Text -> Text` — single-quote wrapping with embedded-quote escaping (matches existing `Harness.Tmux.shellEscape`).
- Migrate `Harness.Tmux.shellEscape` and `shellEscapeStr` to delegate to `shellQuote`. **Do NOT touch** `escapeForShell` or `stealthShellCommand` (those stay; will retire with future TmuxRpc).
- Add haddock banner to `Harness/Tmux.hs` pointing readers to `Internal.ShellQuote` for new code.
- Property tests: round-trip through `bash -c` of `shellQuote "<adversarial>"` recovers the original; metacharacters never interpreted.

**File scope (write):**
- `src/PureClaw/Internal/ShellQuote.hs` (new)
- `src/PureClaw/Harness/Tmux.hs` (delegate `shellEscape`/`shellEscapeStr`; add banner haddock)
- `test/Internal/ShellQuoteSpec.hs` (green)
- `pureclaw.cabal`

**DoDs covered:** prerequisite for 10 (remote arg quoting); no DoD directly green.

**Dependencies:** WU0.

**Human checkpoint:** **No.**

---

### WU5 — `Security.Path` additions

**Purpose:** Typed paths for ssh identity files and runtime sockets, distinct from workspace.

**Spec:**
- New: `newtype KeysRoot = KeysRoot FilePath`, `newtype RuntimeRoot = RuntimeRoot FilePath` (exported constructors; configuration values).
- New: `data SafeKeyPath`, `data SafeRuntimePath` (constructors NOT exported).
- `mkSafeKeyPath :: KeysRoot -> FilePath -> IO (Either PathError SafeKeyPath)`. Validation rules (match `mkSafePath` rigor):
  1. Reject `..` traversal in the requested path.
  2. Canonicalize via `canonicalizePath` and verify the result is under `KeysRoot`.
  3. Reject absolute paths that resolve outside the root.
  4. Reject non-existent roots.
  5. After creation/write of a key file, `fstat` and verify `mode == 0400` and `owner uid == geteuid()`; surface `PathError` (new variant `PathInsecureMode`) otherwise.

**Cascading change:** adding `PathInsecureMode` extends `PathError`. The Plan Review Gate Feasibility scan found one external pattern-match site (`test/Security/PathSpec.hs:80-91`); it is non-exhaustive so the cascade is bounded. Verify no other exhaustive pattern matches exist via `git grep -nE '\bcase\s+\w+\s+::\s+PathError\b' src/ test/ app/` before landing. Add `BackendInvalidOption` mapping inside `Backend/SSH.hs` factories so callers see a `BackendError`, not a raw `PathInsecureMode`.
- `mkSafeRuntimePath :: RuntimeRoot -> FilePath -> IO (Either PathError SafeRuntimePath)` — same rules; mode check is `0600` for known_hosts, socket-creation mode handled by ssh itself.
- Redacted `Show` instances for `SafeKeyPath` and `SafeRuntimePath` (matching existing `SafePath`).
- Setup helper: `ensureKeysRoot :: IO KeysRoot` and `ensureRuntimeRoot :: IO RuntimeRoot` create the directories mode 0700 atomically if missing.

**File scope (write):**
- `src/PureClaw/Security/Path.hs` (extend)
- `test/Security/PathSpec.hs` (extend with `..`-traversal, symlink-escape, mode-check tests)

**DoDs covered:** prerequisite for 5 (SSH defaults), supports 16 (path redaction).

**Dependencies:** WU0.

**Human checkpoint:** **Yes.** Security-typed boundary; auditor sign-off.

---

### WU6 — `Security.Policy` migration

**Purpose:** Extend `SecurityPolicy` with a remote-command allowlist; update every construction site.

**Spec:**
- Add `_sp_allowedRemoteCommands :: AllowList CommandName` to `SecurityPolicy`.
- Helpers: `isRemoteCommandAllowed`, `allowRemoteCommand`, `denyRemoteCommand`.
- Set `_sp_allowedRemoteCommands = AllowList Set.empty` in `defaultPolicy` (deny by default).
- **Enumerate all construction sites up front**: `git grep -nE '\bSecurityPolicy\b' src/ test/ app/` (the broader regex catches both brace-form `SecurityPolicy {...}` AND positional-form `SecurityPolicy AllowAll Full` — the latter exists at `test/Security/CommandSpec.hs:46` per Plan Review Gate Feasibility findings). List each. Update every one.
- `-Werror -Wmissing-fields` (construction sites) and `-Werror -Wincomplete-record-updates` (record-update sites) make any miss a compile error.

**File scope (write):**
- `src/PureClaw/Security/Policy.hs` (extend)
- Every file listed by the grep above (estimated 5–10 sites across src/test/app)
- `test/Security/PolicySpec.hs` (extend)

**DoDs covered:** 17.

**Dependencies:** WU0. (Independent of WU1–WU5 but touches surface that many downstream modules import — finish before WU9.)

**Human checkpoint:** **Yes.** Touches every construction site; sanity-check the enumeration.

---

### WU7 — `PureClaw.Backend.Pty` (real + fake)

**Purpose:** The PTY allocation seam; the ONLY module importing `posix-pty`.

**Spec:**
- New cabal dep: `posix-pty` (added to `pureclaw.cabal` library `build-depends`; Nix flake input if needed).
- Define: opaque `data PtyFds = RealPtyFds <internal> | FakePtyFds <internal>` (constructors NOT exported). The opaque ADT is the **type-level firewall**: a future swap to direct `System.Posix.Terminal` is a single-file change because no downstream module can pattern-match on the constructors.
- `PtyIO` record: `pio_open :: IO PtyFds`, `pio_resize :: PtyFds -> Cols -> Rows -> IO ()`, `pio_close :: PtyFds -> IO ()`.
- `realPtyIO :: PtyIO` — backed by `posix-pty`.
- `fakePtyIO :: FakePtyConfig -> IO PtyIO` — IORef-backed; driven by `FakeClock` from WU3; supports `fpc_initialOutput`, `fpc_eofAfterBytes`.
- Drainer infrastructure: `DrainState` (STM-based: `TBQueue RecvSignal`, `TVar Bool` for truncate latch, `TVar (Maybe Time)` for last-byte-at, `TVar Bool` for drainerDone), drainer-async helper that pushes `RsEof` sentinel on close for deterministic STM wake.
- **Process-wide buffer quota**: `Handles.Backend` maintains a process-wide `QSem` (capacity = aggregate-cap-MiB; configurable via `PURECLAW_BACKEND_AGGREGATE_CAP_MIB` env var, default 64). Pty-bearing factories `bracket`/`finally`-acquire `_pto_recvBufferCap` MiB from the QSem at construction; release on `_bh_close` (idempotent — release is in the close action, protected against double-release by an internal `TVar Bool` flag). On oversubscription, construction returns `Left (BackendBufferQuotaExceeded _pto_recvBufferCap)`.
- **Idle state machine test coverage**: include a property test that exercises every path in the diagram, including the no-bytes-ever path (`RecvTimedOut ""` when `idleTimeoutMs` expires with the drainer never producing a chunk). DoD #21 in the design doc (or current numbering of "RecvTimedOut on no bytes").
- Idle state machine (per design doc): `waiting-for-first-byte → draining → settled|timed-out|eof|truncated`; property-tested against `fakePtyIO` + `testIdleSpec`.
- **CI grep gate**: a CI step (`scripts/check-pty-firewall.sh`) that fails the build on any `import` of `Posix.Pty` outside the firewalled module path. Uses a path-based whitelist (NOT `--exclude-dir`, which would not protect the file `src/PureClaw/Backend/Pty.hs` itself): `grep -RIn 'import\s\+\(qualified\s\+\)\?Posix\.Pty' src/ | grep -v -E '^src/PureClaw/Backend/Pty(\.hs|/Fake\.hs):'` — fails if anything is left. Wired into the project's CI workflow at `.github/workflows/ci.yml`.
- **aarch64-darwin compile smoke**: ensure CI runs `nix develop . --command cabal build` on both flake targets. The existing `.github/workflows/ci.yml` already has a matrix with `x86_64-linux` and `aarch64-darwin` (per Feasibility finding); the WU's task is to verify `posix-pty` builds cleanly on both, not to introduce a new matrix.
- **`realPtyIO` coverage policy**: `realPtyIO` (the `posix-pty`-backed `PtyIO`) is exercised only via integration tests that spawn real subprocesses (DoD #2 bash, DoD #3 ssh) — those tests do cover the real PTY path. Lines exclusively in `realPtyIO` that cannot be reached without a real PTY (kernel-error paths) are excluded from the line-coverage gate via `-- HPC:Exclude` annotations; the threshold in `.coverage-thresholds.json` accounts for this. `fakePtyIO` carries 100% branch coverage. State this explicitly in `Backend/Pty.hs` module haddock.

**File scope (write):**
- `src/PureClaw/Backend/Pty.hs` (new)
- `src/PureClaw/Backend/Pty/Fake.hs` (new)
- `test/Backend/PtySpec.hs` (move from pending: drainer state-machine property tests)
- `pureclaw.cabal` (+ posix-pty; expose modules)
- `flake.nix` (verify posix-pty closure on both targets)
- `scripts/check-pty-firewall.sh` (new)
- `.github/workflows/*` (wire firewall gate + aarch64-darwin smoke; if no workflow exists yet, add a minimal one)

**DoDs covered:** 12 (truncation latch), 18 (coverage on Pty); enables 6/7/8/9 via test seam.

**Dependencies:** WU0, WU1, WU3.

**Human checkpoint:** **Yes.** First use of posix-pty + first CI gate addition.

---

### WU8 — `PureClaw.Backend.Local`

**Purpose:** Local subprocess backends — Pipe (one-shot) and Pty (conversational).

**Spec:**
- `mkLocalBackendHandle :: AuthorizedCommand -> PipeOpts -> IO (Either BackendError BackendHandle)` — pipe-based, stdin/stdout/stderr merged at OS level via `setStderr (useHandleOpen stdoutH)`; close stdin after `_po_stdinBytes`; read until EOF.
- `mkLocalPtyBackendHandle :: AuthorizedCommand -> PtyOpts -> IO (Either BackendError BackendHandle)` — spawns inside PTY via `pto_io.pio_open`; drainer + STM signalling per WU7; complete env from `_pto_env` + minimal `TERM`/`PATH` if absent.
- Idempotent `_bh_close` releases process + PTY.

**File scope (write):**
- `src/PureClaw/Backend/Local.hs` (new)
- `test/Backend/LocalSpec.hs` (move DoD #1, #2 to green)
- `pureclaw.cabal`

**DoDs covered:** 1 (`echo hi` → `RecvSettled "hi\n"`), 2 (bash `cd /tmp; pwd` three-turn).

**Dependencies:** WU1, WU2, WU3, WU7.

**Human checkpoint:** **No.**

---

### WU9 — `PureClaw.Backend.SSH`

**Purpose:** SSH backends, with all security defaults hardcoded.

**Spec:**
- `mkSshBackendHandle`, `mkSshPipeBackendHandle` with the full hardened argv (see design doc § SSH Security Defaults — `-F /dev/null`, `StrictHostKeyChecking=accept-new`, etc., plus `-o PermitLocalCommand=no` defensive override).
- `SshTarget`, `SshHost` (validated newtype with RFC 1123 hostname charset + bracketed-IPv6; rejects leading `-`).
- `SshOpts` (Pty), `SshPipeOpts` (Pipe — distinct opts type, no ignored fields).
- `ControlOpts` (`_co_controlPath :: SafeRuntimePath`, `_co_persistSecs :: Int`); `closeSshMultiplex :: AuthorizedCommand -> ControlOpts -> IO ()` — takes the `AuthorizedCommand` that opened the multiplex (preserves §5.1 invariant); unlinks the socket file on close; `mkSshBackendHandle` with `_so_control = Just _` fails closed if `_co_controlPath` already exists at construction (stale-multiplex defense).
- `RemoteCommand` (constructor NOT exported), `authorizeRemote :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError RemoteCommand`, accessors `getRemoteProgram`/`getRemoteArgs`.
- v1 credential model: Vault loads the (passphrase-less) key; backend writes to ephemeral `SafeKeyPath` mode 0400, ssh uses `-i`, file unlinked + best-effort zero on close.
- Extend `forbiddenEnvVars` in `Handles.Backend` to include `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, `SSH_AGENT_PID`, `BASH_ENV`, `ENV`, `GIT_SSH_COMMAND`, `GIT_SSH`, `PROMPT_COMMAND`, `PS4`.
- Construction errors as `Left BackendError`; send/recv errors as `BackendException`; failure modes structured (no free Text).

**File scope (write):**
- `src/PureClaw/Backend/SSH.hs` (new)
- `src/PureClaw/Handles/Backend.hs` (extend `forbiddenEnvVars`)
- `test/Backend/SSHSpec.hs` (move DoD #3, #4, #5, #15 to green)
- `pureclaw.cabal`

**DoDs covered:** 3 (3-turn ssh bash), 4 (unresolvable host), 5 (argv flags), 15 (`SshHost` rejects leading `-`).

**Dependencies:** WU1–WU8.

**Human checkpoint:** **Yes.** First real ssh + network failure modes.

---

### WU10 — `PureClaw.Backend.Tmux`

**Purpose:** Tmux Attach mode, local and over ssh, with detach-only close.

**Spec:**
- `TmuxSession`, `TmuxWindow`, `TmuxPane` (smart constructors; charset `[A-Za-z0-9_./@:=+-]` no leading `-`; haddock as a numbered checklist matching `mkSafePath` style).
- `TmuxTarget`, `TmuxOpts` (`_to_pty :: PtyOpts`, `_to_socketPath :: Maybe SafeRuntimePath` validated local-fs-only).
- `SshLocation = LocalHost !AuthorizedCommand | RemoteHost !SshTarget !AuthorizedCommand !RemoteCommand` — type-enforced authorization split.
- `mkTmuxBackendHandle :: SshLocation -> TmuxTarget -> TmuxOpts -> IO (Either BackendError BackendHandle)`. Pin-resolution at construction: `tmux <socket?> display-message -p -t '<session>:<window>' '#{window_id}'`, validate output against `^@\d+$`; reject hostile injection.
- Remote-side composition: shell-quote both program path and args via `Internal.ShellQuote.shellQuote`. v1 does NOT share `ControlMaster` for tmux (always fresh ssh hop).
- Internal `TmuxCloseAction = TmuxDetach` (one-constructor sum, constructor NOT exported). `_bh_close` writes the detach key sequence into the existing PTY (does NOT open a new ssh); tolerates write failure as "already detached"; cancels drainer; releases local PTY. Idempotent and never throws.
- **Mid-session destruction test**: a `fakePtyIO`-driven test simulates the pinned `@window_id` being destroyed and re-created with the same name mid-conversation. Asserts that the next `_bh_send`/`_bh_recv` raises `BackendException` with `_be_cause` containing a `BackendBrokenTmuxTarget` payload (or returns it as a `RecvResult`-equivalent — pick the surface that matches the implementation but cover the path). DoD added in plan-review-iter-2 revision.

**File scope (write):**
- `src/PureClaw/Backend/Tmux.hs` (new)
- `test/Backend/TmuxSpec.hs` (move DoD #6, #7, #8, #9, #10 to green)
- `pureclaw.cabal`

**Additional DoD #20** (added in plan-review iter-2 revision): `mkTmuxBackendHandle` with `RemoteHost` attaches to a pre-existing remote window over ssh, sends a command, captures output, and `_bh_close` detaches without destroying the window. The remote target window is still present after close, verified by a second short-lived ssh + `tmux list-windows` from the test harness. (Parallels DoD #6 for the local case.)

**DoDs covered:** 6 (local attach + survive close), 7 (no auto-create), 8 (invalid session at construction), 9 (RemoteHost two-auth + ssh fail surfacing), 10 (program-path + args quoted, `/opt/my tools/tmux` case), 20 (remote attach + survive close), 21 (BackendBrokenTmuxTarget mid-session — added iter-2).

**Dependencies:** WU1–WU9.

**Human checkpoint:** **Yes.** TmuxCloseAction typed close + TOCTOU pin.

---

### WU9.5 — SSH disconnect-mid-recv test (cross-cutting)

**Purpose:** Cover the edge case Plan Review Gate Completeness called out — transport drops during a live conversation, not at construction.

**Spec:** A test under `test/Backend/SSHSpec.hs` that, using `fakePtyIO`, simulates ssh subprocess exit mid-recv and asserts (a) `_bh_recv` returns `RecvEof <bytes-so-far>` deterministically, (b) a subsequent `_bh_send` throws `BackendException` with `_be_context = "ssh-write"`, (c) `_bh_close` is idempotent and never throws. No real ssh required.

Similarly a test for the documented concurrency invariant: two threads call `_bh_send` on the same handle; the second observes `BackendException` with `_be_context = "concurrent-use"` rather than corrupting state. (Implementation may use a guarding `MVar` to detect concurrent entry; doc rule says single-threaded so this is enforcement of the documented contract.)

**File scope (write):**
- `test/Backend/SSHSpec.hs` (extend)
- `src/PureClaw/Handles/Backend.hs` (add concurrent-use detection MVar guard if not already present)

**DoDs covered:** edge cases identified by Plan Review Gate Completeness ("SSH disconnect mid-recv", "concurrent _bh_send / _bh_recv").

**Dependencies:** WU9.

**Human checkpoint:** **No.**

---

### WU11 — Final cross-unit review + coverage gate + PR

**Purpose:** Cross-unit integration; verify coverage; create implementation PR.

**Spec:**
- Run full test suite under coverage (`cabal test --enable-coverage`).
- Enforce thresholds from `.coverage-thresholds.json` (100% lines/branches/functions/statements on new modules).
- Verify `posix-pty` import firewall CI gate passes.
- Verify aarch64-darwin + x86_64-linux build smoke passes.
- Run `/self-reflect` to extract learnings into the knowledge base.
- Commit knowledge base updates.
- Create implementation PR; link Issue #49; cite design PR #48.

**File scope (write):**
- `.beads/knowledge/*` (if `/self-reflect` updates)

**DoDs covered:** 18 (coverage thresholds).

**Dependencies:** WU0–WU10, WU9.5.

**Human checkpoint:** **Yes.** Final pre-PR review.

---

## Dependency Graph

```
              pre-flight (posix-pty Nix build verification)
                        │
                        ▼
                       WU0  ◄──── independent: WU4, WU5, WU6 can also start
                        │
                        ▼
                       WU1 ─── types layer (universal dependency)
                        │
            ┌───────────┼───────────┬────────────┐
            ▼           ▼           ▼            ▼
           WU2         WU3         WU5          WU6
        (Redact)  (NoOp+InMem)  (Sec.Path)  (Sec.Policy)
            │           │           │            │
            └─────┬─────┘           │            │
                  ▼                 │            │
                 WU7              (used by ssh in WU9)
                (PtyIO)             │
                  │                 │
                  ▼                 │
                 WU8  (Local)       │
                  │                 │
                  └────────────┬────┘
                               ▼
                              WU9  (SSH; uses WU4 quoter, WU5 paths, WU6 policy)
                               │
                               ▼
                              WU10  (Tmux; uses WU9 SSH for RemoteHost)
                               │
                               ▼
                              WU11  (final review + coverage + PR)
```

**Parallelisation opportunity:** WU2, WU4, WU5, WU6 can run concurrently after WU1. WU7 starts after WU3.

## Recovery Protocol

Per CLAUDE.md context-recovery section:
- Approved plan: this file (`.beads/plans/active-plan.md`).
- Execution state: `.beads/context/execution-state.md` (updated after each phase transition).
- Project context: `.beads/context/project-context.md` (updated after each WU commits).

On compaction or interruption, the next agent runs `bd prime --work-type recovery` (if available) or reads this file directly.

## Anti-Patterns to Avoid

- **No `--no-verify`** on commits. Pre-commit hooks exist for a reason.
- **No self-certification.** The orchestrator validates independently against the spec.
- **No file-scope creep.** Stay within the listed paths per WU.
- **No skipping the red phase.** Every DoD has its failing test committed before production code.
- **No coverage shortcuts.** `.coverage-thresholds.json` is the source of truth; failures block PR creation.
- **No new dependencies** beyond `posix-pty`. The plan enumerates this one explicitly.
- **No `Harness.Tmux` refactor beyond `shellEscape`/`shellEscapeStr` migration.** That stays in scope; deeper migration is v2.

## Iter-3 Revision Notes (Plan Review Gate)

Changes vs iter-2 in response to Plan Review Gate iter-2 findings:

**Completeness blockers addressed:**
- Updated DoD count from 19 → 24 throughout the plan (Strategy + WU0 spec + WU0 DoD-coverage line). Design doc's `## Acceptance Criteria (v1)` now enumerates 24 DoDs after additions for `BackendBrokenTmuxTarget` mid-session, `RecvTimedOut ""` on no-bytes, `BackendBufferQuotaExceeded` on oversubscription, and `mkNoOpBackendHandle Pipe`/`Pty` resize no-op verification.
- Added process-wide `QSem` buffer-quota infrastructure to WU7 spec: capacity from env var `PURECLAW_BACKEND_AGGREGATE_CAP_MIB` (default 64); `bracket`/`finally`-protected acquire/release; double-release defended by internal `TVar Bool`; oversubscription returns `Left (BackendBufferQuotaExceeded n)`.
- Added explicit test for `RecvTimedOut ""` on no-bytes path to WU7 idle-state-machine property tests.
- Added explicit test for mid-session tmux destruction (`BackendBrokenTmuxTarget`) to WU10.
- Added explicit `_bh_resize` no-op assertions for both kinds in WU3.

**Completeness warnings addressed:**
- Updated Strategy: now correctly says "13 work units (WU0–WU11, plus WU9.5)".
- Enumerated `_be_context` vocabulary in WU1 spec as a closed set documented in haddock: `"send"`, `"recv"`, `"close"`, `"ssh-write"`, `"ssh-disconnect"`, `"pty-eof"`, `"concurrent-use"`, `"tmux-detach"`, `"buffer-overflow"`.
- DoD #24 (haddock decision tree) verification: lightweight doctest asserting the haddock contains the strings `"Pipe"`, `"Pty"`, `"decision tree"` so deletion fails CI.

**Feasibility warnings addressed:**
- Fixed `_p_to_*` → `_pto_*` regression in the design doc (the `to_` → `_to_` replace_all mid-iter-2 corrupted the longer prefix; restored to `_pto_*`).
- Acknowledged that `-Wmissing-fields` is implicit in `-Wall` (project conventions section) rather than separately declared.
- Noted `recv`/`recvWith` top-level helpers (plan) are not yet in design doc's exported-symbol list — to be reconciled at implementation time.

## Iter-2 Revision Notes

Changes vs iter-1 draft (in response to Plan Review Gate iter-1 findings):

**Completeness blockers addressed:**
- Added DoD #20 (remote tmux window survival after close) to design doc + WU10 coverage.
- Added 3 missing examples to design doc: direct ssh Pty (no tmux), `mkSshPipeBackendHandle` one-shot, `try @BackendException` recovery.
- Moved the "Tmux Attach shares the screen" v1 limitation into a prominent callout at the top of the design doc (before Motivation), not buried in V1 Known Limitations.
- Added honest doc note: "best-effort overwrite-with-zero before unlink is theatre on COW/SSD filesystems" — clarifies that the real mitigations are short lifetime + 0400 mode + per-process KeysRoot.

**Completeness warnings addressed:**
- Added new WU9.5 covering SSH disconnect-mid-recv test and concurrent-use invariant test (both edge cases the Completeness reviewer flagged as unenforced).
- Added explicit note that `_bh_send` on a closed pipe / dead transport throws `BackendException` with fixed-vocabulary `_be_context` tags (`"ssh-write"`, `"concurrent-use"`).

**Feasibility warnings addressed:**
- Broadened the SecurityPolicy enumeration regex to `\bSecurityPolicy\b` (catches positional ctor at `test/Security/CommandSpec.hs:46` that brace-form-only regex misses).
- Fixed the CI grep firewall to use a path-based whitelist instead of `--exclude-dir` (the directory exclude does not protect the file `src/PureClaw/Backend/Pty.hs` itself).
- Updated design doc to use leading-underscore field names (`_pto_*` etc.) consistently — was internally inconsistent with project convention and the plan.
- Acknowledged `PathError` new-constructor cascade in WU5 with a grep-driven verification step.
- Noted aarch64-darwin CI matrix already exists in `.github/workflows/ci.yml`; WU7's task is verification of `posix-pty` on that matrix, not introducing a new one.

**Scope warnings addressed:**
- Added `defaultCredentialRedactor` to WU1's exported constants (was missing from earlier draft; referenced as `_pto_redactor` default).
- Added `realPtyIO` coverage policy: integration tests cover real-PTY path; kernel-error lines `-- HPC:Exclude`'d explicitly; `fakePtyIO` carries 100% branch coverage.
- Clarified CI matrix enforcement uses the existing pre-merge workflow (no new infrastructure).

## Open Questions

- None at draft-time. The Plan Review Gate iter-2 reviewers will surface anything missed.
