# Plan: Reliable Harness Output Streaming (content-driven watcher)

- Date: 2026-06-21
- Branch: feat/harness-live-edit
- Status: draft (pending plan-review gate + user approval)
- RED test already committed: `test/Harness/ReconcileSpec.hs` —
  "records a fast turn the watcher only ever samples as Idle (never Thinking)"
  (commit d944fbd)

## Problem

All automatic harness output — both live streaming **and** the final recorded
response — flows through exactly one mechanism: the reconcile watcher's
`Thinking → settle` liveness lifecycle.

- `publishUpdates` (live streaming) only runs for ids whose liveness **this
  tick** is `LivenessThinking` (`Reconcile.hs:636,732`).
- `settle` (final record) only fires on a `Thinking → Idle/AwaitingInput`
  **edge** — `settledIds` requires `prev == Thinking` (`Reconcile.hs:740-745`).
- The send path (`API.hs routeViaHandle`) deliberately records only the
  Request and returns `{"response":""}`, relying on the watcher for the reply
  (`API.hs:2122-2155`).

At the 2-second tick cadence (`defaultTickMicros`, `Reconcile.hs:570`), any turn
that is never *sampled* in a working state produces **no automatic output at
all**:

- **Fast turns** that complete between two polls (never observed Thinking).
- Turns where the spinner heuristic (`isClaudeWorkingLine`) misses the sampled
  frames.

`/harness output` always works because it is an independent on-demand capture
(`SlashCommands.hs:1919-1934` → `_hh_snapshot`) with no dependency on the
liveness lifecycle. That is the user's manual fallback today.

Secondary fidelity gap: `_hh_snapshotTurn` captures the **visible screen only**
(`realCaptureNamed … 0` ⇒ `capture-pane -S -0`, `ClaudeCode.hs:884`). A long
turn whose prose has scrolled off, or a tool-output-dominated screen, yields
truncated or empty extraction even when the watcher *does* observe Thinking.

### Out of scope (noted limitation)

CLI/TUI `/harness start` spawns set `_he_sessionId = Nothing` **by design** —
there is no owning session/`session.json` for a CLI-only harness
(`SlashCommands.hs:1876-1888`). Frontend-started harnesses already backfill
`_he_sessionId` (`API.hs:1776`) and the adopt path sets it
(`ClaudeCode.hs:577`), so the reported frontend symptom is unaffected. Giving
CLI/TUI harnesses an owning session is a separate design change; not included.

**Prose-less / tool-output-only turns.** `extractTurnClaude` intentionally
filters tool/process lines and chrome (`Observer.hs:217-222`), keeping assistant
*prose*. A turn that is purely tool execution with no assistant prose extracts to
empty and is therefore not recorded — this is **pre-existing** behaviour
(`extractTurnClaude` is already what the current watcher uses) and is **unchanged**
by this plan, not a regression. Rationale: the transcript records assistant
prose, not tool chrome; tool activity remains visible via `/harness output` and
the live tmux pane. Turns in practice end with assistant prose (a summary/answer),
which is captured. Making tool-only turns record content is a separate
transcript-semantics decision and is out of scope.

## Fix strategy

Drive streaming and finalization off **turn-content change + stabilization**,
using liveness only as a *guard against premature finalize* — not as the trigger.

Per live entry, per tick (entries with a handle + a `Just` sessionId whose
liveness is `Thinking | Idle | AwaitingInput`; `Exited`/`Orphaned` excluded):

1. Snapshot the whole turn (`_hh_snapshotTurn`).
2. If the snapshot is empty/whitespace → no-op (between turns).
3. If it **grew/changed** vs the last seen text for the active turn → publish an
   ephemeral `EntryUpdated` under the turn's stable minted id; reset the
   stable-tick counter. (This streams even when the watcher classifies the tick
   as Idle — the fast-turn case.)
4. If it is **unchanged** and the harness is `Idle | AwaitingInput` and it has
   been unchanged for `defaultSettleStableTicks` consecutive ticks → record the
   final `Response` from that text (same turnId + start ts), retire the turn.
5. After finalize, the per-entry state is retained (inactive) so that
   subsequent ticks showing the *same* already-recorded content do **not**
   re-stream or re-record. A later change to *different* non-empty content mints
   a **new** turn (the next user message).

Liveness as guard: while `Thinking`, we stream but never finalize — so a long
tool pause (static screen, still Thinking) does not finalize prematurely. The
existing `classifyRow` stability gate (idle requires two byte-identical 50-line
captures) is a second layer of protection.

This subsumes the current `Thinking`-edge behaviour: a normal slow turn still
streams while Thinking and finalizes when it goes idle-stable; a fast turn now
finalizes on idle-stable content even though no Thinking frame was caught.

