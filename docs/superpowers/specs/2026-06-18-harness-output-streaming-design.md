# Harness Output Streaming — Phase 1 (Reliable Output Flow)

**Date:** 2026-06-18
**Status:** Design — approved in brainstorming, pending spec review
**Scope:** Phase 1 of a two-phase effort. Phase 2 (live in-place message editing) is a separate spec.

## Problem

When a user interacts with a tmux-backed harness (Claude Code today; Codex / OpenCode
later) from the PureClaw web frontend, input reaches the harness but **no output comes
back into the PureClaw session** — not even the direct reply to a message the user sent.
Anything the harness does (its reply, multi-step tool work, async work, or the user
typing directly into the tmux window) never reaches the transcript.

### Root cause

`isIdle` (`src/PureClaw/Harness/ClaudeCode.hs:782`) defines idle as
"`❯` present AND not busy", where busy = the screen contains `⠋` (one braille spinner
glyph) or the literal words `Thinking`/`Running`. The live Claude Code TUI violates both
assumptions:

- The input box (`❯` + `────` rules) is rendered **permanently**, even mid-work — so
  "prompt present" is always true.
- The working indicator is a rotating glyph from a set like `✶`/`✻`/`✽` plus a *random
  gerund* and a `(Ns · ↑/↓ Nk tokens)` counter — e.g. `✶ Smooshing… (4m 55s · ↓ 16.6k
  tokens)`. It never contains `⠋` / `Thinking` / `Running`.

So `isIdle` returns true almost immediately after a send; `pollUntilIdle` captures before
the reply renders; `extractLastResponse` returns `""`; and `routeViaHandle`
(`src/PureClaw/Frontend/API.hs:2143`) silently drops empty responses. Net effect: nothing
is recorded.

**Working-vs-idle detection is therefore the linchpin** — it both fixes the round-trip and
enables streaming — and it is inherently per-harness-flavour, since each tool draws its TUI
differently.

## Goals

1. **Mechanism 1 — `/harness output [N]` slash command.** On demand, display the last *N*
   relevant output lines (or the latest extracted response) for the bound harness.
   Ephemeral (not persisted), a manual fallback.
2. **Mechanism 2 — automatic output streaming.** Once a harness is connected, its output is
   recorded to the PureClaw session automatically, including async work and direct-in-tmux
   typing.
3. **Working / idle / awaiting-input detection**, per flavour, driving both the status pill
   and the trigger for capturing output.

### Non-goals (Phase 1)

- Live in-place message editing (one message that visibly grows). That is **Phase 2** and
  requires net-new streaming capability (see "Deferred" below).
- Real Codex / OpenCode detectors. Phase 1 ships a generic stability-only fallback for
  non-Claude flavours; only the Claude observer is fully implemented.

## Prior art

