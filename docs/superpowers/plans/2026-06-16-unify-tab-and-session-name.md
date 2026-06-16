# Unify Tab Name = Session Name — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the displayed name a single *session* property (custom override → start-of-first-message default), identical in Active Tabs and Recent Sessions and across TUI/web, by removing the per-tab `_tab_name` and deriving every label from the session.

**Architecture:** A shared `PureClaw.Session.Title.sessionTitle` helper backs every Haskell surface (web + TUI) so defaults match. `_tab_name` is deleted; the web derives tab labels by joining tab→session client-side (backend tab projection stays meta-free). `/tab rename` re-targets the session description via an injectable `_td_setSessionDescription` seam wired to the gateway's `PUT /api/sessions/{id}/description`, so renames sync cross-process.

**Tech Stack:** Haskell (GHC 9.12, GHC2021), WAI/Warp, hspec; React/TS frontend (vitest). Nix flake — prefix cabal with `nix develop . --command`.

**Spec:** `docs/superpowers/specs/2026-06-16-unify-tab-and-session-name-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/PureClaw/Session/Title.hs` | Shared `sessionTitle` + `firstMessageSnippet` (moved here) | Create |
| `src/PureClaw/Frontend/API.hs` | Use shared `firstMessageSnippet`/`sessionTitle`; clamp description to 120; drop `_ts_name` harness arm | Modify |
| `src/PureClaw/Tabs/Wiring.hs` | `sessionLabel`/`recentSessions` use `sessionTitle` | Modify |
| `src/PureClaw/Routing/TabDispatch.hs` | `_td_setSessionDescription` seam; `doRename` re-target; `tabRow`/death use session title; drop `_tab_name` reads | Modify |
| `src/PureClaw/Tabs/Types.hs` | Remove `_tab_name` from `Tab`; `appendTab`/`rebindSlot` drop the name param | Modify |
| `src/PureClaw/Tabs/Persist.hs` | Stop writing `"name"`; tolerate legacy `"name"` on read | Modify |
| `src/PureClaw/Tabs/Relay.hs` | Drop `_tab_name` read (use slot or session title) | Modify |
| `src/PureClaw/Frontend/TabsView.hs` | Remove `_ts_name` from `TabSnapshot` + encoder | Modify |
| `src/PureClaw/CLI/Commands.hs` | Wire `_td_setSessionDescription` to a gateway `PUT /description` client | Modify |
| `frontend/src/hooks/useApi.ts` | Drop `name` from `TabInfo`/`mapTabInfo` | Modify |
| `frontend/src/App.tsx` | Centralized `sessionFor` label resolver → ActiveTabs/HarnessControls/deriveAgent | Modify |
| `frontend/src/components/{Sidebar,ActiveTabs,HarnessControls}.tsx` | Thread sessions; render session title; harness/unresolved fallback | Modify |
| `frontend/src/App.css` | Always-visible pencil | Modify |
| tests | per task | Modify/Create |

**Commands:** Build `nix develop . --command cabal build`; test match `nix develop . --command cabal test --test-options="--match \"<pat>\""`; frontend `cd frontend && npx vitest run` + `npx tsc --noEmit`. New spec modules wire into `test/Main.hs` + `pureclaw.cabal`.

---

## Task 1: Shared `sessionTitle` helper

**Files:** Create `src/PureClaw/Session/Title.hs`; Modify `src/PureClaw/Frontend/API.hs`; Test `test/Session/TitleSpec.hs`.

- [ ] **Step 1: Write the failing test** (`test/Session/TitleSpec.hs`)

```haskell
module Session.TitleSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import qualified Data.Text.IO as TIO
import qualified Data.Text as T

import PureClaw.Session.Title (sessionTitle)
import PureClaw.Session.Types  -- for SessionMeta + a constructor/helper
-- (use the same minimal-meta builder existing session specs use; grep test/Session for it)

spec :: Spec
spec = describe "sessionTitle" $ do
  it "uses the description override when set" $
    withSystemTempDirectory "title" $ \dir -> do
      meta <- pure (metaWith dir) { _sm_description = Just "My custom name" }  -- adapt to real builder
      t <- sessionTitle dir meta
      t `shouldBe` "My custom name"

  it "falls back to the first user message snippet when no description" $
    withSystemTempDirectory "title" $ \dir -> do
      let sid = "s-title-1"
      createDirectoryIfMissing True (dir </> sid)
      -- one Request transcript line whose first message text is "hello world from the user"
      TIO.writeFile (dir </> sid </> "transcript.jsonl") firstReqLine
      meta <- pure (metaFor sid dir) { _sm_description = Nothing }
      t <- sessionTitle dir meta
      T.unpack t `shouldContain` "hello world"

  it "falls back to a session-id prefix when there is no transcript and no description" $
    withSystemTempDirectory "title" $ \dir -> do
      meta <- pure (metaFor "abcdef0123456789" dir) { _sm_description = Nothing }
      t <- sessionTitle dir meta
      T.unpack t `shouldSatisfy` (not . null)
```

