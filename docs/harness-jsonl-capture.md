# Design: Optional High-Fidelity Harness Conversation View (claude-code JSONL log)

**Issue:** `pureclaw-3oy.33` (epic `pureclaw-3oy`)
**Branch:** `feat/harness-registry-p1`
**Status:** draft round 2 — addressing design-review-gate round 1; pending re-review
**Author:** orchestrator (session of 2026-06-04)

## Problem & guiding principle

Observed bug: a user created a PureClaw-spawned claude-code harness, typed a message
**directly into its tmux window** (not the PureClaw UI), and that message + response
never appeared in the PureClaw frontend.

**Guiding principle (user decision):** the fundamental session experience must be
**guaranteed to work for every harness flavour** and must **not depend on any
harness-specific log**. Therefore:

- The **default** harness transcript shows **exactly the messages PureClaw sent and
  received** — the existing behaviour, unchanged, harness-agnostic.
- Some harnesses (claude-code) *also* keep a richer structured log on disk. **When such
  a log is available, PureClaw offers an optional control to view it** — a
  higher-fidelity, complete record (including out-of-band turns). When it is not
  available (other flavours, or an adopted harness), the control simply does not appear
  and nothing degrades.

So this feature is **purely additive and optional**: it never replaces or modifies the
guaranteed core transcript. The original bug is resolved *for spawned claude-code* by
letting the user opt into the complete log view; for other harnesses the default
PureClaw-sent/received transcript remains the (accepted) limit of what is capturable.

## Background: how harness capture works today

- `harnessSend` (`ClaudeCode.hs:577`) records a `Request` entry and types the message
  into tmux. `harnessReceive` (`ClaudeCode.hs:608`) polls until idle, scrapes the
  rendered TUI screen, `extractLastResponse` takes the last response, records a
  `Response` entry. Invoked from the UI send path (`API.hs:1946`), the agent loop, and
  `/msg`. **This is the guaranteed core and is NOT changed by this feature.**
- The reconcile loop captures the screen every 2 s only for an `isIdle :: Bool`
  (`Reconcile.hs:143`); it records no content.

## The optional source: claude-code's on-disk JSONL session log

Claude Code continuously appends a structured JSONL log per session at:

```
~/.claude/projects/<sanitized-cwd>/<session-uuid>.jsonl
```

(`<sanitized-cwd>` = absolute cwd with `/`→`-`, e.g. `-Users-zoe-code-pureclaw`). One
typed JSON event per line: `type:"user"` `{message:{role,content},timestamp,uuid,
parentUuid,sessionId,cwd,...}`, `type:"assistant"` `{message:{role,content:[blocks],
model,usage,stop_reason},timestamp,uuid,requestId,...}`, plus metadata types we ignore.
It records **every turn regardless of origin** (UI or tmux), with timestamps, model,
usage, and structured content blocks.

**PureClaw does not write this file — Claude Code does.** PureClaw only reads it. Because
Claude Code maintains it independently, the full history is always on disk whether or not
PureClaw is watching — which is why the optional view can be **load-on-demand** with no
risk of missing data.

`claude --session-id <uuid>` is a supported flag, so a PureClaw-spawned harness can mint a
UUID, launch `claude --session-id <uuid>`, and **deterministically** derive the file path.
Adopted harnesses (no minted id) and non-claude-code flavours have **no** available log →
no control offered.

## Goals

1. The default harness transcript is unchanged: PureClaw-sent/received messages, working
   for all flavours, depending on nothing external. (Guarantee preserved.)
2. For a **spawned claude-code** harness, the user can **optionally** open a complete,
   high-fidelity conversation view sourced from claude-code's JSONL log, including
   out-of-band tmux turns.
3. The optional view renders at full fidelity: assistant `text`, `tool_use`/`tool_result`,
   **and `thinking`** (a new frontend rendering path — §6), matching how a native session
   would render the same blocks.
4. The optional view survives restart (re-derive the path from the persisted session-id).

