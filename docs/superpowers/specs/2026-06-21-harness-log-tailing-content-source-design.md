# Design: Claude Code log-tailing as the harness content source

- Date: 2026-06-21
- Branch: feat/harness-live-edit (continues the harness output-streaming work)
- Status: draft (pending spec self-review + user review + design-review gate)
- Related: `docs/superpowers/plans/2026-06-21-harness-output-streaming-reliability.md`
  (the content-driven tmux watcher — WU1/WU2, already merged into this branch)

## Problem

Even after the content-driven watcher (stepTurns), tmux pane scraping is
fundamentally lossy: ANSI rendering, scrollback limits, and heuristic extraction
(`extractTurnClaude`) mean harness output still does not always stream in, and
the final reply is not guaranteed to land in the transcript. The user must fall
back to `/harness output`.

Claude Code, however, writes a complete, structured JSONL transcript of every
session to disk. Because PureClaw mints the session uuid (`--session-id <uuid>`,
`claudeCodeExtraArgs`) and persists both `_h_claudeSessionUuid` and
`_h_canonicalCwd` on the harness spec (`Session/Kind.hs:87,104`), we can locate
and read that file — the ground truth of what the harness produced.

## Goal & success criteria

- **Per-message reliability:** every assistant message appears in the session
  transcript reliably, as soon as Claude finishes writing it to the log
  (~1 tick latency). NOT token-by-token (explicitly not required).
- **Guaranteed final:** the complete final assistant response is always recorded,
  even if tmux missed every intermediate frame.
- Applies to Claude Code harnesses with a known minted session uuid (primarily
  frontend-spawned). Everything else falls back to today's tmux content path.
- No regression to liveness/activity (thinking/idle/awaiting-input) display.

## On-disk format (verified)

`~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`, one JSON object per line:
```
{ "type": "user"|"assistant"|"system"|<meta…>,
  "message": { "role", "content": [ {type:"text"|"thinking"|"tool_use"|"tool_result", …} ],
               "stop_reason", "model", "usage", … },
  "sessionId", "cwd", "timestamp", "uuid", "parentUuid", "gitBranch", … }
```
Meta line types also appear (`mode`, `permission-mode`, `attachment`,
`file-history-snapshot`, `ai-title`, `queue-operation`, `last-prompt`) and are
ignored. A real `user` message starts a turn; `user` messages whose content is a
`tool_result` are continuations of the current turn.

## Architecture

### Content-provider seam (the core idea)

Introduce a per-harness **turn-content provider** — the single thing that
answers "what is the current turn's assistant text?" — with two implementations,
selected when the harness entry is registered:

- **Claude-log provider** — parses the JSONL transcript (chosen when the harness
  is Claude Code AND we have a minted session uuid).
- **tmux-snapshot provider** — today's `_hh_snapshotTurn` behavior (the fallback:
  adopted / CLI / non-Claude / missing-or-stale log).

This plugs into the **existing `stepTurns`** loop (from the merged
output-streaming-reliability work): `stepTurns` already streams on content
growth, dedups unchanged content, finalizes with a stable reused turn id, and
preserves the frontend replace-by-id contract. We change only *where the turn
text comes from*. Streaming/dedup/finalize machinery is reused unchanged.

**Liveness stays 100% tmux** — `classifyRow`/`classifyFromObserver`
(thinking/idle/awaiting-input, approval-prompt detection) is unchanged. The log
provider feeds CONTENT only.

### Locating the log

The file name IS the globally-unique uuid, so we locate by **uuid filename**:
1. Compute the expected dir from `_h_canonicalCwd` (Claude's `<cwd-slug>` rule)
   and check `<dir>/<uuid>.jsonl` first (fast path).
2. If not found there, fall back to a bounded scan of `~/.claude/projects/*/`
   for `<uuid>.jsonl`.

Locating by uuid filename sidesteps any fragility in reconstructing Claude's
exact path-slug encoding: even if the slug rule differs, the uuid filename is
unambiguous. The base dir honors `$CLAUDE_CONFIG_DIR`/`$HOME` (resolve once).

### Tailing the log (incremental)

Per harness, track a **byte offset** (and a small carry buffer for a partial
trailing line). Each reconcile tick, for a log-provider harness:
1. `stat` the file; if missing → provider yields "no log this tick" and the
   watcher uses the tmux fallback for the entry (fail-safe).
2. If size < offset (truncation/rotation) → reset offset to 0, clear carry.
3. Read bytes `[offset, size)`, prepend carry, split on `\n`; the last element
   (no trailing newline) becomes the new carry; advance offset by consumed bytes.
4. Parse each complete line leniently; skip malformed lines and non-message meta
   types; fold message lines into the turn model below.

Reading is bounded IO wrapped so a transient failure never kills the loop
(same resilience contract as the existing watcher: `try`, re-raise
`AsyncCancelled`, log+skip otherwise).

### Turn model & single-writer guarantee

- A real `user` message (content is not solely a `tool_result`) **starts a new
  turn**; capture its `uuid`/`timestamp`.
- Assistant `text` blocks (ignore `thinking`/`tool_use` for the transcript, per
  the "assistant prose, reliably" scope) until the next real user message are
  the turn's response, **accumulated into one entry under a stable id** (reuse
  the current growing-message / replace-on-id behavior).
