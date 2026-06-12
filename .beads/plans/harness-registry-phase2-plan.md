---
issue: pureclaw-3oy
phase: 2
pr: continues-on-feat/harness-registry-p1 (PR #75)
status: APPROVED — plan-review-gate PASSED (Feasibility/Completeness/Scope), COMPLETE — all 6 WUs implemented, reviewed (per-WU + final comprehensive), committed; metaswarm orchestrated
date_drafted: 2026-06-02
design_doc: docs/harness-registry.md (§5 health/eviction, §7 state→visual mapping + actions, §9 Phase 2, §10 Q2)
beads_epic: pureclaw-3oy
branch: feat/harness-registry-p1 (continue committing on the Phase-1 branch, per user; commits append to PR #75)
---

# Implementation Plan — Harness Registry & Lifecycle, Phase 2 (Active Tabs health UX + orphan policy)

**Design:** `docs/harness-registry.md`. **Epic:** `pureclaw-3oy`. Phase 1 (registry identity/health/routing/Active-Tabs-minimal-slice) is merged-pending on this branch (PR #75).

## Goal (Phase 2)
Turn the minimal Active-Tabs slice into a real health UX: distinguish Exited vs Orphaned, surface the
`ExternallyModified` flag and the `stale` cue and the harness **origin**, expose per-row **actions**
(Dismiss / Acknowledge / Restart-reserved / copyable attach-command), implement the deferred **orphan
retention/grace policy** (retain greyed N ticks → auto-evict; session stays in Recent Sessions), and
**drop the frontend window input** (window is auto-assigned). Full-stack: Haskell backend + React/TS frontend.

## Locked design inputs (from §5/§7/§9/§10)
- **State→visual mapping (§7 table):** Thinking (shimmer+dot) / Idle (● running) / Exited (✕ crashed + [Restart-reserved] [Dismiss]) / Orphaned (✕ greyed + [Dismiss]); ExternallyModified = a ⚠ "edited" pill on whatever liveness applies + [Acknowledge]; stale = hold last icon + subtle dimmed cue (no distinct glyph). Reuse the existing 3-icon vocabulary + flags, NOT six glyphs.
- **Actions (§7):** Dismiss removes the live row (Exited/Orphaned) — the session STAYS in Recent Sessions (do NOT delete session.json). Acknowledge clears `_he_extModified` ("name X→Y" tooltip). Restart is a **reserved label** (present, impl deferred). Attach-command (`tmux attach -t <session>:<window>`) copyable on every live row. Origin shown as a pill (Spawned/Discovered/Adopted).
- **Eviction (§5/§10 Q2):** Phase 1 shipped Orphaned *detection*; Phase 2 adds the retention/grace policy. Decision: a **consecutive-orphaned-tick counter** on the entry (test-friendly, no wall-clock); evict at a named threshold; eviction removes the entry from BOTH the registry and the legacy `_env_harnesses` map and emits a disappearance event, but does **NOT** touch `session.json` (the session reappears in Recent Sessions — "appears in exactly one section").
- **Recent-Sessions exclusion** already works (Phase-1 WU8 wired `activeTabSids`); Phase 2 keeps it correct.
- **Drop window input (§9):** the backend already ignores the request's `_tc_window` for placement (Phase-1 WU7 `resolveHarnessSession` reads only the session; `_fe_startHarness` auto-assigns `canonical-<idx>`). So this is a FRONTEND change (remove the Window field); the composer keeps sending `window: ""` so the existing required `TmuxConfig` request decode still succeeds. `_tc_window` stays dual-written for back-compat.

## Explicitly DEFERRED (keep Phase 2 scoped to §9's list)
- PCL-side harness naming (§7 PM S3), WS connection-state dimming/banner (§7), the collapsed Discovered/Adoptable section + Adopt/Release (all Phase 3 / later). Restart *implementation* (label only here).

## Tooling note (full-stack)
- Backend gates (unchanged): `nix develop . --command cabal build all` (-Wall -Werror), `cabal test`, `hlint src/ test/ app/`, 95% coverage per `.coverage-thresholds.json` (honest staged waivers for real-tmux IO only).
- Frontend gates (new): in `frontend/`, `npm run build` (tsc strict + vite build to `frontend/dist`) and `npm test` (vitest run) must pass. The backend serves `frontend/dist` (Server.hs), so frontend WUs MUST rebuild `dist`.

## Work units

### WU1 — Backend: richer `TabSnapshot` (status split + flags + origin + attach command)
- **Files:** `src/PureClaw/Frontend/API.hs`, `test/Frontend/APISpec.hs`.
- Extend `TabSnapshot` additively: `_ts_status` gains distinct `"exited"`/`"orphaned"` (stop collapsing to `"crashed"`); add `_ts_extModified :: Bool`, `_ts_stale :: Bool`, `_ts_origin :: Text` ("spawned"|"discovered"|"adopted"), `_ts_attachCommand :: Maybe Text`. Update `livenessToTabStatus` (Exited→"exited", Orphaned→"orphaned"). `harnessEntriesToTabs` populates the new fields from `HarnessEntry` (`_he_extModified`/`_he_stale`/`_he_origin`; attach = `Just ("tmux attach -t " <> _he_session <> ":" <> _he_windowName)`). `ToJSON` is extend-only (existing keys unchanged; new snake_case keys added).
- **DoD:** D1.1 Exited and Orphaned map to distinct status strings; D1.2 extModified/stale/origin/attach_command appear in `GET /api/tabs` JSON, driven by entry fields; D1.3 existing keys (index/kind/name/status/session_id) unchanged (back-compat); D1.4 `-Wall -Werror` + hlint clean; new pure mappers covered.
- **Depends on:** none.

### WU2 — Backend: orphan grace/retention policy + auto-eviction in the reconcile loop
- **Files:** `src/PureClaw/Harness/Registry.hs` (entry field + helper), `src/PureClaw/Harness/Reconcile.hs` (grace logic + eviction), `src/PureClaw/CLI/Commands.hs` (wire the eviction callback to also drop the legacy map), tests (`test/Harness/ReconcileSpec.hs`, `test/Harness/RegistrySpec.hs`). **Plus the forced `-Wmissing-fields` cascade from the new `HarnessEntry` field:** `src/PureClaw/Harness/ClaudeCode.hs` (the spawn-path `HarnessEntry` literal) and `test/Frontend/APISpec.hs` (`baseEntry`) — set `_he_orphanedTicks = 0` mechanically. Add `_oh_orphanedTicks` to `ObservedHarness` so the counter rides the existing `mergeReconcile`/`applyObserved` path.
- Add `_he_orphanedTicks :: !Int` to `HarnessEntry` (0 when live). Reconcile: when an entry is classified Orphaned, increment the counter (via the observed-merge); when it returns live, reset to 0. When `_he_orphanedTicks >= graceThreshold` (a named `defaultOrphanGraceTicks`, e.g. 15 ticks ≈ 30s at 2s), EVICT: `deleteEntry` from the registry AND invoke an eviction callback that removes the label from the legacy `_env_harnesses` map; emit one final disappearance `ActivityChanged`. **Do NOT delete `session.json`.** Add an eviction seam to `ReconcileDeps` (e.g. `_rd_evict :: HarnessId -> Text -> IO ()`) so it's test-injectable; production wires it in Commands.hs to delete from both the registry and the legacy map. NOTE: the production loop is currently launched via `runActivityProbeLoop` (= `runReconcileLoop`, which hard-codes `defaultReconcileDeps`); to inject `_rd_evict`, Commands.hs must switch that call to `runReconcileLoopWith` with a deps record carrying the eviction callback (in-scope: Commands.hs is listed). The new `_oh_orphanedTicks` on `ObservedHarness` also forces `-Wmissing-fields` at the `ObservedHarness` literals in `test/Harness/RegistrySpec.hs` and the `baseObserved` builder in `Reconcile.hs`/`ReconcileSpec.hs` — all already in WU2 scope.
- **DoD:** D2.1 an Orphaned entry is RETAINED (greyed, still in the snapshot) for `< graceThreshold` ticks; D2.2 at the threshold it is evicted from the registry AND the legacy map, with a final disappearance event; D2.3 the counter RESETS when the entry becomes live again before eviction; D2.4 eviction does NOT remove `session.json` (the sid still loads in Recent Sessions); D2.5 threshold is a named constant exposed to tests; coverage/gates clean.
- **Depends on:** none (parallel with WU1; both touch API.hs? NO — WU2 touches Registry/Reconcile/Commands, WU1 touches API/APISpec — disjoint).

### WU3 — Backend: Dismiss + Acknowledge action endpoints (+ Restart-reserved)
- **Files:** `src/PureClaw/Frontend/API.hs`, `src/PureClaw/Frontend/Server.hs` (re-exports if needed), `src/PureClaw/CLI/Commands.hs` (wire callbacks), tests (`test/Frontend/APISpec.hs`). **Plus the forced `-Wmissing-fields` cascade from the new `FrontendEnv` callbacks** (`_fe_dismissTab`/`_fe_acknowledgeTab`): `test/Frontend/ActivityProbeSpec.hs` (`mkFrontendEnvForD18`) and `test/Frontend/StreamHarness.hs` (the `mkTestFrontendEnv` `FrontendEnv` literal at ~:81 — `mkTestFrontendEnvWith` only delegates; `StreamIntegrationSpec.hs` imports these, no literal of its own) — set the new fields mechanically (a no-op/`pure (Left ...)` default). The four `FrontendEnv {` literals are: `CLI/Commands.hs`, `test/Frontend/StreamHarness.hs`, `test/Frontend/ActivityProbeSpec.hs`, `test/Frontend/APISpec.hs`.
- Add routes mirroring `handleCloseTab`: `POST /api/tabs/{index}/dismiss`, `POST /api/tabs/{index}/acknowledge`, `POST /api/tabs/{index}/restart`. Resolve the display index → `HarnessId` via the SAME sorted snapshot `harnessEntriesToTabs` uses (add a shared `tabIndexToEntry`/`tabIndexToHarnessId` resolver so the index is consistent with `/api/tabs`). Dismiss = user-initiated eviction (reuse WU2's eviction path: remove from registry + legacy map; session.json intact). Acknowledge = clear `_he_extModified` on the entry (registry update). Restart = `501`/`{"error":"restart not yet implemented"}` (reserved). Wire `_fe_dismissTab`/`_fe_acknowledgeTab` callbacks on `FrontendEnv` (mirror `_fe_closeTab`), implemented in Commands.hs against the shared registry + legacy map; broadcast list refresh after each.
- **DoD:** D3.1 dismiss removes the registry+legacy entry and the sid still loads from Recent Sessions (session.json intact); D3.2 acknowledge clears `_he_extModified` (verified via a follow-up `/api/tabs` snapshot); D3.3 restart returns the reserved 501; D3.4 index→entry resolution matches `/api/tabs` ordering (a dismiss of index N hits the same row `/api/tabs` shows at N); D3.5 gates clean.
- **Depends on:** WU1 (shared snapshot/index resolver), WU2 (reuses the eviction path).

### WU4 — Frontend: types + ActiveTabs state→visual mapping + row actions
- **Files:** `frontend/src/types.ts`, `frontend/src/components/ActiveTabs.tsx`, `frontend/src/components/__tests__/ActiveTabs.test.tsx`, and the App/data wiring that passes the new fields + action callbacks (`frontend/src/App.tsx` + the relevant `useApi` hook; `frontend/src/components/__tests__/App.test.tsx`).
- `types.ts`: `TabStatus` adds `'exited' | 'orphaned'` (split from `'crashed'`); `TabInfo` gains `extModified?: boolean`, `stale?: boolean`, `origin?: 'spawned'|'discovered'|'adopted'`, `attachCommand?: string | null` (mirror the WU1 snake_case JSON → camel mapping at the fetch boundary).
- `ActiveTabs.tsx`: render Exited (✕ + reserved-disabled [Restart] + [Dismiss]) vs Orphaned (✕ greyed row + [Dismiss]); a ⚠ "edited" pill + [Acknowledge] when `extModified`; a dimmed/“stale” cue when `stale`; an origin pill; a copyable attach-command control. Wire `onDismiss`/`onAcknowledge` callbacks (App posts to the WU3 endpoints, then refreshes).
- **DoD:** D4.1 vitest tests: exited vs orphaned render distinct icons/actions; D4.2 extModified pill + Acknowledge present and calls back; D4.3 stale dim cue; D4.4 Dismiss calls back with the right index; D4.5 attach-command is copyable/visible; D4.6 origin pill; D4.7 `npm run build` (tsc strict + vite) clean and `npm test` green.
- **Depends on:** WU1 (JSON shape), WU3 (action endpoints).

### WU5 — Frontend: drop the Window input from NewTabComposer
- **Files:** `frontend/src/components/NewTabComposer.tsx`, `frontend/src/hooks/useNewTabSpec.ts` (`buildBackendPayload`), `frontend/src/components/__tests__/NewTabComposer.test.tsx` (+ a `useNewTabSpec` test if one exists).
- Remove the "Window" `Row` from the tmux `BackendFields`. **`buildBackendPayload` (`useNewTabSpec.ts:78`) currently omits `window` when falsy (`if (config.window) backend.window = config.window`), which would make the request fail the backend's required `o .: "window"` decode** — so change it to emit `window: ''` UNCONDITIONALLY for the tmux backend (window is auto-assigned server-side and ignored for placement; `_tc_window` stays dual-written on persist). Keep the Session field. Ensure the form validates and submits without a window input. (Alternative considered & rejected for blast-radius: making the backend `TmuxConfig` decode tolerant `.:? "window" .!= ""` — kept frontend-only instead.)
- **DoD:** D5.1 no Window input rendered for the tmux backend; D5.2 the POST body still includes `window: ""` (assert `buildBackendPayload` emits it unconditionally for tmux); D5.3 Session still honored; D5.4 tests updated; `npm run build` + `npm test` green.
- **Depends on:** none (frontend-only; parallel with WU4 but both touch frontend tests/build — sequence to avoid build races).

### WU6 — Integration + coverage sweep + frontend build
- **Files:** tests; `.coverage-thresholds.json`; rebuild `frontend/dist`.
- Backend: full `cabal test` green, 95% coverage (new pure logic covered; honest waivers only for real-tmux IO), `-Wall -Werror`, hlint, pty-firewall. Frontend: `npm run build` (tsc strict) + `npm test` green; commit the rebuilt `frontend/dist`. End-to-end sanity: a spawned harness shows Idle→ (kill window) →Orphaned→(grace)→evicted; Dismiss/Acknowledge round-trip; attach-command correct; new-tab composer has no window field.
- **DoD:** D6.1 all backend + frontend gates green; D6.2 coverage gate satisfied (waiver hygiene: every entry has filledBy); D6.3 `frontend/dist` rebuilt + committed; D6.4 end-to-end check documented.
- **Depends on:** WU1–WU5.

## Execution order (DAG)
(WU1 ‖ WU2) → WU3 → (WU4 then WU5, frontend sequential to avoid npm/build races) → WU6.
Backend WUs (1,2,3) and frontend WUs (4,5) are in different toolchains; backend and frontend could overlap, but WU4 depends on WU1+WU3 JSON/endpoints, so frontend starts after the backend shape lands.

## Risks / open questions for the plan-review-gate
- **R1 (grace mechanism):** is a consecutive-orphaned-tick counter (no wall-clock) the right test-friendly basis, and is a fixed `defaultOrphanGraceTicks` acceptable for Phase 2 (vs a config field)? Eviction reach: is threading an `_rd_evict` callback that drops from BOTH registry and legacy map (but not session.json) correct and complete?
- **R2 (action keying):** resolving the volatile display index → entry via the sorted snapshot mirrors `handleCloseTab`, but an index can shift between a list fetch and an action if the set changes. Acceptable for Phase 2 (same risk as close), or should actions key by `session_id`/`HarnessId`? (Challenge it.)
- **R3 (TabSnapshot back-compat):** the frontend `TabStatus` currently only has running|idle|crashed; splitting to exited|orphaned is a coordinated backend+frontend change — is the extend-only JSON + the lockstep WU1→WU4 sequencing sufficient, or does any other consumer read `status`?
- **R4 (window drop):** is sending `window: ""` from the composer (frontend-only) the right call, or should the request-side `TmuxConfig` decode be made tolerant (`.:? "window" .!= ""`) so the field can be omitted entirely (a tiny backend change)?
- **R5 (frontend in scope):** is editing the React/TS frontend (a separate toolchain, no Haskell coverage gate) within this epic's remit, and are tsc-strict + vitest the right per-WU gates? Should `frontend/dist` be committed (it is served by the binary) or built in CI?
- **R6 (scope):** confirm PCL-naming, WS connection-state, and the Discovered section are correctly deferred (not silently dropped) per §9.
