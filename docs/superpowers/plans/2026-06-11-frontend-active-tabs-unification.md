# Frontend Active-Tabs Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **All Haskell**: load `.claude/skills/haskell/haskell-coder/SKILL.md` first; `-Wall -Werror`, hlint clean, TDD (commit the failing test separately). Build/test via `nix develop . --command cabal build|test`. Tree is green at PR #80 head.

**Goal:** Make the frontend "Active Tabs" sidebar reflect the backend `TabRegistry` as the single source of truth, bidirectional with chat/CLI: chat/CLI tabs appear in the frontend, their sessions leave "Recent Sessions", and frontend-created sessions become chat-switchable tabs; tabs persist across restart.

**Architecture:** Same process -> the frontend reads the shared `_env_tabRegistry` IORef. A pure `tabSnapshotsFromRegistry` (new `Frontend/TabsView.hs`) projects the `TabList` into the existing `lists` WebSocket frame. A `_env_onTabsChanged :: IO ()` callback (set by `Commands.hs` to `saveTabs` + `broadcastLists`) fires on every registry mutation. Frontend tab endpoints resolve the index against the registry and drive `registryAppend`/`registryRemove`. `tabs.json` wired for persistence.

**Tech Stack:** Haskell (GHC 9.12, GHC2021, Handle/injected-seam pattern, Aeson, hspec), React/TypeScript (vitest), Nix.

**Spec:** `docs/superpowers/specs/2026-06-11-frontend-active-tabs-unification-design.md` (design-review-gate APPROVED 5/5).

**Sequencing / dependencies:** WU1->WU2 (validator+loader) · WU3 (pure projection) · WU4 (notify seam) · WU5 (persistence) · WU6 (read wiring, needs WU3) · WU7 (write path, needs WU6) · WU8 (Commands wiring, needs WU4/5/6/7) · WU9 (React, needs WU7) · WU10 (gate). Each WU is independently RED-GREEN and commits on its own. (Note: this plan's "WU9" is the React unit; it is unrelated to the spec's deferred "WU9 harness-death" — that work is NOT in this plan.)

---

## WU1 — Strict canonical `isValidSessionId` in `Core.Types`

**Files:** Modify `src/PureClaw/Core/Types.hs` (add + export); delete the local copies and import Core's in `src/PureClaw/Agent/SlashCommands.hs`, `src/PureClaw/Frontend/API.hs` (**keep it in API's export list** — `Frontend/Stream.hs:97,594` and `test/Frontend/StreamSpec.hs` import it from `Frontend.API`), `src/PureClaw/Session/Handle.hs` (`isValidBranchSourceId`). New test `test/Core/SessionIdValidatorSpec.hs` (register in `test/Main.hs` + `pureclaw.cabal`).

- [ ] **Step 1: RED** — `test/Core/SessionIdValidatorSpec.hs` (module `Core.SessionIdValidatorSpec`): assert accepts `"20260610-122113-257"`, `"agent_run-01"`; rejects `""`, `".hidden"` (leading dot), `"../etc"`, `"a/b"`, `"a\x00b"`, `"a\\b"`, `"a:b"`, `"a.b"`; and the round-trip `isValidSessionId (ST.unSessionId (ST.newSessionId Nothing t))` is `True`.
- [ ] **Step 2: Run -> FAIL**: `nix develop . --command cabal test --match "isValidSessionId" 2>&1 | tail -20`.
- [ ] **Step 3: GREEN** — in `Core.Types` add to exports + define (qualify chars: `Data.Char qualified as C`; `Data.Text qualified as T`):
```haskell
isValidSessionId :: Text -> Bool
isValidSessionId t = not (T.null t) && T.head t /= '.' && T.all ok t
  where ok c = C.isAsciiLower c || C.isAsciiUpper c || C.isDigit c || c == '_' || c == '-'
```
- [ ] **Step 4:** Delete the 3 local copies; import Core's. `Frontend.API` re-exports it (keep in export list). `Session/Handle.resolveBranchSeed` keeps its `BranchInvalidSourceId` error but uses the strict predicate. Build `-Werror` to find every call site.
- [ ] **Step 5:** Register the spec. Run -> PASS; full suite green.
- [ ] **Step 6: Commit** `feat(tabs-fe): one strict isValidSessionId in Core.Types (#80)`

---

## WU2 — Loader safety: validate ids in `resumeSession`

