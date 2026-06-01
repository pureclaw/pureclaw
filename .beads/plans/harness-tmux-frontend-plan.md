---
issue: pureclaw-99a
pr: pending
status: approved — plan-review-gate PASSED round 2 (Feasibility/Completeness/Scope all PASS)
date_drafted: 2026-05-31
beads_epic: pureclaw-99a
deferred_followup: pureclaw-jlc
branch: fix/frontend-harness-tmux-spawn
note: >
  active-plan.md is currently owned by issue #57 (transcript streaming, status draft).
  This plan is intentionally kept in a separate file to avoid clobbering it.
---

# Implementation Plan — Frontend harness/tmux session creation + first-prompt routing

**Epic:** `pureclaw-99a`
**Deferred follow-up:** `pureclaw-jlc` (separate spawn-new-window vs attach-to-running-session)

## Problem

Creating an AI-Harness/tmux-backed session through the web frontend never starts tmux,
and the first prompt is answered by the LLM provider. Two compounding defects:

1. **`createTab` (`Frontend/API.hs:848`)** handles `TkSession (SkHarness spec)` by persisting
   `SessionMeta` (`_sm_kind = SkHarness`) via `mkSessionHandle` + `_sh_save`, but never calls
   `startTmuxSession`/`mkClaudeCodeHarness` and never inserts a `HarnessHandle` into the shared
   `_fe_harnesses` map. Nothing in the frontend ever writes that map (read-only at `API.hs:346`).
2. **`handleSend` (`API.hs:1030`)** never reads `_sm_kind`; it unconditionally calls
   `doCompletion` (`API.hs:1071`) → routes to the LLM provider.

Working reference (CLI): `/harness start` → `startHarnessByName` (`SlashCommands.hs:2376`) →
`mkClaudeCodeHarness` (`Harness/ClaudeCode.hs`) → `startTmuxSession` + `addHarnessWindow`
(`Harness/Tmux.hs`) → insert into `_env_harnesses` (== `_fe_harnesses`, shared `harnessRef`,
`Commands.hs:625/734`). Messages then route via `_hh_send`/`_hh_receive` (`Agent/Loop.hs:160`).

## Scope

**In scope (user-confirmed):**
- Spawn the tmux harness when an `SkHarness` session is created via the frontend.
- Persist tmux coordinates into the session's `_sm_kind` `HarnessSpec._h_backend = TbTmux TmuxConfig`
  (no new `SessionMeta` field — `TmuxConfig` already serializes: `Kind.hs:235/259`).
- Route `handleSend` to the harness (`_hh_send`/`_hh_receive`) when `_sm_kind = SkHarness`.
- Record the user message + harness response to a broadcasting transcript (FE visibility —
  memory `pureclaw-transcript-frontend-visibility`).
- **Restart reconnect (in scope):** after restart, the CLI's `discoverHarnesses` rebuilds
  `_fe_harnesses` keyed by tmux window name (= `harnessKey`). `handleSend` recomputes the same key
  from the persisted `TmuxConfig` and finds the rediscovered handle.

**Out of scope (deferred → `pureclaw-jlc`):**
- Separating spawn-new-window vs attach-to-running-session. Keep the single existing launch path.

## Key design decisions

- **D-A. Harness-start seam injected into `FrontendEnv`.** Add a callback field
  `_fe_startHarness :: HarnessSpec -> TranscriptHandle -> IO (Either HarnessError StartedHarness)`
  where `StartedHarness = StartedHarness { _shh_key :: Text, _shh_tmux :: TmuxConfig }`.
  Real impl wired in `Commands.hs` (closes over `policy`, `harnessRef`, `windowIdxRef`): allocates
  the window index, **calls the existing `startHarnessByName` (`SlashCommands.hs:2376`)** — NOT bare
  `mkClaudeCodeHarness` — so the `--dangerously-skip-permissions` wiring and flavour resolution
  match the CLI exactly (the `skipPerms` value is taken from the request's `HarnessSpec._h_args`,
  i.e. `--unsafe`/`--dangerously-skip-permissions` present ⇒ skip). It then inserts the handle into
  the shared map keyed by `harnessKey = canonical <> "-" <> show windowIdx`, renames the tmux window
  to `harnessKey`, and bumps `windowIdxRef`. Default stub returns `Left` for tests/one-off scripts.
  Mirrors existing injected callbacks (`_fe_closeTab`, `_fe_listModels`). Keeps `API.hs` decoupled
  from harness/tmux internals and fully testable with a fake seam.
