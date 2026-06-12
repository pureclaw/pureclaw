# Frontend Active-Tabs Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. **All Haskell**: load `.claude/skills/haskell/haskell-coder/SKILL.md` first; `-Wall -Werror`, hlint clean, TDD (commit the failing test separately). Build/test via `nix develop . --command cabal build|test`. The tree is currently green at PR #80 head.

**Goal:** Make the frontend "Active Tabs" sidebar reflect the backend `TabRegistry` as the single source of truth, bidirectional with chat/CLI: chat/CLI tabs appear in the frontend, their sessions leave "Recent Sessions", and frontend-created sessions become chat-switchable tabs; tabs persist across restart.

**Architecture:** Same process → the frontend reads the shared `_env_tabRegistry` IORef. A new **pure** `tabSnapshotsFromRegistry` (in `Frontend/TabsView.hs`) projects the `TabList` into the existing `lists` WebSocket frame. A `_env_onTabsChanged :: IO ()` callback (set by `Commands.hs` to `saveTabs` + `broadcastLists`) fires on every registry mutation. Frontend tab endpoints resolve the index against the registry and drive `registryAppend`/`registryRemove`. `tabs.json` is wired for persistence.

**Tech Stack:** Haskell (GHC 9.12, GHC2021, Handle/injected-seam pattern, Aeson, hspec), React/TypeScript (vitest), Nix.

**Spec:** `docs/superpowers/specs/2026-06-11-frontend-active-tabs-unification-design.md` (design-review-gate APPROVED 5/5).

**Sequencing / dependencies:** WU1→WU2 (validator+loader) · WU3 (pure projection) · WU4 (notify seam) · WU5 (persistence) · WU6 (read wiring, needs WU3) · WU7 (write path, needs WU6) · WU8 (Commands wiring, needs WU4/5/6/7) · WU9 (React, needs WU7) · WU10 (gate). Each WU is independently RED-GREEN and commits on its own.

---

## WU1 — Strict canonical `isValidSessionId` in `Core.Types`

