# Harness Output Streaming — Phase 2 (Live In-Place Editing)

**Date:** 2026-06-20
**Status:** Design — approved in brainstorming, pending spec review
**Scope:** Phase 2 of a two-phase effort. Builds directly on Phase 1 (`docs/superpowers/specs/2026-06-18-harness-output-streaming-design.md`), which must land first (PR #94).

## Problem

Phase 1 makes harness (Claude Code) output flow into the PureClaw session, but a turn appears only once — the reconcile watcher records a single `Response` entry **on settle** (the last `⏺` block). The user's stated ideal is a single message that **visibly grows as the harness works** and finalizes when the turn settles. Phase 1 explicitly deferred this because it is net-new capability: even LLM responses don't live-edit today (the frontend's `reconcileEntries` short-circuits on a matching entry id, and there is no entry-update wire event).

## Goals

1. While a harness session is working, a **single transcript message updates in place** ~every reconcile tick, showing the **whole accumulating turn** (all `⏺` assistant blocks since the last user prompt, tool/process chrome stripped), growing as the turn progresses.
2. On settle, that message is **finalized and persisted once** — the persisted entry IS the final state of the live message (no duplicate).
3. A **streaming/pending indicator** renders while the message is in progress and clears on finalization.

### Decisions locked in brainstorming

- **Cadence:** reuse the existing **2s reconcile tick** — no new fast-poller, no focus-targeting. (Chat-channel use; low response-time expectation.)
- **Scope:** **harness-only**. Build the entry-update mechanism **provider-agnostic** so the LLM/provider completion path *can* adopt it later, but do not touch provider streaming in this phase.
- **Content:** the **whole accumulating turn** (everything since the last `❯` user line; chrome/process stripped), not just the latest block. The final persisted entry = the full turn.
- **Transport:** **replace-whole** — each update carries the current whole-turn text under a stable id; the frontend replaces. No deltas (repaint-safe; trivial at 2s).

### Non-goals (Phase 2)

- Upgrading LLM/provider responses to live-render (the mechanism is built to allow it later; not wired here).
- Sub-2s "typing" feel / per-token streaming.
- Persisting intermediate states to `transcript.jsonl` (updates are ephemeral, WS-only).

## Architecture

Extend the Phase-1 reconcile watcher: for a **working + bound** harness (`_he_sessionId` + `_he_handle` present), **each tick** extract the whole in-progress turn and publish an **ephemeral** `EntryUpdated` (WS-only, never written to disk) under a **stable per-turn entry id**; on settle, **persist once** via the existing Phase-1 `_rd_recordResponse` (same id), and the streaming flag clears.

| Unit | New/changed | Responsibility |
|---|---|---|
| `src/PureClaw/Harness/Observer.hs` | add `_ho_extractTurn` | whole turn since last user prompt (Claude real; generic = cleaned tail) |
| `src/PureClaw/Harness/Reconcile.hs` | changed | per-session turn state; publish `EntryUpdated` on working ticks; persist final on settle (same id); retire turn-id |
| `src/PureClaw/Frontend/StreamBroker.hs` | add `EntryUpdated` | ephemeral entry-update broker event (NOT through the disk-writing transcript handle) |
| `src/PureClaw/Frontend/Stream.hs` | add `SeEntryUpdate` + `streaming` | wire event for an in-progress entry; `streaming`/`pending` flag on the emitted entry |
| `frontend/src/hooks/useTranscriptStream.ts` | changed | `reconcileEntries` REPLACES on matching id (was skip); stable timestamp preserves sort |
| `frontend/src/lib/streamClient.ts` | changed | handle the `entry-update` event → deliver to entry listeners |
| `frontend/src/types.ts` + `components/ChatArea.tsx` | changed | `streaming?: boolean` on the entry; growing-message indicator, cleared on final |

### Unit 1 — `_ho_extractTurn` (whole-turn extraction)

Add to `HarnessObserver`:

```haskell
_ho_extractTurn :: Int -> ByteString -> Text
  -- baseline → raw capture → the whole assistant turn since the last user
  -- prompt: all `⏺` blocks concatenated, chrome + process/tool lines stripped.
  -- "" when there is no assistant content yet.
```

- **Claude impl:** find the LAST user line (`isClaudeUserLine`, `❯ <text>` not `❯ N.`); take everything after it; keep `⏺`/`●`/`⬤` response blocks and their continuation; strip chrome (`isClaudeChrome`) and process/tool lines (the Phase-1 `isProcessLine`-style predicates). Concatenate the surviving assistant blocks (markers stripped) in order. Differs from Phase-1 `_ho_extractResponse` (which returns only the LAST block).
- **Generic fallback:** cleaned last-N lines (same as `_ho_relevantTail`).
- Phase-1 `_ho_extractResponse`/`_ho_relevantTail` and `/harness output` are UNCHANGED (still last-block / tail). Only the live watcher uses `_ho_extractTurn`.

### Unit 2 — Watcher: turn state, updates, finalize

Loop state gains, per session: a turn id + start-timestamp (`Map Text (Text {-turnId-}, UTCTime)` keyed by harness id-text) and the last-pushed turn text (dedup).

**Stable id is the crux:** the streaming updates and the settle-persisted entry MUST share `_te_id` + `_te_timestamp`, or the frontend can't replace and the message duplicates. Phase 1's `_rd_recordResponse :: SessionId -> Text -> IO ()` mints a *fresh* UUID + `getCurrentTime` inside its production closure — so for Phase 2 the loop owns id/timestamp minting and entry construction, and **both seams take a prebuilt `TranscriptEntry`**:

- New `_rd_mintTurn :: IO (Text, UTCTime)` seam — fresh turn id (UUID) + start timestamp; test stub returns fixed values for determinism.
- `_rd_publishUpdate :: SessionId -> TranscriptEntry -> IO ()` — publish `EntryUpdated` to the broker (WS-only; test stub records).
- `_rd_recordResponse` signature CHANGES from Phase 1's `SessionId -> Text -> IO ()` to **`SessionId -> TranscriptEntry -> IO ()`** — the loop passes the fully-built final entry (stable id/ts), and the production closure just persists it (`bracket (mkBroadcastingFileTranscriptHandle …) … (\th -> _th_record th entry)`, which also publishes `EntryRecorded`). The old `recordResponseEntry` text→entry builder moves into the loop (now parameterised by id/ts/streaming).

Per tick, for a bound harness:

- **Working (Thinking)** and the extracted turn (`_hh_snapshot`-style full capture → `_ho_extractTurn`) is non-empty and **changed** since the last push: look up or `_rd_mintTurn` to get `(turnId, ts)`; build `entry { _te_id = turnId, _te_timestamp = ts, _te_direction = Response, payload = turn, streaming = True }`; `_rd_publishUpdate sid entry`; record `turn` as last-pushed.
- **Settle (`Thinking → Idle | AwaitingInput`)**: build the final entry with the SAME `(turnId, ts)` and `streaming = False`; `_rd_recordResponse sid entry` (persists once); then **retire** the turn id (delete from the map) so the next turn mints fresh. If no turn was ever started (empty throughout), skip — as Phase 1.
- The Phase-1 settle dedup (`prevResponses`) and the per-entry `try` (loop-survives-IO-throw) are preserved; the update-publish is likewise guarded with AsyncCancelled re-raised.

### Unit 3 — Broker + wire

- `StreamBroker`: add `EntryUpdated !SessionId !TranscriptEntry`. This is published DIRECTLY to the broker (NOT via `mkBroadcastingFileTranscriptHandle`, so it never writes to `transcript.jsonl`).
- `Stream.hs`: add `SeEntryUpdate !SessionId !TranscriptEntry`; the emitted JSON entry carries `streaming: true`. The settle `EntryRecorded` flows as the existing `SeEntry` with `streaming: false` (absent ⇒ false). The streaming flag rides on the entry's wire encoding (a new optional field), not a separate envelope field, so both events reuse the entry encoder.

### Unit 4 — Frontend

- `useTranscriptStream.ts` `reconcileEntries`: on a matching id, **replace** the existing entry with the incoming one (currently returns `existing` unchanged). New ids still insert sorted by timestamp; replacement keeps the original position because the turn entry's timestamp is stable across updates.
- `streamClient.ts`: handle the `entry-update` server event by delivering its entry to the same entry listeners (so `reconcileEntries` runs). Only delivered for the focused session, like `SeEntry`.
- `types.ts`: `TranscriptEntry` gains `streaming?: boolean`.
- `ChatArea.tsx`: a `streaming` entry renders a subtle growing-message indicator (e.g. a trailing pulse/`▍`); the indicator clears when the final entry (`streaming` false/absent) replaces it.

## Data flow

```
working tick (bound harness):
  turn = extractTurn(snapshot)
  if turn non-empty and turn /= lastPushed[sid]:
    (turnId, ts) = state[sid] or mint
    publishUpdate → broker EntryUpdated(sid, {id:turnId, ts, Response, streaming:true, turn})  [WS only, no disk]
settle (Thinking→Idle/AwaitingInput):
  recordResponse persists Response{id:turnId, ts, streaming:false}  [disk + EntryRecorded → SeEntry]
  retire state[sid]
frontend:
  SeEntryUpdate → reconcileEntries REPLACES by id (streaming:true → indicator)
  SeEntry(final) → REPLACES by id (streaming:false → indicator clears)
```

## Error handling / edges

- **Reconnect mid-turn:** `EntryUpdated` is ephemeral (not in the transcript-file replay), so the user sees the last *persisted* state; the in-progress turn re-appears within one tick (the watcher re-publishes the whole turn each working tick, same id).
- **Server restart mid-turn:** turn-state lost → next turn mints a fresh id → at worst one duplicate of the in-progress turn, deduped by content at settle (bounded; documented).
- **Out-of-order safety:** a single reconcile thread publishes update(s) then the terminal final per turn, and retires the id at settle — no update follows the final for a given id; per-connection WS ordering is FIFO. So `reconcileEntries` replace-on-id is monotonic and the final is terminal.
- **Redundant traffic:** skip publishing when the extracted turn is unchanged since the last push.
- Capture/extract/publish failures skip the tick (loop never dies; AsyncCancelled re-raised), matching Phase 1.

## Testing

- **Observer `_ho_extractTurn` (pure), golden fixtures:** a multi-`⏺`-turn capture returns all assistant blocks since the last user prompt (chrome + process/tool lines stripped, in order); a single-block turn; an empty/no-assistant turn → "". Generic fallback = cleaned tail.
- **Watcher:** scripted captures that grow across ticks → assert successive `EntryUpdated` with the **same id + timestamp**, growing payload, `streaming:true`; an unchanged tick publishes nothing; settle → exactly one persisted `Response` (same id, `streaming:false`) and the turn id retired (a subsequent turn mints a new id). Loop survives a throwing publish/record.
- **Frontend:** `reconcileEntries` replaces on matching id (regression vs the old skip) and preserves sort position via the stable timestamp; a `streaming` entry renders the indicator and a final entry clears it; the `entry-update` event path delivers to listeners.
- The `_rd_mintTurn` / `_rd_publishUpdate` / `_rd_recordResponse` seams make the watcher unit-testable deterministically (fixed turn id + ts; recorded publishes). Coverage per `.coverage-thresholds.json` (≥95%); TDD throughout. The production `_rd_publishUpdate` / `_rd_recordResponse` IO closures are waiver-eligible like Phase-1's record closure (the decision logic — mint/build/dedup/retire — is unit-tested via the seams).

## Relationship to Phase 1

Phase 1 remains correct and unchanged in behavior except that the watcher now *also* publishes in-progress updates while working (it still persists exactly once on settle). `_ho_extractResponse`, `/harness output`, and `_hh_snapshot` are untouched. The provider/LLM path is untouched; the entry-update mechanism is built so it could adopt it in a future phase.