**Files:** Modify `src/PureClaw/Session/Handle.hs` (`resumeSession` guards the id -> a `ResumeInvalidId` constructor). Verify `Tabs/Wiring.hs:openSessionFromDisk` already logs + safe-fallbacks on `Left` (apv fix). Test: `test/Session/HandleSpec.hs`.

- [ ] **Step 1: RED** — assert the SPECIFIC new error so it's truly red (a missing path already returns `Left ResumeMissingMetadata`, which would pass a bare `Left _`):
```haskell
it "resumeSession rejects a traversal id with ResumeInvalidId (no filesystem touch)" $
  withSystemTempDirectory "pc-resume" $ \dir -> do
    r <- resumeSession Nothing mkNoOpLogHandle dir (parseSessionId "../etc")
    r `shouldSatisfy` isResumeInvalidId    -- a helper matching the new ctor
```
- [ ] **Step 2: Run -> FAIL** (no `ResumeInvalidId` ctor).
- [ ] **Step 3: GREEN** — add `ResumeInvalidId` to `ResumeError` (+ Show); at the top of `resumeSession`, `if not (isValidSessionId (unSessionId sid)) then pure (Left ResumeInvalidId) else ...`.
- [ ] **Step 4:** Run -> PASS; suite green.
- [ ] **Step 5: Commit** `fix(tabs-fe): resumeSession validates the id (safe-by-construction) (#80)`

---

## WU3 — `Frontend/TabsView.hs`: pure projection (95%-gated logic)

**Files:** Create `src/PureClaw/Frontend/TabsView.hs` — **relocate** `TabSnapshot` (+ `ToJSON`), `livenessToTabStatus`, `harnessOriginToText` here from `Frontend/API.hs`; add the pure projection. Modify `Frontend/API.hs` to `import Frontend.TabsView` and **re-export** those names (existing call sites/`harnessEntriesToTabs`/tests reference them via `API`). Add the module to `pureclaw.cabal`. New test `test/Frontend/TabsViewSpec.hs` (register).

- [ ] **Step 1: Relocate** the three items into `TabsView.hs` (identical field names/JSON keys); `Frontend.API` imports + re-exports them. Build green (no behavior change; `harnessEntriesToTabs` still compiles).
- [ ] **Step 2: RED** — `test/Frontend/TabsViewSpec.hs` covers the branch matrix with injected lookups (no IO): `BoundSession` present-meta -> kind `"provider"`, status `"idle"` (NOT `"running"`), `_ts_origin ""`; `BoundSession` missing-meta -> provider/idle fallback (no crash); `Dead BoundSession` -> `"exited"`; `BoundHarness` live -> status from liveness + origin + attach command; `BoundHarness` vanished entry -> `"exited"`, `stale=True`; and a **no-secret-leak** assertion (projected snapshot exposes only label/status/kind/sid — none of `_sm_source`/`channelUserId`/creds).
- [ ] **Step 3: Run -> FAIL** (`tabSnapshotsFromRegistry` undefined).
- [ ] **Step 4: GREEN** — add the pure function:
```haskell
tabSnapshotsFromRegistry
  :: TabList
  -> (Core.SessionId -> Maybe SessionTypes.SessionMeta)
  -> (Registry.HarnessId -> Maybe Registry.HarnessEntry)
  -> [TabSnapshot]
```
Per `Tab` (`Tabs.toList`): `BoundSession sid` -> index `unTabIndex _tab_slot`, kind `"provider"`, name `_tab_name`, status (`Live`->`"idle"`, `Dead`->`"exited"`), sessionId `Just (unSessionId sid)`, origin `""`, attach `Nothing`, ext/stale `False`. `BoundHarness hid` with `harnOf hid = Just e` -> kind `"harness"`, status `livenessToTabStatus (_he_liveness e)`, origin `harnessOriginTotext (_he_origin e)`, **attach command computed as `Just ("tmux attach -t " <> _he_session e <> ":" <> _he_windowName e)`** (mirror the existing `Frontend/API.hs` builder — there is NO `_he_attachCommand` accessor), sessionId `_he_sessionId e`, extModified `_he_extModified e`, stale `_he_stale e`, name `_tab_name` (fall back to `_he_label e`); `Nothing` (vanished) -> kind `"harness"`, status `"exited"`, stale `True`, rest defaults. (Verify every `_he_*` accessor against `src/PureClaw/Harness/Registry.hs`.)
- [ ] **Step 5:** Run -> PASS; register spec; suite green; `-Werror` clean.
- [ ] **Step 6: Commit** `feat(tabs-fe): pure tabSnapshotsFromRegistry in Frontend/TabsView (#80)`

