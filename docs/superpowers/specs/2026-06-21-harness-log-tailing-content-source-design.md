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
replace-by-id contract — sourcing the turn text from tmux (`_hh_snapshotTurn`).
We introduce a per-harness **turn-content provider** and select it at harness
activation:

- **Claude-log provider** (spawned claude-code with a uuid): supplies the
  current turn's accumulated assistant prose (and a finalize signal) from the log.
- **tmux-snapshot provider** (everything else): today's behavior, unchanged.

`stepTurns` consumes the selected provider's turn text exactly as it consumes
`_hh_snapshotTurn` today. Because there is exactly one turn-content source per
harness, **single-writer for the assistant Response is structural** — no "disable
the other path" branch. The existing **Request** recording in `routeViaHandle`
(`API.hs`, UI sends) is **unchanged**; the log provider feeds only the assistant
Response content.

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

### Stable identity & idempotent replay

`stepTurns` reuses one minted turn id across a turn's updates + final. For the
log provider the turn id MUST be **derived deterministically from the JSONL**
(e.g. the turn's first assistant message `uuid`) rather than randomly minted, so
that a backfill/restart re-reading the file does not create duplicate entries.
The persistence layer + broker dedup/upsert by `_te_id` (the frontend already
replaces by id). As an optimization the tailer MAY persist its byte offset per
harness to skip already-processed history; correctness rests on the derived
stable id, not on the offset surviving.

### Lifecycle, liveness, fallback

- **Automatic lifecycle:** when a spawned claude-code harness with a uuid becomes
  active, select the log provider and start its tailer (sidecar
  `Map HarnessId (Async ())`, not a serialized field); cancel on harness exit
  (reconcile-detected) or shutdown. Selection is computed each tick (not latched)
  so it engages once `_he_sessionId`/uuid resolve.
- **Liveness unchanged:** `classifyRow`/`classifyFromObserver` (thinking / idle /
  awaiting-input, approval prompts) untouched — 100% tmux.
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
- Restart / backfill replay → idempotent via JSONL-derived stable turn id (+
  optional persisted offset); no duplicate history.
- Harness exits mid-turn → final assistant line already on disk; a final tail
  read before teardown captures it (then finalize).
- Provider selection before `_he_sessionId`/uuid resolves → re-evaluated each
  tick; engages when ready (logs aren't written until first interaction anyway).

## Security (resolves the design-review security blocker)

- Path access ONLY via `SafeClaudeLogPath` (uuid-glob, canonical containment,
  `O_NOFOLLOW` leaf open, owner==euid, no group/other-write, redacted Show).
- uuid = validated `ClaudeSessionUuid` (no `/`,`..`,NUL; CSPRNG-minted;
  globally-unique filename; >1 hit → typed ambiguity, never silently picked).
- **DoS bounds (WU5 D5.4):** 32 MiB backfill / 1 MiB line / 1 MiB buffer →
  loud fallback. Per-tick read bounded; carry buffer bounded.
- All surfaced prose flows through `sanitizeHarnessOutput`.
- Provider selection from the in-memory registry/spec, never a serialized
  "trusted" flag, so a hostile `session.json` cannot coerce tailing of a foreign
  log. Re-validate `SafeClaudeLogPath` on offset-reset/rotation.

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
- Core-wiring (over injected provider, like `Harness.ReconcileSpec`):
  (a) **structural single-writer** — a log-provider harness never calls the tmux
  `_hh_snapshotTurn` (recording fake counter stays 0) and `routeViaHandle`
  Request recording is unchanged;
  (b) **idempotent replay** — re-feeding the same log lines yields one entry per
  derived turn id;
  (c) **fallback** — a non-uuid harness uses the tmux path unchanged;
  (d) **lifecycle** — provider engages on spawned-claude activation, tailer
  cancels on exit.
- TDD throughout; 100% coverage gate (factor real-FS path resolution into a pure
  function + thin IO shell to stay coverable, per the merged work's zero-waiver
  norm); `-Wall -Werror`; hlint clean.

## Verification

- `nix develop . --command cabal test` (+ `--enable-coverage`).
- Manual: frontend-spawn a claude harness, send a prompt whose output scrolls
  past the visible pane — full assistant prose streams per-message and the final
  is recorded without `/harness output`; confirm liveness glyph still tracks
  thinking/idle.