> Build the `SessionMeta` via whatever helper existing `test/Session/*Spec.hs` / `test/Frontend/APISpec.hs` use (grep `_sm_description = `, `emptyMeta`, `mkMeta`). `firstReqLine` is a single JSON `TranscriptEntry` line with `direction=Request` and a messages payload whose first message text contains "hello world from the user" — copy the shape from an existing transcript fixture (grep `test` for `transcript.jsonl` writers / `_te_payload`).

- [ ] **Step 2: Run, expect FAIL** — `nix develop . --command cabal test --test-options="--match \"sessionTitle\""` (module not found).

- [ ] **Step 3: Create `src/PureClaw/Session/Title.hs`** — MOVE `firstMessageSnippet`, `snippetFromPayload`, `snippetCharBudget`, `trimAndTruncate` verbatim from `Frontend/API.hs` (they currently live around `API.hs:1308-1352`), plus `TranscriptEntry` decoding deps. Add `sessionTitle`:

```haskell
module PureClaw.Session.Title
  ( sessionTitle
  , firstMessageSnippet
  , snippetCharBudget
  ) where

-- imports moved with the functions (Aeson, Data.Text, System.IO, the TranscriptEntry type, SessionMeta)

-- | The canonical displayed title for a session: custom override, else the
-- model summary, else a snippet of the first user message, else the agent
-- name, else a session-id prefix. The single source of truth for BOTH the
-- web and the TUI so defaults are identical (spec §0).
sessionTitle :: FilePath -> SessionMeta -> IO Text
sessionTitle baseDir meta =
  case _sm_description meta of
    Just d | not (T.null (T.strip d)) -> pure d
    _ -> case _sm_autoSummary meta of
      Just s | not (T.null (T.strip s)) -> pure s
      _ -> do
        mSnip <- firstMessageSnippet baseDir meta
        pure $ case mSnip of
          Just s | not (T.null s) -> s
          _ -> fallbackLabel meta

fallbackLabel :: SessionMeta -> Text
fallbackLabel meta =
  case _sm_agent meta of
    Just a  -> agentNameText a            -- confirm the AgentName -> Text accessor
    Nothing -> T.take 12 (unSessionId (_sm_id meta))

-- firstMessageSnippet, snippetFromPayload, snippetCharBudget, trimAndTruncate: moved here verbatim
```

> Verify: `TranscriptEntry` (and `_te_direction`/`_te_payload`) — is it defined in `API.hs` (then move/share it too, or import from its real module) or already a leaf type? grep `data TranscriptEntry`. The shared module must not import `Frontend.API` (no cycle) — move whatever it needs to a leaf. Confirm `_sm_autoSummary`/`_sm_agent`/`_sm_description`/`_sm_id` field names + the `AgentName -> Text` accessor (`unAgentName`?).

In `Frontend/API.hs`: delete the moved definitions; `import PureClaw.Session.Title (firstMessageSnippet, snippetCharBudget)`; the existing `firstMessageSnippet` call sites (`API.hs:1138`, `:1189`) now use the import (unchanged behavior).

- [ ] **Step 4: Register** `PureClaw.Session.Title` in `pureclaw.cabal` `exposed-modules`; `Session.TitleSpec` in test `other-modules` + `test/Main.hs`. Run the test → PASS; full `nix develop . --command cabal build` (-Werror clean — Frontend.API still compiles with the import).

- [ ] **Step 5: Commit**
```bash
git add src/PureClaw/Session/Title.hs src/PureClaw/Frontend/API.hs test/Session/TitleSpec.hs test/Main.hs pureclaw.cabal
git commit -m "feat(session): shared sessionTitle helper (firstMessageSnippet moved to a leaf)"
```

