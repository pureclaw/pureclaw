# Unify the tab name and the session name

**Status:** Design — driven by user-stated principles 2026-06-16
**Branch:** feat/web-frontend-slash-dispatch (follows the tui-requires-gateway change)

## Governing principles (from the user — these guide every decision)

1. **There is no difference between a tab name and a session name.** The label in the frontend's **Recent Sessions** list and the label in the **Active Tabs** list are the *same thing*. Opening a recent session as a tab keeps its name; closing a tab (it moves from Active Tabs back to Recent Sessions) keeps its name. The name follows the *session*, not the tab slot.
2. **Default the name to the start of the session's first user message** when the user hasn't set a custom name.
3. **The user can set a custom name for anything in Active Tabs** (important for organizing in-flight work).
4. **No rename is needed in Recent Sessions, and definitely not in Archived.** Renaming is an Active-Tabs-only affordance.

## The core consequence

The displayed name is **a session property**, computed identically wherever a session appears (Active Tab, Recent Session, TUI `/tabs`). The tab-registry field `_tab_name` is **no longer the name source** — a tab is just a view of a session, and the name comes from the session. This is what makes principle 1 hold by construction, and it sidesteps the per-process tab-registry split-brain for *names* (the session title is already shared on disk and re-broadcast).

## Current model (verified)

- There is **no `_sm_name`**; the session title is computed: `sessionDisplayTitle = _sm_description` (user override, in `session.json`, set via `PUT /api/sessions/{id}/description`) `?? _sm_autoSummary` (unwired, always `Nothing`) `?? firstMessageSnippet` (computed live backend-side from the first transcript line, `API.hs:1308`) `?? agent ?? id` (`frontend/src/types.ts:41`).
- `_tab_name :: Text` (`Tabs/Types.hs:101`) is a *separate* field defaulting to the literal `"session"` for provider tabs (or the tmux window key for harness tabs), stored per-process in `tabs.json`. It is the current source of `_ts_name` / `tab.name` in the sidebar (`ActiveTabs.tsx:122`) and the TUI `/tabs` listing (`TabDispatch.tabRow`).
- `computeListsSnapshot` re-reads session metas fresh from disk on every broadcast; `PUT /description` already calls `broadcastLists`. The backend tab projection (`tabSnapshotsFromRegistry`, `TabsView.hs`) deliberately takes **no** session meta (a documented security boundary) but **does** emit each tab's `sessionId` (`_ts_sessionId`).
- Both tab kinds are session-backed: `BoundSession sid` directly; `BoundHarness hid` is an `SkHarness` session reachable via the harness registry's `_he_sessionId`.

## Design

### 0. Shared session-title derivation (required for principle 1 to hold on ALL surfaces)

Design-review found the title is computed **differently** today: the web uses `description → autoSummary → firstMessageSnippet → …` (snippet derived live backend-side, `API.hs:1308`), but the **TUI** uses `Wiring.sessionLabel = _sm_description ?? unSessionId` (`Wiring.hs:629`) — **no snippet**. So as-is, the TUI default would be a raw session id while the web shows the first-message snippet — violating principle 1.

**Fix:** extract the canonical title derivation into ONE shared helper that both the Frontend and the TUI call:

```haskell
-- new leaf module, e.g. PureClaw.Session.Title
sessionTitle :: FilePath -> SessionMeta -> IO Text   -- baseDir, meta -> the displayed title
-- = _sm_description ?? _sm_autoSummary ?? firstMessageSnippet(baseDir, meta) ?? agent ?? id-prefix
```

`firstMessageSnippet` (currently private in `Frontend.API`) moves into this shared module; `Frontend.API` and the TUI both call `sessionTitle`. This guarantees identical defaults everywhere. The **TS mirror stays pure**: `sessionDisplayTitle` in `frontend/src/types.ts` keeps using the backend-computed `firstMessageSnippet` already on the wire (`_si_firstMessageSnippet`) — do NOT port the IO/transcript read to TS. Only the Haskell surfaces call the IO `sessionTitle`. The TUI's `sessionLabel`/`recentSessions`/`tabRow` switch to `sessionTitle`.

### 1. Name source: the session title (principles 1 & 2)

Everywhere a tab/session label is displayed, it resolves to `sessionDisplayTitle` for that session:
`_sm_description` (custom override) → `firstMessageSnippet` (default, start of first user message) → existing fallbacks. `_tab_name` is retired as the display-name source.

