---
issue: pureclaw-3oy.33
epic: pureclaw-3oy
design_doc: docs/harness-jsonl-capture.md
status: IN-PROGRESS — WU0,WU1,WU2,WU3,WU4,WU6,WU8 COMPLETE (committed). Next: WU5 (JsonlTailDeps + tailer loop; deps WU2,WU3,WU4 all met) -> then WU7 (capability+wiring; deps WU5,WU6) -> WU9 (frontend view; deps WU7,WU8) -> WU10 (integration+coverage sweep)
date_drafted: 2026-06-04
branch: feat/harness-registry-p1
---

# Implementation Plan — Optional High-Fidelity Harness Conversation View (claude-code JSONL log)

**Design:** `docs/harness-jsonl-capture.md` (APPROVED 5/5 by the design-review gate, round 2).

## Strategy

Additive, optional feature. The **default** harness transcript (PureClaw sent/received) is
**not touched**. We add a capability-gated, load-on-demand, read-only view sourced from
claude-code's own on-disk JSONL log, for **spawned claude-code harnesses only**.

11 work units. **WU0 (Phase-0 spike) is a hard prerequisite** for the path-derivation and
converter WUs — its captured artifacts (the real on-disk path + real JSONL lines) are those
WUs' test fixtures. TDD throughout: each WU lands failing tests first (red), then code
(green); every WU keeps `-Wall -Werror` + `cabal test` green per-commit (additive-only,
per the epic's per-commit-green discipline). Frontend WUs land vitest red→green + `tsc`
strict. Pre-PR `/self-reflect` per CLAUDE.md.

### Dependency graph (topological)

```
WU0 (spike) ─┬─> WU2 (SafeClaudeLogPath) ─┐
             └─> WU3 (converter) ─────────┤
WU1 (ClaudeSessionUuid) ─> WU2            │
WU4 (line-splitter) ─────────────────────┤
                                          v
WU1 ─> WU6 (spawn+persist)        WU5 (tailer: needs WU2,WU3,WU4)
                                          │
                       WU6, WU5 ─> WU7 (capability + on-demand backend wiring)
WU8 (frontend thinking renderer, independent) ─┐
                                  WU7, WU8 ─> WU9 (frontend optional-view control)
                                  WU1..WU9 ─> WU10 (integration + coverage sweep)
```

Parallelizable: (WU1 ‖ WU4) after WU0; (WU2 ‖ WU3) after their deps; WU8 any time; WU6 ‖ the
WU2/3/5 chain (WU6 needs only WU1).

---

## Work Units

### WU0 — Phase-0 spike (PREREQUISITE; investigative, not production code)
**Goal:** empirically verify the load-bearing assumptions and capture fixtures.
**DoD:**
- D0.1 Confirm `claude --session-id <uuid>` on a **fresh** run creates exactly
  `~/.claude/projects/<sanitized-cwd>/<uuid>.jsonl`; record the result.
- D0.2 Confirm `--resume`/`--continue` (or re-`--session-id`) **appends to the same file**
  (does not fork a new one). Record the exact resume invocation that appends.
- D0.3 Determine the exact `sanitize(cwd)` algorithm by spawning with several cwds (plain,
  trailing slash, spaces, dots, a symlinked dir) and reading back the real directory name;
  document the rule + `CLAUDE_CONFIG_DIR` relocation behaviour.
- D0.4 Confirm claude-code only ever **appends** (no in-place rewrite/compaction) across a
  `/compact` and a long session; if compaction exists, document it (open-time backfill still
  works; only the live offset path needs a re-read).
- D0.5 Capture **fixture artifacts**: a real `<uuid>.jsonl` (or representative excerpt) with
  `user`, `assistant` events that include a **`thinking` block** (WU8's data source), `text`,
  and `tool_use`, plus a `tool_result` event → committed under `test/fixtures/claude-jsonl/`
  for WU3/WU8.
**Output:** a short findings note in a **sibling file** (`docs/harness-jsonl-capture-spike.md`)
— do NOT mutate the gate-approved design doc — plus committed fixtures. **Loud-fallback**
requirement (§H.4) recorded for WU5/WU7.
**Scope:** docs + `test/fixtures/`. No production code.

### WU1 — `ClaudeSessionUuid` validated newtype
**Files:** new `src/PureClaw/Harness/ClaudeSession.hs` (or a leaf module); test sibling.
**DoD:**
- D1.1 Smart constructor accepts only a canonical UUID (hex+hyphens, fixed length); value
  ctor unexported. Rejects `/`, `..`, NUL, wrong length/charset.
- D1.2 A `mintClaudeSessionUuid :: IO ClaudeSessionUuid` using a **CSPRNG** (UUIDv4 from a
  cryptographic source).
- D1.3 `FromJSON` routes through the smart constructor (mirror `SessionPrefix`,
  `Session/Types.hs:93-97`); `ToJSON` round-trips.
- D1.4 **Redacted `Show`** (does not print the raw value into general logs).
**Deps:** none. Pure + one IO mint.

### WU2 — `SafeClaudeLogPath` smart constructor
**Files:** new module (e.g. `src/PureClaw/Harness/ClaudeLogPath.hs`); test sibling.
**Deps:** WU0 (sanitize rule), WU1 (uuid).
**DoD:**
- D2.1 Value ctor unexported (mirror `SafePath`). The only way to obtain the path.
- D2.2 **Locate by uuid-glob (WU0 refinement):** the WU0 spike found the cwd→dir-name rule is
  canonicalize + `[^A-Za-z0-9]→-` (version-fragile). Since the `<uuid>` is unique and
  PureClaw-minted, resolve the file by globbing `<base>/projects/*/<uuid>.jsonl` (base from
  `CLAUDE_CONFIG_DIR` else `~/.claude`; at most one hit) rather than reconstructing the dir
  name. Persisted canonical cwd (§B) is a cross-check/fallback only.
- D2.3 `canonicalizePath`es the candidate and verifies canonical containment under the
  canonical `<base>/projects` root (rejects symlink escape — cf. `Path.hs:99-105`).
- D2.4 Opens the final component with `O_NOFOLLOW` (net-new: `unix` `openFd` with
  `OpenFileFlags{nofollow=True}` — the existing `checkModeAndOwner` uses `getFileStatus`,
  which FOLLOWS symlinks, so only its owner/mode *logic* is reused, not an O_NOFOLLOW open);
  rejects if `owner /= geteuid()` or group/other-writable.
- D2.5 Redacted `Show`.
- D2.6 Tests: table-driven derivation (plain/nested/trailing-slash/env-relocated) + rejection
  (symlink-escape via temp symlink, `..`, foreign owner, missing file → typed error).

### WU3 — pure JSONL → `TranscriptEntry` converter
**Files:** new module (e.g. `src/PureClaw/Harness/ClaudeLogConvert.hs`); test sibling + WU0
fixtures.
**Deps:** WU0 (real fixtures).
**DoD:**
- D3.1 `convertLine :: ByteString -> Maybe TranscriptEntry`: `assistant` → Response entry with
  payload `{content:[blocks], usage, model}` at top level + `_te_model` column set;
  `user` → Request entry payload `{messages:[{role:"user",content}]}`; `tool_result` user
  event → Request entry whose `messages[].content[]` carries `tool_use_id`+content (so
  `App.tsx buildToolResultIndex` joins it). `_te_id`/`_te_correlationId` ← JSONL `uuid`;
  `_te_timestamp` ← event `timestamp`.
- D3.2 Unknown `type` / malformed line → `Nothing` (skipped), never throws.
- D3.3 Golden fixtures captured by serializing a **real** `TranscriptEntry` payload from the
  Haskell encoder (byte-for-byte vs production), asserting **payload AND** `_te_model`/
  `_te_harness` columns. Covers text, thinking, tool_use, tool_result, unknown, malformed.
- D3.4 Idempotence golden: same event twice → same `_te_id` (de-dup obligation documented).
- D3.5 Content passes through the **same** `sanitizeHarnessOutput` filter the TUI/display path
  uses (`Handles/Harness.hs:61-89`) — true parity, not an ad-hoc equivalent — before it
  becomes payload destined for broadcast.

### WU4 — pure line-splitter (`Offset`/`Buffer`)
**Files:** part of the tail module; test sibling.
**Deps:** none.
**DoD:**
- D4.1 `newtype Offset = Offset Integer`, `newtype Buffer = Buffer ByteString`.
- D4.2 `splitLines :: ByteString -> Buffer -> ([CompleteLine], Buffer)` — complete LF-delimited
  lines emitted; partial trailing line buffered; a chunk split across two reads reassembles;
  a stray `\r` is NOT stripped into content (logs are LF).

### WU5 — `JsonlTailDeps` + tailer loop
**Files:** tail module; test sibling.
**Deps:** WU2, WU3, WU4.
**DoD:**
- D5.1 `JsonlTailDeps` named record (`readFrom :: SafeClaudeLogPath -> Offset ->
  IO (ByteString, Offset)`, EOF/size probe, sanitizer, clock) + `defaultJsonlTailDeps`
  (mirror `ClaudeCodeDeps`/`ReconcileDeps`).
- D5.2 Loop: backfill from offset 0, then live-tail deltas, converting via WU3, delivering to
  a broadcast sink (injected). Offset advances monotonically.
- D5.3 **AsyncCancelled re-raised** (cf. `Reconcile.hs:505`); only non-async exceptions
  swallowed+logged.
- D5.4 DoS caps with **concrete pinned numbers** (revisit in VALIDATE if needed):
  max backfill file size **32 MiB**, max single-line bytes **1 MiB**, max buffered
  partial-line bytes **1 MiB**; over-cap → loud "log unavailable" fallback, never silent
  partial read.
- D5.5 `readFrom` degraded path: file shrinks/disappears → return current size + signal
  re-read-from-0 (total function, no negative delta).
- D5.6 Tests over injected deps: offset monotonicity, partial buffering, teardown on cancel,
  cap enforcement, shrink/disappear handling.

### WU6 — spawn correlation + persistence
**Files:** `ClaudeCode.hs` (mint+inject), `Session/Kind.hs` (`_h_claudeSessionUuid`), tests.
**Deps:** WU1.
**DoD:**
- D6.1 On spawn, mint a `ClaudeSessionUuid` (WU1 CSPRNG) and inject `--session-id <uuid>`
  through the **existing `[Text]` args** at the `mkClaudeCodeHarnessWith` call site (NOT by
  widening `_ccd_addWindow`'s signature); confirm `hasUnsafeFlag`/other arg handling
  unaffected.
- D6.2 Persist additively as `_h_claudeSessionUuid :: Maybe Text` on `HarnessSpec` with
  tolerant `.:? "claudeSessionUuid"` + emit-when-Just (mirror `_h_harnessId`,
  `Kind.hs:71-77`). Name disambiguated from `Registry._he_sessionId` with a doc note.
- D6.3 Persist the **canonicalized** spawn cwd used for path derivation.
- D6.4 Tests: codec round-trip; back-compat decode of an old `session.json` lacking the field
  → `Nothing`; arg injection present in the spawned argv.

### WU7 — capability surfacing + on-demand backend wiring
**Files:** `Frontend/API.hs` (snapshot field + open/close endpoints + sidecar map), tests.
**Deps:** WU5, WU6.
**DoD:**
- D7.1 `has_session_log` **computed** at snapshot-build time (NOT a stored field) from
  `flavour==claude-code && _he_origin==OriginSpawned` joined to the session's
  `_h_claudeSessionUuid` presence. **Join seam:** `HarnessEntry` carries no uuid
  (`Registry.hs:125-144`), so the builder resolves `_he_sessionId` → load the session's
  `HarnessSpec` (via the session store) → check `_h_claudeSessionUuid`. Name this join
  explicitly. Snapshot-builder test asserts the additive field does not perturb existing
  tab-JSON consumers.
- D7.2 Endpoints to open/close the optional view for a tab index → start/stop the WU5 tailer;
  Async handle stored in a **sidecar `Map HarnessId (Async ())`** (not on `HarnessEntry`).
- D7.3 Tail entries reach the frontend over the **existing `StreamBroker`**, which is
  `SessionId`-keyed fan-out (no "topic" concept). Publish the optional record's
  `EntryRecorded` under a **dedicated synthetic `SessionId`** (e.g. derived from the harness
  id) that the frontend's full-session view focuses on — keeping it cleanly separate from the
  core session's transcript stream. Auth is the existing **connection-level WS Origin
  allowlist** the broker already enforces (`Stream.hs originAcceptable`); the tail rides the
  already-authenticated WS connection, so there is **no new egress path** (the frontend just
  focuses an additional SessionId it is already entitled to receive).
- D7.4 Teardown wired to BOTH explicit view-close AND the reconcile-detected **exit** signal.
- D7.5 Loud fallback when the path is unavailable/over-cap (returns a typed "log unavailable").
- D7.6 Tests: open→tailer runs, close→cancelled, exit→cancelled; capability computed correctly
  for spawned-claude-code vs adopted vs other-flavour.

### WU8 — frontend thinking renderer (independent; touches native sessions)
**Files:** `frontend/src/types.ts`, `App.tsx` (extractor), `ChatArea.tsx` (render), tests.
**Deps:** none.
**DoD:**
- D8.1 New `MessageContent` `thinking` variant + extractor for `type:"thinking"` blocks.
- D8.2 Rendered collapsed-by-default with its **own distinct "Thinking" label** (not the bare
  System-prompt `CollapsedBlock`). Content escaped (React text; no `dangerouslySetInnerHTML`).
- D8.3 Regression test: existing native-session text/tool_use rendering unchanged.

### WU9 — frontend optional-view control + rendering
**Files:** `HarnessControls.tsx`, a new full-session view component, `useApi.ts`,
stream hook, tests.
**Deps:** WU7, WU8.
**DoD:**
- D9.1 A control in/near `HarnessControls`, shown **iff** `has_session_log` (mirroring the
  existing `tab.origin` conditional), labelled as the higher-fidelity, complete claude-code
  session log (a superset incl. tmux-typed turns).
- D9.2 Opening it calls the WU7 open endpoint, focuses the dedicated synthetic SessionId,
  renders the full record (text + tool calls + thinking via WU8); closing tears down. The
  text and tool-call render paths (not just thinking) treat JSONL content as untrusted —
  React text-escaping, no `dangerouslySetInnerHTML` (reuse the existing native render
  components, which already escape; assert it).
- D9.3 Degraded ("log unavailable" / parse-degraded) and **not-applicable** ("not available for
  this harness") states use the muted `Field` styling; absence is explained, not silent.
- D9.4 The default transcript is provably unaffected by opening/closing the optional view.
- D9.5 vitest for visibility predicate, render of a golden full-session record, teardown.

### WU10 — integration + coverage sweep
**Deps:** WU1–WU9.
**DoD:**
- D10.1 Integration: a stub writes a JSONL file incl. an out-of-band turn; opening the optional
  view surfaces that turn; the default transcript is unchanged. Plus an explicit
  **restart re-derivation** test: persisted `_h_claudeSessionUuid` + canonical cwd →
  re-derive `SafeClaudeLogPath` → re-validate containment → tail resumes.
- D10.2 `cabal build -Wall -Werror` clean; `cabal test` green; hlint clean; pty-firewall OK;
  frontend `tsc` strict + vitest green.
- D10.3 Coverage per `.coverage-thresholds.json` (the binding source of truth) for new modules;
  any staged-waiver routed through the threshold file, never applied silently at commit time.
  Pre-PR `/self-reflect` KB capture committed.

---

## Success criteria (from design §Round-2 resolutions)

1. An out-of-band tmux turn appears in the optional view within a few seconds of opening it.
2. Opening/closing the optional view never alters or drops an entry in the default transcript.
3. The control is absent for non-claude-code/adopted harnesses, and that absence is explained.

## Risks

- WU0 outcomes could invalidate assumptions (e.g. compaction exists, or sanitize rule differs):
  the plan degrades gracefully (open-time backfill) and WU0 lands first so WU2/WU3 build on
  facts, not guesses.
- `--session-id` flag/behaviour drift across Claude Code versions: WU0 pins it; WU7 loud
  fallback covers a missing/unexpected file.