**Files:**
- Modify: `src/PureClaw/Core/Types.hs` (add the predicate + export)
- Modify: `src/PureClaw/Agent/SlashCommands.hs` (delete local copy, import Core's)
- Modify: `src/PureClaw/Frontend/API.hs` (delete weak `isValidSessionId`, import Core's)
- Modify: `src/PureClaw/Session/Handle.hs` (delete weak `isValidBranchSourceId`, route callers to Core's)
- Test: `test/Core/SessionIdValidatorSpec.hs` (new) — register in `test/Main.hs` + `pureclaw.cabal`

- [ ] **Step 1: RED test** — `test/Core/SessionIdValidatorSpec.hs`, module `Core.SessionIdValidatorSpec`, `spec :: Spec`:

```haskell
module Core.SessionIdValidatorSpec (spec) where

import PureClaw.Core.Types (isValidSessionId)
import PureClaw.Session.Types qualified as ST
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

spec :: Spec
spec = describe "isValidSessionId (strict canonical)" $ do
  it "accepts a normal session id" $
    isValidSessionId "20260610-122113-257" `shouldBe` True
  it "accepts underscores and hyphens" $
    isValidSessionId "agent_run-01" `shouldBe` True
  it "rejects empty" $ isValidSessionId "" `shouldBe` False
  it "rejects a leading dot" $ isValidSessionId ".hidden" `shouldBe` False
  it "rejects .. traversal" $ isValidSessionId "../etc" `shouldBe` False
  it "rejects a slash" $ isValidSessionId "a/b" `shouldBe` False
  it "rejects a NUL/control char" $ isValidSessionId "a\x00b" `shouldBe` False
  it "rejects a backslash / colon / dot" $ do
    isValidSessionId "a\\b" `shouldBe` False
    isValidSessionId "a:b" `shouldBe` False
    isValidSessionId "a.b" `shouldBe` False
  it "round-trips every minted id (format must stay within the charset)" $
    let t = UTCTime (fromGregorian 2026 6 11) (secondsToDiffTime 45296)
    in isValidSessionId (ST.unSessionId (ST.newSessionId Nothing t)) `shouldBe` True
```

- [ ] **Step 2: Run → FAIL** (`isValidSessionId` not in `Core.Types`):
  `nix develop . --command cabal test --match "isValidSessionId" 2>&1 | tail -20`

- [ ] **Step 3: GREEN** — in `src/PureClaw/Core/Types.hs` add to the export list `isValidSessionId` and define (mirror the strict `Agent/SlashCommands.hs` copy; note it also rejects `.`-containing ids since `.` ∉ charset, which covers `a.b` and leading-dot):

```haskell
-- | The one strict session-id predicate. Path-traversal-safe: a valid id is a
-- nonempty string over [a-zA-Z0-9_-] with no leading dot. Used at every boundary
-- where an id is path-joined (parseRef, resumeSession, openSessionFromDisk) and at
-- the HTTP/WS surfaces. Single source of truth — do NOT re-define elsewhere.
isValidSessionId :: Text -> Bool
isValidSessionId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all ok t
  where ok c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_' || c == '-'
```
(Ensure `Data.Char (isAsciiLower, isAsciiUpper, isDigit)` and `Data.Text qualified as T` are imported in `Core.Types`.)

- [ ] **Step 4: Refactor the three copies onto it.** In `Agent/SlashCommands.hs`, `Frontend/API.hs`, and `Session/Handle.hs`: delete the local `isValidSessionId`/`isValidBranchSourceId` definitions and import `isValidSessionId` from `PureClaw.Core.Types`; point every caller (`resolveBranchSeed` in `Session/Handle.hs` keeps its `BranchInvalidSourceId` error but now uses the strict predicate) at it. Build to find every call site (`-Werror` will flag the now-unused imports / missing names).

- [ ] **Step 5: Register** `Core.SessionIdValidatorSpec` in `test/Main.hs` + `pureclaw.cabal`.

- [ ] **Step 6: Run → PASS** + full suite green: `nix develop . --command cabal test 2>&1 | tail -6`. Build `-Werror` clean.

- [ ] **Step 7: Commit**
```bash
git add -A && git commit -m "feat(tabs-fe): one strict isValidSessionId in Core.Types (#80)"
```

---

## WU2 — Loader safety: validate ids in `resumeSession`/`openSessionFromDisk`

**Files:**
- Modify: `src/PureClaw/Session/Handle.hs` (`resumeSession` rejects invalid id → existing `ResumeError`; add a `ResumeInvalidId` constructor if none fits)
- Modify: `src/PureClaw/Tabs/Wiring.hs` (`openSessionFromDisk` already has a `Left`-fallback that logs; no change needed if it routes through `resumeSession` — verify; if it builds a handle directly, add the guard there too)
- Test: `test/Session/HandleSpec.hs` (extend) or `test/Tabs/WiringSpec.hs`

- [ ] **Step 1: RED** — add to `test/Session/HandleSpec.hs`:
```haskell
it "resumeSession rejects a traversal session id without touching the filesystem" $
  withSystemTempDirectory "pc-resume" $ \dir -> do
    r <- resumeSession Nothing mkNoOpLogHandle dir (parseSessionId "../etc")
    case r of
      Left _  -> pure ()                       -- rejected (any ResumeError)
      Right _ -> expectationFailure "expected Left for a traversal id"
```
- [ ] **Step 2: Run → FAIL** (currently path-joins + likely `ResumeMissingMetadata` only by accident, or opens): `cabal test --match "traversal session id"`.
- [ ] **Step 3: GREEN** — at the top of `resumeSession`, guard: `if not (isValidSessionId (unSessionId sid)) then pure (Left ResumeInvalidId) else …` (add `ResumeInvalidId` to the `ResumeError` sum + its `Show`/handling if needed). Confirm `openSessionFromDisk`'s existing `Left` fallback logs a warning and returns a safe fresh handle (per the `apv` fix) — no boot crash.
- [ ] **Step 4: Run → PASS** + suite green.
- [ ] **Step 5: Commit** `fix(tabs-fe): resumeSession validates the id (safe-by-construction) (#80)`

---

## WU3 — `Frontend/TabsView.hs`: pure projection (the 95%-gated logic)

**Files:**
- Create: `src/PureClaw/Frontend/TabsView.hs` — relocate `TabSnapshot`, `livenessToTabStatus`, `harnessOriginToText` here from `Frontend/API.hs`; add the pure projection.
- Modify: `src/PureClaw/Frontend/API.hs` — import `Frontend.TabsView`, re-export `TabSnapshot` (+ helpers) so existing call sites/tests compile unchanged.
- Modify: `pureclaw.cabal` (add `PureClaw.Frontend.TabsView` to library `exposed-modules`/`other-modules`).
- Test: `test/Frontend/TabsViewSpec.hs` (new) — register in Main.hs + cabal.

- [ ] **Step 1: Relocate** the `TabSnapshot` record + `ToJSON TabSnapshot` + `livenessToTabStatus` + `harnessOriginToText` from `Frontend/API.hs` into the new `TabsView.hs` (cut/paste; keep field names/JSON keys identical). In `Frontend/API.hs`, `import PureClaw.Frontend.TabsView` and add `TabSnapshot (..)`, `livenessToTabStatus`, `harnessOriginToText` to its re-export list. Build green (no behavior change yet — `harnessEntriesToTabs` still works).

- [ ] **Step 2: RED test** — `test/Frontend/TabsViewSpec.hs`, module `Frontend.TabsViewSpec`. Cover the branch matrix with **injected** lookups (no IO):
```haskell
-- Build a TabList with a BoundSession and a BoundHarness; inject lookups.
spec = describe "tabSnapshotsFromRegistry" $ do
  it "projects a BoundSession with present meta as kind=provider, status=idle" $ do
    let tl = mkTabList [ (BoundSession (parseSessionId "s1"), "chat 0", Live) ]
        metaOf sid = if sid == parseSessionId "s1" then Just (providerMeta "s1") else Nothing
        harnOf _   = Nothing
        [t] = tabSnapshotsFromRegistry tl metaOf harnOf
    _ts_kind t      `shouldBe` "provider"
    _ts_status t    `shouldBe` "idle"      -- NOT "running"
    _ts_sessionId t `shouldBe` Just "s1"
    _ts_origin t    `shouldBe` ""
  it "BoundSession with MISSING meta falls back to provider/idle (no crash)" $ ...
  it "BoundHarness live → status from liveness + origin + attachCommand from the entry" $ ...
  it "BoundHarness with a VANISHED entry → status exited, stale=True" $ ...
  it "Dead BoundSession → status exited" $ ...
  it "surfaces NO secret field" $        -- everything-visible: label/status/kind/sid only
    -- assert the projected TabSnapshot exposes none of _sm_source/channelUserId/creds
    ...
```
(Provide `mkTabList`/`providerMeta`/harness-entry fixtures in the spec.)

- [ ] **Step 3: Run → FAIL** (`tabSnapshotsFromRegistry` undefined).

- [ ] **Step 4: GREEN** — add the pure function to `TabsView.hs` and export it:
```haskell
tabSnapshotsFromRegistry
  :: TabList
  -> (Core.SessionId -> Maybe SessionTypes.SessionMeta)
  -> (Registry.HarnessId -> Maybe Registry.HarnessEntry)
  -> [TabSnapshot]
tabSnapshotsFromRegistry tl metaOf harnOf =
  [ project tab | tab <- Tabs.toList tl ]
  where
    project tab = case Tabs._tab_ref tab of
      Tabs.BoundSession sid -> TabSnapshot
        { _ts_index     = Tabs.unTabIndex (Tabs._tab_slot tab)
        , _ts_kind      = "provider"
        , _ts_name      = Tabs._tab_name tab
        , _ts_status    = case Tabs._tab_status tab of
                            Tabs.Live -> "idle"
                            Tabs.Dead -> "exited"
        , _ts_sessionId = Just (Core.unSessionId sid)
        , _ts_extModified = False, _ts_stale = False
        , _ts_origin    = "", _ts_attachCommand = Nothing }
      Tabs.BoundHarness hid -> case harnOf hid of
        Just e  -> TabSnapshot
          { _ts_index = Tabs.unTabIndex (Tabs._tab_slot tab)
          , _ts_kind = "harness"
          , _ts_name = Tabs._tab_name tab     -- registry label (or fall back to _he_label)
          , _ts_status = livenessToTabStatus (Registry._he_liveness e)
          , _ts_sessionId = Registry._he_sessionId e
          , _ts_extModified = Registry._he_extModified e
          , _ts_stale = Registry._he_stale e
          , _ts_origin = harnessOriginToText (Registry._he_origin e)
          , _ts_attachCommand = Registry._he_attachCommand e }
        Nothing -> TabSnapshot                -- vanished entry
          { _ts_index = Tabs.unTabIndex (Tabs._tab_slot tab)
          , _ts_kind = "harness", _ts_name = Tabs._tab_name tab
          , _ts_status = "exited", _ts_sessionId = Nothing
          , _ts_extModified = False, _ts_stale = True
          , _ts_origin = "", _ts_attachCommand = Nothing }
```
(Adjust field accessor names to the real `HarnessEntry`/`SessionMeta` — verify against `Harness/Registry.hs` and `Session/Types.hs`. The `_ts_name` for harness may prefer `Tabs._tab_name` and fall back to `Registry._he_label e`.)

- [ ] **Step 5: Run → PASS**; register the spec; full suite green; build `-Werror` clean.
- [ ] **Step 6: Commit** `feat(tabs-fe): pure tabSnapshotsFromRegistry in Frontend/TabsView (#80)`

---

## WU4 — `_env_onTabsChanged` notify seam (chat mutations → rebroadcast)

**Files:**
- Modify: `src/PureClaw/Agent/Env.hs` (add `_env_onTabsChanged :: IO ()` to `AgentEnv` + a `TabSubsystem` field, default `pure ()`; add to ALL `AgentEnv` construction sites — `-Werror -Wmissing-fields` will enumerate them)
- Modify: `src/PureClaw/Routing/TabDispatch.hs` (add `_td_onTabsChanged :: IO ()` to `TabDispatchDeps`; call it after `cmdNt`/`cmdNew`/`cmdClose`/`cmdRename`/wizard-bind — at the registry-mutation boundary)
- Modify: `src/PureClaw/Tabs/Wiring.hs` (`mkTabDispatchDeps` wires `_td_onTabsChanged = _env_onTabsChanged env`; any direct registry mutation in Wiring also calls it)
- Test: `test/Routing/TabDispatchSpec.hs` (extend with a recorder)

- [ ] **Step 1: RED** — extend the TabDispatch fake-deps harness with `f_tabsChanged :: IORef Int` wired to `_td_onTabsChanged = modifyIORef' f_tabsChanged (+1)`; assert it fires once per mutation:
```haskell
it "fires _td_onTabsChanged once on /nt" $ do
  f <- mkFakes
  handleInbound (f_deps f) convA "/nt"
  readIORef (f_tabsChanged f) `shouldReturn` 1
it "fires once on /close" $ ...
it "does NOT fire on a no-op (e.g. /tabs list)" $ do
  ...; readIORef (f_tabsChanged f) `shouldReturn` 0
```
- [ ] **Step 2: Run → FAIL** (field/seam not present).
- [ ] **Step 3: GREEN** — add the fields; call `_td_onTabsChanged (_ctx_deps ctx)` at the end of each mutating command (factor a tiny `notifyChanged ctx` helper). Add `_env_onTabsChanged` to `AgentEnv` (default `pure ()`) and `newTabSubsystem`; fix every construction site. Wire `mkTabDispatchDeps`.
- [ ] **Step 4: Run → PASS** + suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): _env_onTabsChanged notify seam on registry mutation (#80)`

---

## WU5 — Persistence: `_pd_sessionExists` seam + strict `parseRef` + reconcile drops

**Files:**
- Modify: `src/PureClaw/Tabs/Persist.hs` (`PersistDeps._pd_sessionExists :: SessionId -> IO Bool`; `parseRef` rejects invalid `SessionId`; `reconcileTabs.keepTab` drops a `BoundSession` failing `_pd_sessionExists`)
- Test: `test/Tabs/PersistSpec.hs` (extend; drive via `loadTabs` — no new exports)

- [ ] **Step 1: RED** — extend `PersistSpec`:
```haskell
it "reconcile drops a BoundSession whose session.json is absent, keeps an existing one" $ do
  -- write a tabs.json with two BoundSession tabs; _pd_sessionExists True for s1, False for s2
  ... loadTabs deps ... -> tabs has s1, not s2
it "parseRef drops a BoundSession with a traversal/leading-dot/control id, loads the rest" $ do
  -- hand-write tabs.json containing ids: "../etc", ".hidden", "a b", and "good1"
  ... loadTabs deps ... -> only "good1" survives
it "reconcile drops a dead-harness tab (existing behavior preserved)" $ ...
```
- [ ] **Step 2: Run → FAIL** (PersistDeps lacks `_pd_sessionExists`; parseRef lacks the guard).
- [ ] **Step 3: GREEN** — add `_pd_sessionExists` to `PersistDeps`; in `keepTab`, `BoundSession sid -> _pd_sessionExists deps sid`; in `parseRef`, after decoding a `BoundSession`, `if isValidSessionId (unSessionId sid) then Just (BoundSession sid) else Nothing` (mirroring the invalid-`HarnessId` drop). Update every `PersistDeps` construction (tests + any default) with the new field.
- [ ] **Step 4: Run → PASS** + suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): persistence _pd_sessionExists + strict parseRef guard (#80)`

---

## WU6 — Read wiring: `FrontendEnv` registry + lists IO wrapper + exclusion

**Files:**
- Modify: `src/PureClaw/Frontend/API.hs` (add `_fe_tabRegistry :: TabRegistry`, `_fe_cursors :: IORef CursorState` to `FrontendEnv`; replace `_fe_listTabs` body with the IO wrapper gathering the two lookups → `tabSnapshotsFromRegistry`; `computeListsSnapshot` recentSessions AND archived exclusion now reads registry-derived `tabs`)
- Test: `test/Frontend/APISpec.hs` (extend; there's a `mkTestFrontendEnvWithTabs`-style helper — wire a real `TabRegistry`)

- [ ] **Step 1: RED** — `APISpec`:
```haskell
it "a BoundSession tab appears in tabs and its sid is excluded from BOTH recent and archived" $ do
  reg <- newTabRegistry; _ <- registryAppend reg (BoundSession (parseSessionId sid)) "chat 0"
  env <- mkTestFrontendEnv ... { _fe_tabRegistry = reg, ... }   -- session sid also on disk (archived)
  v <- computeListsSnapshot env
  -- tabs contains sid; recentSessions does not; archivedSessions does not
it "a harness-tab session stays dual-listed in recent" $ ...
```
- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: GREEN** — add the fields; `_fe_listTabs = do { tl <- readTabs (_fe_tabRegistry env); metas <- listSessions (_fe_sessionsDir env) Nothing big; entries <- Registry.snapshot (_fe_harnessRegistry env); pure (tabSnapshotsFromRegistry tl (lookupMeta metas) (lookupEntry entries)) }`. In `computeListsSnapshot`, derive `activeTabSids` from the new `tabs` (already does) and ALSO subtract them from the archived filter. Update every `FrontendEnv` construction site (tests + `Commands.hs` placeholder — `Commands` is fully wired in WU8) with the two new fields.
- [ ] **Step 4: Run → PASS** + suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): lists frame projects from the TabRegistry; tab-bound sids leave recent+archived (#80)`

---

## WU7 — Write path: registry-resolved actions + create + cap

**Files:**
- Modify: `src/PureClaw/Frontend/API.hs` (`handleNewTab` appends `BoundSession`/`BoundHarness`; tab-action endpoints resolve index against the `TabRegistry`; close releases the runtime via `_env_exec`; harness-only guard; `_fe_maxTabs` pre-check; drop `_fe_tabCount`)
- Test: `test/Frontend/APISpec.hs` (extend; ~14 `_fe_tabCount` assertions → `readTabs` length)

- [ ] **Step 1: RED** — `APISpec`:
```haskell
it "handleNewTab (provider) appends a BoundSession and returns its slot/sid" $ ...
it "close resolves the registry slot and removes the tab (any kind)" $ ...
it "dismiss on a BoundSession tab returns a 4xx 'not a harness tab'" $ ...
it "create beyond _fe_maxTabs returns the cap 4xx (no append)" $ ...
```
- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: GREEN** —
  - new `resolveRegistrySlot :: FrontendEnv -> Int -> IO (Maybe (TabIndex, TabRef))` via `readTabs` (replaces `tabIndexToEntry` for tab actions).
  - `handleNewTab`: provider → mint+`registryAppend (BoundSession sid)`; harness → spawn then `registryAppend (BoundHarness hid)` after the deferred-success point; raw-shell arm: leave as-is (deferred) — but the affordance is hidden in WU9 so it isn't hit.
  - `close` → `registryRemove`; for `BoundSession` also `release (_env_exec env) ref` (stop the runtime). `dismiss`/`release`/`destroy`/`acknowledge` → resolve ref; if `BoundHarness` run the existing harness teardown, else return `{"error":"not a harness tab"}` 4xx.
  - cap: read `length <$> readTabs`; if `>= _fe_maxTabs` return the cap 4xx before appending. Remove `_fe_tabCount` IORef + its read/write; replace its assertions in `APISpec` with `readTabs`-length checks.
  - call `_env_onTabsChanged` after each mutation.
- [ ] **Step 4: Run → PASS** + suite green.
- [ ] **Step 5: Commit** `feat(tabs-fe): frontend tab endpoints drive the registry (create/close/cap) (#80)`

---

## WU8 — `CLI/Commands.hs` wiring + boot reconcile + integration

**Files:**
- Modify: `src/PureClaw/CLI/Commands.hs` (set `_fe_tabRegistry`/`_fe_cursors` from the shared subsystem; `_env_onTabsChanged = \-> saveTabs stateDir <$> readTabs … <*> readIORef cursors >> broadcastLists frontendEnv`; `loadTabs`+reconcile after `bootReconstruct`, seed the registry/cursors before `Async.withAsync runFrontend`; wire `_pd_sessionExists`/`_pd_harnessLive`/`_pd_stateDir`)
- Test: `test/Integration/CLISpec.hs` or a focused `test/Frontend/APISpec.hs` integration

- [ ] **Step 1: RED (integration)** — a test that: builds the shared env+frontendEnv (as Commands does), runs `runTabbedLoop`-style `/nt`, and asserts a broadcast `lists` snapshot contains the new tab and excludes its sid from recent; plus a **dual-write-consistency** assertion: a frontend `handleNewTab (BoundSession)` then `registryLookupSlot` for that slot equals the created ref (the same ref chat `/N` would resolve).
- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: GREEN** — wire as above. `_env_onTabsChanged` saves+broadcasts. Boot: after `bootReconstruct`, `loadTabs (PersistDeps stateDir harnessLive (pure ()) sessionExists)` → seed `_ts_tabRegistry`/`_ts_cursors` before server start. `_pd_sessionExists sid = doesFileExist (sessionsDir </> unSessionId sid </> "session.json")`.
- [ ] **Step 4: Run → PASS** + full suite green; build `-Werror` clean; `nix develop . --command hlint src test app`.
- [ ] **Step 5: Commit** `feat(tabs-fe): wire registry↔frontend in Commands + boot persistence (#80)`

---

## WU9 — React frontend: slot-exhaustion surfacing + hide raw-shell + verify render

**Files:**
- Modify: `frontend/src/App.tsx` (the inline `fetch('/api/tabs/new')` in `handleComposerSend`: on `!res.ok`, `await res.json()` and set a composer error state rendered via the existing `role="alert"` block; generalize `attachError`→`composerError` or add `createError`)
- Modify: the new-tab composer/menu component (hide/disable the **raw-shell** create option)
- Test: `frontend/src/__tests__/…` (vitest) — slot-exhaustion message renders; a session-kind tab renders under Active Tabs with the idle icon

- [ ] **Step 1: RED (vitest)** — mock `/api/tabs/new` → 409 `{"error":"maximum tab count reached"}`; assert the composer renders an actionable message (not a silent no-op). And a render test: a `TabInfo` with `kind:"provider", status:"idle", origin:""` renders under "Active Tabs", shows the muted `○` (no green dot), and shows only Archive + Close controls.
- [ ] **Step 2: Run → FAIL**: `cd frontend && npm test -- --run`.
- [ ] **Step 3: GREEN** — read the 4xx body and surface it; hide the raw-shell create affordance. (No new guard code for harness-only controls — they self-suppress for a provider/idle/origin-"" tab; the render test asserts that.)
- [ ] **Step 4: Run → PASS**; `cd frontend && npm run build` (typecheck) clean.
- [ ] **Step 5: Commit** `feat(tabs-fe): surface slot-exhaustion, hide raw-shell affordance (#80)`

---

## WU10 — Coverage + final gate + self-reflect

- [ ] **Step 1: Coverage** — `nix develop . --command cabal test --enable-coverage`; confirm `PureClaw.Frontend.TabsView` ≥95% (pure projection branch matrix). If the thin IO wrapper in `Frontend.API` dips the module, add the integration assertion (WU8 already exercises `broadcastLists → _fe_listTabs → wrapper`) or a one-line justified note in `.coverage-thresholds.json`. Do NOT add a `TabsView` waiver (it must self-hit 95%).
- [ ] **Step 2: Full gate** — `cabal build` `-Werror` clean; `cabal test` green; `hlint src test app` → No hints; `cd frontend && npm test --run && npm run build`.
- [ ] **Step 3: `/self-reflect`** — capture any learnings (e.g. the dual-source-of-truth unification pattern); commit knowledge-base updates.
- [ ] **Step 4: Commit** any threshold/coverage updates `chore(tabs-fe): coverage gate + final cleanup (#80)`. Push to `origin/feat/tabs-as-view-refactor` (updates PR #80).

---

## Self-review (author checklist — done)
- **Spec coverage:** every Components-table row maps to a WU (Core.Types→WU1; loader→WU2; TabsView→WU3; notify seam→WU4; Persist→WU5; API read→WU6; API write→WU7; Commands→WU8; React→WU9; gate→WU10). Edge cases (status idle, archived exclusion, closed-focused cursor, slot-exhaustion, traversal guard, reconcile drop) each have a test.
- **Type consistency:** `tabSnapshotsFromRegistry`, `_env_onTabsChanged`, `_td_onTabsChanged`, `_pd_sessionExists`, `_fe_tabRegistry`/`_fe_cursors`, `isValidSessionId`, `resolveRegistrySlot` used consistently across WUs.
- **Deferred (out of scope, per spec):** raw-shell `BoundShell`, frontend rename, WU9 harness-death notified removal, the transcript-fd-leak follow-up.
