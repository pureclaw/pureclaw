# Plan: Wire `/tab new <kind>` runtime dispatch (ai + harness)

- **Issue:** pureclaw-de0 (under epic #79 — Tabs-as-View Refactor)
- **PR:** lands in open PR #80, branch `feat/tabs-as-view-refactor`
- **Date:** 2026-06-12
- **Type:** bug fix / gap closure (deferred dispatch never wired)

## Problem

`/tab new ai` and `/tab new harness` typed in the TUI do nothing visible: no tab
appears in the frontend "Active Tabs" / "Running Harnesses" sections.

**Root cause (verified):** the `/tab new <kind>` grammar
(`Routing.Parse.parseTabNew`, `SlashCommands.tabNewP` → `CmdTab (TabNewCmd ...)`)
is parsed and unit-tested but has **no runtime handler**. The live TUI dispatcher
`handleNonWizard` (`src/PureClaw/Routing/TabDispatch.hs` ~L225) matches
`("/tab" : args) -> cmdTab ctx args` for **all** `/tab …` input, routing it to the
attach-**wizard** (treating `"new ai"` as a fuzzy search query). It never calls
`registryAppend`, so `notifyChanged → broadcastLists` never fires.
`executeSlashCommand (CmdTab _)` (`SlashCommands.hs:1224`) is only a defensive stub.

The frontend broadcast path is **correct and shared**: one `TabRegistry` `IORef`
(built in `CLI/Commands.hs:684`), and `_env_onTabsChanged` → `broadcastLists`
(`CLI/Commands.hs:727-731`). `/nt` and `/new` work precisely because they reach
`bindNewTab` (which appends + fires `notifyChanged`). So the fix is to give
`/tab new` a real handler that funnels into `bindNewTab`.

## Scope

**In scope (user-confirmed): `ai` and `harness` kinds must create tabs that appear
in the frontend.**

| Input | Behaviour |
|---|---|
| `/tab new`, `/tab new ai`, `/tab new provider` | Mint a default-provider session (the existing `/nt` path), append a `BoundSession` tab, focus, broadcast. |
| `/tab new harness [flavour]` | Spawn a harness (default flavour `claude-code`, backend local), append a `BoundHarness` tab, focus, broadcast. |
| `/tab new shell` / `ssh` / `tmux` | Emit a clear **"not yet supported"** message. No registry mutation, no wizard. |
| `/tab` / `/tab <query>` (no `new`) | **Unchanged** — still opens the attach-wizard. |

**Out of scope (explicit):**
- `shell` / `ssh` / `tmux` tab *creation* (only the not-yet-supported message).
- Provider/model selection from `/tab new provider <argtext>` — argtext is ignored
  for now (bare default session), matching today's `_td_newDefaultSession`. Noted as
  a follow-up.
- Honoring a caller-specified tmux session/window for harness placement
  (already deferred upstream as pureclaw-jlc).

## Design

Two work units. WU-A is independently shippable and fixes `/tab new ai` alone;
WU-B adds the harness seam.

### WU-A — `/tab new` dispatch + ai/provider routing

1. **`TabDispatch.handleNonWizard`** — insert a match **before** the generic
   `("/tab" : args)` wizard arm:
   ```haskell
   ("/tab" : "new" : rest) -> cmdTabNew ctx rest
   ("/tab" : args)         -> cmdTab    ctx args   -- unchanged
   ```
2. **New `cmdTabNew :: Ctx -> [Text] -> IO ()`** — parse the kind keyword from
   `rest` (reuse `parseTabKindArg` semantics; bare/`ai`/`provider` → provider):
   - provider/ai/bare → `_td_newDefaultSession`; on `Right ref`
     `bindNewTab ctx ref defaultSessionName "new tab"`; on `Left msg` `emit msg`.
   - `harness` → in WU-A, emit "not yet supported" (placeholder, replaced in WU-B).
   - `shell`/`ssh`/`tmux` → emit "not yet supported".
   - unknown keyword → emit a usage hint.
   `bindNewTab` already handles `SlotsFull`, `AlreadyBound`, ensure/cursor/notify.

**Files:** `src/PureClaw/Routing/TabDispatch.hs`, `test/Routing/TabDispatchSpec.hs`.

**TDD (WU-A):** in `TabDispatchSpec.hs`, construct `TabDispatchDeps` with a
recording stub `_td_newDefaultSession` and a recording `_td_onTabsChanged`:
- `/tab new`, `/tab new ai`, `/tab new provider` → registry gains one `BoundSession`,
  `_td_onTabsChanged` fired once, emit `new tab /<slot>`.
- `Left` from `_td_newDefaultSession` → emit that message, **no** append, **no** notify.
- slots-full → `slotsFullMsg`, no notify.
- `/tab new shell|ssh|tmux` → "not yet supported", no append, no notify.
- `/tab <query>` (no `new`) → still opens the wizard (regression guard).

### WU-B — harness spawn seam + harness routing

1. **`AgentEnv`** (`src/PureClaw/Agent/Env.hs`): add
   `_env_startHarness :: HarnessSpec -> IO (Either Text (TabRef, Text))`
   (returns the bound `BoundHarness` ref + display label/key). The seam must live
   on `AgentEnv` because the dispatcher is built by `mkTabDispatchDeps env …`
   (`Wiring.hs:156`) inside `runTabbedLoop env` (`Wiring.hs:140`), which receives
   **only** `env` — exactly why `_env_onTabsChanged` lives there too.
   Also export a shared default
   `noStartHarness :: HarnessSpec -> IO (Either Text (TabRef, Text))`
   = `\_ -> pure (Left "harness spawn not wired")` for every non-exercising site.

1b. **Construction-site sweep (`-Werror`/`-Wmissing-fields`).** There is **NO**
   field-level auto-default in Haskell: `cabal.project` sets `-Werror` and `-Wall`
   includes `-Wmissing-fields`, so every *full* `AgentEnv { … }` literal must
   assign `_env_startHarness` or the build fails. (The `_env_onTabsChanged`
   precedent confirms this — it was spelled by hand in every literal; nothing
   defaults it. The prior draft's "mirrors `_env_onTabsChanged = pure ()` default"
   claim was wrong and is retracted.) **Record *updates* (`env { … }`) do not need
   it** — only literals do. The compiler enumerates every offender; add
   `_env_startHarness = noStartHarness` (tests, matching each file's existing
   `error "stub…"` / `pure ()` convention) or the real closure (Commands.hs) until
   the build is green. **Complete literal inventory (verified by grep):**
   - `src/PureClaw/Agent/Env.hs` — the `data AgentEnv` definition (add field + `noStartHarness`).
   - `src/PureClaw/CLI/Commands.hs:689` — real closure (see item 3).
   - `test/Agent/SlashCommandsSpec.hs` — **40 literals** (`= AgentEnv` / `pure AgentEnv` at L336, 501, 554, 604, 653, 714, 766, 814, 873, 933, 985, 1037, 1084, 1147, 1205, 1255, 1298, 1351, 1410, 1471, 1520, 1637, 1690, 1741, 1833, 1891, 1942, 1988, 2115, 2166, 2229, 2283, 2359, 2412, 2462, 2510, 2573, 2653, 2720, 2885).
   - `test/Tabs/WiringSpec.hs:278`, `test/Tools/DelegateSpec.hs:81`,
     `test/Integration/SignalFlowSpec.hs:70`, `test/Agent/BackgroundSpec.hs:60`,
     `test/Onboarding/StartSpec.hs:316` — one literal each.
   - **NOT affected:** `src/PureClaw/Routing/Types.hs` (comments only),
     `src/PureClaw/Tabs/Wiring.hs` (field selectors/signatures only — no `AgentEnv` literal).
2. **Shared helper** — extract the session-meta + persist-coords + registry-link
   core of `createHarnessTab` (`Frontend/API.hs:1715-1767`, i.e. steps: build
   `SessionMeta`, `mkSessionHandle`/`_sh_save`, call the spawn seam, persist real
   `TbTmux` coords + `_h_harnessId`/`_h_claudeSessionUuid`/`_h_canonicalCwd`,
   `Registry.modifyEntry … _he_sessionId`) into a reusable
   `spawnHarnessSession` returning `Either HarnessError (SessionId, HarnessId, SessionMeta, Text {-key-})`.
   `createHarnessTab` is refactored to call it, then `registryAppend` +
   `finishHarnessTab` (behaviour unchanged). This avoids duplicating the subtle
   persist/link logic (aligns with the project's single-source+projection
   unification value, commit 0eaa86b).
3. **`CLI/Commands.hs`** — assign `_env_startHarness = \spec -> do { r <- spawnHarnessSession …; pure (fmap (\(sid,hid,_meta,key) -> (BoundHarness hid, key)) r mapped to Either Text) }`,
   reusing the in-scope `_fe_startHarness frontendEnv`/`broker`/`logger`/`sessionsDir`/`harnessReg`
   (same `let` group as `AgentEnv`, line 689; forward-reference `frontendEnv` lazily
   exactly like `_env_onTabsChanged`). `HarnessError` is mapped to `Text` for the
   dispatcher-facing seam.
4. **`Tabs/Wiring.hs`** — add `_td_spawnHarness :: HarnessSpec -> IO (Either Text (TabRef, Text))`
   to `TabDispatchDeps`, set `_td_spawnHarness = _env_startHarness env` in
   `mkTabDispatchDeps`.
5. **`TabDispatch.cmdTabNew`** — replace the WU-A harness placeholder: build a
   `HarnessSpec` (flavour from `rest` via the existing flavour resolver, default
   `claude-code`; backend local; default args) → `_td_spawnHarness spec`; on
   `Right (ref, label)` `bindNewTab ctx ref label "new harness"`; on `Left msg` `emit msg`.

**Files (WU-B):**
- Source: `src/PureClaw/Agent/Env.hs` (field + `noStartHarness`),
  `src/PureClaw/Frontend/API.hs` (extract `spawnHarnessSession`),
  `src/PureClaw/CLI/Commands.hs` (real `_env_startHarness` closure),
  `src/PureClaw/Tabs/Wiring.hs` (`_td_spawnHarness` field + pass-through),
  `src/PureClaw/Routing/TabDispatch.hs` (`TabDispatchDeps` field + harness arm of `cmdTabNew`).
- Tests — new assertions: `test/Routing/TabDispatchSpec.hs`,
  `test/Frontend/APISpec.hs` (helper extraction kept green).
- Tests — **`-Wmissing-fields` construction-site sweep** (add `_env_startHarness = noStartHarness`):
  `test/Agent/SlashCommandsSpec.hs` (40 literals), `test/Tabs/WiringSpec.hs`,
  `test/Tools/DelegateSpec.hs`, `test/Integration/SignalFlowSpec.hs`,
  `test/Agent/BackgroundSpec.hs`, `test/Onboarding/StartSpec.hs`.

**TDD (WU-B):** dispatcher tests with a recording stub `_td_spawnHarness`:
- `/tab new harness` → stub called with flavour `claude-code`/local; registry gains
  one `BoundHarness`; `_td_onTabsChanged` fired; emit `new harness /<slot>`.
- `/tab new harness claude-code` → same, explicit flavour.
- `Left` from the seam → emit message, no append, no notify.
The shared `spawnHarnessSession` stays covered by the existing `createHarnessTab`
frontend tests (refactor-in-place; no behaviour change).

## Why this is feasible (key references)

- The spawn machinery (`windowIdxRef`, `policy`, `harnessReg`, `startHarnessByName`,
  `resolveHarnessName`/`resolveHarnessSession`, and `_fe_startHarness` itself) is all
  in scope at the `let` that builds `AgentEnv` (`CLI/Commands.hs:689-832`), so
  `_env_startHarness` is constructible there with zero new module cycles — it's a
  plain function field assigned in `CLI/Commands.hs`, exactly like
  `_env_onTabsChanged` references `broadcastLists frontendEnv`.
- `bindNewTab` already does append + `ensure` (attaches to the just-spawned handle
  via `startHarness`'s registry lookup — **no double spawn**) + cursor + `notifyChanged`
  (→ persist + `broadcastLists`) + emit. The harness ref reuses this unchanged.
- `_td_newDefaultSession` is the proven `/nt` provider path that already reaches the
  frontend, so the ai/provider half is a pure routing change.

## Coverage / gates

- Source of truth: `.coverage-thresholds.json` (**95%** lines/branches/functions/statements).
- New dispatcher logic (`cmdTabNew` + the `handleNonWizard` arm) is pure/IO-thin and
  fully exercised by `TabDispatchSpec` stubs.
- `_env_startHarness` real closure + `mkTabDispatchDeps` pass-through are WAI/boot IO
  glue of the same class already waived for `PureClaw.Frontend.API` (staged waiver,
  WU8 #80). If coverage dips on `CLI/Commands.hs`/`Frontend.API`, extend that
  existing IO-glue waiver with a justification rather than adding contrived tests.
- `nix develop . --command cabal build` (`-Wall -Werror`) + `cabal test` green before each commit.

## Definition of Done

1. `/tab new`, `/tab new ai`, `/tab new provider` append a `BoundSession` tab, focus it,
   and the new tab appears in the frontend lists (broadcast fired). ✔ test
2. `/tab new harness [claude-code]` spawns a harness, appends a `BoundHarness` tab,
   focuses it, and it appears under "Running Harnesses" (broadcast fired). ✔ test
3. `/tab new shell|ssh|tmux` emits a clear "not yet supported" message; no registry
   mutation, no wizard. ✔ test
4. `/tab` / `/tab <query>` still opens the attach-wizard (no regression). ✔ test
5. Build clean under `-Wall -Werror`: every `AgentEnv` literal (the 40 in
   `SlashCommandsSpec` + the 5 single-literal test files + `Commands.hs`) assigns
   `_env_startHarness`; `-Wmissing-fields` reports zero offenders. `cabal test`
   green; coverage gate satisfied (or the existing `Frontend.API`/`Tabs.Wiring`
   IO-glue waiver extended with justification).
6. Existing `ParseSpec`/`SlashCommandsSpec` grammar tests remain green (no parser change).