- **Web — three `tab.name` consumers, centralized join:** design-review found `tab.name` is read in **three** places, not one: `ActiveTabs.tsx:122` (tab row), `HarnessControls.tsx:82` (harness header), and `deriveAgent` in `App.tsx:1212` (chat-header/TopBar title). All switch to the session title. To avoid per-site drift, **compute the label once in `App`** (it already holds `sessions`/`archivedSessions` and already joins by `session_id` in `deriveAgent`/`HarnessControls`) via a shared `sessionFor(sessionId)` resolver, and thread it (or the resolved label) into `ActiveTabs` (which does NOT currently receive `sessions` — add the prop via `Sidebar`). The resolver checks BOTH `sessions` and `archivedSessions` (a tab can stay open after its session is archived). This keeps the backend tab projection meta-free (the join uses only the session list the client already has + the tab's `sessionId`) — the documented security boundary is preserved.
- **Harness tabs / unresolved join:** the harness snapshot exposes `_ts_sessionId` but it is `Maybe` (`_he_sessionId :: Maybe Text`, `Registry.hs:144`) — it can be `Nothing` (no backing session yet / vanished). When `sessionFor` yields nothing (harness without a session id, or a tab whose session isn't in either list yet), the row falls back to a defined label — the harness flavour / window label (kept available on the snapshot) — so a row **never renders blank**. An empty session (zero messages) resolves via `sessionDisplayTitle`'s existing id-prefix fallback, not the literal `"session"`.
- **Web — Recent Sessions / Archived:** already render `sessionDisplayTitle`. Unchanged — and now provably identical to the Active Tab label.
- **TUI `/tabs`:** `tabRow` resolves each session tab's title from session meta (the TUI has the session store) instead of `_tab_name`. Harness tabs likewise resolve their session title.

### 2. Custom override (principle 3): rename from Active Tabs → session description

A custom name is `_sm_description`, written via the existing `PUT /api/sessions/{id}/description` (the single canonical writer; the web pencil already uses it).

- **Web:** the rename affordance is the existing **chat-header pencil** (it edits the focused active tab's session title via `PUT /description`). **Decision:** the pencil is currently revealed only on hover (`ChatArea.tsx` / the `editable-title-pencil` CSS) — make it **always visible** to improve discoverability. No per-tab inline rename is added; the focused active tab's pencil is sufficient.
- **TUI — via an injectable seam (not an inline HTTP call):** `TabDispatch` runs purely through `TabDispatchDeps` and has no HTTP/gateway access; routing rename inline would break that testable-deps pattern (design-review blocker). Add a seam:
  ```haskell
  , _td_setSessionDescription :: SessionId -> Maybe Text -> IO (Either Text ())
  ```
  `/tab rename <slot> <name>` (`doRename`) resolves the slot → `SessionId` locally (via `registryLookupSlot` + `_tab_ref`), runs `Parse.sanitizeTabName` TUI-side, then calls the seam; a `Left err` surfaces a user-facing message (gateway down / 4xx / no session). The production seam is wired in `CLI/Commands.hs` (where the HTTP `Manager` + gateway URL already live for `probeGatewayUp`) to `PUT /api/sessions/{id}/description`; tests inject a fake. The gateway persists to shared `session.json` and broadcasts to the browser. For TUI `/tabs` to SHOW titles, **reuse the existing `_td_recentSessions :: IO [(SessionId, Text)]`** (lower blast radius — it already returns titles and is already being switched to `sessionTitle` in §0) rather than adding a new `_td_sessionTitle` seam; `tabRow` resolves each session tab's title from that list.
- **Description length cap (security):** `handleSetDescription` (`API.hs:1247`) clamps the override to a concrete max — **120 chars**, matching the existing `snippetCharBudget` so the override and the default snippet share one bound (the user override is currently unbounded and now displays in more places). The title renders as a React-escaped text child everywhere (no `dangerouslySetInnerHTML`).

### 3. Default (principle 2)

Falls out automatically: a session with no `_sm_description` shows `firstMessageSnippet` (start of the first user message). New tabs stop showing the literal `"session"`. No new mechanism needed — it's already the session default.

### 4. Scope of rename (principle 4)

Rename is **Active-Tabs-only**. Recent Sessions and Archived get **no** rename affordance (the chat-header pencil is on a focused active tab, which is fine). No change to those lists beyond them continuing to show `sessionDisplayTitle`.

### 5. Cross-process sync

A rename in either surface sets `_sm_description` on the shared `session.json` via the gateway's `PUT /description`, which broadcasts the refreshed lists snapshot (read fresh from disk) to all browser clients. The TUI reads the title from the shared session on its next `/tabs`. So: TUI rename → reflected in the web live; web rename → reflected in the TUI on next listing. Both read one shared source.

## Explicitly out of scope

- The tab **registry** split-brain — *which* sessions are open as tabs, their **slots / order / membership** — remains per-process. This change unifies only the **name**. (A separate effort if the user wants full registry sharing / the gateway-as-single-source-of-truth thin-client.)

## Remove the `_tab_name` field (decided)

`_tab_name` is **deleted**, not just bypassed:

- Remove it from the `Tab` record (`Tabs/Types.hs`) and from `tabs.json` serialization (`Persist.hs` `encodeTab`/`parseTab`). **Back-compat:** `parseTab` must tolerate (ignore) a `"name"` key in existing `tabs.json` files so older state loads cleanly; the name now derives from the session, so dropping the stored value is harmless.
- Update all construction/mutation sites that set it (`registryAppend`/`appendTab`/`rebindSlot`/`bindNewTab`/`cmdTabNew`) to no longer take/store a name.
- `/tab rename` (`doRename`) no longer relabels the registry — it re-targets the session description (see §2).
- Remove `_ts_name` from the tab snapshot (`TabsView.hs`) since its only source was `_tab_name`; the frontend derives the label from the session (the snapshot already carries `sessionId`). This is a wire-contract change — update the frontend `TabInfo`/`mapTabInfo` accordingly.
- **Harness tabs:** their name becomes their `SkHarness` session's title via the same shared `sessionTitle` helper (so parity holds for harness rows too). When the session title is empty/unavailable, fall back to the harness flavour / window label (today `_he_label`, surfaced on the snapshot at `API.hs:531`). The fallback is computed by the same path on both surfaces.

**Blast radius (verified by design-review — for the plan to enumerate):** `_tab_name` is constructed at two real sites (`appendTab` `Types.hs:161`; `rebindSlot` `Types.hs:241`) and read at `Persist.hs:194/262`, `Relay.hs:141`, `TabsView.hs:151/167/183`, `TabDispatch.hs:461/675`. `-Wincomplete-record-updates` flags the two updates; `appendTab`/`rebindSlot` lose their `Text` name param (update callers `registryAppend`, `TabDispatch.hs:387`, `bindNewTab`). `_ts_name` removal also touches the harness arm `API.hs:531` and the encoder `TabsView.hs:85`. Tests to rewrite: `Tabs/TypesSpec.hs:199/296/317`, `Routing/TabDispatchSpec.hs` (656/665/678/687/1033/1091), `Frontend/{APISpec,TabsViewSpec}.hs` name assertions, frontend `Sidebar/ActiveTabs/HarnessControls/App` tests that construct `name:`, and `mapTabInfo`/`TabInfo` (`useApi.ts`). Add a `Tabs/PersistSpec.hs` fixture with a legacy `"name"` key to prove `parseTab` ignores it.

## Affected surfaces (from investigation)

- Read/display: `frontend/src/components/ActiveTabs.tsx` (join to session title), `src/PureClaw/Routing/TabDispatch.hs` `tabRow` (TUI `/tabs`), `src/PureClaw/Routing/Relay.hs:141`, death message. (`TabsView.hs` may stay meta-free; the join is client-side — confirm harness snapshots expose `sessionId`.)
- Write: `/tab rename` (`TabDispatch.doRename`) → re-target to the session description via the gateway `PUT /description`; web Active-Tabs rename affordance → same endpoint. The web pencil is unchanged.
- The `firstMessageSnippet` default already exists (`API.hs:1308`); no change.

## Testing (high level)

- Active-Tab label == Recent-Session label for the same session (web): set a description, assert both lists show it; clear it, assert both show the first-message snippet.
- Open a recent session as a tab → label unchanged; close a tab → label unchanged in Recent Sessions.
- `/tab rename` in a TUI process updates the session description (via the gateway endpoint) and the web sidebar reflects it after a broadcast; web rename reflects in the TUI `/tabs`.
- Default name = start of first user message when no override; override sticks.
- No rename affordance reachable for Recent Sessions / Archived.