---

## Task 2: TUI title parity (`sessionLabel`/`recentSessions` → `sessionTitle`)

**Files:** Modify `src/PureClaw/Tabs/Wiring.hs`; Test `test/Tabs/WiringSpec.hs`.

`recentSessions` (`Wiring.hs`) currently does `(_sm_id m, sessionLabel m)` where `sessionLabel m = fromMaybe (unSessionId id) _sm_description` — NO snippet. Switch it to the shared `sessionTitle` (IO) so a session with no description shows the first-message snippet, matching the web.

- [ ] **Step 1: Write the failing test** — in `test/Tabs/WiringSpec.hs`, assert `recentSessions env` returns the first-message snippet for a session with no description (seed a session dir + a Request transcript line; reuse the harness the spec already uses to build an `AgentEnv`/sessions dir). Expected (red): it returns the raw session id (current `sessionLabel`).

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — change `recentSessions`:
```haskell
recentSessions :: AgentEnv -> IO [(Core.SessionId, Text)]
recentSessions env = do
  dir   <- sessionsDirOf env
  metas <- Session.listSessions dir Nothing 50
  mapM (\m -> (,) (SessionTypes._sm_id m) <$> Title.sessionTitle dir m) metas
```
Add `import qualified PureClaw.Session.Title as Title`. Delete `sessionLabel` (now unused) OR keep it only if another caller needs it (grep `sessionLabel` — if only `recentSessions` used it, remove it). `recentSessions` is already `IO`, so the change is local.

- [ ] **Step 4: Run the test → PASS; full build.**

- [ ] **Step 5: Commit** — `git commit -am "feat(tui): recentSessions uses shared sessionTitle (snippet parity with web)"`

---

## Task 3: `_td_setSessionDescription` seam + `/tab rename` re-target + gateway wiring + description cap

**Files:** Modify `src/PureClaw/Routing/TabDispatch.hs` (deps + doRename), `src/PureClaw/Tabs/Wiring.hs` (`mkTabDispatchDeps`), `src/PureClaw/CLI/Commands.hs` (production seam), `src/PureClaw/Frontend/API.hs` (clamp); Test `test/Routing/TabDispatchSpec.hs`.

- [ ] **Step 1: Write the failing test** (`test/Routing/TabDispatchSpec.hs`) — using the existing `simpleFakes` harness, wire `_td_setSessionDescription` to a SPY (records `(SessionId, Maybe Text)`); seed a `BoundSession` tab at slot 0; drive `/tab rename 0 newname` (via `handleInbound` or `runTabCommand`); assert the spy recorded `(<that session id>, Just "newname")` and that the registry was NOT relabelled (since `_tab_name` is going away — for THIS task the registry still has `_tab_name`; assert the spy fired). Also assert a sanitize-reject input emits an error and does NOT call the spy.

- [ ] **Step 2: Run, expect FAIL** (no `_td_setSessionDescription`).

