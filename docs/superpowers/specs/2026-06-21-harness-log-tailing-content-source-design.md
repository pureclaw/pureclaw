# Design: Claude Code log as the live core content source (prose-only hybrid)

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

| Merged | Module | Reused here? |
|---|---|---|
| WU1 | `Harness.ClaudeSession` (`ClaudeSessionUuid`, `mintClaudeSessionUuid`) | yes — locate + validate |
| WU2 | `Harness.ClaudeLogPath` (`SafeClaudeLogPath`) | yes — secure path locate |
| WU3 | `Harness.ClaudeLogConvert` (`convertLine`, full fidelity) | **no** (full-fidelity; reserved for a future optional view). We add a small pure prose extractor instead. |
| WU4 | `Harness.JsonlTail` (`splitLines`, `Offset`, `Buffer`) | yes — chunk→line splitting |
| WU6 | `ClaudeCode` spawn + `Session.Kind` `_h_claudeSessionUuid`/`_h_canonicalCwd` | yes — uuid+cwd already persisted |
| WU8 | frontend renderer | not needed (prose → existing Response rendering) |

**Pending in the epic:** WU5 (the live tailer loop IO), WU7/WU9 (optional-view
wiring + UI), WU10. This delta builds WU5's tailer *mechanics* and wires them to
the core transcript instead of an opt-in view.

## What changes vs the epic (the delta)

The epic scoped the log as an **optional, opt-in, secondary VIEW** on a synthetic
SessionId, under a prior **user decision**: "the fundamental session experience
… must not depend on any harness-specific log." That optional view does not fix
the reported symptom — tmux scraping is lossy, so the **default** transcript
still drops streaming output and can miss the final.

> **New decision (2026-06-21):** for a **spawned claude-code harness**, the JSONL
> log becomes the **live source of the assistant-response content in the core
> transcript**, with a **fail-safe fallback to today's tmux path** when no log is
> available. Liveness/activity stays 100% tmux.

## Fidelity: prose-only (user decision, confirmed)

The core transcript surfaces **assistant prose only** — assistant `text` blocks,
concatenated per turn, sanitized via `sanitizeHarnessOutput`. `thinking`,
`tool_use`, and `tool_result` are **not** surfaced into the core transcript
(they remain visible live in tmux and via `/harness output`; full-fidelity is a
possible future optional view reusing `convertLine`). Because it is prose-only,
the design plugs into the existing turn model rather than emitting structured
entries.

## Goal & success criteria

- **Per-message reliability:** assistant prose appears in the core transcript
  reliably, ~1 poll after Claude writes it. NOT token-by-token.
- **Guaranteed final:** the complete final response always lands, even if tmux
  missed every frame (the log is durable on disk; finalize is event-based).
- Applies to **spawned claude-code harnesses with a minted uuid**. Adopted / CLI
  / non-claude / missing-or-over-cap log → today's tmux content path (no
  regression). Loud WARN if a spawned-claude log is expected but absent.
- No regression to liveness/activity display.

## Architecture

### Content-provider seam → existing `stepTurns` (structural single-writer)

The merged `stepTurns` loop already streams a turn on content growth, dedups,
finalizes with a stable reused turn id, and preserves the frontend
replace-by-id contract — sourcing the turn text from tmux (`_hh_snapshotTurn ::
IO Text`) and minting turn ids via `_rd_mintTurn`. We introduce a per-harness
**turn-content provider**, selected once at harness activation (NOT swapped
mid-turn — see Lifecycle):

- **Claude-log provider** (spawned claude-code with a uuid): supplies the
  current turn's accumulated assistant prose from the log.
- **tmux-snapshot provider** (everything else): today's behavior, unchanged.

The provider is a **richer record than `IO Text`** — it returns, per tick, the
current turn's prose text PLUS a `finalized?` flag PLUS a deterministic turn id
(see Stable identity). `IO Text` alone cannot carry the finalize signal or the
derived id, so `stepTurns` is **minimally modified** (not "unchanged"): (a) read
turn text from the selected provider where it reads `_hh_snapshotTurn` today;
(b) at `startTurn`, take the provider's derived id instead of `_rd_mintTurn` for
the log provider; (c) treat the provider's `finalized?` as an authoritative
finalize that short-circuits the idle-stability heuristic. The tmux provider
keeps the existing `_hh_snapshotTurn` + `_rd_mintTurn` + stability-finalize
behavior verbatim.