[faryo](https://github.com/Snailflyer/faryo) (MIT) solves the same problem. We reimplement
its heuristics in Haskell (they are facts about the harnesses' terminal output, not borrowed
code). Adopted ideas, validated against live captures:

- A per-agent profile object (`AgentProfile`) with an `agent_ready_for_input` predicate →
  our `HarnessObserver`.
- Concrete Claude working-line signal: a spinner-glyph set
  `· ✢ ✱ ✲ ✳ ✴ ✵ ✶ ✷ ✸ ✹ ✺ ✻ ✼ ✽ ✾ ✿ ★` + gerund + `(Ns · …tokens/thinking)`.
- Prompt disambiguation: `❯` is the idle prompt only when **not** followed by `\d+.` (the
  menu-selection cursor).
- Chrome lines to strip: bare `❯`/`›`, `esc to interrupt`, `? for shortcuts`,
  `(ctrl+o to expand)`.
- Process-vs-output classification: tool lines (`Bash(`, `Read(`, `Edit(`, `⎿`, `✻`,
  `(ctrl+o to expand)`) are *process*, the `⏺`/`●` blocks are assistant *output*.
- A third activity state: **awaiting input/approval** (`Do you want to proceed?`, numbered
  `Yes/No`, `Enter to confirm · Esc to cancel`).
- Capture with `capture-pane -p -J` (the `-J` joins wrapped lines, removing split-line
  artifacts; PureClaw currently omits it).

## Architecture

Five units; four reuse existing infrastructure.

| Unit | New/changed | Purpose |
|---|---|---|
| `PureClaw.Harness.Observer` | **new module** | Per-flavour pure detection/extraction seam |
| Output watcher (extend `Harness/Reconcile.hs`) | changed | Sole recorder of harness Response output, on settle |
| Send-path decoupling (`Frontend/API.hs`) | changed | Record Request + inject keystrokes; no blocking receive |
| `/harness output [N]` (`Agent/SlashCommands.hs` + dispatch) | new | On-demand ephemeral display |
| Activity detection → status pill (`Reconcile.hs`) | changed | Correct working / idle / needs-input via the observer |
| Capture primitive `-J` (`Harness/Tmux.hs`) | changed | Join wrapped lines |

### Unit 1 — `HarnessObserver` (the per-flavour seam)

A record of pure functions, mirroring the `ClaudeCodeDeps` style, selected by flavour:

```haskell
-- PureClaw.Harness.Observer

-- | The classified activity state of a harness, derived from a pane capture.
data HarnessActivityState
  = HasWorking        -- actively producing output (spinner / status line present)
  | HasAwaitingInput  -- blocked on an approval prompt or menu (needs the user)
  | HasIdle           -- settled, ready for input, nothing pending
  deriving stock (Eq, Show)

data HarnessObserver = HarnessObserver
  { _ho_classify        :: Text -> HarnessActivityState
      -- ^ Pane capture (ANSI-stripped, -J joined) → activity state.
  , _ho_extractResponse :: Int -> ByteString -> Text
      -- ^ baseline line count → raw capture → latest assistant response
      --   (compacted: chrome + process lines stripped, output blocks since the
      --   last user prompt joined). "" when there is no new response.
  , _ho_relevantTail    :: Int -> ByteString -> Text
      -- ^ N → raw capture → cleaned last-N relevant lines (for /harness output).
  }

observerFor :: HarnessFlavour -> HarnessObserver
```

- **Claude Code observer** (`HClaudeCode`): relocates and replaces the marker logic
  currently in `ClaudeCode.hs`.
  - `_ho_classify`:
    - `HasWorking` if a working/status line matches: spinner-glyph set above + gerund +
      `…`, or a `(Ns · …tokens|thinking)` counter, or `esc to interrupt`.
    - else `HasAwaitingInput` if an approval/menu prompt is present (`Do you want to
      (proceed|create|edit|write|run|allow|make)…?`, `Yes, and don't ask again`,
      `Enter to confirm`, `Esc to cancel`, or a numbered `❯ 1. Yes` / `2. No` option line).
    - else `HasIdle` (a bare `❯`/`›` prompt not followed by `\d+.`).
  - `_ho_extractResponse`: split into lines; classify each as
    user (`❯ …text`, not `❯ \d+.`) / status / process (`Bash(`,`Read(`,`Edit(`,`Write(`,
    `MultiEdit(`,`Grep(`,`Glob(`,`LS(`,`Task(`,`TodoWrite(`, `⎿`, `✻`,
    `(ctrl+o to expand)`, edit-preview/diff lines) / output (`⏺`/`●` blocks and their
    continuation). Return the assistant **output** blocks since the last user prompt, with
    chrome stripped. When the state is `HasAwaitingInput`, return the approval/menu prompt
    text so the user sees the question.
  - `_ho_relevantTail N`: ANSI-strip, drop chrome lines, return the last `N`.
  - **Glyph note:** live captures show the assistant marker as `⏺` (U+23FA); faryo uses `●`
    (U+25CF). The implementation matches **both** and is confirmed against a captured fixture.
- **Generic fallback** (`HCodex`, `HOpenCode`, `HHermes`, `HPureClaw`, `HCustom`): no flavour
  markers, so `_ho_classify` always returns `HasIdle` (it cannot detect working from a single
  frame, and never reports `HasAwaitingInput`). The watcher's cross-tick stability gate
  (Unit 2) is what actually distinguishes working from idle for these flavours.
  `_ho_extractResponse` / `_ho_relevantTail` return cleaned (ANSI-stripped) last-N lines. Real
  Codex/OpenCode detectors are deferred.

**Classification is per-frame; the watcher adds stability.** `_ho_classify` only inspects a
single capture. The watcher (Unit 2) combines it with cross-tick stability to produce the
final state, so the rule is identical for all flavours: `HasWorking` (marker) ⇒ working;
`HasAwaitingInput` ⇒ awaiting-input; `HasIdle` ⇒ idle **only if the capture is unchanged
since the previous tick**, otherwise working (still rendering). This stability confirmation
both prevents Claude from settling mid-repaint and is the *sole* working signal for the
marker-less generic fallback.

### Unit 2 — Output watcher (extend the reconcile loop)

`Harness/Reconcile.hs` already runs every 2 s, captures each registered harness pane (now
with `-J`), and classifies liveness. Extend it to own response recording:

- Maintain per-harness watcher state: `(prevActivity, lastRecordedResponseHash)`.
- Compute the final `state` by combining `_ho_classify capture` (via `observerFor (entry
  flavour)`) with cross-tick stability, per the combined rule in Unit 1: a `HasIdle` marker
  result is confirmed idle only when the capture is unchanged since the previous tick;
  otherwise it is still working.
- Map to the activity vocabulary the frontend consumes (`SaHarnessStatus`):
  `HasWorking → HarnessThinking`, `HasIdle → HarnessIdle`, `HasAwaitingInput →
  HarnessNeedsInput` (the new value — see Unit 5). Publish on transition (existing path).
- **On a settle transition** (`HasWorking → HasIdle` or `HasWorking → HasAwaitingInput`),
  for a harness bound to a PureClaw session (`Registry._he_sessionId`): run
  `_ho_extractResponse baseline capture`, where `baseline` is the harness's recorded
  scrollback baseline when reachable (else `0` — `_ho_extractResponse` returns only the
  latest assistant block, so pre-baseline backlog is not re-emitted, and the response-hash
  is the primary dedup guard). If the result is non-empty **and** its hash differs from
  `lastRecordedResponseHash`, record **one** `Response` entry to that session's transcript
  via `mkBroadcastingFileTranscriptHandle`, then update the hash. This flows through the
  existing broker → WS → frontend path.
- Capture/extract failures skip the tick (the loop is already exception-isolated).

This makes output recording automatic for any registered harness — no per-connect wiring —
and covers async work and direct-in-tmux typing, because the watcher observes the pane
regardless of who produced the output.

**Dedup:** in-memory hash per session, plus the existing scrollback `baseline`. Both
re-derive after a restart; a duplicate of the last response after reconnect is acceptable
and bounded to one.

### Unit 3 — Decouple send from receive

Today `routeViaHandle` (`Frontend/API.hs:2122`) does send → blocking `_hh_receive` (≤120 s)
→ record Response inline, which would both double-record against the watcher and block the
HTTP response. Change the harness send path to: record the **Request** entry and inject
keystrokes, then respond promptly. The **watcher is the sole recorder of Response output.**

- `POST /api/sessions/{id}/send` to a harness returns promptly after injecting input; the
  reply arrives over the existing WS stream once the watcher records it.
- `_hh_receive` / `pollUntilIdle` remain for the CLI/TUI path but are fixed to use the
  observer's `_ho_classify` instead of the broken `isIdle`.

### Unit 4 — `/harness output [N]` slash command

Add to the existing `GroupHarness` (`/harness start|stop|list|attach`). Resolves the bound
harness, captures its pane (`-J`), runs `observerFor flavour`:
`_ho_relevantTail N` when `N` is given, else `_ho_extractResponse` (latest response). Returns
the cleaned text **ephemerally** — matching how slash output is returned verbatim and never
persisted today (`runSlashInput`). Default `N` when omitted is the latest extracted response.

### Unit 5 — Activity detection → status pill

`_ho_classify` (combined with stability) replaces the screen heuristic the reconcile loop
uses for liveness. A new `HarnessNeedsInput` value is added to the `HarnessActivity`
vocabulary and carried through `SaHarnessStatus` → `ServerEvent` → the frontend
`ActivityKind`, where it renders with the existing `--needs-input` color. (The internal
`Liveness` enum gains a corresponding awaiting-input case feeding this mapping.)
`HarnessExited` / `HarnessOrphaned` classification (PID / `pane_dead`) is unchanged.

## Data flow

```
spawn/adopt ─▶ registry entry (existing) ─▶ reconcile loop observes every 2 s
   loop: capture pane (-J) ─▶ observerFor(flavour)._ho_classify
        ├─ activity state ─▶ SaHarnessStatus (working / idle / needs-input) ─▶ WS ─▶ pill
        └─ on settle transition ─▶ _ho_extractResponse ─▶ dedup vs last hash
                                   └─ if new: record Response ─▶ broker ─▶ WS ─▶ transcript
user sends msg (frontend) ─▶ record Request + inject keystrokes; reply arrives via watcher
user runs /harness output [N] ─▶ capture ─▶ observer ─▶ ephemeral text (not persisted)
```

## Error handling

- Capture/extract failure in the watcher: log + skip the tick; never crash the loop.
- Empty extraction: record nothing.
- Harness window gone / not corroborated: existing reconcile classification
  (`Exited`/`Orphaned`) applies; no response recorded.
- Dedup-state loss on restart: at most one duplicate of the last response; bounded and
  acceptable.

## Testing

- **Observer (pure), golden fixtures from real captures** saved under
  `test/fixtures/harness/` (working-spinner frame, idle frame, awaiting-approval frame,
  multi-`⏺`-block turn):
  - `_ho_classify` → `HasWorking` on spinner/`esc to interrupt`/token-counter frames;
    `HasAwaitingInput` on approval/menu frames; `HasIdle` on the bare-prompt frame; and
    **not** `HasIdle` when the menu cursor `❯ 1.` is present.
  - `_ho_extractResponse` pulls the assistant `⏺`/`●` block(s) since the last user prompt
    and strips chrome + process lines; returns the prompt text when awaiting input.
  - `_ho_relevantTail N` returns N cleaned lines.
  - Generic fallback: stability-only classification; cleaned last-N extraction.
- **Watcher:** simulated `working → idle` sequence records exactly one Response; repeated
  idle ticks dedup to zero; a `working → awaiting-input` transition records the prompt;
  output produced with no preceding `/send` (direct-tmux) is still recorded.
- **Send path:** harness `POST /send` records a Request, injects keystrokes, responds
  promptly, and does **not** record a Response (the watcher owns that).
- **Slash command:** `/harness output` returns extracted text and persists nothing.
- Coverage per `.coverage-thresholds.json` (≥95%), TDD throughout.

## Known Phase-1 limitation

A multi-step turn emits several `⏺`/`●` blocks (think → tool → think → final); turn-level
capture records the **last** assistant block per settle. Seeing the full progression live is
exactly what **Phase 2 (live-edit)** delivers; `/harness output` is the manual workaround
meanwhile.

## Deferred to Phase 2 (separate spec)

Live in-place message editing — one transcript entry that visibly grows as the harness
works, finalized on settle. Requires net-new streaming capability that does not exist today
even for LLM responses: an entry-update broker/wire event, `reconcileEntries`
(`frontend/src/hooks/useTranscriptStream.ts:35`) replacing instead of skipping on a matching
id, a pending/streaming flag, and persist-once-on-settle. It can also upgrade LLM token
streaming to render live.
