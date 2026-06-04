# Design: Harness Conversation Capture via JSONL Session-Log Tail

**Issue:** `pureclaw-3oy.33` (epic `pureclaw-3oy`)
**Branch:** `feat/harness-registry-p1`
**Status:** draft — pending design-review gate
**Author:** orchestrator (session of 2026-06-04)

## Problem

A user creates a PureClaw-spawned claude-code harness, sends some messages through
the PureClaw UI (these appear), then types a message **directly into the harness's
tmux window**. That out-of-band message and its response **never appear** in the
PureClaw frontend session transcript.

### Root cause (verified)

Harness transcript capture is driven **exclusively by PureClaw-initiated
request/response cycles**:

- `harnessSend` (`ClaudeCode.hs:577`) records a `Request` entry and types the
  message into tmux.
- `harnessReceive` (`ClaudeCode.hs:608`) polls until idle, captures the **rendered
  TUI screen** (`capture-pane`), runs `extractLastResponse` (grabs only the *last*
  response), and records one `Response` entry.
- These are invoked only from the UI send path (`API.hs:1946`), the agent loop
  (`Loop.hs:173`), and `/msg` (`SlashCommands.hs:1209`).

The reconcile/activity loop captures the screen every 2 s but only to compute an
`isIdle :: Bool` for the status dot (`Reconcile.hs:143`) — it discards the content.

**Nothing records activity the user initiates directly in tmux.** Worse,
`extractLastResponse` only ever yields the latest response, so even the next
UI-initiated turn would not backfill an intervening out-of-band exchange. Scraping a
redrawing full-screen TUI is also inherently lossy/fragile.

## Key finding: claude-code writes a structured on-disk log

Claude Code maintains an **append-only JSONL session log** per session at:

```
~/.claude/projects/<sanitized-cwd>/<session-uuid>.jsonl
```

where `<sanitized-cwd>` is the absolute cwd with `/` replaced by `-`
(e.g. `/Users/zoe/code/pureclaw` → `-Users-zoe-code-pureclaw`). Each line is a typed
JSON event. The relevant ones:

- `type:"user"` → `{ message:{role:"user", content:<str|[blocks]>}, timestamp, uuid,
  parentUuid, sessionId, cwd, gitBranch, ... }`
- `type:"assistant"` → `{ message:{role:"assistant", content:[blocks], model, usage,
  stop_reason, ...}, timestamp, uuid, parentUuid, requestId, ... }`
- Other types (`mode`, `permission-mode`, `system`, `file-history-snapshot`,
  `last-prompt`, `ai-title`, `queue-operation`, `attachment`, …) are ignored.

This log contains **every turn regardless of origin** — UI-sent or typed directly in
tmux — with timestamps, model, token usage, and structured content blocks. It is a
strictly better capture source than the TUI scrape.

`claude --session-id <uuid>` is a supported CLI flag, so PureClaw can mint a UUID,
spawn `claude --session-id <uuid> …`, and **deterministically** know which file to
tail. No race-prone "newest file" guessing for spawned harnesses.

## Goals

1. Out-of-band turns (input typed in the harness's tmux window) and their responses
   appear in the PureClaw transcript + live UI stream for **PureClaw-spawned
   claude-code harnesses**.
2. Full-fidelity capture: assistant `text`, `thinking`, and `tool_use`/`tool_result`
   blocks are recorded like a native provider session renders them.
3. Survive restart: a reconnected harness re-tails the same JSONL file.
4. No double-recording: the UI send path and the tail must not both record the same
   turn.

## Non-goals

- Adopted claude-code harnesses (PureClaw did not spawn → no known session-id):
  **keep the current TUI scraping.** No JSONL tail.
- Non-claude-code flavours (codex, opencode, hermes, custom): keep TUI scraping. The
  JSONL backend is selected by **flavour = claude-code AND origin = spawned**.
- Editing/replaying claude-code's log. We only read it.

## Design

### 1. Correlation & spawn

- When spawning a claude-code harness, mint a fresh `SessionUuid` and inject
  `--session-id <uuid>` into the claude argv (command assembly in `ClaudeCode.hs`).
- Persist the uuid in the session's `session.json` (`_sm_kind`'s harness spec or a
  sibling field) so a restart can relaunch with the same `--session-id` (resume) and
  re-tail the same file.
- Derive the log path from the harness cwd + uuid:
  `~/.claude/projects/<sanitize(cwd)>/<uuid>.jsonl`. The **cwd fix landed earlier this
  session** (`faac3da`) is what makes this derivation reliable.

`sanitize(cwd)` = replace every `/` with `-` on the absolute path. (Edge: leading `/`
yields a leading `-`, matching observed dir names. Confirm against odd cwds — see Risks.)

### 2. Per-harness async tailer

- Each spawned claude-code harness owns a lightweight `Async` that follows its JSONL
  file from a byte offset, polling at ~250–500 ms (kqueue/inotify optional later).
- Lifecycle: started when the harness is registered/spawned, cancelled when the
  harness is destroyed/released/exits. Tracked alongside the registry entry.
- A tailer is a pure-ish loop over an injected seam (`readFrom :: FilePath -> Offset
  -> IO (ByteString, Offset)`) so it is deterministic in tests (feed byte chunks).

### 3. Backfill + live tail (offset model)

- **On open/spawn:** read the file from the start to current EOF, convert all
  user/assistant events, record them (idempotently — see §5), and remember the EOF
  byte offset.
