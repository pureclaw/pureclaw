# Frontend Active-Tabs Unification — Design

**Date:** 2026-06-11
**Issue:** frontend-parity follow-up to the Tabs-as-View cutover (#79 / PR #80)
**Status:** design — pending user review

## Goal

Make the frontend "Active Tabs" section reflect the **real** active tabs from the
backend `TabRegistry`, with bidirectional sync between the web frontend and the
chat/CLI surface. Concretely (user requirements):

1. The "Active Tabs" section shows **all** active tabs.
2. Sessions that have an active tab appear under **Active Tabs**, not under
   **Recent Sessions**.
3. When a new tab is created in chat or the CLI ("the TUI"), it appears in the
   frontend.
4. When a new session is created in the frontend, it appears under **Active Tabs**
   AND chat/CLI can switch to it (`/N`).

## Background — current state (the gap)

The frontend tab list and chat's tabs are **two separate systems**:

- **Frontend "Active Tabs"** is built by `computeListsSnapshot` (`Frontend/API.hs`)
  from `_fe_listTabs`, which today is `harnessEntriesToTabs <$> Registry.snapshot
  harnessReg` — i.e. derived from the **HarnessRegistry** + the frontend's own
  `/api/tabs/new` (`_fe_tabCount`). It knows nothing about chat's tabs.
- **Chat/CLI tabs** live in the **backend `TabRegistry`** (`PureClaw.Tabs`,
  `_env_tabRegistry`), created by `/new`,`/nt` (`Routing.TabDispatch` +
  `Tabs.Wiring`), keyed by `TabRef = BoundSession SessionId | BoundHarness
  HarnessId`. It is **not wired into the frontend**.

Consequences: a chat-created tab's session shows under "Recent Sessions" (never
"Active Tabs"); a frontend-created session is invisible to chat. `saveTabs`/
`loadTabs` exist but are **never called** (chat tabs are volatile). There is **no
separate TUI** — `CmdTui` is the CLI chat loop, so "chat or the TUI" is one surface.

Two facts make this tractable:
- **Same process, shared memory.** `runFrontend`, the reconcile loop, and
  `runTabbedLoop` run in one OS process under nested `Async.withAsync`
  (`CLI/Commands.hs`), all built from one `AgentEnv`. The frontend can read the
  *same* `_env_tabRegistry` IORef directly.
- **Push plumbing already exists.** `computeListsSnapshot` → `broadcastLists` →
  the `lists` WebSocket frame → `useListsStream` fires on every mutation and once
  on connect. `recentSessions` already excludes sessions bound to active
  non-harness tabs.

## Approved decisions

- **Single source of truth:** the `TabRegistry` is the one source for the sidebar
  tab list (all surfaces project from it).
- **All tabs unified:** session/provider tabs, harness/tmux tabs, and raw-shell
  tabs all live in the `TabRegistry`.
- **Persist `tabs.json`:** wire `saveTabs` on mutation + `loadTabs`+reconcile on boot.
- **Single phase:** deliver all four requirements together.
- **Raw-shell tabs** are modelled as `BoundHarness` (a raw shell *is* a tmux window
  tracked by the HarnessRegistry); no `TabRef` change. **Verify during planning:**
  confirm the frontend's raw-shell creation actually registers a `HarnessId` in the
  HarnessRegistry. If a raw-shell is *not* harness-backed, fall back to extending
  `TabRef` with a `BoundShell` variant (a localized `Tabs/Types.hs` change with its
  own persistence codec arm) rather than forcing it onto `BoundHarness`.
- **One surface sends at a time:** a tab is sent-to from chat *or* frontend; the
  per-session `TranscriptHandle` remains the sole serialized writer. Simultaneous
  send to the *same* tab from both surfaces is out of scope.

## Architecture

### A. Wire the registry into the frontend
Add to `FrontendEnv` (`Frontend/API.hs`):
- `_fe_tabRegistry :: TabRegistry`
- `_fe_cursors :: IORef CursorState`
Set both in `CLI/Commands.hs` from the shared `AgentEnv` (`_env_tabRegistry`,
`_env_cursors`) — the same IORefs `runTabbedLoop` mutates.