- **Finalize** the turn when the log shows it ended: the next real user message
  appears, OR the latest assistant message carries a *terminal* `stop_reason`
  (`end_turn` / `stop_sequence` / `max_tokens`) — explicitly NOT `tool_use`,
  which means the turn continues after the tool result. This is a durable,
  event-based final — strictly better than tmux stability-guessing. (The
  next-user-message signal is the backstop if a terminal `stop_reason` is ever
  absent.)
- **Single writer:** when the log provider is active for a harness, the tmux
  content path (the `stepTurns` tmux snapshot + its finalize) is **disabled** for
  that harness; tmux feeds only liveness. Exactly one writer → no
  double-recording. The send path (`routeViaHandle`) continues to record the
  Request only (unchanged).

The transcript stable-id contract is preserved: one minted turn id reused across
`EntryUpdated` (per-message growth) and the final `EntryRecorded`
(`mkTurnEntry`, `_te_id = turnId`), so the frontend replaces by id exactly as
today.

## Components / units

1. **`PureClaw.Harness.ClaudeLog` (new, pure + thin IO):**
   - PURE: parse a JSONL line → a typed record (or `Nothing` for meta/malformed);
     fold a list of records into `[Turn]` (turn = stable key + accumulated
     assistant text + finalized?); incremental fold given prior state + new lines.
   - IO (thin, injectable seam): resolve the log path by uuid; read appended
     bytes from an offset. Mirrors the `ClaudeCodeDeps`/`ReconcileDeps` seam
     pattern so it is tested without a real `~/.claude`.
2. **Provider selection + offset/carry state** threaded in the reconcile loop
   alongside the existing `TurnState` map (one provider + tail-state per harness).
3. **`stepTurns` integration:** the turn-text source becomes the selected
   provider; finalize gains the log's event-based signal when the log provider is
   active (stability-based finalize remains for the tmux provider).

## Data flow

spawn (frontend) → mint uuid + persist `_h_claudeSessionUuid`/`_h_canonicalCwd`
→ registry entry tagged log-capable → reconcile tick: log provider reads new
JSONL lines → fold into turn text → `stepTurns` streams `EntryUpdated` on growth
and records `EntryRecorded` on turn-end → broker → frontend (replace-by-id).
Liveness in parallel from tmux as today.

## Error handling / edge cases

- Missing/not-yet-created log → tmux fallback for that entry (logs are created on
  first interaction; until then there is nothing to stream anyway).
- Malformed/partial line → buffered (partial) or skipped (malformed); never
  crashes the fold.
- File rotation/truncation → offset reset.
- uuid present but file never appears (e.g. claude failed to start with that id)
  → permanent tmux fallback for that harness; WARN once.
- Non-Claude / adopted / CLI harness → tmux provider (no behavior change).
- Multiple assistant text blocks in one turn → concatenated in order into the one
  turn entry.

## Out of scope

- Token-by-token sub-message streaming (explicitly not required).
- Surfacing `tool_use`/`tool_result`/`thinking` into the transcript (assistant
  prose only this iteration; tool activity stays visible via tmux + `/harness
  output`). A possible later "everything-visible" enhancement.
- Best-effort log **discovery** for adopted Claude harnesses we did not spawn
  (no minted uuid) — deferred; risk of binding the wrong session.
- Giving CLI/TUI harnesses an owning session (separate design).

## Testing

- Pure parser + turn-fold: golden fixtures of real log lines — multi-text turn,
  interleaved tool_use/tool_result, thinking blocks, partial trailing line,
  malformed line, meta-type lines, turn boundary via new user message, turn end
  via `stop_reason`, file rotation (offset reset).
- Injected IO seam: provider integration in the reconcile loop tested with a fake
  log source (no real `~/.claude`), same pattern as `Harness.ReconcileSpec`.
- Single-writer: assert the tmux content path is disabled when the log provider
  is active (no double-record).
- TDD throughout; 100% coverage gate (`.coverage-thresholds.json`); `-Wall
  -Werror`; hlint clean.

## Verification

- `nix develop . --command cabal test` (+ `--enable-coverage`).
- Manual: frontend-spawn a Claude harness, send a prompt that scrolls output
  past the visible pane, confirm full reply streams per-message and the final is
  recorded — without `/harness output`.