## Non-goals

- Modifying or replacing the guaranteed core transcript. (It is untouched.)
- Merging the two records into one stream (this is what created the round-1 de-dup
  blocker — explicitly avoided; they are independent).
- An always-on per-harness tailer. The optional view is loaded on demand and torn down
  when closed.
- Capturing out-of-band turns for adopted harnesses or non-claude-code flavours (no log
  available; the default transcript is the accepted limit there).
- Editing/replaying claude-code's log. Read-only.

## Design

### A. Capability detection

- A spawned claude-code harness advertises an **available structured log** capability:
  `flavour == claude-code && origin == OriginSpawned && a persisted session-id exists`.
- This capability is surfaced to the frontend (e.g. a `has_session_log: bool` on the
  harness's tab/registry snapshot). The frontend shows the optional-view control **only**
  when true. Origin/flavour are taken from the **in-memory registry** decision, never a
  raw serialized flag (security §G).

### B. Spawn correlation & persistence

- On spawn, mint a `SessionUuid` (a **validated newtype** — §G) and inject
  `--session-id <uuid>` into the claude argv (injection point: `mkClaudeCodeHarnessWith`
  / `_ccd_addWindow`, `ClaudeCode.hs:287`; confirm arg handling like `hasUnsafeFlag` is
  unaffected).
- Persist the uuid additively as `_h_sessionUuid :: Maybe Text` on `HarnessSpec`, with a
  tolerant `.:? "sessionUuid"` + emit-when-Just codec — exactly mirroring `_h_harnessId`
  (`Kind.hs:71-77`), provably non-breaking for old `session.json`.
- Persist the **canonicalized** cwd used at spawn (the one the factory validated via
  `mkSafePath`), not the raw `_h_cwd` text, so path derivation on restart cannot diverge.

### C. On-demand load + live tail (only while the view is open)

When the user opens the optional view for a harness:

1. Resolve the log path via the `SafeClaudeLogPath` smart constructor (§G).
2. **Backfill:** read the whole file start→EOF, convert `user`/`assistant` events to
   `TranscriptEntry` (§E), deliver them, remember the byte offset.
3. **Live tail:** poll appended bytes past the offset (~250–500 ms), split on `\n`,
   buffer a partial trailing line until its newline arrives, convert complete lines,
   advance the offset.
4. **Teardown:** when the view closes (or the harness is destroyed/exits), stop the tail.

No offset is persisted: every open backfills from 0. Because the JSONL `uuid` is the
entry id (§E), re-opening is naturally idempotent.

**No second on-disk PureClaw store.** Claude Code's own `<uuid>.jsonl` is the source of
truth and is always on disk; the optional view is a **read-through** of that file plus a
**separate in-process broadcast topic** for the live tail. PureClaw writes no second
transcript file. This keeps the core transcript writer and its "sole writer" invariant
(`API.hs:1930-1937`) completely untouched (PureClaw still never writes claude-code's log
either — §56). The separate broadcast topic **reuses the core transcript stream's existing
per-client authorization boundary** (cite the `API.hs` WS auth check) — it introduces no
new unauthenticated egress path.

### D. Tailer architecture (Handle pattern + DI)

- A `JsonlTailDeps` **named record of IO ops** + `defaultJsonlTailDeps`, mirroring
  `ClaudeCodeDeps`/`ReconcileDeps`: `readFrom :: SafeClaudeLogPath -> Offset ->
  IO (ByteString, Offset)`, an EOF/size probe, and the content sanitizer (§G). Tests
  inject fakes; no filesystem needed.
- `newtype Offset = Offset Integer`. The line-splitter is a **pure** function
  `ByteString -> Buffer -> ([CompleteLine], Buffer)` so partial-line and split-across-reads
  cases are unit-tested without IO.
- While a view is open, an `Async` runs the tail loop. Its handle lives in a **sidecar
  map keyed by HarnessId** (NOT a serialized field on `HarnessEntry`, which is snapshotted).
- **AsyncCancelled discipline:** the tail loop's catch-all **re-raises `AsyncCancelled`**
  (per the project invariant at `Reconcile.hs:505`, `BroadcastingTranscript.hs:87`) so
  `withAsync`/`cancel` teardown works; it swallows only non-async exceptions (logged). §8's
  "never crashes" applies to *non-cancellation* errors only.

### E. Payload contract (pinned to the frontend parser)

The frontend does **not** render the raw JSONL shape. It parses (`App.tsx:70-235`):
- **Response** entry payload as a top-level `{ content: [blocks], usage, model }`
  (`CompletionResponse` shape).
- **Request** entry payload as a top-level `{ system_prompt?, messages: [{role,content}] }`,
  with `tool_result` blocks harvested from `role:"user"` content.

So the converter must **transform** each JSONL event into that exact shape:
- `assistant` event → **Response** entry: `message.content` → top-level `content`;
  `message.usage` → top-level `usage`; `message.model` → `_te_model`.
- `user` event → **Request** entry: wrap as `{ messages: [{ role:"user", content }] }`.
- `tool_result` (claude-code logs it as a subsequent `user`-type event with a
  `tool_result` block) → a **Request** entry whose `messages[].content[]` carries the
  `tool_use_id`+content, so `App.tsx buildToolResultIndex` (`App.tsx:67-90`) joins it to
  its `tool_use`.
- `_te_id`/`_te_correlationId` ← the JSONL event `uuid`; `_te_timestamp` ← event
  `timestamp`.

These exact target JSON shapes are pinned as **golden fixtures asserted against
`App.tsx`'s parser** (a real captured provider `_te_payload` is the reference target).

### F. Thinking rendering (new frontend path — full fidelity)

The frontend currently has **no renderer for `thinking` blocks** (`extractTextFromContent`
handles only `text`; `extractToolCalls` only `tool_use`) — native sessions drop them too.
To deliver Goal 3, add a `MessageContent` **thinking** variant rendered collapsed-by-default
(reusing the existing `collapsedText` affordance) + the matching extractor. This applies to
both the optional harness view and native provider sessions (a free fidelity win).

### G. Security (the round-1 CRITICAL items)

- **`SafeClaudeLogPath` smart constructor** (value constructor unexported, mirroring
  `SafePath`): the *only* way to obtain the path the reader opens. It (a) computes the base
  root from the same source claude-code uses (incl. `CLAUDE_CONFIG_DIR`/env relocation),
  (b) `canonicalizePath`es the fully-assembled candidate, (c) verifies canonical containment
  under the canonical `~/.claude/projects` root (catches symlink escape, as `mkSafePath`
  does at `Path.hs:99-105`), (d) opens the final component with `O_NOFOLLOW` to harden
  against TOCTOU symlink swaps.
- **`SessionUuid` validated newtype:** smart constructor accepts only a canonical UUID
  (hex+hyphens, fixed length); `FromJSON` routes through it (mirroring `SessionPrefix`,
  `Session/Types.hs:93-97`) and is **re-validated on restart** before any path derivation —
  so a hostile/edited `session.json` cannot inject `/`, `..`, or NUL into the path.
- **Derive the path from the canonicalized spawn cwd** (persisted, §B), and re-run the
  containment check at every (re)open — not only at first spawn.
- **Sanitization parity:** JSONL-derived content passes through the same
  `sanitizeHarnessOutput` filter the TUI/display path uses (`Handles/Harness.hs:61-89`)
  before reaching the broadcast, so terminal escapes/control chars are stripped consistently.
- **DoS caps:** a max file size for backfill and a max single-line length (skip + debug-log
  an over-long line rather than buffering unbounded); bound concurrent reader memory.
- **Trusted origin:** the "spawned claude-code" capability is decided from the in-memory
  registry, never a serialized `origin` flag, so an edited `session.json` cannot coerce
  tailing of an adopted/foreign session's log.

### H. Phase-0 spike (mandatory before any reader code)

Empirically verify the load-bearing assumptions against the installed `claude` binary,
capturing real artifacts as fixtures:
1. `claude --session-id <uuid>` on a **fresh** spawn creates exactly that uuid's `.jsonl`;
   `--resume`/`--continue` **appends to the same file** (does not fork a new one).
2. The exact `sanitize(cwd)` algorithm (spaces, dots, symlinks, trailing slash, long
   paths, `CLAUDE_CONFIG_DIR`) — capture the real path, don't reverse-engineer.
3. Claude Code only ever **appends** to the JSONL (never rewrites/compacts in place) — the
   byte-offset tail depends on this. If compaction exists, the open-time backfill still
   works (we re-read from 0 each open); only the *live* offset tail would need a re-read.
4. **Loud fallback:** if the derived path does not appear within a short window after the
   view opens, log loudly and show a "log unavailable" state — never silently show nothing.

## Frontend / UX

- Default harness view: the existing PureClaw-sent/received transcript (unchanged). For a
  harness, this lives in the harness pane alongside the controls we just shipped
  (`HarnessControls`).
- When `has_session_log` is true, a control (toggle/tab, e.g. "Full session (claude-code
  log)") reveals the optional complete view, loaded on demand (§C). Closing it tears down
  the tail.
- The optional view renders text + tool calls + thinking (§E/§F). It is visibly labelled
  as the claude-code session log so the user understands it is the richer, complete record
  (and may include turns they typed directly in tmux).
- Degraded states surfaced (not silent): log unavailable / parse-degraded → a small notice
  in the optional view.

## Testing strategy

- **Pure path derivation** (`SafeClaudeLogPath`): table-driven (trailing slash, nested,
  root, env-relocated base) + rejection tests (`..`, symlink-escape via a temp symlink,
  non-canonical-containment, bad uuid).
- **`SessionUuid`**: accepts canonical UUIDs; rejects `/`, `..`, NUL, wrong length;
  `FromJSON` round-trip + hostile-`session.json` rejection.
- **Pure JSONL→`TranscriptEntry` converter:** golden fixtures (user / assistant /
  thinking / tool_use / tool_result / unknown-type-skipped / malformed-skipped) asserted to
  produce the exact `_te_payload` JSON `App.tsx` parses.
- **Pure line-splitter:** chunk fed across two reads → one complete line + buffered partial.
- **Tailer loop** over injected `JsonlTailDeps`: offset monotonicity, partial buffering,
  teardown on cancel (AsyncCancelled re-raised).
- **Frontend:** vitest for the thinking renderer + the optional-view toggle visibility
  (shown iff `has_session_log`) and rendering of a golden full-session record.
- **Integration:** a stub writes a JSONL file incl. an out-of-band turn; opening the
  optional view shows that turn; the default transcript is unaffected.

## Round-2 review resolutions (folded; binding refinements, non-blocking)

All five reviewers APPROVED round 2. The following suggestions are folded in as binding
refinements for the implementation plan:

- **Naming (Architect):** name the claude-code id `ClaudeSessionUuid` /
  `_h_claudeSessionUuid` to keep it unmistakably distinct from the existing
  `Registry._he_sessionId` (the PureClaw session join). Add a disambiguating doc note.
- **No second store (Architect):** see §C — the optional view is a read-through + a
  separate broadcast topic; no `claude-session.jsonl` is written. `readFrom` must define a
  total degraded path when the file shrinks/disappears (return current size, signal
  re-read-from-0) so the tailer never returns a negative/garbage delta.
- **Security hardening (Security):** (a) `SafeClaudeLogPath` also checks
  `owner == geteuid()` (and rejects group/other-write), mirroring `mkSafeKeyPath`'s
  `checkModeAndOwner`, to close the foreign-/pre-created-file substitution vector that
  `O_NOFOLLOW` alone does not; (b) the minted `ClaudeSessionUuid` uses a **CSPRNG** (v4
  from a cryptographic source) so an attacker cannot pre-create the target file; (c)
  `ClaudeSessionUuid` / `SafeClaudeLogPath` get a **redacted `Show`** (like
  `SafeKeyPath`/`SafeRuntimePath`) so the path is not leaked into general logs; (d) pin
  **concrete numeric DoS limits** (max backfill file size, max single-line bytes, max
  buffered partial-line bytes) so VALIDATE can assert them; over-cap → the loud
  "log unavailable" fallback (§H.4), never a silent partial read; (e) the frontend
  thinking/tool render path must treat JSONL content as untrusted (React text-escaping;
  no `dangerouslySetInnerHTML`) in addition to `sanitizeHarnessOutput`.
- **Fidelity rendering (Designer):** the thinking block renders with its **own distinct
  collapsed label ("Thinking")**, not the bare `CollapsedBlock` chrome used for the System
  prompt. Golden fixtures assert **both** `_te_payload` **and** the sibling `_te_model` /
  `_te_harness` columns (the rendered agentName comes from the column, not the payload).
- **TDD obligations (CTO):** (a) golden fixtures are captured by serializing a **real**
  `TranscriptEntry` payload from the Haskell encoder (byte-for-byte vs production), not
  hand-written JSON — the first sub-step of the converter WU; (b) add an **idempotence
  golden**: feed the same JSONL event twice → de-duped by `_te_id`; (c) pin a concrete
  `Buffer` newtype and assert the splitter does not strip a stray `\r` into content
  (logs are LF); (d) inject `--session-id` through the **existing `[Text]` args** at the
  `mkClaudeCodeHarnessWith` call site, not by widening `_ccd_addWindow`'s signature; (e)
  the thinking renderer is its **own WU** with a regression assertion that native-session
  text/tool_use rendering is unchanged (it touches native sessions too).
- **WU ordering (CTO):** the **Phase-0 spike (§H) blocks** the `SafeClaudeLogPath`
  derivation and converter WUs — its captured artifacts (real path, real JSONL lines) are
  those WUs' fixtures. Not parallel.
- **Capability surfacing (Architect/CTO):** `has_session_log` is **computed** at
  snapshot-build time from the in-memory registry decision (`flavour==claude-code &&
  OriginSpawned && claudeSessionUuid present`), **not a stored field**, so it cannot drift
  from the trusted-origin decision (§G). Add a snapshot-builder test asserting the additive
  field does not perturb existing tab-JSON consumers. Wire the harness **exit** signal
  (reconcile-detected death) to cancel the sidecar tail Async, not only explicit view-close.
- **UX (Designer/PM):** the optional-view control lives in/near `HarnessControls`, gated on
  `has_session_log` (mirroring the existing `tab.origin` conditional there); degraded and
  "not available for this harness" states use the same muted `Field` styling. The label
  states the view is the **higher-fidelity, complete** claude-code session log (a superset
  that may include turns typed directly in tmux). Per-open opt-in (no sticky preference) is
  the deliberate v1 model.
- **Measurable success criteria (PM):** (1) an out-of-band tmux turn appears in the
  optional view within a few seconds of opening it; (2) opening/closing the optional view
  never alters or drops an entry in the default transcript; (3) the control is absent for
  non-claude-code/adopted harnesses and that absence is explained, not silent.

## Risks / open questions (for re-review)

1. **Spike assumptions (§H)** are load-bearing; the spike must land first as its own WU.
2. **Two stored records** — confirm the separate optional record file + broadcast topic do
   not interfere with the core transcript's REST seed / WS reconcile (they are keyed and
   streamed independently; the default view never reads the optional store).
3. **`claude --session-id` create-vs-fork semantics** and **append-vs-compaction** — both in
   the spike; the design degrades gracefully (open-time backfill) if compaction exists.
4. **Capability surfacing** — adding `has_session_log` to the snapshot must be additive and
   not perturb existing tab JSON consumers.
