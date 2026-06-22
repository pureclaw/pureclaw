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

Correct mechanism (the **disk-seeded recorded-id set is the correctness guard**;
the offset is only an optimization — this closes the record-vs-offset crash
window the gate identified):

1. **Deterministic, namespaced turn id.** The log provider's turn id is
   `derive(SessionId, firstAssistantUuid)` — a pure function of the session and
   the **first assistant line's JSONL `uuid`** for the turn, pinned at turn start
   and NOT changed as later assistant lines of the same turn arrive (so mid-turn
   `EntryUpdated`s keep one id; replace-by-id holds). Namespacing by `SessionId`
   prevents any cross-harness `_te_id` collision. The derivation is documented
   (e.g. a UUIDv5 over `SessionId || firstAssistantUuid`) and stable across
   restarts because it depends only on durable on-disk JSONL bytes.
2. **Recorded-id set seeded from the existing transcript at tailer startup.**
   When the tailer starts, it loads the set of turn ids already present in this
   session's `transcript.jsonl` (one read of existing `_te_id`s) into an
   in-memory set. The record wiring (the `_rd_recordResponse` closure) **refuses
   to record a turn whose derived id is already in the set**, and adds each newly
   recorded id to it. Because (1) is deterministic from durable bytes, a turn
   re-folded after a crash/restart derives the **same** id, which is already in
   the disk-seeded set → it is skipped. This makes the deterministic id an
   ACTUAL dedup (something now refuses the duplicate write), closing both crash
   windows: (a) turn recorded but offset not yet persisted → re-fold derives the
   same id, already seeded from disk, skipped (no duplicate); (b) offset advanced
   past an unrecorded turn → cannot happen, because the offset is not the guard.
   We still do NOT modify `_th_record` (no per-write re-read); the set is read
   ONCE at startup.
3. **Persisted byte offset is an optimization only.** The tailer MAY persist its
   processed offset per harness to skip re-folding already-processed history on
   restart (cheaper than re-reading from 0). It is NOT relied on for correctness
   (the id set is). **Missing/corrupt/absent offset fails closed:** for a
   non-empty pre-existing log, seek to **EOF and record nothing historical**
   (only new prose is surfaced); never default to offset 0 and re-backfill. A
   freshly-spawned harness's log is empty, so there is nothing to re-emit anyway.

**Offset/state file:** `<sessionsDir>/<sessionId>/harness-logtail-<HarnessId>`
(0600 under the existing 0700 session dir), written **write-then-rename**
(mirrors `ClaudeCode.hs` `renameFile` pattern) carrying `{offset, lastRecordedId}`;
a torn/garbage value parses to "fail closed → seek EOF," never offset 0.

**Implementation invariants (from architect re-confirm):**
- The recorded-id set is a **captured `IORef`** constructed alongside
  `reconcileDeps` (`CLI/Commands.hs`), OUTSIDE the per-call bracket that opens a
  fresh transcript handle — so it persists across record calls (the production
  `_rd_recordResponse` opens/closes a handle each call). The reconcile loop is
  single-threaded, so check-set → record → add-id is atomic w.r.t. itself.
- Seed the set by reading **all** `_te_id`s via the untrimmed transcript query
  (`_th_query emptyFilter` — which does NOT apply compaction trimming), NOT
  `loadRecentMessages` (which trims to the last compaction boundary and could
  miss a pre-boundary id, re-introducing a duplicate).
- The on-disk `_te_id` column is a flat unscoped `Text`; `derive(SessionId,
  firstAssistantUuid)` is what prevents cross-session/-harness id reuse from
  colliding within one file.
- **Invariant to keep dormant:** the legacy `harnessReceive`/`_hh_receive`
  direct-record path (`ClaudeCode.hs`, random id; `Runtimes.hs`/`SlashCommands.hs`
  drainers) must stay OFF the frontend reconcile flow — `routeViaHandle` does not
  call `_hh_receive` (`API.hs`). Re-enabling a `_hh_receive`-driven Response
  record for a log-provider harness would bypass the recorded-id set and
  re-introduce duplicates. (Testing item (a) guards the frontend path.)

### Lifecycle, liveness, fallback

- **Automatic lifecycle:** when a spawned claude-code harness with a uuid becomes
  active, select the log provider and start its tailer in a sidecar
  `Map HarnessId (Async ())` (not a serialized field). The uuid is resolved
  ONCE (via `_he_sessionId` → `session.json` `HarnessSpec`) and the validated
  `ClaudeSessionUuid` + `SafeClaudeLogPath` are **captured in the provider
  closure / cached** — NOT re-decoded from `session.json` every tick. The
  selection predicate gates on **`flavour == claude-code && a ClaudeSessionUuid
  resolves`** — NOT on `origin`: a PureClaw-spawned harness is boot-reconstructed
  as `OriginDiscovered` after a restart, so an `origin == Spawned` gate would
  defeat restart-idempotency. Only spawned-with-uuid harnesses persist
  `_h_claudeSessionUuid` (adopted/CLI/non-claude lack it), so uuid-resolvability
  is the correct capability signal across both origins. Selection engages once
  `_he_sessionId`/uuid resolve; thereafter it is **latched** (see
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
- Restart → recorded-id set seeded from the on-disk transcript; deterministic
  ids re-derived from the same bytes are already in the set → skipped (no
  duplicate), even if the persisted offset was stale at crash. Missing offset →
  seek to EOF (record nothing historical), never re-backfill from 0.
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
  (b) **crash/restart idempotency** — record a turn, simulate a crash with a
  STALE persisted offset, restart: the recorded-id set seeded from the on-disk
  transcript causes the re-folded turn (same derived id) to be skipped → one
  entry on disk, not two. Also: missing offset → seek-to-EOF records nothing
  historical; within-run rotation re-read is deduped by the same set;
  (c) **merged DoD regression** — the existing `ReconcileSpec` tmux-provider
  tests (#3 once-only, #4 distinct ids, unchanged-once) still pass verbatim,
  proving the provider seam is additive;
  (d) **fallback** — a non-uuid harness uses the tmux path unchanged;
  (e) **no mid-turn fork** — log over-cap mid-turn finalizes once under the log
  id, then falls back at the next boundary (no second id for the same turn);
  (f) **lifecycle** — provider engages on spawned-claude activation; tailer
  `Async` cancels on exit with `SomeAsyncException` re-raised, teardown
  `timeout`-bounded.
- TDD throughout; coverage meets `.coverage-thresholds.json` (the source of
  truth — currently 95% lines/branches/functions/statements, with a
  `stagedWaivers` mechanism). Aim to add NO new waiver: factor real-FS path
  resolution + the tailer IO behind injectable deps (`JsonlTailDeps`) with a pure
  shell, and budget ONE CLI/integration test (spawn a claude harness, feed a
  fixture log) to exercise the thin production wiring. `-Wall -Werror`; hlint
  clean.

## Verification

- `nix develop . --command cabal test` (+ `--enable-coverage`).
- Manual: frontend-spawn a claude harness, send a prompt whose output scrolls
  past the visible pane — full assistant prose streams per-message and the final
  is recorded without `/harness output`; confirm liveness glyph still tracks
  thinking/idle.
