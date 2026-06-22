# Design: Claude Code log as the live core content source (hybrid)

- Date: 2026-06-21
- Branch: feat/harness-live-edit
- Status: draft (revised after discovering the harness-jsonl-capture epic;
  pending design-review gate)
- **Builds on the existing approved epic** `harness-jsonl-capture`
  (`pureclaw-3oy.33`): design `docs/harness-jsonl-capture.md` (5/5), plan
  `.beads/plans/harness-jsonl-capture-plan.md` (3/3). This document is a
  **delta** on that epic, not a replacement of its merged foundation.

## Relationship to the harness-jsonl-capture epic

The epic already built and merged the hard parts (on this branch):

| Merged | Module | Role |
|---|---|---|
| WU1 | `Harness.ClaudeSession` (`ClaudeSessionUuid`, `mintClaudeSessionUuid`) | CSPRNG uuid, validated newtype, redacted Show |
| WU2 | `Harness.ClaudeLogPath` (`SafeClaudeLogPath`) | constructor-private path locator: uuid-glob, canonical containment, `O_NOFOLLOW`, owner/mode |
| WU3 | `Harness.ClaudeLogConvert` (`convertLine`) | pure JSONL line → `TranscriptEntry` (full fidelity), `_te_id ← JSONL uuid`, `sanitizeHarnessOutput` applied |
| WU4 | `Harness.JsonlTail` (`splitLines`, `Offset`, `Buffer`) | pure chunk→complete-line splitter |
| WU6 | `ClaudeCode` spawn + `Session.Kind` `_h_claudeSessionUuid`/`_h_canonicalCwd` | mint+inject `--session-id`, persist uuid+cwd |
| WU8 | frontend `App.tsx` | renders assistant/text/tool_use/tool_result/thinking |

**Pending in the epic:** WU5 (the live tailer loop IO), WU7 (optional-view
capability + open/close backend), WU9 (frontend optional-view control), WU10
(integration).

## What changes vs the epic (the delta)

The epic deliberately scoped the log as an **optional, opt-in, secondary VIEW**
on a synthetic SessionId, governed by a prior **user decision**:

> "the fundamental session experience must be guaranteed to work for every
> harness flavour and **must not depend on any harness-specific log**" — and the
> default transcript "shows exactly the messages PureClaw sent and received …
> harness-agnostic." (`docs/harness-jsonl-capture.md`)

That optional view does **not** fix the reported symptom — tmux scraping is
lossy, so the **default** transcript still drops streaming output and can miss
the final. The user has now **reopened that decision** and chosen the hybrid:

> **New decision (2026-06-21):** for a **spawned claude-code harness**, the
> JSONL log becomes the **live source of truth for the core transcript** — not a
> separate opt-in view — with a **fail-safe fallback to today's tmux path** when
> no log is available. Liveness/activity stays 100% tmux.

So the delta is: **promote the WU5 tailer from an opt-in synthetic-session
broadcast to the automatic, single-writer core-transcript source** for spawned
claude-code harnesses. WU7's capability gate / open-close endpoints and WU9's
optional-view UI are **superseded** for the core path (no opt-in control); they
remain possible later for non-spawned/other flavours but are out of scope here.

This is strictly safer than today for spawned claude-code, and it also fixes the
epic's original bug (a turn typed directly into the tmux window never reached the
frontend) — the log records every turn regardless of origin.

## Goal & success criteria (unchanged from brainstorm)

- **Per-message reliability:** every assistant/user message appears in the core
  transcript reliably, ~1 poll after Claude writes it. NOT token-by-token.
- **Guaranteed final:** the complete final response always lands, even if tmux
  missed every frame (the log is durable on disk).
- Applies to **spawned claude-code harnesses with a minted uuid**. Adopted / CLI
  / non-claude / missing-or-over-cap log → today's tmux content path (no
  regression). Loud fallback if a spawned-claude log is expected but absent.
- No regression to liveness/activity display.