### B. Project the tab list from the registry (read path)
Replace the `_fe_listTabs` body (and any direct harness-snapshot use in
`computeListsSnapshot`) with a **projection** `tabSnapshotsFromRegistry`:
read `readTabs _fe_tabRegistry`; for each `Tab` produce a `TabSnapshot`:
- `_ts_index` ← `_tab_slot`.
- `BoundSession sid`:
  - `_ts_sessionId` ← `Just (unSessionId sid)`.
  - `_ts_kind` ← from the session's `_sm_kind` (`SkProvider` → `"provider"`).
  - `_ts_name` ← `_tab_name` (registry label).
  - `_ts_status` ← from `_tab_status` (`Live` → `"running"`, `Dead` → `"exited"`).
    (Live activity — thinking/idle shimmer — continues to come from the separate
    `sessionActivity` stream keyed by session id; unchanged.)
  - harness-only fields (`_ts_origin`, `_ts_attachCommand`, `_ts_extModified`,
    `_ts_stale`) ← defaults.
- `BoundHarness hid`:
  - enrich from the `HarnessRegistry` entry (`Registry.lookupById`): `_ts_status`
    from liveness, `_ts_origin`, `_ts_attachCommand`, `_ts_extModified`, `_ts_stale`,
    `_ts_name` (prefer the registry tab name; fall back to the harness label),
    `_ts_sessionId` from the harness's backing session (if any), `_ts_kind`
    (`"harness"` or `"raw_shell"` per the entry). A `BoundHarness` whose entry has
    vanished projects as `status="exited"`/stale (reconcile removes it on next boot).

`recentSessions` exclusion is unchanged in shape but now sees registry-derived
`tabs`, so **all** session-backed (non-harness) tab sids drop out of Recent Sessions
— satisfying requirement 2.

### C. Notify-on-change seam (live push for chat mutations)
The tab subsystem must trigger a `lists` rebroadcast when chat mutates the registry,
without `Routing`/`Tabs` depending on `Frontend`. Add an injected callback:
- `TabSubsystem`/`AgentEnv` gains `_env_onTabsChanged :: IO ()` (default `pure ()`).
- `CLI/Commands.hs` sets it to `broadcastLists frontendEnv` (and, see E, persistence).
- Call it after every registry mutation on the chat path: `cmdNt`, `cmdNew`/
  `resetActiveTab`, `cmdClose`, `cmdRename`, wizard bind, and any `registrySetStatus`
  (e.g. harness-death status flips). Implement as a single helper invoked from
  `TabDispatch` (via a new `_td_onTabsChanged` deps field) and `Wiring`.

Because `broadcastLists` recomputes the snapshot from the live registry + session
dir + harness registry, one callback covers every mutation source.

### D. Frontend creation/mutation drives the registry (write path)
Route the frontend tab endpoints through the `TabRegistry`:
- `POST /api/tabs/new` (`createTab`/`handleNewTab`):
  - provider session → mint session (as today) **then** `registryAppend
    _fe_tabRegistry (BoundSession sid) name`.
  - harness → spawn (as today) **then** `registryAppend (BoundHarness hid) name`.
  - raw-shell → spawn tmux window (as today) **then** `registryAppend (BoundHarness
    hid) name`.
  - the `36`-slot cap is enforced by the registry (`SlotsFull`); **drop
    `_fe_tabCount`** and derive count/cap from `readTabs` length. Surface
    `SlotsFull` as the existing "max tabs" error.
- `POST /api/tabs/{i}/close|dismiss|release|destroy` → `registryRemove
  _fe_tabRegistry slot` (plus the existing harness teardown for harness tabs).
- Every write-path mutation also calls `_env_onTabsChanged` (broadcast + persist).

A frontend-created `BoundSession` tab is now a real registry tab → chat `/N` resolves
its ref, `ensure` starts the runtime, `resolveSession` loads the session from disk
(the `apv` fix gives correct metadata) → requirement 4. The frontend's own selection
(`selectedId`) stays a frontend-local view; the **list** is shared, focus is per-surface.

### E. Persistence
- **Save:** `_env_onTabsChanged` also calls `saveTabs stateDir <tabs> <cursors>`
  (best-effort; failure logged, not fatal). One seam → save + broadcast together.
- **Load:** in boot (`newTabSubsystem`/`Commands.hs`), after the harness discovery
  pass, call `loadTabs`+`reconcileTabs` (`Tabs/Persist.hs`) with `PersistDeps`
  wired (`_pd_stateDir`, `_pd_harnessLive` = HarnessRegistry liveness probe,
  `_pd_discoveryReady` = the boot-discovery gate) and seed the `TabRegistry` +
  `CursorState` IORefs from the result. Reconcile drops dead-harness tabs, keeps
  session tabs.

## Data flow (end to end)

- **chat `/nt`** → `registryAppend` (IORef) → `_env_onTabsChanged` → `saveTabs` +
  `broadcastLists` → `lists` WS frame → `useListsStream` → Active Tabs row appears.