---

## WU4 — `_env_onTabsChanged` notify seam

**Files:** `src/PureClaw/Agent/Env.hs` (add `_env_onTabsChanged :: IO ()` to `AgentEnv` + a `TabSubsystem` field, default `pure ()`; **fix ALL `AgentEnv` construction sites** — `-Werror -Wmissing-fields` enumerates them: `Commands.hs` + ~7 test files incl. `SlashCommandsSpec`/`WiringSpec`/`DelegateSpec`/`SignalFlowSpec`/`BackgroundSpec`/`StartSpec`/`DepthLimitSpec`). `src/PureClaw/Routing/TabDispatch.hs` (`_td_onTabsChanged :: IO ()` in `TabDispatchDeps`; call after `cmdNt`/`cmdNew`/`cmdClose`/`cmdRename`/wizard-bind). `src/PureClaw/Tabs/Wiring.hs` (`mkTabDispatchDeps` sets `_td_onTabsChanged = _env_onTabsChanged env`). Test: `test/Routing/TabDispatchSpec.hs`.

- [ ] **Step 1: RED** — extend the fake-deps harness with `f_tabsChanged :: IORef Int` wired to `_td_onTabsChanged = modifyIORef' f_tabsChanged (+1)`; assert fires once on `/nt`, once on `/close`, and 0 on a no-op (`/tabs`).
- [ ] **Step 2: Run -> FAIL**.
- [ ] **Step 3: GREEN** — add fields; call `_td_onTabsChanged (_ctx_deps ctx)` at the end of each mutating command (factor `notifyChanged ctx`). Add `_env_onTabsChanged` (default `pure ()`) to `AgentEnv`/`newTabSubsystem`; fix every construction site; wire `mkTabDispatchDeps`.
- [ ] **Step 4:** Run -> PASS; suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): _env_onTabsChanged notify seam on registry mutation (#80)`

---

## WU5 — Persistence: `_pd_sessionExists` + strict `parseRef` + reconcile drop

**Decode model (VERIFIED — do not restructure):** `loadTabs` uses `eitherDecodeStrict'` over `FromJSON PersistedState` = `traverse parseTab`, so **any** `parseRef`/`parseTab` `fail` discards the WHOLE `tabs.json` and boots **fresh** (the existing `freshOn "a non-UUID harnessId"` test proves this). Per-tab survivorship is ONLY in `reconcileTabs` (filters the decoded list). So the strict `parseRef` guard is **fresh-on-invalid** (still safe: an invalid/traversal id never becomes a `TabRef`, so never reaches a path-join). Do NOT change the `freshOn` test.

**Files:** `src/PureClaw/Tabs/Persist.hs` (`PersistDeps._pd_sessionExists :: SessionId -> IO Bool`; `parseRef` rejects invalid `SessionId`; `reconcileTabs.keepTab` drops a `BoundSession` failing `_pd_sessionExists`). Test: `test/Tabs/PersistSpec.hs` (drive via `loadTabs` — no new exports).

- [ ] **Step 1: RED** —
```
it "reconcile drops a BoundSession whose session.json is absent, keeps an existing one"
  -- decode succeeds (valid ids); _pd_sessionExists True for s1, False for s2 -> tabs has s1, not s2
it "loadTabs boots FRESH when tabs.json has a traversal/leading-dot session id"
  -- tabs.json with a BoundSession id "../etc" + a valid sibling -> (emptyTabs, emptyCursors)
it "reconcile drops a dead-harness tab (existing behavior preserved)"
```
- [ ] **Step 2: Run -> FAIL** (no `_pd_sessionExists`; parseRef lacks the guard).
- [ ] **Step 3: GREEN** — add `_pd_sessionExists :: SessionId -> IO Bool` to `PersistDeps`; `reconcileTabs.keepTab`: `BoundSession sid -> _pd_sessionExists deps sid`; `parseRef`: after decoding `BoundSession sid`, `if isValidSessionId (unSessionId sid) then pure (BoundSession sid) else fail "invalid session id"` (mirrors the invalid-`HarnessId` `fail`). Update every `PersistDeps` construction with the new field.
- [ ] **Step 4:** Run -> PASS; suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): persistence _pd_sessionExists + strict parseRef guard (#80)`

---

## WU6 — Read wiring: `FrontendEnv` (+ shared `Exec`) + lists projection + exclusion

**Files:** `src/PureClaw/Frontend/API.hs` — add `_fe_tabRegistry :: TabRegistry`, `_fe_cursors :: IORef CursorState`, **and `_fe_exec :: Exec`** to `FrontendEnv` (the close path in WU7 needs `Exec.release`; `FrontendEnv` has no exec today and `Frontend.API` does not import `Tabs.Exec` — add the import). Replace `_fe_listTabs` with the IO wrapper -> `tabSnapshotsFromRegistry`; `computeListsSnapshot` recentSessions AND archived exclusion read registry-derived `tabs`. Update every `FrontendEnv` construction site (tests) for the 3 new fields. Test: `test/Frontend/APISpec.hs`.

- [ ] **Step 1: RED** — a `BoundSession` tab in the registry appears in `tabs` and its sid is excluded from BOTH `recentSessions` and `archivedSessions`; a harness-tab session stays dual-listed in recent.
- [ ] **Step 2: Run -> FAIL**.
- [ ] **Step 3: GREEN** — add the 3 fields; `_fe_listTabs = do { tl <- readTabs (_fe_tabRegistry env); metas <- listSessions (_fe_sessionsDir env) Nothing big; entries <- Registry.snapshot (_fe_harnessRegistry env); pure (tabSnapshotsFromRegistry tl (lookupMeta metas) (lookupEntry entries)) }`. In `computeListsSnapshot`, derive `activeTabSids` from the new `tabs` and subtract them from the **archived** filter too.
- [ ] **Step 4:** Run -> PASS; suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): lists frame projects from the TabRegistry; tab-bound sids leave recent+archived (#80)`

---

## WU7 — Write path: registry-resolved actions + create + cap

**Files:** `src/PureClaw/Frontend/API.hs`. Test: `test/Frontend/APISpec.hs` (~14 `_fe_tabCount` assertions -> `readTabs` length). **Note:** WU1 already tightened the live HTTP/WS resume surfaces (`API.hs:1362/1779/1845`, `Stream.hs:594`) from the weak guard to the strict one — an intentional tightening (real `newSessionId` ids pass; covered by WU1's round-trip test), not a regression.

- [ ] **Step 1: RED** — `handleNewTab` (provider) appends a `BoundSession` and returns its slot/sid; `close` resolves the registry slot and removes any-kind tab; `dismiss` on a `BoundSession` tab -> 4xx `{"error":"not a harness tab"}`; create beyond `_fe_maxTabs` -> the cap 4xx (no append).
- [ ] **Step 2: Run -> FAIL**.
- [ ] **Step 3: GREEN** —
  - `resolveRegistrySlot :: FrontendEnv -> Int -> IO (Maybe (TabIndex, TabRef))` via `readTabs` (replaces `tabIndexToEntry`/`withResolvedTab` for tab actions).
  - `handleNewTab`: provider -> mint + `registryAppend (BoundSession sid)`; harness -> spawn then `registryAppend (BoundHarness hid)` after the deferred-success point. (Raw-shell arm left as-is/deferred; affordance hidden in WU9 so it isn't hit.)
  - `close` -> `registryRemove`; for `BoundSession` also `release (_fe_exec env) ref` (stop the runtime — the SessionStore is `runTabbedLoop`-local + benign-if-stale, NOT evicted). `dismiss`/`release`/`destroy`/`acknowledge`: resolve ref; `BoundHarness` -> existing harness teardown; else `{"error":"not a harness tab"}` 4xx.
  - cap: `n <- length <$> readTabs ...`; if `n >= _fe_maxTabs env` return the cap 4xx before append. Remove the `_fe_tabCount` IORef + its reads/writes; replace its `APISpec` assertions with `readTabs`-length checks.
  - call `_env_onTabsChanged` after each mutation.
- [ ] **Step 4:** Run -> PASS; suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): frontend tab endpoints drive the registry (create/close/cap) (#80)`

---

## WU8 — `CLI/Commands.hs` wiring + boot reconcile + integration

**Files:** `src/PureClaw/CLI/Commands.hs` — set `_fe_tabRegistry`/`_fe_cursors`/`_fe_exec` from the shared subsystem (`_ts_tabRegistry`/`_ts_cursors`/`_ts_exec tabSub`); `_env_onTabsChanged = (saveTabs stateDir <$> readTabs reg <*> readIORef cursors) >> broadcastLists frontendEnv`; `loadTabs`+reconcile after the synchronous `bootReconstruct` (strictly before `Async.withAsync runFrontend`), seed `_ts_tabRegistry`/`_ts_cursors` before server start; `PersistDeps { _pd_stateDir = pureclawDir </> "state", _pd_harnessLive = …, _pd_discoveryReady = pure (), _pd_sessionExists = \sid -> doesFileExist (sessionsDir </> unSessionId sid </> "session.json") }`. Test: a focused integration spec.

- [ ] **Step 1: RED (integration)** — build the shared env+frontendEnv; run a `/nt` and assert a broadcast `lists` snapshot contains the new tab and excludes its sid from recent; **dual-write consistency**: a frontend `handleNewTab (BoundSession)` then `registryLookupSlot` for that slot equals the created ref (the same ref chat `/N` resolves).
- [ ] **Step 2: Run -> FAIL**.
- [ ] **Step 3: GREEN** — wire as above.
- [ ] **Step 4:** Run -> PASS; full suite green; `-Werror` clean; `hlint src test app`.
- [ ] **Step 5: Commit** `feat(tabs-fe): wire registry<->frontend in Commands + boot persistence (#80)`

---

## WU9 (React) — slot-exhaustion surfacing + raw-shell affordance + render check

**Files:** `frontend/src/App.tsx` (the inline `fetch('/api/tabs/new')` in `handleComposerSend`: on `!res.ok`, `await res.json()` and set a composer error state rendered via the existing `role="alert"` block — generalize `attachError`->`composerError` or add `createError`). Any remaining raw-shell create affordance (NOTE: the top-level "Raw Shell" radio is ALREADY removed — `NewTabComposer.test.tsx` asserts this; only hide a still-present backend-selector raw-shell option, if any). Tests: vitest under `frontend/src`.

- [ ] **Step 1: RED (vitest)** — mock `/api/tabs/new` -> 409 `{"error":"maximum tab count reached"}`; assert the composer renders an actionable message (not a silent no-op). Render test: a `TabInfo` `{kind:"provider", status:"idle", origin:""}` renders under "Active Tabs", shows the muted `○` (no green dot), and only Archive + Close controls.
- [ ] **Step 2: Run -> FAIL**: `cd frontend && npm test -- --run`.
- [ ] **Step 3: GREEN** — read the 4xx body and surface it; hide any remaining raw-shell create option. (No new guard code for harness-only controls — they self-suppress for provider/idle/origin-"" tabs; the render test asserts that.)
- [ ] **Step 4:** Run -> PASS; `cd frontend && npm run build` (typecheck) clean.
- [ ] **Step 5: Commit** `feat(tabs-fe): surface slot-exhaustion, hide raw-shell affordance (#80)`

---

## WU10 — Coverage + final gate + self-reflect

- [ ] **Step 1: Coverage** — `cabal test --enable-coverage`; `PureClaw.Frontend.TabsView` >=95% (pure branch matrix; NO waiver). If the thin IO wrapper in `Frontend.API` dips the (non-waived) module, lean on WU8's integration (`broadcastLists -> _fe_listTabs -> wrapper`) or add a one-line justified note.
- [ ] **Step 2: Full gate** — `cabal build` `-Werror` clean; `cabal test` green; `hlint src test app` -> No hints; `cd frontend && npm test --run && npm run build`.
- [ ] **Step 3: `/self-reflect`** — capture learnings (dual-source-of-truth unification); commit KB updates.
- [ ] **Step 4: Commit** any threshold updates `chore(tabs-fe): coverage gate + final cleanup (#80)`; push to `origin/feat/tabs-as-view-refactor` (updates PR #80).

---

## Self-review (author checklist — done)
- **Spec coverage:** every Components-table row -> a WU (Core.Types->WU1; loader->WU2; TabsView->WU3; notify->WU4; Persist->WU5; API read+`_fe_exec`->WU6; API write->WU7; Commands->WU8; React->WU9; gate->WU10). Edge cases (idle status, archived exclusion, closed-focused cursor, slot-exhaustion, traversal guard, reconcile drop, runtime-release-on-close, dual-write, no-secret-leak) each have a test.
- **Decode model corrected** (WU5 fresh-on-invalid, not per-tab drop). **`_fe_exec` field added** (WU6) so WU7's runtime-release compiles. **`isValidSessionId` re-exported** from `Frontend.API` (Stream consumers). **attachCommand** computed from `_he_session`/`_he_windowName`.
- **Deferred (out of scope, per spec):** raw-shell `BoundShell`, frontend rename, spec-WU9 harness-death notified removal, transcript-fd-leak follow-up.