## Fidelity decision (changed from the brainstorm's "prose only")

The brainstorm chose "assistant prose only" — made before we knew `convertLine`
exists. The hybrid **reuses `convertLine`**, which already emits full-fidelity,
frontend-ready entries (assistant `Response` with content/usage/model; user
`Request`; `tool_result` joined by `tool_use_id`; `thinking` carried through —
all `sanitizeHarnessOutput`-filtered, all rendered by the merged WU8). Feeding
these into the core transcript makes a harness session look like a native
session and reuses merged, tested code rather than writing a lossy prose
extractor. **Decision: full fidelity via `convertLine`.** (Flagged for user
confirmation at spec review, since it reverses the earlier prose-only answer.)

## Architecture

### Tailer (WU5) — built per the epic's approved DoD

Implement WU5 exactly as the epic plan specifies (this resolves the security
gate's DoS finding — the caps are already pinned):
- `JsonlTailDeps` injectable seam (`readFrom :: SafeClaudeLogPath -> Offset ->
  IO (ByteString, Offset)`, size probe, sanitizer, clock) + `defaultJsonlTailDeps`,
  mirroring `ReconcileDeps`/`ClaudeCodeDeps`.
- Backfill from offset 0, then live-tail appended bytes; `splitLines` (WU4)
  buffers partial trailing lines; offset advances monotonically.
- **DoS caps (D5.4):** max backfill 32 MiB, max single line 1 MiB, max buffered
  partial 1 MiB → over-cap triggers the **loud "log unavailable" fallback**
  (§H.4), never a silent partial read.
- File shrink/disappear (D5.5) → re-read-from-0 signal; total `readFrom`.
- Runs in an `Async`; **re-raises `AsyncCancelled`** (project invariant), swallows
  only logged non-async exceptions (D5.3).
- Locates the file ONLY through `SafeClaudeLogPath` (uuid-glob + containment +
  `O_NOFOLLOW` + owner/mode); uuid is the validated `ClaudeSessionUuid`.

### Core-transcript wiring (the new unit)

- **Lifecycle (automatic):** when a spawned claude-code harness with a
  `_h_claudeSessionUuid` becomes active, start its tailer; stop it on harness
  exit (reconcile-detected) or shutdown. Async handles held in a sidecar
  `Map HarnessId (Async ())` (not a serialized field), as the epic specified.
  Selection predicate (computed, never a stored flag): `flavour == claude-code
  && origin == Spawned && uuid present` — resolved via `_he_sessionId → session.json
  HarnessSpec`.
- **Emission to the REAL session:** each `convertLine` result is published to the
  harness's **actual `SessionId`** (the core transcript stream) and persisted —
  NOT a synthetic id. The frontend renders it via the existing path (WU8).
- **Idempotent upsert by `_te_id`:** `convertLine` sets `_te_id ← JSONL uuid`
  (stable). Backfill-from-0 (on start/restart) re-reads the whole file, so the
  transcript writer + broker MUST **dedup/upsert by `_te_id`** so replays do not
  duplicate. The frontend already replaces-by-id; the **persistence layer must
  also dedup by `_te_id`** (key requirement of this unit).
- **Single writer (critical):** while the tailer is active for a harness, the
  tmux content paths are **disabled** for it — BOTH the merged `stepTurns`
  content recording AND `routeViaHandle`'s `Request` recording (`API.hs`). The
  tailer is the **sole transcript writer**, capturing user prompts (incl.
  out-of-band tmux-typed ones) and assistant turns from the log. tmux feeds only
  liveness. Exactly one writer → no double-recording.
- **Liveness unchanged:** `classifyRow`/`classifyFromObserver` (thinking / idle /
  awaiting-input, approval prompts) untouched — 100% tmux.
- **Fallback:** any harness without an active, valid tailer (non-claude, adopted,
  CLI, no uuid, missing/over-cap log) keeps today's tmux content path verbatim.

## Data flow

spawn (frontend) → mint uuid, persist `_h_claudeSessionUuid`/`_h_canonicalCwd`
(WU6, merged) → harness active → start tailer (sidecar Async) → resolve
`SafeClaudeLogPath` by uuid → backfill+tail JSONL → `convertLine` per line →
publish to real SessionId + persist (dedup by `_te_id`) → broker → frontend
(replace-by-id). tmux content path disabled for this harness; liveness from tmux
as today. Harness exit → cancel tailer Async.

## Error handling / edge cases

- Log not yet created (logs appear on first interaction) → tmux fallback until it
  exists; loud WARN if it never appears for a spawned-claude harness.
- Over-cap / malformed / partial → handled by WU5 caps + `convertLine` totality
  (skips) + carry buffer; never crashes the loop.
- Restart / backfill replay → idempotent via `_te_id` dedup (no duplicate
  history).
- Harness exits mid-turn → the final assistant line is already on disk; the tail
  (or a final backfill on the exit tick) captures it before teardown.
- `_he_sessionId` not yet linked at first tick → selection re-evaluated each
  tick (not latched), so the tailer starts once the link lands.

## Security (resolves the design-review security blocker)

All requirements are already met by merged modules + WU5's pinned caps; the spec
makes them explicit for the core path:
- Path access ONLY via `SafeClaudeLogPath` (uuid-glob, canonical containment,
  `O_NOFOLLOW` leaf open, owner==euid, no group/other-write, redacted Show).
- uuid is a validated `ClaudeSessionUuid` (cannot contain `/`,`..`,NUL); minted
  via CSPRNG; spoof-resistant (globally-unique filename; >1 hit → typed
  ambiguity error, never silently picked).
- **DoS bounds (D5.4):** 32 MiB backfill / 1 MiB line / 1 MiB buffer caps →
  loud fallback. Per-tick read is bounded; carry buffer is bounded.
- All surfaced text flows through `sanitizeHarnessOutput` (`convertLine` already
  does this); frontend treats content as untrusted (React escaping, no
  `dangerouslySetInnerHTML`).
- Selection from in-memory registry/spec, never a serialized "trusted" flag, so a
  hostile `session.json` cannot coerce tailing of a foreign log.
- Re-validate the `SafeClaudeLogPath` on offset-reset/rotation.

## Out of scope

- Token-by-token streaming (not required).
- Optional opt-in synthetic-session VIEW (epic WU7/WU9) — superseded by automatic
  core wiring for spawned claude-code; not built here.
- Best-effort log discovery for adopted claude harnesses (no minted uuid).
- Non-claude flavours / CLI harnesses feeding the core from a log (no log).

## Testing

- Reuse WU5's enumerated tests (D5.6): offset monotonicity, partial buffering,
  `AsyncCancelled` teardown, cap enforcement, shrink/disappear — over injected
  `JsonlTailDeps` (no real `~/.claude`).
- New core-wiring tests: (a) **single-writer** — when the tailer is active, the
  tmux `stepTurns` content path and `routeViaHandle` Request recording are NOT
  invoked (recording fakes whose counters must stay 0); (b) **idempotent replay**
  — backfilling the same lines twice yields one entry per `_te_id`; (c) emission
  goes to the harness's real SessionId; (d) fallback — a non-uuid harness uses the
  tmux path unchanged; (e) lifecycle — tailer starts on spawned-claude activation,
  cancels on exit.
- Golden fixtures from the epic's WU0 (`test/fixtures/claude-jsonl/`).
- TDD throughout; 100% coverage gate (factor real-FS path resolution into a pure
  function + thin IO shell to stay coverable, as the CTO review noted); `-Wall
  -Werror`; hlint clean.

## Verification

- `nix develop . --command cabal test` (+ `--enable-coverage`).
- Manual: frontend-spawn a claude harness; (1) send a prompt whose output scrolls
  past the visible pane — full reply streams per-message + final recorded without
  `/harness output`; (2) type a message directly into the tmux window — it now
  appears in the frontend transcript (the epic's original bug).
