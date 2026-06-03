---
issue: pureclaw-3oy
phase: 3
pr: new branch off main after PR #75 merges (separate Phase-3 PR) — confirm with user
status: APPROVED v2 — plan-review-gate PASSED all 4 (Security/Feasibility/Completeness/Scope); COMPLETE — all 8 WUs implemented, reviewed (per-WU + final comprehensive + Security), committed; metaswarm orchestrated
date_drafted: 2026-06-02
design_doc: docs/harness-registry.md (§6 adopt-external, §8 B2/B3/B4/C1/C2/C3, §7 Discovered section + Adopt/Release, §9 Phase 3, §10 Q5)
beads_epic: pureclaw-3oy
delivers: pureclaw-jlc (attach-to-running side; spawn-side _tc_window placement stays deferred — WU8 records the residual)
---

# Implementation Plan — Harness Registry & Lifecycle, Phase 3 (Adopt external tmux) — v2

**Design:** `docs/harness-registry.md` (approved). **Epic:** `pureclaw-3oy`. Phases 1 & 2 complete (PR #75). Most security-sensitive phase — a trust-boundary expansion.

v2 incorporates the plan-review-gate v1 must-fixes: SEC-1 (consent predicate + endpoint test), SEC-2 (matcher semantics), SEC-3 (release re-corroboration), FEAS-1 (B3 baseline is unimplemented — now its own WU), FEAS-2 (runChat consent-wiring signature change), and the completeness tightenings (origin-pill render DoD, session.json adopt DoD).

## Goal (Phase 3)
Let a user **adopt** an external (unmanaged) tmux window so PureClaw tracks/captures/manages it, and **release** it later (never killing it). On-demand **discovery** (bounded by an allow-list) lists adoptable candidates; **adoption is typed, default-deny, consent-gated** (§8 B2); captured output flows **from the adoption point forward** (§8 B3); discovered-but-unadopted candidates are **metadata-only, no capture** (§8 C1). Plus the §7 Discovered/Adoptable UI and the §8 C3 input-hygiene hardening.

## Locked design decisions (v2 — resolve §10 Q5 + gate must-fixes)
- **D1 — Default-deny allow-list + EXACT matcher (SEC-2).** Add `_sp_adoptableSessionPatterns :: [SessionPattern]` to `SecurityPolicy` (a list, default `[]` = **deny all**; do NOT route through `AllowList`'s `AllowAll` — there must be NO implicit allow-all path). `SessionPattern` matcher semantics (anchored, full-string): a pattern is EITHER a literal session name (exact match) OR a non-empty prefix followed by a single trailing `*` (prefix match). **A bare `*` / empty prefix is REJECTED at config load (matches nothing), never allow-all.** Empty list and empty pattern match NOTHING. Loaded from the policy config key `adoptable_sessions` (a list of strings); a missing/empty key → `[]` = deny. Define `matchesSessionPattern :: [SessionPattern] -> Text -> Bool` (pure, total, no regex → no ReDoS).
- **D2 — Typed adoption capability (`AdoptedHarness`).** New `AdoptedHarness` (value ctor NOT exported; mirror `AuthorizedCommand`), constructible ONLY via `authorizeAdoption :: SecurityPolicy -> ConsentChannel -> Text {-session-} -> Either AdoptError AdoptedHarness`. Order: (1) `ConsentChannel` must be `ConsentInteractive` else `Left AdoptNoConsentChannel` (headless-deny dominates, checked FIRST); (2) session matches `_sp_adoptableSessionPatterns` else `Left AdoptNotAllowed`. Default-deny. The adopt mechanism REQUIRES an `AdoptedHarness` token (type-enforced — impossible to adopt without passing the gate).
- **D3 — ConsentChannel: precise predicate + fail-closed (SEC-1 / FEAS-2).** `data ConsentChannel = ConsentInteractive | ConsentHeadless`. **Predicate (v1 codebase): `ConsentInteractive` IFF the run was launched as the foreground interactive TUI (`CmdTui`); ALL other invocations — `CmdGateway` (signal/telegram bot server), `CmdImport`, and any future cron/RemoteTrigger/`--bg`/daemon mode — map to `ConsentHeadless`.** Rationale: a bot/gateway/scheduled run has no human at the browser adopt-confirm dialog; fail-closed favors denial. (When a future mode adds a genuine interactive frontend session, classify it explicitly.) **Wiring (FEAS-2):** `runChat :: ChatOptions -> IO ()` does NOT currently know the invocation mode; add a `ConsentChannel` (or `RunMode`) parameter to `runChat`, set by `runCLI` from the `Command` dispatch (`CmdTui` → `ConsentInteractive`, else `ConsentHeadless`), and store it as `_fe_consentChannel` on `FrontendEnv`. The adopt ENDPOINT passes `_fe_consentChannel` to `authorizeAdoption` BEFORE any tmux mutation. Default fail-closed to `ConsentHeadless` if unknown.
- **D4 — Discovery = transient metadata-only list, NOT registry entries (C1 by construction).** A scan returns `[DiscoverableWindow]` (NEW transient type: sessionName/windowName/windowIndex/panePid; NO handle, NO capture). Candidates are NEVER inserted into the registry and NEVER `capture-pane`d (they aren't `HarnessEntry`s). Discovery is on-demand, **bounded** (B4): scan ONLY sessions matching `_sp_adoptableSessionPatterns`; empty allow-list → empty. (`OriginDiscovered` in the registry stays = a boot-reconstructed window WE marked — distinct from an unmarked external candidate.)
- **D5 — Capture-from-adoption-point is a REAL mechanism (FEAS-1, B3).** The ClaudeCode handle's `baselineRef` is currently INERT (unused, `_`-prefixed). WU3 makes it LIVE: `harnessReceive`/`extractLastResponse` honor a recorded scrollback baseline so pre-baseline backlog is excluded from the transcript AND the WS broadcast. Spawned harnesses set baseline at spawn (current behavior preserved: empty/spawn-time). WU4 (adopt) sets the baseline to the window's CURRENT scrollback end at adopt time, so an adopted window's prior backlog never enters the transcript/broadcast.
- **D6 — Adopt = spawn-for-an-existing-window.** Given an `AdoptedHarness` token + a `DiscoverableWindow`: stamp `@pcl_id`, `setRemainOnExit`, record shell PID (+ best-effort harness PID — may be `Nothing` for a non-flavour window, OK), set the capture baseline to current-end (D5), register an `OriginAdopted` `HarnessEntry` (+ legacy map sync, D-ADD-2), and **create/link a `session.json`** (a harness session, like spawn). Adopt does NOT create the window.
- **D7 — Release = unmark + deregister, NEVER kill, with re-corroboration (SEC-3).** New `clearWindowMarkerArgs`/`clearWindowMarker` (`set-option -wu -t <session>:<window> @pcl_id`). Release MUST first verify the entry is `OriginAdopted` AND PID-corroborated (or the live window still carries THIS entry's `@pcl_id`); on mismatch/stale → **deregister from the registry+legacy map WITHOUT issuing any tmux `set-option` (mutate no window) and log**. On corroborated match → clear `@pcl_id`, deregister, do NOT kill the window. **Retain** `transcript.jsonl`+`session.json` by default (C2); purge is a RESERVED flag (Phase-3 MVP = retention only, documented no-op).
- **D8 — C3 input hygiene.** `sendKeysNamedArgs` → `send-keys -l -- <literal>` (payload literal; tmux key tokens not interpreted) with `Enter` a SEPARATE `send-keys`. Add `validateTmuxIdent` rejecting/`--`-guarding leading-`-` session/window names. argv `P.proc` (via the WU3-phase1 `tmuxProc` seam) preserved as primary defense. Shared-path change → regression-test existing ClaudeCode/Tmux interaction (incl. the `cd <dir>`+Enter launch path which must still EXECUTE).

## Explicitly DEFERRED
Transcript purge/redact on Release (reserved flag only); spawn-side `_tc_window` placement (pureclaw-jlc spawn half — WU8 records the residual); live discovery streaming (on-demand pull only); PCL-side naming; WS connection-state.

## Tooling (unchanged): backend `cabal build all`(-Wall -Werror)/`cabal test`/`hlint`/95% coverage (honest real-tmux-IO waivers)/`scripts/check-pty-firewall.sh`; frontend `npm run build`(tsc strict)+`npm test`; `frontend/dist` git-ignored (build, don't commit).

## Work units

### WU1 — Security: typed default-deny adoption gate
- **Files:** `src/PureClaw/Security/Policy.hs` (+`_sp_adoptableSessionPatterns :: [SessionPattern]`, `SessionPattern`, `matchesSessionPattern`), `src/PureClaw/Security/Adoption.hs` (NEW — `AdoptedHarness` ctor-unexported, `ConsentChannel`, `AdoptError`, `authorizeAdoption`, accessors), `src/PureClaw/CLI/Commands.hs` (policy config load of `adoptable_sessions`), cabal, `test/Security/AdoptionSpec.hs` (NEW). **`-Wmissing-fields` cascade for the new SecurityPolicy field — enumerate ALL `SecurityPolicy {` brace literals via grep across src+test; the known set is `Policy.hs` defaultPolicy, `Commands.hs` buildPolicy ×3, `test/Security/CommandSpec.hs`, AND `src/PureClaw/Backend/SSH.hs` (a 6th literal the v1 review found)** (record-UPDATES like `defaultPolicy { … }` need no change). `buildPolicy` also gains the `adoptable_sessions` config plumbing (thread the parsed value in).
- **DoD:** D1.1 default `[]` → `authorizeAdoption` returns `Left AdoptNotAllowed`; D1.2 allow-listed (literal AND prefix-`*`) session + `ConsentInteractive` → `Right`; D1.3 `ConsentHeadless` → `Left AdoptNoConsentChannel` EVEN with an allow-listed session (headless-deny checked first/dominates); D1.4 `AdoptedHarness` value ctor NOT exported; D1.5 matcher edge cases asserted: empty pattern → no match, bare `*`/empty-prefix → rejected/no-match (no allow-all), literal match, prefix match, non-match; missing config key → `[]`=deny; `-Wall -Werror`+hlint clean; full coverage (pure).
- **Depends on:** none.

### WU2 — Discovery: `DiscoverableWindow` + bounded on-demand scan + endpoint
- **Files:** `src/PureClaw/Harness/Discovery.hs` (NEW — `DiscoverableWindow`, `scanDiscoverable`), `src/PureClaw/Frontend/API.hs` (`POST /api/discovery/scan`), `src/PureClaw/CLI/Commands.hs` (wire), cabal, tests.
- **DoD:** D2.1 returns ONLY unmarked windows in allow-listed sessions (injected seam); D2.2 empty allow-list → empty; D2.3 a marked (`@pcl_id`) window is never returned; D2.4 scan NEVER calls `capture-pane` (assert via seam); D2.5 endpoint JSON shape; gates clean; coverage.
- **Depends on:** WU1.

### WU3 — Capture baseline: make the handle scrollback-baseline LIVE (B3 mechanism)
- **Files:** `src/PureClaw/Harness/ClaudeCode.hs` (make `baselineRef` live: `harnessReceive`/`extractLastResponse` honor a recorded baseline so pre-baseline scrollback is excluded from recorded output + broadcast; remove the `_` prefixes; reconcile the `IORef ByteString` type vs. an offset/length/marker — choose the simplest correct representation), tests (`test/Harness/ClaudeCodeSpec.hs`).
- **DoD:** D3.1 with a baseline set to the current end, a subsequent `harnessReceive` returns ONLY post-baseline output (pre-baseline backlog excluded) — asserted via the injected capture seam; D3.2 baseline = spawn default preserves existing spawned-harness behavior (regression — existing ClaudeCode tests green); D3.3 the excluded backlog never reaches the transcript NOR the WS broadcast (assert both paths); gates clean; coverage.
- **Depends on:** none (general capability; WU4 consumes it). Sequence before WU4.

### WU4 — Adopt: typed-gated mechanism + consent wiring + endpoint + session.json
- **Files:** `src/PureClaw/Harness/ClaudeCode.hs` (`adoptExternalWindow` — mirror spawn minus window-create; set baseline to current-end via WU3), `src/PureClaw/Frontend/API.hs` (`POST /api/tabs/{index}/adopt` — consent-confirmed body required; call `authorizeAdoption (_fe_policy) (_fe_consentChannel) session`; adopt on `Right`), `src/PureClaw/CLI/Commands.hs` (FEAS-2: add `ConsentChannel` param to `runChat`, set from `runCLI` `Command` dispatch; set `_fe_consentChannel`; wire `_fe_adopt`), `FrontendEnv` (**add TWO new fields: `_fe_consentChannel :: ConsentChannel` AND `_fe_policy :: SecurityPolicy`** — the gate found `FrontendEnv` carries NO policy today, but the adopt endpoint needs it for `authorizeAdoption`; **each new field triggers the same `-Wmissing-fields` cascade = the 4 `FrontendEnv {` literals: `Commands.hs:740`, `test/Frontend/{StreamHarness,ActivityProbeSpec,APISpec}.hs`** — set both at all 4), tests.
- **DoD:** D4.1 adopt (allow-listed + `ConsentInteractive`) stamps `@pcl_id`+remain-on-exit, records shell PID, sets baseline to current-end (B3 — assert ≠ 0/backlog), registers an `OriginAdopted` entry + legacy map, AND **creates/links a session.json** (assert the session file exists + loads); D4.2 (endpoint-level integration, SEC-1) adopt returns **403 for a `ConsentHeadless` FrontendEnv EVEN with an allow-listed session + valid consent body**, and 403 for a non-allow-listed session — in both cases NO `@pcl_id` stamped, NO entry; D4.3 the adopt code path REQUIRES an `AdoptedHarness` token (type-enforced); D4.4 a freshly-adopted window appears in `/api/tabs` with `origin="adopted"` + attach command; gates clean; coverage (real-tmux IO honestly waived).
- **Depends on:** WU1, WU2, WU3.

### WU5 — Release: clearWindowMarker + re-corroborated mechanism + endpoint (never kills)
- **Files:** `src/PureClaw/Harness/Tmux.hs` (+`clearWindowMarkerArgs`/`clearWindowMarker`), `src/PureClaw/Frontend/API.hs` (`POST /api/tabs/{index}/release`), `src/PureClaw/CLI/Commands.hs` (wire), tests.
- **DoD:** D5.1 release of a corroborated `OriginAdopted` entry clears `@pcl_id` (argv `set-option -wu @pcl_id` asserted), removes from registry+legacy map, issues NO `kill-window`/`kill-session` (assert via seam); D5.2 (SEC-3) release of a STALE/uncorroborated or non-`OriginAdopted` entry deregisters WITHOUT any tmux `set-option`/mutation (assert the seam saw no window op) + logs; D5.3 transcript/session.json persist (sid still in Recent Sessions); D5.4 purge flag accepted-but-reserved (documented no-op); gates clean; coverage.
- **Depends on:** WU4.

### WU6 — C3 input hygiene: `send-keys -l --` literal + identifier validation
- **Files:** `src/PureClaw/Harness/Tmux.hs` (`sendKeysNamedArgs` → `-l --`+separate Enter; `validateTmuxIdent`), `test/Harness/TmuxSpec.hs` + caller-argv-assert updates.
- **DoD:** D6.1 argv = `send-keys -t <target> -l -- <payload>` then separate `send-keys -t <target> Enter`; a `C-c`/`Enter` payload is literal; D6.2 leading-`-` identifiers rejected/`--`-guarded; D6.3 regression: the `cd <dir>`+Enter launch path still EXECUTES; existing ClaudeCode/Tmux integration green; gates clean.
- **Depends on:** none (sequence to avoid Tmux.hs collisions with WU5).

### WU7 — Frontend: Discovered/Adoptable section + Adopt(consent)/Release UI + hooks/types
- **Files:** `frontend/src/types.ts` (+`DiscoverableWindow`), `frontend/src/hooks/useApi.ts` (`useDiscoverableWindows`/`scan`, `adoptWindow`, `releaseHarness`), `frontend/src/components/Sidebar.tsx` (`DiscoverableSection` modeled on `ArchivedSection` — collapsed/counted/hidden-when-empty + Scan button), `frontend/src/components/ActiveTabs.tsx` (Adopt + consent confirm dialog on discovered candidates; Release on `origin="adopted"` rows), `frontend/src/App.tsx` (wire), tests.
- **DoD:** D7.1 Discoverable section renders scan results (collapsed/counted/hidden-when-empty) + Scan button calls the scan endpoint; D7.2 Adopt shows a consent confirmation naming the trust consequence, then calls adopt; D7.3 Release on an adopted row calls release (distinct from Close/Dismiss); D7.4 the origin pill renders "adopted"/"spawned" on the relevant rows (completeness fix); D7.5 `npm run build`(tsc strict)+`npm test` green.
- **Depends on:** WU2, WU4, WU5.

### WU8 — Integration + coverage sweep + close pureclaw-jlc + e2e
- **Files:** tests; `.coverage-thresholds.json`; rebuild `frontend/dist`; resolve `pureclaw-jlc`.
- **DoD:** D8.1 all backend+frontend gates green; D8.2 coverage gate + waiver hygiene (new pure logic — adoption gate/matcher, discovery filter, baseline, release argv+corroboration, send-keys argv — covered; real-tmux IO honestly waived); D8.3 e2e documented (scan→adopt(consent)→adopted+captured-from-now→release→window survives+session in Recent); D8.4 pureclaw-jlc: adoption delivers the attach side — close it OR record the spawn-placement residual as a tracked follow-on.
- **Depends on:** WU1–WU7.

## Execution order (DAG)
WU1 → WU2 → WU3 → WU4 → WU5 → WU7 → WU8; WU6 independent (slot to avoid Tmux.hs collisions with WU5). Backend (WU1-6) before frontend (WU7).

## Risks / open questions for the gate
- **R-SEC1 (consent):** is `CmdTui`-only `ConsentInteractive` (everything else Headless, fail-closed) the right v1 predicate, and is the endpoint-level 403 test (D4.2) sufficient proof? (Re-review focus.)
- **R-SEC2 (matcher):** is literal-or-trailing-`*`-with-non-empty-prefix, anchored, empty=deny, no-allow-all sufficient + safe? (Re-review.)
- **R-SEC3 (release):** is OriginAdopted+PID-corroboration before `-wu` (else deregister-only) the right anti-spoof posture? (Re-review.)
- **R-FEAS1 (baseline):** is making `baselineRef` live (WU3) correctly scoped as its own WU, and is D3.1/D3.3 (exclude backlog from transcript AND broadcast) achievable in the receive path?
- **R1 (scope):** spawn-side `_tc_window` placement stays deferred (WU8 records the residual) — confirmed acceptable for "delivers pureclaw-jlc"?
- **R2 (branch):** new branch off main after PR #75 merges (separate Phase-3 PR) — confirm with user.