- [ ] **Step 3: Implement.**
  - Add to `TabDispatchDeps` (`TabDispatch.hs`): `, _td_setSessionDescription :: !(SessionId -> Maybe Text -> IO (Either Text ()))`.
  - Rewrite `doRename` so that for a `BoundSession` slot it resolves the `SessionId` (via `registryLookupSlot` + `_tab_ref`), runs `Parse.sanitizeTabName name` (TUI-side), and on success calls `_td_setSessionDescription sid (Just clean)`, emitting the result (`Right () -> "renamed /N <clean>"`, `Left err -> err`). Remove the `rebindSlot`-relabel for session tabs. (Harness/raw-shell rename: out of scope here — emit "rename applies to session tabs" or leave as today; pin in self-review.)
  - **Thread the closure as a parameter — do NOT add an `AgentEnv` field** (adding one would break ~41 full `AgentEnv {...}` literals in `test/Agent/SlashCommandsSpec.hs` + `test/Tabs/WiringSpec.hs` under `-Wmissing-fields`). Instead:
    - `mkTabDispatchDeps :: AgentEnv -> ExecDeps -> SessionStore -> (SessionId -> Maybe Text -> IO (Either Text ())) -> TabDispatchDeps` — add the closure param and set `_td_setSessionDescription = <closure>`.
    - `runTabbedLoop :: AgentEnv -> SessionStore -> (SessionId -> Maybe Text -> IO (Either Text ())) -> IO ()` — add the param and pass it to its internal `mkTabDispatchDeps`.
    - Update ALL `mkTabDispatchDeps` call sites (its internal use in `runTabbedLoop`; the web-seam use in `CLI/Commands.hs` from the `_env_runTabCommand` wiring; and `test/Frontend/APISpec.hs`'s `mkRunTabCommandSeam (mkTabDispatchDeps …)` site) and ALL `runTabbedLoop` callers (`CLI/Commands.hs`; `test/Integration/SignalFlowSpec.hs`; `test/Tabs/WiringSpec.hs`) — tests pass a fake/no-op `\_ _ -> pure (Right ())`.
  - **`CLI/Commands.hs` builds the closure per `ServerMode`** (already in scope — the tui-requires-gateway change added it):
    - `ServeFrontend` (gateway process owns the frontend): set the description **in-process** — `\sid mDesc -> do { r <- setDescription sessionsDir sid mDesc; case r of { Right () -> broadcastLists frontendEnv >> pure (Right ()); Left e -> pure (Left (renderSetDescErr e)) } }`. No self-HTTP.
    - `RequireGateway` (tui process): HTTP `PUT http://127.0.0.1:<port>/api/sessions/<sid>/description` body `{"description": <name>}` via the existing `manager` (the one `probeGatewayUp` uses), mapping non-2xx / exceptions to `Left <user message>`. The gateway persists + broadcasts.
    Pass this closure into `runTabbedLoop env tabStore <closure>` and the web-seam `mkTabDispatchDeps … <closure>`.

- [ ] **Step 4: Clamp the description** — in `Frontend/API.hs` `handleSetDescription`, clamp `mDesc` to `snippetCharBudget` (120) chars before `setDescription` (so the override shares the snippet bound). Add a test in `test/Frontend/APISpec.hs`: a 500-char description is stored truncated to ≤120.

- [ ] **Step 5: Run tests → PASS; full build (-Werror clean — NO `AgentEnv` field added, so the SlashCommandsSpec/WiringSpec literals are untouched; only the `mkTabDispatchDeps`/`runTabbedLoop` signatures + their enumerated call sites change).** Commit:
```bash
git add -A src/ test/
git commit -m "feat(tabs): /tab rename re-targets session description via injectable gateway seam; cap description at 120"
```

---

## Task 4: Remove `_tab_name` (backend) + `_ts_name` from the snapshot

**Files:** Modify `src/PureClaw/Tabs/Types.hs`, `Tabs/Persist.hs`, `Tabs/Relay.hs`, `Routing/TabDispatch.hs`, `Frontend/TabsView.hs`, `Frontend/API.hs`; Tests across `test/Tabs/*`, `test/Routing/TabDispatchSpec.hs`, `test/Frontend/{TabsViewSpec,APISpec}.hs`.

Blast radius is enumerated in the spec. Do it as one coherent change (it won't compile half-done).

- [ ] **Step 1: Write/adjust the failing test** — add a `Tabs/PersistSpec.hs` test: a `tabs.json` written with a legacy `"name"` key **loads** (parseTab ignores it) and **re-encodes WITHOUT** `"name"` (round-trip drops it). Expected (red): parse fails or re-encode keeps `name`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement the removal.**
  - `Tabs/Types.hs`: remove `_tab_name` from `Tab`. `appendTab`/`rebindSlot` drop their `Text` name parameter (and stop setting the field). Update callers: `registryAppend`, `bindNewTab` (`TabDispatch.hs:387` and the others) — they no longer pass a name.
  - `Tabs/Persist.hs`: `encodeTab` stops emitting `"name"`; `parseTab` ignores any `"name"` key (use `.:? "name"` and discard, or just don't read it — confirm Aeson tolerates extra keys).
  - `Routing/TabDispatch.hs`: `tabRow` resolves each session tab's title from `_td_recentSessions` (look up the slot's session id in the recents list; fall back to a harness/window label for harness tabs). The deferred-death message (`TabDispatch.hs:675`) uses the resolved title or the slot.
  - `Tabs/Relay.hs:141`: replace `_tab_name <$> lookupSlot` with the slot or the resolved title (it's a display string — use the recents/title lookup or just `/N`).
  - `Frontend/TabsView.hs`: remove `_ts_name` from `TabSnapshot` (and the `"name" .= _ts_name` at `:85`). Remove the harness arm's `_ts_name = _he_label` (`API.hs:531`) and the BoundSession `_ts_name = _tab_name`. Keep `_ts_sessionId`. **Add a harness label fallback field** to the snapshot (e.g. `_ts_label :: Maybe Text` carrying `_he_label`) so the frontend can render a never-blank harness name when its session id is `Nothing` — ids/labels only, no session description (preserves the meta-free boundary).
  - Rewrite the affected Haskell tests (the spec lists them): `Tabs/TypesSpec.hs`, `Routing/TabDispatchSpec.hs`, `Frontend/{TabsViewSpec,APISpec}.hs` — drop `_tab_name`/`_ts_name` assertions; assert titles via the new path where relevant.

- [ ] **Step 4: Run the affected specs + full build (-Werror clean).** Full `nix develop . --command cabal test` green.

- [ ] **Step 5: Commit**
```bash
git add -A src/ test/
git commit -m "refactor(tabs): remove _tab_name and _ts_name; tab labels derive from the session"
```

---

## Task 5: Frontend — derive tab labels from the session (three consumers)

**Files:** Modify `frontend/src/hooks/useApi.ts`, `frontend/src/App.tsx`, `frontend/src/components/{Sidebar,ActiveTabs,HarnessControls}.tsx`; Test `frontend/src/components/__tests__/*` + `App` test.

- [ ] **Step 1: Read** how `deriveAgent` (`App.tsx:1206-1217`) and `HarnessControls` already join `tab.session_id`→`sessions`/`archivedSessions`; mirror that. Note `ActiveTabs` does NOT receive `sessions` today (`Sidebar.tsx:251`).

- [ ] **Step 2: Write the failing test** — vitest: render `ActiveTabs` for a tab whose `session_id` matches a session with `description: "Custom"` → row shows "Custom"; a tab whose session has no description but a `firstMessageSnippet` → shows the snippet; a tab whose session is missing/`session_id` null (harness) → shows the harness label fallback, never blank. (Use the existing ActiveTabs test harness; it currently passes `name:` — change to pass `sessions` + a tab with `session_id`.)

- [ ] **Step 3: Implement.**
  - `useApi.ts`: remove `name` from `TabInfo` and from `mapTabInfo`/`TabInfoWire`; add `label?: string` (the harness fallback from `_ts_label`) if not already present.
  - `App.tsx`: add a `sessionFor = (id?: string) => sessions.find(...) ?? archivedSessions.find(...)` resolver and a `tabLabel(tab) = tab.session_id ? sessionDisplayTitle(sessionFor(tab.session_id)) : (tab.label ?? '…')` (never blank). Use it in `deriveAgent` (replace `name: tab.name`) and pass `sessions`/the resolver down.
  - `Sidebar.tsx`: pass `sessions` (and archived) to `ActiveTabs`.
  - `ActiveTabs.tsx:122`: render `tabLabel(tab)` (via the resolver prop) instead of `{tab.name}`.
  - `HarnessControls.tsx:82`: use the same resolver instead of `tab.name`.

- [ ] **Step 4: Run** `cd frontend && npx vitest run` (green) + `npx tsc --noEmit` (clean — no remaining `tab.name` refs; grep `\.name` on tab objects).

- [ ] **Step 5: Commit** — `git add -A frontend/ && git commit -m "feat(frontend): tab labels derive from the session title (centralized join)"`

---

## Task 6: Always-visible rename pencil

**Files:** Modify `frontend/src/App.css` (the `.editable-title-pencil` rules).

- [ ] **Step 1: Locate** the pencil CSS — `grep -n "editable-title" frontend/src/App.css`. It currently sets the pencil `opacity: 0` and only reveals it (`opacity: 1` / accent color) on `.editable-title:hover`.

- [ ] **Step 2: Implement** — base `.editable-title-pencil { opacity: 1; color: var(--text-faint); }` (always visible, muted), and `.editable-title:hover .editable-title-pencil { color: var(--accent-primary); }` (brighten on hover). No JSX change (`ChatArea.tsx` already always renders the pencil; it was hidden by CSS).

- [ ] **Step 3: Verify** — build the frontend (`cd frontend && npm run build`), run the app via the `run`/`visual-review` skill or manually; confirm the pencil is visible at rest on the focused chat header and not visually noisy. (If a vitest/RTL assertion on computed style is feasible, add one; otherwise this is a visual change — note it.)

- [ ] **Step 4: Commit** — `git add frontend/src/App.css && git commit -m "feat(frontend-ui): make the rename pencil always visible for discoverability"`

---

## Task 7: Cross-surface parity tests + verification + coverage

**Files:** Test `frontend/src/hooks/__tests__/` or an App-level test; `test/Frontend/APISpec.hs`.

- [ ] **Step 1: Web parity test (vitest)** — given one session, the Active-Tab label and the Recent-Session label are the SAME string: set a description → both show it; clear it → both show the first-message snippet (both call `sessionDisplayTitle` over the same `SessionInfo`). Assert string equality (not pixel).

- [ ] **Step 2: Persistence-transition test** — open a recent session as a tab → its label is unchanged; close a tab → it appears in Recent Sessions with the same label. (Hook/component level; assert the resolver yields the same string before/after the membership change since it keys off the session.)

- [ ] **Step 3: Backend rename round-trip** — APISpec: `PUT /api/sessions/{sid}/description {"description":"X"}` → `broadcastLists` payload's tab snapshot for that session carries `sessionId` and the session list shows `description=X`; (the label join is client-side, so assert the session-list description + that the tab snapshot exposes the matching `sessionId`). The TUI seam (`_td_setSessionDescription`) is covered by Task 3's spy.

- [ ] **Step 4: No-rename-in-Recent/Archived** — confirm (frontend) there is no rename affordance wired on Recent Sessions / Archived rows (grep the components; assert the edit affordance only exists on the chat-header / focused tab).

- [ ] **Step 5: Full verification** — `nix develop . --command bash -c "cabal clean && cabal build"` (-Werror) + `cabal test` (green); `cd frontend && npx vitest run && npx tsc --noEmit && npm run build`. Coverage: `nix develop . --command cabal test --enable-coverage` — the new `Session.Title` module and the `tabRow` title path must meet 95% (`.coverage-thresholds.json`); `TabDispatch` is NOT waived, so the new `doRename`/seam branches need fake-injected success+error tests.

- [ ] **Step 6: Commit + push** — `git add -A && git commit -m "test(tabs): cross-surface name parity + rename round-trip" && git push`

---

## Resolved during planning (verified by review)

- `TranscriptEntry` is already a leaf type in `PureClaw.Transcript.Types` (NOT in `API.hs`) — so moving `firstMessageSnippet` into `Session.Title` has **no import cycle**. `Session.Title` imports `Transcript.Types` + `Session.Types` + Aeson/Text/System.IO.
- The `AgentName -> Text` accessor is `unAgentName`; `_sm_autoSummary`/`_sm_description`/`_sm_agent`/`_sm_id` are the real `SessionMeta` field names.
- `sessionLabel` (Wiring.hs) has exactly ONE caller (`recentSessions`) — safe to delete in Task 2.
- `Parse.sanitizeTabName :: Text -> Either NameError Text` exists (Task 3).
- `test/Tabs/PersistSpec.hs` ALREADY EXISTS — Task 4 Step 1 ADDS a test to it (not "create"). Note `parseTab` currently uses `o .: "name"` (a REQUIRED key) — it MUST switch to `.:?`/ignore, else even the project's own new files (which stop writing "name") fail to parse.

## Open verification items (resolve during implementation)

- Harness rename behavior (out of scope here — emit a clear "rename applies to session tabs" message) — Task 3.
- `_td_recentSessions` is capped at the 50 most-recent sessions (`listSessions dir Nothing 50`). A tab bound to an older session won't be found in the recents list → `tabRow` falls back to the slot/harness label (never blank), which is acceptable; if exact titles for old open tabs matter, widen the cap or do a point lookup — note in Task 4 self-review.
- Exact pencil CSS line numbers (`App.css:607-615`) — Task 6.
- Coverage: `Session.Title` + the new `tabRow`/`doRename`/seam branches in `TabDispatch` are NOT waived (95%); cover the seam success+error arms with fakes — Task 7.