- **frontend "new tab"** → `POST /api/tabs/new` → mint + `registryAppend` →
  `_env_onTabsChanged` → broadcast + save → frontend row appears; chat `/tabs`
  lists it; chat `/N` switches + runtime ensured on send.
- **chat `/close N`** / **frontend close** → `registryRemove` → broadcast + save →
  row removed everywhere; if it was a session tab, the session reappears under
  Recent Sessions (no longer tab-bound).
- **boot** → harness discovery → `loadTabs`+reconcile → seed registry → first
  `lists` snapshot on WS connect reflects restored tabs.

## Components & boundaries

| Unit | Change | Owns |
|---|---|---|
| `Frontend/API.hs` | `_fe_tabRegistry`/`_fe_cursors` fields; `tabSnapshotsFromRegistry` projection; write-path endpoints append/remove via registry; drop `_fe_tabCount` | lists projection + frontend tab endpoints |
| `Agent/Env.hs` (+`TabSubsystem`) | add `_env_onTabsChanged :: IO ()` | the change-notify seam |
| `Routing/TabDispatch.hs` | `_td_onTabsChanged` deps field; call after each mutation | chat-side mutation notify |
| `Tabs/Wiring.hs` | call notify after its registry mutations | live-loop notify |
| `Tabs.hs` / `Tabs/Persist.hs` | (no API change expected) wire `saveTabs`/`loadTabs` from Commands | persistence |
| `CLI/Commands.hs` | set `_fe_tabRegistry`/`_fe_cursors`; set `_env_onTabsChanged = saveTabs + broadcastLists`; `loadTabs`+reconcile on boot | wiring |
| React frontend | minimal — already renders from the `lists` frame; verify `TabInfo`/`mapTabInfo` still match the (unchanged-shape) `TabSnapshot` | rendering |

## Error handling & edge cases

- **Vanished `BoundHarness` entry** → project `status="exited"`/stale; reconcile drops on next boot. (Full *live notified* harness-death removal is **WU9** — deferred; this feature only reflects exited status.)
- **Session tab whose `session.json` is gone/archived** → projection falls back to the registry `_tab_name`/sid; row still renders. Archived session that is tab-bound: it's a tab (Active Tabs), not in Recent/Archived (tab binding wins).
- **`SlotsFull` at 36** (chat or frontend create) → surface the existing slot-exhaustion copy; no state change.
- **`saveTabs` failure** → log + continue (durability is best-effort; live sync unaffected).
- **Concurrent registry mutation** (chat + frontend) → `atomicModifyIORef'` serializes; the later broadcast reflects the merged state.
- **Same-tab simultaneous send from both surfaces** → out of scope (documented).

## Testing strategy

Backend (TDD, `-Werror`/hlint clean, coverage gate):
- **Projection unit tests** (`Frontend/API` or a focused spec): `TabList` +
  injected session-meta/harness-entry lookups → expected `TabSnapshot[]` for each
  ref kind (session, harness, raw-shell, vanished-harness).
- **`recentSessions` exclusion**: a registry with a `BoundSession` tab → that sid
  absent from `recentSessions`, present as a tab.
- **Notify seam**: a recording `_env_onTabsChanged` fires exactly once per chat
  mutation (`/nt`,`/new`,`/close`,`/rename`).
- **Write path**: `handleNewTab` (provider/harness/raw-shell) appends the right
  `TabRef`; close removes it; cap enforced via registry.
- **Persistence**: `saveTabs`→`loadTabs`+reconcile round-trip; reconcile drops a
  dead-harness tab, keeps a session tab; boot seeds the registry.
- **Integration**: drive `runTabbedLoop` `/nt` and assert a broadcast `lists`
  snapshot includes the new tab and excludes its sid from `recentSessions`;
  frontend `createTab` → registry append → chat `/N` switch resolves the runtime.

Frontend: verify the `lists` frame shape is unchanged (so `mapTabInfo`/components
need no change); a light test that a session-kind tab renders under Active Tabs.

## Out of scope (this feature)
- WU9 live *notified* harness-death removal (only exited-status reflection here).
- Coordinating simultaneous sends to the same tab from both surfaces.
- Any new sidebar visual design (the existing Active Tabs / Running Harnesses /
  Recent Sessions layout is reused).
- WU10 `[tabs]` config.

## Open follow-ups
- If projection/wiring pushes `Frontend/API.hs` further over a healthy size, extract
  the tab projection into a focused `Frontend/TabsView.hs` module.
