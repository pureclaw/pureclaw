---
issue: pureclaw-3oy
pr: pending
status: PAUSED — superseded/subsumed by the Harness Registry & Lifecycle design (epic pureclaw-3oy expanded 2026-06-01). Session-name plumbing folds into that design; do not execute standalone.
date_drafted: 2026-06-01
beads_epic: pureclaw-3oy
related: pureclaw-99a (frontend harness/tmux, PR #74), pureclaw-jlc (deferred attach)
branch: feat/tmux-session-name
note: >
  active-plan.md is owned by #57. This plan is a separate file. Builds on the
  fix/frontend-harness-tmux-spawn branch work (PR #74); will branch from it or main.
---

# Implementation Plan — Per-harness tmux session name; drop window from create config

**Epic:** `pureclaw-3oy`

## Problem

The frontend tmux backend's `session` and `window` fields have no effect:
`_fe_startHarness` (`Commands.hs`) ignores the request's `_h_backend`, hardcodes the tmux
session to the constant `"pureclaw"` (`ClaudeCode.hs:38`), auto-assigns a window, and
`createHarnessTab` overwrites the persisted backend with `TbTmux (TmuxConfig "pureclaw" harnessKey
Nothing)`. The backend's `TmuxConfig` parser also *requires* `session` + `window`, so a tmux backend
with blank fields fails to parse.

## User decision

- The tmux **session name is per-harness**, defaults to **`pureclaw`**, and names the
  `tmux attach -t <session>` target — i.e. it is honored: the harness window is created in / placed
  into that session.
- The **`window` field is removed from the create config** (auto-assigned on creation). `window` is
  only meaningful when **attaching** to an existing session (the unimplemented `pureclaw-jlc`).

## Key design decisions

- **D-A. Window name is the harness key; session is placement only.** Keep the harness map key =
  the tmux **window name** = `canonical <> "-" <> show globalIdx`, where `globalIdx` comes from the
  existing global `windowIdxRef` counter (so names are globally unique even across sessions). The
  session name is *where* the window lives and the `attach -t` target; it is **not** part of the
  key. This leaves the harness keyspace, `harnessKeyFromKind`, restart-routing, and the CLI
  `/harness`/`/target` surface unchanged.
- **D-B. Target harness windows by NAME, not numeric index.** Today `addHarnessWindow`/`sendToWindow`
  /`captureWindow`/`stopHarnessWindow`/`renameWindow` target `session:<Int index>` and discovery
  asserts `winIdx == tmuxIndex`. With multiple sessions + a global counter, the global name suffix
  ≠ the per-session tmux index, so switch all harness tmux ops to target `session:<windowName>`
  (tmux supports `-t session:window_name`; names are globally unique). Drop the `winIdx == idx`
  coupling in discovery. `windowIdxRef` is retained solely to mint unique name suffixes.
- **D-C. Thread the session name through the harness factory.** Replace the `sessionName` constant
  with a parameter on `mkClaudeCodeHarness` / `mkClaudeCodeHarnessWith` / `startHarnessByName`
  (default `"pureclaw"` so the CLI `/harness start` path is unchanged). The handle's `_hh_session`
  becomes the real session (so `probeHarness`/activity + the "attach with" message use it).
- **D-D. `TmuxConfig` JSON tolerates absent fields; type stays `Text` for now.** Make FromJSON
  default `session` → `"pureclaw"` and `window` → `""` (both `.:?` + `.!=`) in BOTH encodings
  (standalone `TmuxConfig` and inline `TbTmux`). Keep `_tc_window :: Text`. The create flow always
  overwrites the persisted window with the real auto-assigned name, so `""` never persists for a
  harness; the typed `Maybe`-window model (Nothing = create / Just = attach) is **deferred to the
  attach work `pureclaw-jlc`** where it becomes load-bearing — avoiding a ~20-test-site `Maybe`
  churn now. **(Reviewers: challenge Text-vs-Maybe here.)**
- **D-E. Discovery enumerates sessions.** `discoverHarnesses` enumerates tmux sessions
  (`tmux list-sessions -F '#{session_name}'`) and scans each, keying by window name, so a harness in
  a custom session reconnects after a gateway restart (consistent with pureclaw-99a's restart scope).
- **D-F. Frontend: session input defaults to `pureclaw`; window input removed.** `buildBackendPayload`
  always sends `session` (default `"pureclaw"`) and never sends `window` for tmux.

## Targeting model (resolved after round-1 completeness review)

The tmux session was a hardcoded constant (`"pureclaw"`) and callers build `"<session>:<component>"`
target strings ad-hoc in ~10 places spanning send / receive / poll / scrollback / status / rename /
stop / activity-probe / discovery. Honoring a per-harness session requires threading the session into
**every** one of those. To centralize, introduce a helper `windowTarget :: Text -> Text -> String`
(= `"<session>:<windowName>"`) in `Tmux.hs` and route all harness targeting through it. Note:
`captureWindow :: Text -> Int -> IO ByteString` already takes the full target STRING as its first arg
(callers pass `"<session>:<idx>"`); it is renamed for clarity and callers pass `windowTarget session
name`. Complete site inventory (each assigned to a WU below): `addHarnessWindow`, `sendKeysSmall/Large`,
`stopHarnessWindow`, `renameWindow` (Tmux.hs); `harnesseSend`→`sendToWindow`, `harnessReceive`'s
`target`/`pollUntilIdle`/`captureFullScrollback`, `checkWindowStatus`/`checkWithTmux` (list-windows),
`_hh_session`, `_hh_stop`, `mkDiscoveredClaudeCodeHandle` (ClaudeCode.hs); `probeActivity`
(Frontend/API.hs:400) and the probe in `Frontend/ActivityProbe.hs`; `discoverHarnessesIn`
(SlashCommands.hs); `/harness start` handler and the `/session` handler (SlashCommands.hs:2188).

## Work units

### WU1 — `TmuxConfig` JSON defaults (no type change)
- **Files:** `src/PureClaw/Session/Kind.hs`, `test/Session/KindSpec.hs`.
- FromJSON for `TmuxConfig` and inline `TbTmux`: `session` via `.:? "session" .!= "pureclaw"`,
  `window` via `.:? "window" .!= ""`, `pane` unchanged. ToJSON unchanged.
- **DoD:** D1.1 `{"tag":"tmux"}` → `TbTmux (TmuxConfig "pureclaw" "" Nothing)`; D1.2 tmux object with
  only `session` parses with `window=""`; D1.3 existing round-trips pass; `-Wall -Werror` clean.
  D1.4 raw-shell `TmuxConfig` users (Tab.Backend, Handles.Tab, AutoSpawn) unaffected (no type change) —
  confirmed by full build + their existing tests.
- **Depends on:** none.

### WU2 — `Tmux.hs`: session-aware, name-based targeting + helpers
- **Files:** `src/PureClaw/Harness/Tmux.hs`, `test/Harness/*` (e.g. TmuxSpec).
- Add `windowTarget session name`. Switch `addHarnessWindow`/`sendToWindow`(`sendKeysSmall/Large`)/
  `stopHarnessWindow`/`renameWindow` to take `(session, windowName)` and target via `windowTarget`
  (drop the numeric-index target). Rename `captureWindow`'s misleading param; it keeps taking a full
  target string. `startTmuxSession` returns whether it **created** the session (e.g.
  `IO (Either HarnessError Bool)`) so the harness can reuse the fresh session's default window 0
  (F7): on a freshly-created session reuse window 0 (rename→name, cd, launch); on an existing session
  `new-window -n <name>`. Add `listTmuxSessions :: IO [Text]` (`tmux list-sessions -F '#{session_name}'`).
- **DoD:** D2.1 ops target `<session>:<windowName>` (unit tests assert the argv); D2.2
  `startTmuxSession` reports created-vs-existed; D2.3 fresh session reuses window 0, existing session
  gets a named `new-window`; D2.4 `listTmuxSessions` parses names; D2.5 `-Wall -Werror` clean.
- **Depends on:** WU1.

### WU3 — `ClaudeCode.hs` + `startHarnessByName`: thread session everywhere
- **Files:** `src/PureClaw/Harness/ClaudeCode.hs`, `src/PureClaw/Agent/SlashCommands.hs`
  (`startHarnessByName` + `/harness start` handler + the `/session` handler at :2188), tests.
- `mkClaudeCodeHarness`/`mkClaudeCodeHarnessWith` gain a **session** param (default `"pureclaw"`) and a
  **windowName**; replace the `sessionName` const at EVERY use (90,95,102,109,111,144,155,287,320,322):
  `startSession`, `addWindow`, `sendToWindow`, `harnessReceive` target + `pollUntilIdle` +
  `captureFullScrollback`, `_hh_session`, `_hh_stop`, and **`checkWindowStatus`/`checkWithTmux`** (which
  gain a session param and use it in `list-windows -t <session>` instead of the literal `"pureclaw"`,
  F3). `mkDiscoveredClaudeCodeHandle` gains a session param (F5) so discovered handles target their real
  session. `startHarnessByName` gains a session param (default `"pureclaw"`) and passes it through; the
  `/harness start` handler passes `"pureclaw"` and renames/inserts by window name. **F4 decision:** the
  `/session` handler (:2188) is metadata-only (`createSession` writes session.json, does NOT spawn) — it
  is updated to `TmuxConfig "pureclaw" "" Nothing` (default session, auto window) to match the new
  convention. D3.5 must assert a `/session`-created harness record still resolves correctly (or document
  that it is not routed until started, since `harnessKeyFromKind` would return `Just ""`).
- **DoD:** D3.1 no `sessionName` const remains (grep clean); D3.2 send/receive/poll/scrollback/status/
  stop all target the threaded session (tests via the injectable seams + argv assertions); D3.3 CLI
  `/harness start` still spawns + routes + reports correct status (regression); D3.4 a harness in a
  non-`pureclaw` session has a correct `_hh_session` and a working `_hh_status`; D3.5 `/session` handler
  produces the new convention; `-Wall -Werror` clean.
- **Depends on:** WU2.

### WU4 — `_fe_startHarness` honors `_tc_session`
- **Files:** `src/PureClaw/CLI/Commands.hs`, `test/Frontend/APISpec.hs`.
- Read `_tc_session` from the request spec's `TbTmux` (default `"pureclaw"`), pass it + the minted
  window name to `startHarnessByName`, and persist `TmuxConfig { _tc_session = <session>,
  _tc_window = <windowName>, _tc_pane = Nothing }`. Note: WU2 changed `renameWindow` to
  `(session, windowName)`, so this site's `renameWindow "pureclaw" windowIdx ...` call switches its
  first arg to `<session>` and second to the window name (`-Werror` forces it).
- **DoD:** D4.1 harness created with `session:"foo"` spawns in session `foo` (injected-seam assertion);
  D4.2 persisted `_sm_kind` carries `_tc_session="foo"` + the auto window name; D4.3 blank/absent
  session → `"pureclaw"`; D4.4 `harnessKeyFromKind` routing (by window name) still works.
- **Depends on:** WU3.

### WU5 — Multi-session discovery (restart reconnect for custom sessions)
- **Files:** `src/PureClaw/Agent/SlashCommands.hs` (`discoverHarnesses`/`discoverHarnessesIn`), tests.
- `discoverHarnesses` enumerates `listTmuxSessions` and scans each via `discoverHarnessesIn`, building
  handles via `mkDiscoveredClaudeCodeHandle <session>` (WU3), keyed by window name. Drop the
  `winIdx == idx` coupling (names use a global suffix, not the per-session index). **F6:** the global
  counter seed = `max` of the parsed name-suffixes across ALL discovered harness windows `+ 1` (not the
  per-session tmux index max), so freshly-minted names never collide.
- **DoD:** D5.1 `discoverHarnesses` scans every session; D5.2 a harness in session `foo` reconnects
  after a simulated restart (handle present under its window-name key, `_hh_session="foo"`); D5.3 the
  global-counter seed = max name-suffix across sessions + 1; D5.4 single-`pureclaw` behavior preserved;
  D5.5 two harnesses in the SAME custom session get distinct globally-unique window names and both
  rediscover (covers the second-harness-in-same-session edge: existing session → `new-window -n`).
- **Depends on:** WU3 (shared `SlashCommands.hs`; sequence after WU3 — no parallel edit), WU2.

### WU6 — Activity probes target the harness's session+window
- **Files:** `src/PureClaw/Frontend/API.hs` (`probeActivity`/`probeHarness`),
  `src/PureClaw/Frontend/ActivityProbe.hs`, tests (`test/Frontend/ActivityProbeSpec.hs`).
- The probes currently build `tmuxSession <> ":" <> extractWindowIdx windowName` (API.hs:400,
  ActivityProbe.hs:182). Retarget to `windowTarget (_hh_session hh) <windowName>` so a custom-session
  harness's activity is read from the correct window. `probeHarness` already has `_hh_session hh`.
- **DoD:** D6.1 `probeActivity` targets `<session>:<windowName>` using the harness's `_hh_session`;
  D6.2 `extractWindowIdx`-based targeting removed; D6.3 ActivityProbe tests still pass; clean build.
- **Depends on:** WU3 (needs `_hh_session` to carry the real session).

### WU7 — Frontend: default session to `pureclaw`, drop the window input
- **Files:** `frontend/src/hooks/useNewTabSpec.ts`, `frontend/src/components/NewTabComposer.tsx`,
  `frontend/src/components/__tests__/NewTabComposer.test.tsx`.
- Default `backendConfig.session` to `"pureclaw"` when the tmux backend is selected;
  `buildBackendPayload` always sends `session`, never `window`. Remove the Window `<Row>` from the
  tmux config UI; keep/relabel the Session row (default `pureclaw`).
- **DoD:** D7.1 tmux payload includes `session` (default `"pureclaw"`) and NO `window` key (vitest);
  D7.2 the Window input is gone; D7.3 editing the session input is reflected in `buildBody`;
  D7.4 full frontend vitest green.
- **Depends on:** none (integrates at WU8).

### WU8 — Coverage + integration sweep
- **Files:** tests; `.coverage-thresholds.json` is the source of truth.
- **DoD:** D8.1 `cabal test` + frontend `vitest` green; D8.2 coverage of new logic (JSON defaults,
  `windowTarget`, session threading reachable branches, discovery parse/seed, `_fe_startHarness`
  session plumbing) with integration-only tmux IO documented; D8.3 `-Wall -Werror` + hlint clean.
- **Depends on:** WU1–WU7.

## Risks / resolved questions
- **R1 (RESOLVED — Scope):** `_tc_window` stays `Text`; the `Maybe` (Nothing=create/Just=attach) model
  is deferred to `pureclaw-jlc` where it is load-bearing. Behaviorally the window is never a create
  input and is always overwritten with the auto name, so the user-visible requirement is met without a
  ~25-site `Maybe` churn. (Scope reviewer round-1 concurred this is minimal, not under-delivery.)
- **R2 (RESOLVED — Feasibility):** tmux supports `-t <session>:<window_name>`; names are globally unique
  via the global counter, so `<session>:<name>` is unambiguous. Round-1 feasibility confirmed.
- **R3 (RESOLVED — F4):** `/session` handler (:2188) is updated to the new convention in WU3.
- **R4 (RESOLVED):** full `sessionName`-site inventory enumerated in the Targeting model section; line
  287 is a string literal in `checkWindowStatus` (threaded in WU3), distinct from the const refs.
- **R5/F7 (RESOLVED):** `startTmuxSession` returns created-vs-existed; WU2 reuses the fresh session's
  default window 0, else `new-window -n` — no idle window 0, and no wrong assumption that window 0 is
  the harness's in a pre-existing session.
- **R6 (RESOLVED):** raw-shell `TmuxConfig` users unaffected (no type change) — WU1 D1.4 verifies.
- **F1/F2/F5 (RESOLVED):** probe retargeting → WU6; `harnessReceive`/scrollback/poll + discovered-handle
  session → WU3 (ClaudeCode.hs now in scope for both creation and discovery paths).
- **R-new (Completeness):** `captureWindow` takes a full target string (not session-only) — callers
  build the target; WU2/WU3 route those through `windowTarget`. Confirm no caller is left building a
  bare-session or index-based target.