- **Live:** from that offset, read appended bytes, split on `\n`, hold a partial
  trailing line until its newline arrives, convert complete lines, advance the offset.
- This single offset model unifies backfill and live tail with no gap/overlap.

### 4. Full-fidelity content mapping

Map each `user`/`assistant` JSONL event to a PureClaw `TranscriptEntry`:

- `user` event → `Request` entry; `content` (string or block list) → payload.
- `assistant` event → `Response` entry; `content` blocks (`text`, `thinking`,
  `tool_use`) → the same payload shape provider responses already use, so the frontend
  renders thinking/tool calls identically. `model` → `_te_model`; `usage` → metadata.
- `_te_id` / `_te_correlationId` derive from the JSONL event `uuid` (stable, enables
  idempotency). `_te_timestamp` from the event `timestamp`.
- `tool_result` (which claude-code logs as a subsequent `user`-type event with a
  tool_result block) is matched to its `tool_use` by `tool_use_id`, mirroring the
  existing provider tool-call rendering.

### 5. De-dup with the UI send path (the tricky part)

**Decision:** *UI send records + tail fills gaps* (not "tail is sole recorder").
Rationale: the UI send path gives immediate, low-latency echo of a user-sent message
and its response; the tail backfills only what the UI did not originate (out-of-band
turns). This is the option with the most de-dup risk and is called out for the gate.

Mechanism to guarantee no duplicates:

- All tail-recorded entries are keyed by their JSONL event `uuid`. The transcript
  writer becomes **idempotent on `uuid`**: recording an entry whose `uuid` is already
  present is a no-op.
- UI-originated entries (`_hh_send`/`_hh_receive`) do **not** carry a JSONL uuid, so to
  prevent the tail from re-recording the same turn the tailer maintains a short
  **correlation window**: when it sees a `user` JSONL event whose content matches a
  message PureClaw just injected via `_hh_send` (within N seconds), it treats that turn
  (and the immediately-following assistant event) as already-owned by the UI path and
  **reconciles** rather than appends — replacing the UI's heuristic-scraped entry with
  the precise JSONL one (same display position), or skipping if good enough.
- Out-of-band `user` events (no matching recent injection) are appended as new turns.

> **Gate focus.** This reconciliation is the riskiest element. An alternative — "tail
> is the sole recorder, `_hh_send` only injects keystrokes" — removes the matching
> problem entirely at the cost of ~250–500 ms echo latency on UI sends. The gate should
> decide whether the gap-fill complexity is justified over sole-recorder simplicity.

### 6. Adopted harnesses & other flavours

- The JSONL capture backend is selected iff `flavour == claude-code && origin ==
  spawned`. Everything else keeps `harnessSend`/`harnessReceive` TUI scraping
  unchanged. No behaviour change for adopted/codex/etc.

### 7. Restart / resume

- On boot reconstruction of a spawned claude-code harness, read the persisted uuid,
  relaunch `claude --session-id <uuid> --resume` (or `--continue`) so claude resumes
  the same session and continues appending to the same JSONL, and restart the tailer
  from the persisted/derived offset (or re-backfill).

### 8. Defensive parsing

- Unknown `type` values → ignored. Malformed/partial trailing line → buffered until
  its newline. A line that fails JSON decode → logged at debug and skipped (never
  crashes the tailer). Missing optional fields tolerated. Format drift across Claude
  Code versions degrades gracefully (skip what we can't map).

## Security considerations

- The tailer reads files under `~/.claude/projects/`. It only ever opens the **exact
  path derived from a uuid PureClaw itself minted** for a harness it spawned — never an
  arbitrary or user-supplied path. cwd is already validated (`validateCwd`).
- No writes to claude-code's logs. No new outbound surface.
- The JSONL may contain secrets the user typed; it flows into the PureClaw transcript
  exactly as UI-sent content already does (same trust domain, same on-disk transcript).
  No new exposure beyond what PureClaw already stores.

## Testing strategy

- Pure converter: golden fixtures of real JSONL lines (user/assistant/thinking/
  tool_use/tool_result/unknown/partial) → expected `TranscriptEntry` values.
- Tailer loop: injected `readFrom` seam fed scripted byte chunks (incl. a line split
  across two reads) → asserts entries recorded once, offset advances, partial line
  buffered.
- Idempotency: replaying the same uuids is a no-op; the UI-correlation window
  suppresses the duplicate of a just-injected turn.
- Path derivation: cwd → sanitized dir name table (incl. trailing slash, nested).
- Integration: spawn stub writes a JSONL file; assert out-of-band turn appears in the
  transcript + WS broadcast.

## Risks / open questions

1. **De-dup correctness** (§5) — the gap-fill matching is the main risk; sole-recorder
   is the simpler fallback if the gate rejects it.
2. **cwd sanitization rule** — confirm claude-code's exact algorithm for unusual cwds
   (spaces, dots, symlinks, very long paths) rather than assuming `/`→`-`.
3. **`--session-id` resume semantics** — confirm `--session-id <uuid>` on a *fresh*
   spawn creates that id, and that resume re-uses the same file (vs `--fork-session`).
4. **Log location override** — `CLAUDE_CONFIG_DIR`/env may relocate `~/.claude`;
   derive the base from the same rule claude-code uses.
5. **Format stability** — undocumented format; pin a tolerant parser and add a
   version-drift smoke check.