Because there is exactly one turn-content source per harness, **single-writer for
the assistant Response is structural** — no "disable the other path" branch. The
existing **Request** recording in `routeViaHandle` (`API.hs`, UI sends) is
**unchanged**; the log provider feeds only the assistant Response content.

### The log provider (builds WU5's tailer mechanics)

- Locate the file ONLY via `SafeClaudeLogPath` (uuid-glob + canonical
  containment + `O_NOFOLLOW` + owner/mode); uuid is the validated
  `ClaudeSessionUuid` from `_h_claudeSessionUuid`.
- Read incrementally with WU5's mechanics: `JsonlTailDeps` injectable seam
  (`readFrom :: SafeClaudeLogPath -> Offset -> IO (ByteString, Offset)` + size
  probe + clock), `splitLines` (WU4) for partial-line buffering, offset advances
  monotonically; **DoS caps (WU5 D5.4): 32 MiB backfill / 1 MiB line / 1 MiB
  buffer → loud "log unavailable" fallback**, never a silent partial read; file
  shrink/disappear → re-read-from-0 signal; runs under `Async` and **re-raises
  `AsyncCancelled`**, swallowing only logged non-async exceptions.
- **New pure prose fold** (small, total; extend `ClaudeLogConvert` or a sibling):
  parse each complete line; for `assistant` events accumulate sanitized `text`
  blocks into the current turn; a real `user` event (not solely `tool_result`)
  ends the prior turn and starts a new one; ignore everything else. Yields, per
  tick, the current turn's prose text + a `finalized?` flag. NEVER throws (skips
  malformed/unknown lines).
- **Finalize signal:** a turn is finalized when the log shows a terminal
  `stop_reason` (`end_turn`/`stop_sequence`/`max_tokens`, NOT `tool_use`) or the
  next real user event appears — a durable, event-based final fed into
  `stepTurns` (short-circuits its idle-stability guess for the log provider).

### Stable identity & idempotent replay (corrected — addresses the gate blocker)

**Constraint discovered in review:** the durable transcript write path is
**append-only with no upsert** — `_th_record` (`Handles/Transcript.hs`) writes to
an `O_APPEND` fd and never reads existing ids; the reload paths
(`readReplaySlice`, `loadRecentMessages`) do **not** dedup by `_te_id`. So there
is NO persistence-layer dedup to lean on, and re-emitting a finalized turn WOULD
duplicate it on disk and on context reload. The earlier draft's "persistence
dedups by `_te_id`" was wrong.

Correct mechanism, in order of authority:

1. **Persisted offset is the cross-restart correctness mechanism.** The tailer
   persists its processed byte **offset (high-water mark)** per harness (next to
   the session). On (re)start it **resumes from that offset** and processes only
   NEW lines — it does NOT re-backfill already-recorded turns into the core
   transcript. This is what prevents duplication across a PureClaw restart while
   the harness keeps running. (First start of a freshly spawned harness has an
   empty log, so there is nothing to re-emit.) The offset is persisted durably
   (write-then-rename) so a crash cannot leave a torn value.
2. **Deterministic, namespaced turn id** as a within-run + defense-in-depth
   guard. The log provider's turn id is `derive(SessionId, firstAssistantUuid)`
   — pinned at turn start and NOT changed as later assistant lines of the same
   turn arrive (so mid-turn `EntryUpdated`s keep one id; replace-by-id holds).
   Namespacing by `SessionId` prevents any cross-harness `_te_id` collision.
3. **In-memory recorded-id set** per session for the process lifetime: the
   wiring skips re-recording a `_te_id` already emitted this run (covers an
   offset-reset/rotation re-read within a run). This set is fresh after restart —
   the persisted offset (1) is the cross-restart guard, not this set.

We deliberately do NOT modify `_th_record` to do read-before-write upsert (it
would re-read the whole transcript per write). Correctness comes from *not
re-emitting* (offset resume) plus deterministic ids, not from a dedup at the
sink.

### Lifecycle, liveness, fallback