### Terminal-transition finalize (harness exits at end of turn)

A harness can produce a full reply and then **exit** (process dies → dead PID;
or the tmux window dies → `pane_dead`), classified `LivenessExited`
(`Reconcile.hs:539,548`); a window vanishing from the sweep is `LivenessOrphaned`.
Neither is in `streamableIds`, so without special handling an **active** turn
that already streamed content would never finalize — the terminal turn would be
lost. (This matches a real instance of the user's symptom and is also a gap in
the *current* code, whose `settledIds` likewise only fires on `Idle/AwaitingInput`.)

Fix: each tick, for any id with an **active** turn in the state map whose current
liveness is terminal (`Exited`/`Orphaned`) or whose entry is absent from this
tick's observation, finalize the turn from its **last streamed text**
(`_tsLastText`) and retire it. If it never streamed any content (`_tsLastText`
empty — e.g. the process died before any capture), there is nothing to record
and the turn is simply dropped (an exited+dead pane cannot be captured by
`/harness output` either).

### AwaitingInput semantics (no fragmentation regression)

Finalizing on stable `AwaitingInput` content records the approval/menu prompt as
its own entry so the user sees the question — this **matches the current
behaviour** (the existing test `ReconcileSpec.hs:417` asserts the prompt is
recorded) and the current code's structure: the present `settle` *also* retires
the turn id at the `Thinking→AwaitingInput` edge (`Reconcile.hs:691-694`
deletes from the turn map), so the post-approval continuation already becomes a
new turn under current code. WU1 preserves this: after the user answers, the
harness resumes (`Thinking`) and the continuation is a fresh turn with a new
minted id. This is intended (an approval question and the subsequent answer are
distinct response entries), not a new fragmentation introduced by this plan. The
stable-id contract is preserved *within* each turn (prompt entry has one id;
continuation has one id). The existing AwaitingInput test must still record
exactly `[the prompt]` (WU1 DoD #2).

## Work units

### WU1 — Content-driven watcher (PRIMARY)

**Files:** `src/PureClaw/Harness/Reconcile.hs`, `test/Harness/ReconcileSpec.hs`

Replace the two separate `publishUpdates` (Thinking-gated) and `settle`
(prev==Thinking-edge) passes with a single content-driven `stepTurns` pass.

- Introduce a richer per-entry turn state carried by the loop (replaces the
  `Map Text (Text, UTCTime, Text)` turnMap):
  ```haskell
  data TurnState = TurnState
    { _tsTurnId  :: !Text      -- stable id: same across every update + the final
    , _tsStarted :: !UTCTime
    , _tsLastText:: !Text      -- last text we streamed/observed for this turn
    , _tsStable  :: !Int       -- consecutive ticks _tsLastText unchanged
    , _tsActive  :: !Bool      -- True = streaming, not yet finalized
    }
  ```
- `streamableIds obs = ids with liveness ∈ {Thinking, Idle, AwaitingInput}`.
- `stepTurns` per id (snapshot `t = _hh_snapshotTurn hh`):
  - empty `t` → unchanged state.
  - new content (no state) → mint id, `_rd_publishUpdate`, state active, stable 0.
  - changed + active → `_rd_publishUpdate` (same id), stable 0.
  - changed + inactive (previous turn done) → mint NEW id, publish, active.
  - unchanged → stable+1; if active && liveness ∈ {Idle,AwaitingInput} &&
    stable ≥ `defaultSettleStableTicks` → `_rd_recordResponse` (same id+ts),
    mark inactive (retire).
- **Terminal transition:** for any id with an active turn in the state map whose
  current liveness is `Exited`/`Orphaned` or is absent from this tick's
  observation, finalize from `_tsLastText` (if non-empty) and mark inactive; an
  empty `_tsLastText` is dropped (nothing was ever captured to record).
- New constant `defaultSettleStableTicks :: Int = 1`.

**Trace of the committed RED test under this algorithm** (frames all idle;
`_hh_snapshotTurn` returns `""` on the 1st call then `"fast answer"`;
`defaultSettleStableTicks = 1`):

1. Baseline tick (empty prevCaps) classifies the idle frame `Thinking`; the loop
   body does not run the content step at baseline. No snapshot call.
2. First content-step tick (Idle): snapshot `""` → empty → no-op (between turns).
3. Next tick (Idle): snapshot `"fast answer"` → new content (no state) → mint id,
   `_rd_publishUpdate`, state `{active, lastText="fast answer", stable=0}`.
4. Next tick (Idle): snapshot `"fast answer"` → unchanged → stable=1; active &&
   Idle && stable ≥ 1 → `_rd_recordResponse "fast answer"`, mark inactive.
5. Subsequent idle ticks: unchanged + inactive → no-op (no re-record).

Result: recorded exactly `[(sess-1, "fast answer")]` — the asserted value. The
fixture's first-`""` snapshot is handled naturally as "between turns"; it no
longer relies on the old startup edge.
- Resilience preserved: wrap each id's step in `try @SomeException`; re-raise
  `AsyncCancelled`; on other exceptions log + skip. On a `_rd_recordResponse`
  failure, mark the turn **inactive** (do not retry every tick → no log spam),
  matching the spirit of the existing Finding-1 resilience test.
- `prev` liveness is still threaded for `diffLiveness`/`ActivityChanged`
  (unchanged); only the turn-emission logic changes.

**DoD:**
1. The committed RED test now PASSES (fast turn recorded exactly once) — per the
   trace above.
2. All existing "output watcher — record Response on settle" tests still pass —
   verified by trace, not assertion: working→idle records once + dedups;
   working→awaiting-input records exactly `[the prompt]`; sessionId=Nothing skips;
   spinner→idle with no send; Finding-1 resilience.
3. New test: an idle harness showing already-recorded content across many ticks
   records/streams it **exactly once** (no re-record on unchanged content).
4. New test: two sequential turns (content changes to a new value after the
   first finalizes) produce **two** records with **distinct** turn ids.
5. New test: a turn that grows across ticks publishes ≥2 `EntryUpdated`s under a
   **single stable** turn id, and the final record reuses that id.
6. New test: a harness with an **active streamed turn** that transitions to
   `Exited` (or `Orphaned`) finalizes its turn from the last streamed text
   exactly once; an active turn that exits having streamed nothing records
   nothing.
7. New test: the existing AwaitingInput case records exactly `[the prompt]` under
   the content-stability finalize (no fragmentation / no extra record).
8. `-Wall -Werror` clean; hlint clean.

### WU2 — Widen `snapshotTurn` capture extent (SECONDARY)

**Files:** `src/PureClaw/Harness/ClaudeCode.hs`
(+ `test/Harness/ClaudeCodeSpec.hs` if snapshotTurn capture is covered there)

- Change `_hh_snapshotTurn` capture from `realCaptureNamed … 0` (visible only)
  to a scrollback-inclusive extent (e.g. 200 lines) at **both** handle-builder
  sites (`ClaudeCode.hs` ~414 and ~884) so `extractTurnClaude` can locate the
  last user line and the full prose for long turns. `extractTurnClaude` already
  trims to "since the last user line", so extra scrollback only improves
  boundary detection; it cannot leak prior turns.
- Introduce a named constant for the extent (avoid a bare magic number).

**DoD:**
1. Both snapshotTurn sites use the widened, named extent.
2. A test demonstrates a long turn (prose beyond the visible screen) extracts
   the full turn (vs truncated/empty under `-S -0`). If existing ClaudeCodeSpec
   coverage already exercises the seam, extend it; otherwise add a focused
   `extractTurnClaude`/capture test.
3. `/harness output` behaviour unchanged (its `_hh_snapshot` extent is separate).
4. `-Wall -Werror` clean; hlint clean.

## Test plan / coverage

- TDD throughout (RED already committed for the core case).
- `.coverage-thresholds.json` (100% lines/branches/functions/statements) is the
  blocking gate. Every new branch in `stepTurns` (empty / new / changed-active /
  changed-inactive / unchanged-not-yet / unchanged-finalize / terminal-finalize /
  terminal-empty-drop / record-failure) must be covered by a `ReconcileSpec` case.
- Full suite green: `nix develop . --command cabal test`.

## Risks & mitigations

- **Premature finalize mid-turn** (output pauses): mitigated by the liveness
  guard (only finalize when Idle/AwaitingInput) + the existing two-tick capture
  stability gate + the `defaultSettleStableTicks` counter.
- **Re-recording unchanged content**: mitigated by retaining inactive turn
  state and only minting a new turn on a *changed* non-empty snapshot.
- **Back-to-back turn id reuse**: a new turn is detected as a content change
  after the previous turn went inactive; the inter-turn idle normally finalizes
  the first turn before the second begins.
- **Behavioural shift in timing**: finalize now lands ~1 tick after the last
  content change rather than on the liveness edge; assertions are on recorded
  *content/identity*, not timing, so existing tests remain valid.

## Verification

- `nix develop . --command cabal test` (full suite).
- `nix develop . --command cabal test --enable-coverage` meets thresholds.
- Manual: start a harness from the web frontend, send a fast prompt, confirm
  the reply streams + persists without `/harness output`.
