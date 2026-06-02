---
issue: pureclaw-3oy
phase: 1
pr: ready-for-pr
status: COMPLETE — all 9 WUs implemented, reviewed (per-WU + final comprehensive), committed (Feasibility/Completeness/Scope), additive-registry strategy
date_drafted: 2026-06-01
design_doc: docs/harness-registry.md (APPROVED by 5-agent design-review-gate)
beads_epic: pureclaw-3oy
branch: feat/harness-registry-p1 (branch from main AFTER PR #74 merges — design decision K6)
note: >
  Implements Phase 1 of the approved Harness Registry & Lifecycle design. Folds in the
  paused per-harness-session-name plan (.beads/plans/tmux-session-name-plan.md) session-threading core.
  active-plan.md is owned by #57; this is a separate file.
---

# Implementation Plan — Harness Registry & Lifecycle, Phase 1

**Design:** `docs/harness-registry.md` (approved + Phase-0 spike done, §11). **Epic:** `pureclaw-3oy`.

## Goal (Phase 1)

Replace the fragile window-name-keyed harness map with a durable **HarnessId registry** reconciled
against tmux, so PureClaw-spawned harnesses survive rename/move/PCL-restart and out-of-band death is
detected; route PureClaw's tmux use through an authorization seam; and **wire Active Tabs to the registry**
so a spawned harness appears there (the user's reported symptom). Backend + minimal Active-Tabs slice;
full health UX + orphan policy + adopt-external are Phases 2–3.

## Locked design inputs (from the approved doc + spike)

- Identity = `HarnessId` (UUID) anchored by `@pcl_id` window user-option (re-find hint) + shell PID
  (`#{pane_pid}`) + **harness-process PID** (descend from `pane_pid`, match `comm`; macOS confirmed the
  binary is a direct child of the `script` pane — §11 E2). Trust = PID-provenance, not the marker.
- `TVar (Map HarnessId HarnessEntry)`; cached-coordinate handles (no per-I/O sweep); symmetric-diff
  reconcile (emits disappearance); resilient loop (tolerate transient sweep failure, don't die).
- `remain-on-exit on` per harness window (spike §11 E3 — else `Exited` collapses into `Orphaned`).
- `HarnessId` additive/optional in `session.json` + **dual-write `_tc_window`** for back-out; legacy rows
  lazily migrate.
- **Registry strategy decision — ADDITIVE (user-chosen; resolves the cutover blast-radius):**
  the `HarnessRegistry` (TVar) is a **NEW field** `_env_harnessRegistry` on `AgentEnv` (and
  `_fe_harnessRegistry` on `FrontendEnv`, same TVar) — the **source of truth for identity/health**.
  The existing `_env_harnesses`/`_fe_harnesses :: IORef (Map Text HarnessHandle)` are **kept, type
  unchanged**, maintained as **synced derived views** (a spawned/discovered handle is inserted into BOTH
  the registry by `HarnessId` and the legacy map by label). The obsolete `_env_nextWindowIdx` is **kept**
  (window naming stays `canonical-<idx>`, display-only; `@pcl_id` is the durable anchor). So **legacy
  consumers (`/status`/`/target`/`/msg`, completion, `Tab/Harness.lookupHarness`, `Loop.TargetHarness`,
  `Session/Handle.resolveResumedTarget`) and their tests are UNCHANGED** — no logic edits, no retype.
  Only **frontend routing** (`sendToHarness`/`harnessKeyFromKind`) moves to id-based resolution via the
  registry (the durable-routing win). Full cutover of legacy consumers to registry-only is **deferred** to
  a later phase. NOTE: `_env_registry` is already the `ToolRegistry` field — the new field is
  `_env_harnessRegistry`, NOT `_env_registry`.
- tmux auth seam (§8 B1): **decision — reuse `AuthorizedCommand`** via a dedicated internal
  `authorizeTmuxCommand` constructor (manager-owned, always-permitted-but-logged), not a brand-new policy
  type; covers EVERY `P.proc tmux*` site (Harness/Tmux.hs runTmux/runTmuxSilent/captureWindow/
  listSessionWindows; ClaudeCode.hs captureFullScrollback/checkWithTmux).

## Work units

### WU1 — `Harness/Tmux.hs`: identity ops + session-aware name targeting + capability check
- **Files:** `src/PureClaw/Harness/Tmux.hs`, `test/Harness/TmuxSpec.hs` (or existing harness test).
- Add: `windowTarget session name`; switch `addHarnessWindow`/`sendToWindow`(`sendKeysSmall/Large`)/
  `stopHarnessWindow`/`renameWindow`/`captureWindow` to `(session, windowName)` targeting (from the paused
  plan WU2). `setWindowMarker session window uuid` (`set-option -w @pcl_id`), `readMarkers` (server sweep
  fields incl `@pcl_id`,`#{pane_pid}`,`#{pane_dead}`), `listTmuxSessions`, `setRemainOnExit` per window.
  `startTmuxSession` returns created-vs-existed (spike: reuse fresh window 0 else `new-window -n`).
  `harnessPidOf paneShellPid flavourBinary` (ps-descend-from-pane, comm match — NEVER global grep).
  Capability check (`requireTmux` confirms `@pcl_id`/`pane_dead` format support; degrade + warn if absent).
- **DoD:** D1.1 ops target `<session>:<windowName>` (argv asserted); D1.2 marker set/read round-trips;
  D1.3 `harnessPidOf` returns the direct child of a given pane shell pid matching a comm (unit test with a
  synthetic process or injected ps output); D1.4 `startTmuxSession` reports created/existed; D1.5
  `remain-on-exit` set; D1.6 capability check; `-Wall -Werror`.
- **Depends on:** none.

### WU2 — `PureClaw.Harness.Registry` (new module): `HarnessId`, `HarnessEntry`, `TVar` registry
- **Files:** `src/PureClaw/Harness/Registry.hs` (new), `test/Harness/RegistrySpec.hs` (new); cabal file.
- `HarnessId` (UUID newtype), `HarnessEntry` (§4 fields incl shell/harness PID, origin, liveness,
  extModified/stale flags, cached coord, sessionId, handle), `HarnessRegistry = TVar (Map HarnessId
  HarnessEntry)`. Pure-ish STM CRUD: insert, lookupById, lookupByLabel (name→id), delete, snapshot,
  **mergeReconcile** (atomically merge tmux-observed fields by key, preserving concurrently-inserted
  entries — the lost-update-safe path).
- **DoD:** D2.1 CRUD + snapshot under STM; D2.2 `mergeReconcile` preserves a concurrently-inserted entry
  (test: insert during a merge); D2.3 label→id resolution; D2.4 round-trip of `HarnessId` ToJSON/FromJSON;
  `-Wall -Werror`.
- **Depends on:** none (parallel with WU1).

### WU2b — Add the `_env_harnessRegistry`/`_fe_harnessRegistry` field (additive, mechanical, foundational)
- **What:** add the NEW field to `AgentEnv` (`src/PureClaw/Agent/Env.hs`) and `FrontendEnv`
  (`src/PureClaw/Frontend/API.hs`), wire one shared `HarnessRegistry` TVar in `CLI/Commands.hs` (alongside
  the kept `_env_harnesses`/`_env_nextWindowIdx`). This is purely additive: NO field renamed, NO field
  removed, NO consumer logic changed.
- **Files:** `src/PureClaw/Agent/Env.hs` (+1 field), `src/PureClaw/Frontend/API.hs` (+1 field on
  FrontendEnv), `src/PureClaw/CLI/Commands.hs` (construct the TVar; set both fields). Plus **every
  `AgentEnv {`/`FrontendEnv {` record-construction site** (enumerable via grep across `src/` + `test/` —
  the actual sites — enumerate via `grep -rn 'pure AgentEnv\|= AgentEnv\|<- .*AgentEnv\|pure FrontendEnv\|=
  FrontendEnv' src test` (NOT `'AgentEnv {'` — the brace is on the next line; ~60+ sites incl. ~40 in
  `test/Agent/SlashCommandsSpec.hs`, plus `test/Frontend/{APISpec,ActivityProbeSpec,StreamHarness}.hs` and
  the `AgentEnvOverrides`/`mkDefaultAgentEnv` builder in `test/Routing/RegistrySpec.hs`) adds the new field
  defaulted to a fresh empty registry. **Mechanical one-line additions, no logic.**
- **DoD:** D2b.1 the new field exists on both envs; the shared TVar is wired in `Commands.hs`; whole
  project + tests build `-Wall -Werror` (the compiler is the binding "no site missed" gate). D2b.2 the
  `pure/= AgentEnv` / `FrontendEnv` grep sweep above (NOT `'AgentEnv {'`, which matches nothing) confirms
  every construction site sets the field. D2b.3 NO existing consumer logic changed (the legacy
  `_env_harnesses`/`_fe_harnesses`/`_env_nextWindowIdx` are untouched); `cabal test` green (existing tests
  pass unmodified except the mechanical field addition).
- **Depends on:** WU2. (Foundational — WU4/WU5/WU6/WU7/WU8 depend on WU2b.)

### WU3 — tmux auth seam (§8 B1): route all `P.proc tmux*` through `authorizeTmuxCommand`
- **Files:** `src/PureClaw/Security/Command.hs` (add `authorizeTmuxCommand`/internal constructor),
  `src/PureClaw/Harness/Tmux.hs` (runTmux/runTmuxSilent/captureWindow/listSessionWindows),
  `src/PureClaw/Harness/ClaudeCode.hs` (captureFullScrollback/checkWithTmux), tests.
- Every raw `P.proc tmuxBin …` constructs an `AuthorizedCommand` via the internal tmux constructor (logged;
  manager-owned). Enumerate via a grep sweep so none slips. Does NOT change the in-pane shell-string path
  (that remains `shellEscape`-defended).
- **DoD:** D3.1 every `P.proc tmux*` site goes through the seam (grep proof + test that an unauthorized
  tmux call is impossible by construction); D3.2 existing harness/CLI behavior unchanged (regression);
  `-Wall -Werror`.
- **Depends on:** WU1 (touches the same Tmux.hs functions; sequence after WU1).

### WU4 — `ClaudeCode.hs` + `SlashCommands` harness-start: thread session/id, cached-coordinate handle, PIDs
- **Files:** `src/PureClaw/Harness/ClaudeCode.hs`, `src/PureClaw/Agent/SlashCommands.hs`
  (`startHarnessByName`, `/harness start`, `/session` :2188), tests.
- `mkClaudeCodeHarness`/`mkClaudeCodeHarnessWith` gain session + windowName + a registry-entry ref; the
  handle reads its coordinate from the entry (cached) and re-resolves on tmux-not-found (§4/K3) — no frozen
  `windowIdx` closure. On spawn: generate `HarnessId`, stamp `@pcl_id`, `set remain-on-exit on`, capture
  shell PID + derive harness PID, register a `Spawned` entry **AND insert the handle into the legacy
`_env_harnesses` map under its label (unchanged — additive sync so legacy consumers keep working)**.
Thread session into all targets incl.
  `harnessReceive`/`pollUntilIdle`/`captureFullScrollback`/`checkWindowStatus` (session param). `_hh_session`
  = real session. `startHarnessByName` + `/harness start` pass the session (default `"pureclaw"`);
  `/session` :2188 → new convention. (`extractWindowIdx` deletion is NOT here — it lives in
`Frontend/API.hs:409`/`ActivityProbe.hs:196`, handled in WU5.)
- **DoD:** D4.1 no `sessionName` const remains; D4.2 spawn registers a `HarnessId` entry with shell+harness
  PID + `@pcl_id` + remain-on-exit (verified via injected tmux seam); D4.3 handle re-resolves coordinate on
  a simulated tmux-not-found; D4.4 CLI `/harness start` still spawns + routes + correct status (regression);
  `-Wall -Werror`.
- **Depends on:** WU1, WU2, WU2b, WU3.

### WU5 — Reconcile loop (registry-based) + registry boot-reconstruction (additive)
- **Files:** new `src/PureClaw/Harness/Reconcile.hs` (the loop) + rework `src/PureClaw/Frontend/ActivityProbe.hs`
  to delegate to it (broker events now from reconcile; **delete `extractWindowIdx` :196**),
  `src/PureClaw/Frontend/API.hs` (`probeHarness`/`probeActivity`/`handleHarnesses` read the registry;
  **delete `extractWindowIdx` :409**), `src/PureClaw/CLI/Commands.hs` (boot: build the registry from a
  sweep; the runActivityProbeLoop call becomes the reconcile loop), tests (`test/Frontend/ActivityProbeSpec.hs`).
  **`discoverHarnesses` is KEPT unchanged** (it still seeds the legacy `_env_harnesses` map + `nextWindowIdx`
  at boot — additive); the registry is built/maintained by the new reconcile loop in parallel.
- 2 s loop: one server sweep (`readMarkers`), retain only our-`@pcl_id` rows **corroborated by recorded
  shell/harness PID**; `mergeReconcile` into the registry; compute liveness (Idle/Thinking via capture for
  ours only; Exited via harness-PID-gone/`pane_dead`; Orphaned via missing); set `extModified`/`stale`
  flags. **Symmetric diff** → emit `ActivityChanged` incl. disappearance (fixes `ActivityProbe.hs:117`);
  preserve first-tick baseline. **Resilient:** transient sweep failure → mark `stale`, continue (never die
  except on cancel). Retarget `probeActivity`/`Frontend.ActivityProbe` to `windowTarget (_he_session)`.
- **Boot reconstruction (additive — registry built alongside the kept `discoverHarnesses`):** at startup,
  one sweep builds the registry — every window carrying our `@pcl_id` becomes an entry (origin `Spawned`,
  liveness from PID/`pane_dead`). Legacy windows (named `claude-code-<idx>`, no `@pcl_id`, present in the
  legacy map via `discoverHarnesses`) are lazily stamped a fresh `HarnessId` + `@pcl_id` on first sight
  (ties to WU6). This is the PCL-restart-reconnect path. `discoverHarnesses` itself stays (legacy map);
  the registry reconstruction is the new parallel path the reconcile loop owns.
- **DoD:** D5.1 reconcile updates entries by id; D5.2 disappearance emits an event; D5.3 transient failure
  doesn't kill the loop; D5.4 Idle/Thinking/Exited/Orphaned classified correctly (injected sweep fixtures);
  D5.5 non-ours `@pcl_id`/uncorroborated rows are never captured; first-tick baseline preserved;
  D5.6 boot reconstruction builds the registry from `@pcl_id` windows (PCL-restart reconnect) and lazily
  stamps/migrates legacy `claude-code-<idx>` windows (legacy map via `discoverHarnesses` unchanged);
  D5.7 (§8 C4 — sweep side)
  an `@pcl_id` collision or a marked window whose recorded shell/harness PID does NOT match is **logged and
  treated as "not ours" — never captured and never registered as live**; PID-only matches (legacy/no-marker)
  require a second corroborating signal (`#{pane_start_time}` or window-name prefix) to defend PID reuse.
- **Depends on:** WU1, WU2, WU2b, WU4, **WU6** (boot reconstruction's lazy back-fill calls WU6's persistence
  helper; WU6 lands first so WU5 owns the boot-migration end-to-end — single owner of the migration invariant).

### WU6 — Persistence + routing key migration
- **Files:** `src/PureClaw/Session/Kind.hs` (HarnessSpec: additive optional `_h_harnessId`),
  `src/PureClaw/Frontend/API.hs` (`harnessKeyFromKind` → resolve id w/ name fallback; `sendToHarness`),
  `src/PureClaw/Core/Types.hs`/`Agent/Loop.hs` (TargetHarness label→id resolution), tests.
- `HarnessId` additive `.:? "harnessId"` (no existing session.json breaks); **dual-write `_tc_window`**;
  legacy `_tc_window`-keyed rows resolve via name fallback and lazily back-fill a `HarnessId` on first
  match. `harnessKeyFromKind` returns the id (or name fallback). `TargetHarness` stays `Text` label,
  resolved to id at lookup via the registry.
- **DoD:** D6.1 old session.json (no harnessId) still decodes + routes (back-compat test); D6.2 new
  session.json carries both harnessId + `_tc_window`; D6.3 routing by id works; D6.4 name-fallback path
  tested; D6.5 lazy back-fill on first match; D6.6 (§8 C4 — routing side) `sendToHarness`/`harnessKeyFromKind`
  resolution refuses to route to a registry entry that is not PID-corroborated (a spoofed/uncorroborated
  marker never receives keystrokes), with a logged refusal — tested.
- **Depends on:** WU2, WU2b.

### WU7 — `_fe_startHarness`/`createTab` use the registry + honor `_tc_session`
- **Files:** `src/PureClaw/CLI/Commands.hs`, `src/PureClaw/Frontend/API.hs` (createHarnessTab), tests.
- `_fe_startHarness` reads `_tc_session` (default `"pureclaw"`), spawns via the new path, registers the
  entry, persists `HarnessId` + `TmuxConfig{session,windowName}`. createHarnessTab persists the id.
- **DoD:** D7.1 frontend-created harness registers a `HarnessId` entry in the registry; D7.2 persisted
  session.json carries harnessId + `_tc_session`; D7.3 default session `"pureclaw"`; D7.4 first-prompt
  routing (from PR #74) still works via the id.
- **Depends on:** WU2b, WU4, WU6.

### WU8 — Minimal Active-Tabs slice (the user's symptom)
- **Files:** `src/PureClaw/CLI/Commands.hs` (`_fe_listTabs` wired to a registry snapshot), possibly
  `src/PureClaw/Frontend/API.hs` (map `HarnessEntry`→`TabSnapshot`), tests (`test/Frontend/APISpec.hs`).
- Wire `_fe_listTabs` to `registrySnapshot` → `[TabSnapshot]` (index/kind/name/status/sessionId from
  entries). Status maps liveness → existing `running|idle|crashed` vocabulary (full mapping is Phase 2).
- **DoD:** D8.1 a spawned harness appears in `GET /api/tabs` (the reported symptom fixed); D8.2 status
  reflects liveness; D8.3 Recent-Sessions exclusion (`activeTabSids`) now non-trivially excludes it.
- **Depends on:** WU2, WU2b, WU7.

### WU9 — Coverage + integration sweep
- **Files:** tests; `.coverage-thresholds.json` source of truth.
- **DoD:** D9.1 `cabal test` green; D9.2 coverage of new pure/logic (registry CRUD/merge, harnessPidOf
  parser, reconcile classification, key migration, harnessKeyFromKind) meets thresholds; integration-only
  real-tmux IO documented; D9.3 `-Wall -Werror` + hlint clean.
- **Depends on:** WU1–WU8.

## Risks / open questions for the plan-review-gate
- **R1:** Is reusing `AuthorizedCommand` for the tmux seam (WU3) the right call vs a dedicated internal type?
  (§10b decision — challenge it.)
- **R2:** Blast radius of replacing the `Text`-keyed `_env_harnesses`/`_fe_harnesses` with the `HarnessId`
  registry across `Agent/Loop.hs` (TargetHarness), `Tab/Harness.hs` (`lookupHarness`), `/harness`/`/target`
  CLI, discovery — is the WU split right, and is anything missed? (discovery itself is Phase 1? — it's
  needed for PCL-restart reconnect of spawned harnesses; confirm WU5 covers boot reconstruction, or add it.)
- **R3:** `harnessPidOf` testability without real processes — is an injected `ps`-output seam sufficient,
  and is the macOS-confirmed/Linux-unconfirmed split acceptable for Phase 1 (Linux validated in CI)?
- **R4:** Does folding the session-name plan's targeting changes into WU1/WU4 here fully retire that paused
  plan, or are pieces (frontend window-input removal) correctly deferred to Phase 2?
- **R5:** Boot-time registry reconstruction (replacing `discoverHarnesses`) — is it in WU5 or a missing WU?
