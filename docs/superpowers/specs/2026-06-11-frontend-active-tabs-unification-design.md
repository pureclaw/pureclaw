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
- **All real tabs unified:** the two tab kinds that exist today —
  `BoundSession` (provider/chat sessions) and `BoundHarness` (tmux harness tabs) —
  both live in the `TabRegistry` and project into the sidebar.
- **Persist `tabs.json`:** wire `saveTabs` on mutation + `loadTabs`+reconcile on boot.
- **Single phase:** deliver all four requirements together.
- **Raw-shell tabs are OUT OF SCOPE (deferred).** Design review confirmed the
  frontend's raw-shell create path (`createTab` `TkRawShell` arm, `Frontend/API.hs`)
  is a **vestigial stub**: it spawns no tmux window, registers no `HarnessId`, and
  returns `session_id=null` — there is nothing to bind a `TabRef` to. Forcing it onto
  `BoundHarness` is unbuildable, and adding a `BoundShell` variant for an unbacked
  stub is premature. This feature therefore covers `BoundSession` + `BoundHarness`
  only; raw-shell unification waits on real raw-shell backing (a separate follow-up,
  at which point a `BoundShell` `TabRef` variant + persistence/reconcile arm is added).
  The frontend raw-shell create affordance is left untouched (its current stub
  behavior); it is simply not registry-backed yet.
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

**The projection is a separately-exported PURE function** (REQUIRED — the
`Frontend/TabsView.hs` extraction below is mandatory, not optional, so the branch
matrix is unit-testable to the 95% gate on the non-waived `Frontend.API`). Mirror
the existing pure-and-tested `harnessEntriesToTabs` pattern:

```haskell
-- pure: all branch logic here, no IO
tabSnapshotsFromRegistry
  :: TabList
  -> (SessionId -> Maybe SessionMeta)        -- session-meta lookup (injected)
  -> (HarnessId  -> Maybe Registry.HarnessEntry) -- harness-entry lookup (injected)
  -> [TabSnapshot]
```
A thin IO wrapper in `Frontend.API` gathers the two lookups
(`listSessions`/`tryLoad` for meta, `Registry.snapshot` for harness entries — both
read once per snapshot) and applies the pure function. Per `Tab`:
- `_ts_index` ← `_tab_slot`.
- `BoundSession sid`:
  - `_ts_sessionId` ← `Just (unSessionId sid)`.
  - `_ts_kind` ← from the session's `_sm_kind` (`SkProvider` → `"provider"`); falls
    back to `"provider"` if meta is missing.
  - `_ts_name` ← `_tab_name` (registry label).
  - `_ts_status` ← session-tab mapping: `_tab_status` `Live` → **`"idle"`**,
    `Dead` → `"exited"`. (A session tab has no tmux process, so it must NOT render
    as `"running"`/green; the only live cue is the separate `sessionActivity`
    "thinking" shimmer keyed by `session_id`, unchanged.)
  - harness-only fields (`_ts_origin` → `""`, `_ts_attachCommand` → `Nothing`,
    `_ts_extModified` → `False`, `_ts_stale` → `False`).
- `BoundHarness hid`:
  - enrich from the injected `HarnessEntry` lookup: `_ts_status` from liveness
    (running/idle/exited/orphaned), `_ts_origin`, `_ts_attachCommand`,
    `_ts_extModified`, `_ts_stale`, `_ts_name` (prefer the registry tab name; fall
    back to the harness label), `_ts_sessionId` from the harness's backing session
    (if any), `_ts_kind` `"harness"`. A `BoundHarness` whose entry has vanished
    projects as `status="exited"`, `stale=True` (reconcile removes it on next boot).

`recentSessions` exclusion keeps its shape but now reads registry-derived `tabs`, so
**all** session-backed (non-harness) tab sids drop out of Recent Sessions
(requirement 2). Harness-backed tab sessions are still intentionally **dual-listed**
in Recent Sessions (the existing `k /= "harness"` carve-out is preserved) so the
harness conversation stays clickable. **Archived-but-tab-bound:** the archived list
filter must ALSO exclude sids bound to a tab (tab binding wins over both Recent and
Archived) so a tab-bound session never appears under Archived.

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
  - provider session → mint session **and `_sh_save` it to disk** (see E — this
    closes the persistence-zombie gap), **then** `registryAppend _fe_tabRegistry
    (BoundSession sid) name`.
  - harness → spawn (as today, registering a real `HarnessId`) **then**
    `registryAppend (BoundHarness hid) name` *after* the deferred-count success
    point (so a failed spawn never appends a phantom tab).
  - **Cap:** retain the configurable `_fe_maxTabs` (`_rc_maxTabs`) as a **pre-check**
    before `registryAppend` — do NOT silently replace it with the registry's hard
    36-slot cap. `readTabs` length supersedes the `_fe_tabCount` IORef as the count
    source (drop `_fe_tabCount`; this is in-scope test churn — ~14 `_fe_tabCount`
    assertions in `APISpec` become `readTabs`-length assertions). A registry
    `SlotsFull` (or the `_fe_maxTabs` pre-check) returns a clear 4xx with the
    `{"error": …}` JSON convention; **the frontend must render an actionable
    slot-exhaustion message** (today the non-branch create path silently swallows a
    `!res.ok`, so the cap would otherwise be a silent no-op — see the React row).