- **D-B. Persist coordinates in `TmuxConfig`, not a new field.** On success, set
  `_h_backend = TbTmux (TmuxConfig { _tc_session = "pureclaw", _tc_window = harnessKey,
  _tc_pane = Nothing })`. `handleSend` reads `_tc_window` as the lookup key. Avoids touching the
  ~39 `SessionMeta` construction/match sites and aligns with `pureclaw-jlc`.
- **D-C. Fallible spawn before the slot is consumed; explicit ordering.** Per memory
  `lazy-session-creation-frontend-only`, `_fe_tabCount` is bumped unconditionally with no decrement
  (`API.hs:852`). The harness branch of `createTab` runs in this exact order:
  1. Generate `sid`; build initial `meta` (with the request's `SkHarness` spec).
  2. `mkSessionHandle` + `_sh_save` (creates the session dir + transcript; `API.hs:891-892`).
  3. Call `_fe_startHarness spec (_sh_transcript sh)`.
  4. **On `Left err`:** remove the just-created session dir (`removeDirectoryRecursive`), do NOT bump
     `_fe_tabCount`, return an error status (`503` for tmux/binary unavailable, `403` for
     not-authorized). No slot consumed, no orphan dir.
  5. **On `Right started`:** update `meta._sm_kind` backend to the returned `TmuxConfig`, `_sh_save`
     again, bump `_fe_tabCount`, publish `SaSessionCreated`, respond `200`.
  Provider/raw-shell paths keep the current top-of-function bump unchanged.
- **D-D. Transcript recording in `handleSend`.** `handleSend` opens a broadcasting transcript
  (as `doCompletion` does via `mkBroadcastingFileTranscriptHandle`) and records the user message +
  sanitized harness response. The harness's own internal `_th_record` (raw HarnessInput/Output)
  is a separate, pre-existing concern; to avoid duplicate display entries, `handleSend` records the
  chat-visible pair explicitly and does not double-encode. (D3.5 verifies no duplicate entries.)
- **D-E. Kind branch precedes the provider/model guard.** The current `handleSend` returns
  `503 "No provider configured"` / `"No model configured"` at `API.hs:1048-1054` BEFORE any
  kind-based branching. The fix loads `_sm_kind` FIRST: an `SkHarness` session routes to the harness
  with NO provider/model requirement; only the `SkProvider` path falls through to the existing
  provider/model guard + `doCompletion`. (D3.1/D3.6 verify harness routing with `_fe_provider`/
  `_fe_model` both `Nothing`.)

## Work units

### WU1 — Harness-start seam + pure helpers (foundation)
- **Files:**
  - `src/PureClaw/Frontend/API.hs` (add `_fe_startHarness`, `StartedHarness`, pure
    key-derivation + routing-decision helpers).
  - `src/PureClaw/CLI/Commands.hs` (wire real impl at the **single** production construction
    site, `Commands.hs:733`).
  - **All FrontendEnv record-construction sites must add the new field (enforced by `-Werror`):**
    `src/PureClaw/CLI/Commands.hs:733` (production), `test/Frontend/APISpec.hs:1414`,
    `test/Frontend/ActivityProbeSpec.hs:284`, `test/Frontend/StreamHarness.hs:78` (the last feeds
    `StreamIntegrationSpec`). Tests use the default `Left` stub except where they assert spawning.
- **DoD:**
  - D1.1 `FrontendEnv` has `_fe_startHarness`; builds clean under `-Wall -Werror`. All four
    construction sites updated; `cabal build` AND `cabal test` compile.
  - D1.2 Pure helper `harnessKeyFromKind :: SessionKind -> Maybe Text` returns
    `Just (_tc_window cfg)` for `SkHarness` with `TbTmux`, `Nothing` otherwise. Unit-tested both arms.
  - D1.3 Pure helper deciding "route to harness vs provider" from `SessionKind`. Unit-tested.
  - D1.4 `Commands.hs` constructs the real `_fe_startHarness` (delegating to `startHarnessByName`);
    default stub covered by a test.
- **Depends on:** none.

### WU2 — `createTab` spawns harness + persists `TmuxConfig`
- **Files:** `src/PureClaw/Frontend/API.hs` (`createTab`/`handleNewTab`), `test/Frontend/APISpec.hs`.
- **DoD:**
  - D2.1 `POST /api/tabs/new` with `SkHarness` calls `_fe_startHarness` and the returned handle is
    discoverable in `_fe_harnesses` under `harnessKey` (verified via injected fake).
  - D2.2 Persisted `session.json` `_sm_kind` is `SkHarness` with `_h_backend = TbTmux TmuxConfig`
    carrying the real `_tc_window = harnessKey`.
  - D2.3 On `_fe_startHarness` failure: error status returned, `_fe_tabCount` NOT incremented,
    partial session dir removed.
  - D2.4 `SkProvider` and `TkRawShell` paths byte-for-byte unchanged (regression test).
  - D2.5 Branch path (`mSeed = Just`) for providers unchanged.
- **Depends on:** WU1.

### WU3 — `handleSend` routes `SkHarness` to the harness + records transcript
- **Files:** `src/PureClaw/Frontend/API.hs` (`handleSend`),
  `src/PureClaw/Session/Handle.hs` (**export `tryLoad`** — currently internal, omitted from the
  export list `Handle.hs:1-41`; or add a thin exported `loadSessionMeta` wrapper),
  `test/Frontend/APISpec.hs`.
- **DoD:**
  - D3.1 `handleSend` loads the session meta via the exported loader and branches on `_sm_kind`
    **before** the provider/model guard (D-E); `SkHarness` → `_hh_send` + `_hh_receive`
    (sanitized), returns `{"response": ...}`; does NOT call `doCompletion`.
  - D3.2 `SkProvider` session still hits the provider/model guard, then `doCompletion` (unchanged).
  - D3.3 `SkHarness` session with no live handle in `_fe_harnesses` → clear error (NOT a provider
    completion, NOT a 500 crash).
  - D3.4 Restart simulation: a `SkHarness` session whose persisted `_tc_window` matches a handle
    inserted under that key routes correctly (key recomputation verified).
  - D3.5 User message + sanitized harness response recorded to the broadcasting transcript; no
    duplicate display entries.
  - D3.6 `SkHarness` routing succeeds even when `_fe_provider = Nothing` AND `_fe_model = Nothing`
    (the bug-class guard at `API.hs:1048-1054` must not pre-empt harness routing).
  - D3.7 Blank/whitespace-only `_hh_receive` output → returns `{"response":""}` (or a defined
    empty-result shape) without error and without a duplicate transcript entry. (`_hh_receive`
    can legitimately return `""` per `Handles/Harness.hs:37,48`.)
- **Depends on:** WU1 (helpers), WU2 (for an end-to-end happy path; D3 itself testable with a fake
  handle pre-inserted into `_fe_harnesses`).

### WU4 — Coverage + integration sweep
- **Files:** tests only; `.coverage-thresholds.json` is the source of truth.
- **DoD:**
  - D4.1 `nix develop . --command cabal test` green.
  - D4.2 Coverage meets `.coverage-thresholds.json` for all touched modules (or documented staged
    waiver per project protocol for unreachable real-tmux IO branches).
  - D4.3 No `-Wall -Werror`/hlint regressions.
- **Depends on:** WU1–WU3.

## WU4 coverage assessment (measured 2026-06-01)

Full suite: **2277 examples, 0 failures, 9 pending**. Build clean under `-Wall -Werror`; hlint clean on changed files.

`PureClaw.Frontend.API` HPC (full test tix): **69% expressions (1500/2165), 68% alternatives, 52% top-level decls.** This module-level figure is BELOW the global 95% target, but:
- It is dominated by **pre-existing integration-only surfaces** unchanged by this epic: the provider `doCompletion`/`runCompletionLoop` tool loop, the WebSocket/stream handlers, and `probeHarness`/`captureWindow` tmux IO. The adjacent `PureClaw.Frontend.ActivityProbe` is already staged-waived for exactly this reason (`probeHarness` needs real tmux). The 52% top-level figure is further deflated by HPC's per-derived-instance accounting (each `ToJSON`/`Show` method counts as a decl), the documented project-wide artifact.
- This epic did NOT regress coverage: the new logic is unit-tested — `harnessKeyFromKind`/`shouldRouteToHarness` (both arms), `createHarnessTab` (success + all 3 failure arms via `harnessErrorResponse` 403/503), `handleSend` kind-branch, `sendToHarness` (success, no-handle 503, blank-output, restart routing, AND the exception→500 arm via D3.8), `recordHarnessEntry`. Verified by the three per-WU adversarial reviews + the D3.8 tick check.

Coverage of the two formerly-uncovered NEW expressions:
1. `createHarnessTab` `Just broker -> _streamBroker_publish (SaSessionCreated updatedMeta)` — **NOW COVERED** by a dedicated test in `APISpec` ("POST /api/tabs/new (harness spawn — WU4 broker publish)"). The earlier claim that this arm was "consistent with the pre-existing, also-untested provider-create publish arm" was **incorrect**: the provider-create publish arm IS tested (`ActivityProbeSpec` D18) and the broker-capture infra already exists. The new test builds a `Just`-broker env, subscribes, POSTs the harness new-tab body, drains the subscriber queue, and asserts exactly one `ActivityChanged _ (SaSessionCreated m)` whose `_sm_kind` is `SkHarness hs` with `_h_backend hs == TbTmux tc` and `_tc_window tc == "claude-code-0"`. This both exercises the publish arm AND validates the post-spawn-meta correctness fix (the PUBLISHED meta carries the real spawned `TbTmux` backend, not the request placeholder).
2. `PureClaw.CLI.Commands._fe_startHarness` real implementation — spawns a live tmux session + `claude` binary; **integration-only**, same class as the waived `ActivityProbe.runActivityProbeLoop`. Not unit-testable; the seam is exercised in tests via an injected fake.

No `stagedWaivers` entry added: per policy point 1, waivers are for deferred/stubbed module bodies, not integration-only IO. Gap #1 is now unit-tested; the remaining gap #2 is integration-only and documented here; `Frontend.API`/`CLI.Commands` were already non-waived and below the per-module target prior to this epic.

## Risks / resolved questions
- **R1 (RESOLVED — Completeness).** The four `FrontendEnv` construction sites that `-Werror` will
  force: `CLI/Commands.hs:733` (production), `test/Frontend/APISpec.hs:1414`,
  `test/Frontend/ActivityProbeSpec.hs:284`, `test/Frontend/StreamHarness.hs:78`. All listed in WU1
  file scope; tests adopt the default `Left` stub except where they assert spawning.
- **R2 (Feasibility, accepted).** `APISpec` tests exercise the seam via an injected fake
  `_fe_startHarness` + fake `HarnessHandle`; the real-tmux IO inside `startHarnessByName`/
  `mkClaudeCodeHarness`/`Harness.Tmux` is already covered by the existing CLI/harness test suite and
  is unchanged by this work. Any newly-unreachable IO branch uses the project's documented staged
  coverage-waiver protocol; WU4/D4.2 records exactly what is waived and why.
- **R3 (RESOLVED — Feasibility).** D-D: `handleSend` records the chat-visible user/response pair to
  its own broadcasting transcript; the harness handle's internal `_th_record` writes raw
  HarnessInput/Output entries. D3.5/D3.7 assert no duplicate FE-visible entry.
- **R4 (RESOLVED — Scope).** `_tc_window` carrying the tmux window NAME (`harnessKey =
  canonical-<idx>`) is exactly what `discoverHarnesses` keys on (`SlashCommands.hs:2439-2447`); the
  deferred `pureclaw-jlc` attach case will read the same coordinates, so this is forward-compatible,
  not conflicting.
- **R5 (Completeness, accepted).** `_fe_tabCount`/`windowIdxRef` keep the existing plain-`IORef`
  read-then-write discipline (no new concurrency contract introduced). Window-index allocation lives
  inside `_fe_startHarness` (Commands scope) and reuses the same `windowIdxRef` the CLI uses; this
  PR does not change the concurrency model. Tightening to atomic CAS is out of scope (flagged for a
  separate hardening task if `POST /api/tabs/new` is ever called concurrently).