- **Automatic lifecycle:** when a spawned claude-code harness with a uuid becomes
  active, select the log provider and start its tailer in a sidecar
  `Map HarnessId (Async ())` (not a serialized field). The uuid is resolved
  ONCE (via `_he_sessionId` → `session.json` `HarnessSpec`) and the validated
  `ClaudeSessionUuid` + `SafeClaudeLogPath` are **captured in the provider
  closure / cached** — NOT re-decoded from `session.json` every tick. Selection
  engages once `_he_sessionId`/uuid resolve; thereafter it is **latched** (see
  no-mid-turn-fork below).
- **Async discipline:** each tailer runs under `withAsync`/`bracket`; on
  teardown it re-raises `SomeAsyncException` (NOT only `AsyncCancelled`) per the
  recurring darwin-CI-hang invariant (`[[tabs-runtime-async-cancel-hang]]`),
  swallowing only logged non-async exceptions; cancelled on reconcile-detected
  harness exit and on shutdown; test teardown is `timeout`-bounded.
- **No mid-turn provider fork:** the provider is chosen at activation (before any
  turn; logs aren't written until first interaction) and is **not swapped while a
  turn is active**. If the log goes over-cap / disappears mid-turn, the tailer
  finalizes the prose already surfaced (under its stable id) and only THEN does
  the harness fall back to the tmux provider at the next turn boundary — so a
  single logical turn never forks across two providers / two ids.
- **Liveness unchanged & finalize authority:** `classifyRow`/
  `classifyFromObserver` (thinking / idle / awaiting-input, approval prompts) are
  untouched — 100% tmux. For the log provider the **log's `finalized?` signal is
  authoritative** and bypasses the tmux idle-stability guard, so a guaranteed
  final is never held hostage to a stale "Thinking" tmux frame; tmux liveness
  remains only the activity-glyph source.
- **Fallback:** no active/valid log provider (non-claude, adopted, CLI, no uuid,
  missing/over-cap log) → tmux-snapshot provider = today's behavior, verbatim.

## Known limitation (consequence of prose-only)

A user message typed **directly into the tmux window** (out-of-band) is not
captured as a Request (prose-only; Requests still come only from `routeViaHandle`
on UI sends). The assistant's **prose response** to such a turn DOES appear (from
the log). This only partially addresses the epic's original out-of-band bug;
full capture (incl. out-of-band Requests) would require the full-fidelity
`convertLine` path, which is out of scope per the prose-only decision.

## Data flow

spawn (frontend) → mint uuid + persist `_h_claudeSessionUuid`/`_h_canonicalCwd`
(WU6, merged) → harness active → select log provider, start tailer → resolve
`SafeClaudeLogPath` by uuid → tail JSONL (bounded) → prose fold → current-turn
prose + finalize → `stepTurns` streams `EntryUpdated` on growth, records
`EntryRecorded` on finalize, under a JSONL-derived stable id → broker → frontend
(replace-by-id). tmux is the content source only for non-log harnesses; liveness
from tmux always. Harness exit → cancel tailer.

## Error handling / edge cases

- Log not yet created → tmux fallback until it exists; loud WARN if it never
  appears for a spawned-claude harness.
- Over-cap / malformed / partial line → WU5 caps + fold totality + carry buffer;
  never crashes the loop.
- Restart → resume from the persisted offset; only new lines processed → no
  duplicate history (deterministic ids + in-memory recorded-set as defense).
- Over-cap mid-turn → finalize the prose already surfaced under its stable id,
  emit the loud fallback, then switch to tmux at the next turn boundary (never
  fork the in-flight turn).
- Harness exits mid-turn → final assistant line already on disk; a final tail
  read before teardown captures it (then finalize).