- **Tab actions resolve the index against the `TabRegistry`, not the HarnessRegistry**
  (fixes the index-aliasing blocker). Today `withResolvedTab`/`tabIndexToEntry`
  resolve `_ts_index` against `sortedHarnessEntries`; with interleaved session+harness
  tabs that aliases. Rewire all tab-action endpoints
  (`close`/`dismiss`/`release`/`destroy`/`acknowledge`) to resolve `_ts_index` →
  `_tab_slot` → `_tab_ref` via `readTabs _fe_tabRegistry`:
  - `close` → `registryRemove _fe_tabRegistry slot`, valid for any tab kind. For a
    `BoundSession` tab also `release` the runtime (`Exec`) and evict the
    `SessionStore` cache entry so a closed-then-reopened session does not resurrect a
    stale `SessionHandle`/runtime. The `session.json` stays on disk → the session
    reappears under Recent Sessions.
  - `dismiss`/`release`/`destroy`/`acknowledge` are **harness-only**: on a
    `BoundHarness` tab they run the existing harness teardown; on a `BoundSession`
    tab they return a clear `"not a harness tab"` 4xx (and the UI should suppress
    these controls on session rows — see Designer section). No silent mis-route.
- Every write-path mutation also calls `_env_onTabsChanged` (broadcast + persist).

A frontend-created `BoundSession` tab is now a real registry tab whose `session.json`
exists on disk → chat `/N` resolves its ref, `ensure` starts the runtime,
`resolveSession` loads the (real) session metadata → requirement 4. The frontend's
own selection (`selectedId`) stays a frontend-local view; the **list** is shared,
focus is per-surface.