- Provider selection before `_he_sessionId`/uuid resolves → engages when ready
  (logs aren't written until first interaction anyway), then latched per turn.

## Security (resolves the design-review security blocker)

- Path access ONLY via `SafeClaudeLogPath` (uuid-glob, canonical containment,
  `O_NOFOLLOW` leaf open, owner==euid, no group/other-write, redacted Show).
- uuid = validated `ClaudeSessionUuid` (no `/`,`..`,NUL; CSPRNG-minted;
  globally-unique filename; >1 hit → typed ambiguity, never silently picked).
- **DoS bounds (normative here, not by cross-reference):** the tailer enforces
  **max backfill 32 MiB, max single line 1 MiB, max buffered partial 1 MiB**;
  over-cap → loud "log unavailable" fallback, never a silent partial read. Since
  `JsonlTail.splitLines` cannot self-cap, the carry-buffer cap is enforced by a
  **bounded combinator at the JsonlTail boundary** (e.g. `splitLinesBounded ::
  maxBuffer -> chunk -> Buffer -> Either OverCap (...)`) so the cap is
  type-enforced and purely unit-testable. The per-tick read is independently
  bounded (read `min(size-offset, maxChunk)`, drain over ticks) so a
  rapidly-growing file cannot deliver an unbounded single chunk, and the
  backfill cap applies on every shrink/disappear re-read.
- All surfaced prose flows through `sanitizeHarnessOutput`. Note this is a
  display/ANSI sanitizer, not a secret redactor — but it is the SAME treatment
  tmux already gives, so no new exposure; confirm `transcript.jsonl` keeps the
  session dir's owner-only (`0o600`) mode.
- Deterministic turn id is **namespaced by `SessionId`** (`derive(SessionId,
  firstAssistantUuid)`) so two harnesses cannot collide on one `_te_id`.
- Provider selection from the in-memory registry/spec (validated `FromJSON`
  uuid), never a serialized "trusted" flag, so a hostile `session.json` cannot
  coerce tailing of a foreign log.
- **TOCTOU:** re-validate `SafeClaudeLogPath` on offset-reset/rotation, and the
  steady-state read re-open uses `O_NOFOLLOW` (not just the initial validation),
  closing the validate→reopen leaf-swap window.

## Out of scope

- Token-by-token streaming.
- Surfacing `thinking`/`tool_use`/`tool_result`/out-of-band Requests into the
  core transcript (full-fidelity `convertLine` path; possible future optional
  view — epic WU7/WU9).
- Best-effort log discovery for adopted claude harnesses (no minted uuid).
- Non-claude / CLI harnesses feeding the core from a log.

## Testing

- WU5 tailer mechanics over injected `JsonlTailDeps` (no real `~/.claude`):
  offset monotonicity, partial buffering, `AsyncCancelled` teardown, cap
  enforcement, shrink/disappear.
- New pure prose fold: golden fixtures (`test/fixtures/claude-jsonl/` from WU0) —
  multi-text turn, interleaved tool_use (ignored), thinking (ignored), turn
  boundary via new user event, terminal `stop_reason`, malformed/meta lines
  skipped.
- Bounded combinator: `splitLinesBounded` over-cap path is purely unit-tested
  (no-LF line exceeding the buffer cap → `OverCap`, not unbounded growth).
- Core-wiring (over injected provider, like `Harness.ReconcileSpec`):
  (a) **structural single-writer** — a log-provider harness never calls the tmux
  `_hh_snapshotTurn` (recording fake counter stays 0) and `routeViaHandle`
  Request recording is unchanged;
  (b) **offset-resume idempotency** — restart from a persisted offset re-emits
  nothing; and a within-run rotation re-read is deduped by the recorded-id set →
  one entry per derived turn id;
  (c) **merged DoD regression** — the existing `ReconcileSpec` tmux-provider
  tests (#3 once-only, #4 distinct ids, unchanged-once) still pass verbatim,
  proving the provider seam is additive;
  (d) **fallback** — a non-uuid harness uses the tmux path unchanged;
  (e) **no mid-turn fork** — log over-cap mid-turn finalizes once under the log
  id, then falls back at the next boundary (no second id for the same turn);
  (f) **lifecycle** — provider engages on spawned-claude activation; tailer
  `Async` cancels on exit with `SomeAsyncException` re-raised, teardown
  `timeout`-bounded.
- TDD throughout; 100% coverage gate (factor real-FS path resolution into a pure
  function + thin IO shell to stay coverable, per the merged work's zero-waiver
  norm); `-Wall -Werror`; hlint clean.

## Verification

- `nix develop . --command cabal test` (+ `--enable-coverage`).
- Manual: frontend-spawn a claude harness, send a prompt whose output scrolls
  past the visible pane — full assistant prose streams per-message and the final
  is recorded without `/harness output`; confirm liveness glyph still tracks
  thinking/idle.