### E. Persistence
- **Sessions are already durable** — `mkSessionHandle` (`Session/Handle.hs`) writes
  `session.json` unconditionally at construction, and both `mkNewDefaultSession`
  (`/nt`) and the frontend provider path go through it. So **no `_sh_save` change is
  needed** (an earlier draft wrongly claimed `/nt` sessions weren't saved — corrected).
- **Save:** `_env_onTabsChanged` also calls `saveTabs stateDir <tabs> <cursors>`
  (atomic temp+rename, 0600; best-effort — failure logged, not fatal). One seam →
  save + broadcast together. Persistence is tested *directly* via the `Persist` module
  (round-trip through `saveTabs`/`loadTabs`), independent of the broadcast seam.
- **Load:** in boot, after the existing synchronous `Reconcile.bootReconstruct`
  (`Commands.hs`, strictly before `Async.withAsync runFrontend`), call
  `loadTabs`+`reconcileTabs` with `PersistDeps` wired (`_pd_stateDir =
  pureclawDir </> "state"`, `_pd_harnessLive` = HarnessRegistry liveness probe,
  `_pd_discoveryReady = pure ()` since discovery already completed synchronously) and
  seed the `TabRegistry` + `CursorState` IORefs from the result **before** the
  server/loop start, so the first WS `lists` snapshot already reflects restored tabs.
  Reconcile keeps: a `BoundSession` tab **iff its `session.json` exists** — this is
  **defense-in-depth against a hand-edited or partially-written `tabs.json`** that
  references a session that was deleted out-of-band (not against an unsaved session,
  which can't happen); a `BoundHarness` tab iff `_pd_harnessLive`.
- **Traversal guard (security):** `SessionId` is opaque and `resumeSession`/
  `openSessionFromDisk` path-join it **with no validation**. Promote a single
  **strict** canonical validator `isValidSessionId` to the leaf `Core.Types`
  (non-empty; no leading `.`; no `..`; no `/`/control/NUL; charset `[a-zA-Z0-9_-]`)
  and: (a) `parseRef` (`Tabs/Persist.hs`) rejects a `BoundSession` whose decoded
  `SessionId` fails it — drop that tab, load the rest (tolerant, mirroring the
  invalid-`HarnessId` arm); (b) `resumeSession`/`openSessionFromDisk` also validate
  (safe-by-construction regardless of caller). Refactor the existing three divergent
  `isValidSessionId`/`isValidBranchSourceId` copies (`Frontend/API.hs`,
  `Session/Handle.hs`, `Agent/SlashCommands.hs`) onto the one strict definition so the
  rule lives in exactly one place.

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
| **`Frontend/TabsView.hs` (NEW)** | **relocate** `TabSnapshot` + `livenessToTabStatus` + `harnessOriginToText` here from `Frontend.API` (they're needed by the pure fn and `Frontend.API` will import `TabsView`, so they move *down* to avoid an import cycle; `Frontend.API` re-exports them for existing call sites/tests). Add the **pure** `tabSnapshotsFromRegistry :: TabList -> (SessionId -> Maybe SessionMeta) -> (HarnessId -> Maybe HarnessEntry) -> [TabSnapshot]`; exported + unit-tested (branch matrix) | pure projection logic + the wire type (95%-gated) |
| `Frontend/API.hs` | import + re-export `TabsView`; `_fe_tabRegistry`/`_fe_cursors` fields; thin IO wrapper gathering lookups → `tabSnapshotsFromRegistry`; recentSessions+archived exclusion reads registry tabs; **tab-action endpoints resolve index against the TabRegistry slot** (close any kind; dismiss/release/destroy/acknowledge harness-only with a `"not a harness tab"` 4xx backstop); `_fe_maxTabs` pre-check; drop `_fe_tabCount` | lists IO wrapper + frontend tab endpoints |
| `Agent/Env.hs` (+`TabSubsystem`) | add `_env_onTabsChanged :: IO ()` (default `pure ()`) | the change-notify seam |
| `Routing/TabDispatch.hs` | `_td_onTabsChanged` deps field; call after `cmdNt`/`cmdNew`/`cmdClose`/`cmdRename`/wizard-bind | chat-side mutation notify |
| `Tabs/Wiring.hs` | call notify after its registry mutations; on close release the runtime + evict the `SessionStore` (add a remove op — owned here; the frontend close path reaches it via the shared `_env_exec`/store, see §D) | live-loop notify |
| `Core/Types.hs` | the one strict `isValidSessionId` (leaf) | session-id validation |
| `Tabs/Persist.hs` | `parseRef` rejects an invalid `SessionId` (strict guard); `reconcileTabs` drops `BoundSession` tabs whose `session.json` is absent. (Both reachable in tests via `loadTabs` — no new exports needed.) | persistence codec + reconcile |
| `Session/Handle.hs` | `resumeSession`/`openSessionFromDisk` validate the id (safe-by-construction); drop the local validator copy in favor of `Core.Types` | loader safety |
| `CLI/Commands.hs` | set `_fe_tabRegistry`/`_fe_cursors`; set `_env_onTabsChanged = saveTabs + broadcastLists`; `loadTabs`+reconcile after `bootReconstruct`, before server start | wiring |
| React frontend | **surface slot-exhaustion**: the non-branch new-tab create path (`App.tsx`) must read the 4xx error body and render an actionable message (e.g. *"All N tab slots in use — close a tab to free one"*) instead of the current silent no-op. Harness-only controls already self-suppress on session rows via existing data-gating (`isDead`/`isExited`/`origin==='adopted'`/`extModified`/`attachCommand` all false-empty; Destroy needs `kind==='harness'`) — **no new guard code**; Archive + Close intentionally remain. Verify `mapTabInfo` maps a session tab (kind `provider`, status `idle`, origin `""`) cleanly with no green "running" dot. | rendering + error surfacing |

## Error handling & edge cases

- **Vanished `BoundHarness` entry** → project `status="exited"`/stale; reconcile drops on next boot. (Full *live notified* harness-death removal is **WU9** — deferred; this feature only reflects exited status.)
- **Session tab whose `session.json` is gone/archived** → projection falls back to the registry `_tab_name`/sid; row still renders. Archived session that is tab-bound: it's a tab (Active Tabs), not in Recent/Archived (tab binding wins).
- **`SlotsFull` at 36** (chat or frontend create) → 4xx; the frontend renders an actionable "close a tab to free a slot" message (chat already prints its own copy); no state change.
- **`saveTabs` failure** → log + continue (durability is best-effort; live sync unaffected).
- **Concurrent registry mutation** (chat + frontend) → `atomicModifyIORef'` serializes; the later broadcast reflects the merged state.
- **Same-tab simultaneous send from both surfaces** → out of scope (documented).
- **One surface closes the tab another surface had focused** → there are two distinct
  "focus" notions: the **backend per-`TabRef` cursor** (chat) and the **frontend
  `selectedId`** (web, local). When the ref is removed, the chat cursor becomes
  unresolvable → cleared (existing `cmdClose` compaction clears cursors on the removed
  ref); chat's next plain message shows the "no active tab — /new …" hint. The
  frontend's `selectedId` is independent: closing a tab the frontend had selected as
  `session:<sid>` leaves a valid selection (the session re-renders from Recent
  Sessions); closing one selected as `tab:<index>` falls back to compose/empty. No
  cross-surface focus coupling is added.
- **Rename directionality** → only chat `/rename` mutates a tab label in this phase
  (it propagates to the frontend via the notify seam). There is no frontend rename
  endpoint; frontend-initiated rename is a deferred follow-up, not a regression.
- **Frontend-created provider tab before any message** → projects as kind
  `"provider"`, status `idle`, no activity shimmer; chat `/N` to it then sends and
  the runtime is ensured. Consistent in both surfaces.

## Testing strategy

Backend (TDD, `-Werror`/hlint clean, 95% coverage gate):
- **Pure projection unit tests** (`Frontend/TabsView.hs`): `tabSnapshotsFromRegistry`
  over the full branch matrix with injected lookups — `BoundSession` (meta present →
  kind `provider`/status `idle`; meta missing → fallback), `BoundHarness` (live →
  status from liveness + origin/attach; vanished entry → `exited`/`stale`). This is
  where the 95% branch coverage lives (no IO).
- **No-secret-leak assertion**: the projection surfaces only label/status/kind/sid —
  assert no `_sm_source`/`channelUserId`/model-credential field ever reaches a
  `TabSnapshot`.
- **`recentSessions`/`archived` exclusion**: a registry with a `BoundSession` tab →
  that sid absent from BOTH `recentSessions` and `archivedSessions`, present as a
  tab; a `BoundHarness` tab's session still dual-listed in Recent.
- **Notify seam (per path)**: a recording `_env_onTabsChanged` fires once per
  `TabDispatch` mutation (`/nt`,`/new`,`/close`,`/rename`) and once per `Wiring`
  mutation — pin which mutations route through which so a double-fire is caught.
- **Write path**: `handleNewTab` (provider/harness) appends the right `TabRef`;
  `_fe_maxTabs` pre-check + `SlotsFull` yield a 4xx; close removes the tab AND
  releases the runtime/evicts the `SessionStore`; dismiss/release on a `BoundSession`
  tab returns the `"not a harness tab"` 4xx.
- **Strict id validation**: `Core.Types.isValidSessionId` rejects leading-dot,
  `..`, `/`, control/NUL, and non-`[a-zA-Z0-9_-]` ids; `parseRef` drops a tab whose
  id fails it (tested via `loadTabs` decoding a hand-written `tabs.json` with a
  leading-dot / control-char / absolute-looking id — not just `..`).
- **Persistence**: `saveTabs`→`loadTabs`+reconcile round-trip driven **directly via
  the `Persist` module** (no new exports — through `loadTabs`); reconcile drops a
  dead-harness tab AND a `BoundSession` tab whose `session.json` is absent, keeps a
  saved session tab; boot seeds the registry. Save-failure is non-fatal; concurrent
  appends serialize (no lost update).
- **Frontend slot-exhaustion**: a frontend test that a 4xx from `/api/tabs/new`
  renders the actionable message (not a silent no-op).
- **Dual-write consistency (req 4)**: a frontend `createTab` (`BoundSession`) and a
  chat `/N` resolve the **same** `TabRef` (`registryLookupSlot` equality) — the
  cross-surface invariant.
- **`mkNewDefaultSession` durability**: a `/nt`-minted session's `session.json`
  exists on disk after creation.
- **Integration**: drive `runTabbedLoop` `/nt` → broadcast `lists` snapshot includes
  the new tab and excludes its sid from Recent; frontend `createTab` → registry
  append → chat `/N` switch resolves + ensures the runtime.

Test churn (in-scope, not regressions): the ~14 `_fe_tabCount` assertions in `APISpec`
become `readTabs`-length assertions.

Frontend: verify the `lists` frame shape is unchanged (so `mapTabInfo`/most components
need no change); confirm a session-kind tab (kind `provider`, status `idle`) renders
under Active Tabs with no green "running" dot and harness-only controls suppressed.

## Out of scope (this feature)
- **Raw-shell tab unification** — the frontend raw-shell path is a vestigial,
  unbacked stub; deferred until real raw-shell backing exists (then add a `BoundShell`
  `TabRef` variant + persistence/reconcile arm). Covered here: `BoundSession` +
  `BoundHarness` only. To avoid an operator clicking "raw shell" and getting a stub
  that never appears in Active Tabs (reading as a req-1 bug), **hide/disable the
  raw-shell create affordance** in the frontend for this phase (small UI change).
- WU9 live *notified* harness-death removal (only exited-status reflection here).
- Frontend-initiated tab rename (chat `/rename` → frontend is one-directional here).
- Coordinating simultaneous sends to the same tab from both surfaces.
- Any new sidebar visual design (the existing Active Tabs / Running Harnesses /
  Recent Sessions layout is reused).
- WU10 `[tabs]` config.

## Open follow-ups
- `BoundShell` `TabRef` variant + real raw-shell backing (deferred raw-shell unify).
- Frontend-initiated rename endpoint.
