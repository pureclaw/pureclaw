# Implementation Plan — `/bg` command (GitHub issue #52, beads pureclaw-2m3)

## Goal

Add a `/bg <prompt>` slash command patterned after Hermes' `/background`. It spawns
a **fresh AI session** using **default agent/model/provider** (inherited from
`AgentEnv` at spawn), runs the prompt **in the background without stealing focus**,
and **pushes the tab's final response to the current channel on completion**
(prefixed `[bg /N done]`).

Confirmed scope decisions (user):
- **Result surfacing**: push the completed result to the current channel (not merely
  available-in-tab).
- **Names**: only `/bg` (no `/background` / `/btw` aliases).

## Architecture mapping (researched)

PureClaw's concurrency model *is* tabs. A "fresh session running concurrently" is a
new AI tab spawned by the dispatcher. Relevant seams:

- Parser: `PureClaw.Routing.Parse.parseInput` → `parseSlashCommandForm` →
  `Slash.parseSlashCommand` (derived from `allCommandSpecs`, the single source of truth).
- Command ADT: `PureClaw.Agent.SlashCommands.SlashCommand`.
- Dispatch: `PureClaw.Routing.Dispatcher.dispatchSlash` routes `CmdTab`/`CmdStart`
  specially and everything else to the focused tab; `ratelimitedSpawn` enforces S7.
- Spawn UX: `PureClaw.Routing.AutoSpawn.handleDefault`/`handleNew` spawn a tab via an
  injected `SpawnIO`, write focus, enqueue text, emit a banner.
- AI tab loop: `PureClaw.Tab.Ai.runOneTurn` runs the provider turn; it already
  computes `focusedNow` and streams chunks only when focused.
- Output gating: `PureClaw.Routing.ChannelOut` emits `SrcDispatcher` events
  unconditionally and `SrcTab n` events only when `n` is focused.

### Key design decisions

1. **Background flag lives with the tab** (`AiTabState._ats_background :: !Bool`),
   sourced from a new `AiSpawnArgs._ai_background :: !Bool`. Rationale: it travels
   with the tab state, so it is immune to tmux-style index renumbering on close, and
   it avoids adding a field to `AgentEnv` (39 construction sites in
   `SlashCommandsSpec.hs` alone).
2. **Completion push fires only when the bg tab is NOT focused**:
   `when (_ats_background state && not focusedNow) $ emitBgCompletion ...`. This means
   (a) a focused tab streams live with no duplicate output; (b) only `/bg` tabs push —
   not every non-focused tab. Emitted via `SrcDispatcher` `BannerLine` so it bypasses
   focus gating and always reaches the current channel. Exact banner text:
   `"[bg /" <> n <> " done] " <> body`.
3. **`/bg` never steals focus** — `handleBg` deliberately omits the
   `writeIORef _env_focus` that `handleDefault`/`handleNew` perform.
4. **The bg-aware factory is injected by the dispatcher** via the `SpawnIO` callback,
   so `AutoSpawn` stays decoupled from `Tab.Ai` (no new import cycle).
5. **`/bg` is AI-only by design** ("run a *prompt*"). `handleBg` and `ratelimitedSpawnBg`
   spawn a **fixed AI kind** (`TkSession (SkProvider <placeholder>)`) — NOT
   `_rc_defaultKind`. The placeholder `ProviderSpec` is ignored by the factory; the
   real provider/model come from `_env_provider`/`_env_model` at `allocState` time
   (same contract as `AutoSpawn.tabKindArgToKind`). This keeps the spawn kind and the
   hardcoded `mkTabAi` factory consistent even if a user configures a non-AI
   `_rc_defaultKind`, and makes the X1 crash-retry path (which respins via the *normal*
   `_ds_factory`) replay a valid AI kind.

### Build-warning caveat (MUST READ — drives several DoD items)

`-Wincomplete-patterns` and `-Wmissing-fields` are **OFF** in this project (only
`-Wincomplete-uni-patterns` and `-Wpartial-fields` are on; see `pureclaw.cabal` +
`cabal.project`). Therefore:
- Adding `CmdBg` to `SlashCommand` will **compile clean** even if a pattern-match site
  omits the arm — and then **crash at runtime** with `Non-exhaustive patterns`. The
  `executeSlashCommand` `CmdBg` arm is **correctness-mandatory**, not optional.
- Adding `_ai_background`/`_ats_background` to records will **compile clean** at any
  construction site that omits the field — and then the strict field is `⊥`, throwing
  when forced. **Every** construction site must be updated by hand.

### Exhaustive list of `SlashCommand` match sites (must be checked for `CmdBg`)
- `executeSlashCommand` (`SlashCommands.hs:~937`) — **must add `CmdBg` arm** (no catch-all).
- `dispatchSlash` (`Dispatcher.hs:705`) — has a `_ -> routeToFocused` catch-all; **must
  add explicit `CmdBg` arm** (else `/bg` silently routes to the focused tab — build won't warn).
- `Agent.Loop` (`Loop.hs:~104`) — `Just (CmdTab ...)` / `Just cmd` / `Nothing`; `CmdBg`
  flows into `Just cmd -> executeSlashCommand`, covered by the `executeSlashCommand` arm.
- `Tab.Ai.handleEvent` (`Ai.hs:424`) re-parses leading-`/` `UserText` → `executeSlashCommand`,
  also covered by that arm.
- `Show`/`Eq` derived; `/help` renders from `allCommandSpecs` (spec-driven) — automatic.
- Dashboard / PromptRenderer / Onboarding / LegacyDispatch do **not** match top-level
  `SlashCommand` — unaffected.

## Work Units

### WU1 — Command vocabulary + parser (`CmdBg`)
**Files**: `src/PureClaw/Agent/SlashCommands.hs`, `test/Agent/SlashCommandsSpec.hs`,
`test/Routing/ParseSpec.hs`.

- Add constructor `CmdBg !Text` to `SlashCommand` (exported via `(..)`).
- Add `bgCommandSpecs :: [CommandSpec]` with one spec `"/bg <prompt>"` (GroupSession),
  parser `bgArgP` that requires a non-empty prompt (mirrors `msgArgP`); append to
  `allCommandSpecs`.
- Add `executeSlashCommand env (CmdBg _) ctx` fallback arm (legacy single-tab
  `runAgentLoop` path): emit a message that background tasks require the tabbed-chat
  dispatcher (mirrors the `CmdTab` fallback). Returns `ctx` unchanged.

**DoD**
- `parseInput rc "/bg summarize the repo"` ⇒ `Right (ParsedSlashCmd (CmdBg "summarize the repo"))`.
- `parseInput rc "/bg"` and `"/bg   "` ⇒ `Left ParseErrorMalformed`.
- `parseInput rc "/bg   do thing  "` ⇒ prompt argument with surrounding whitespace
  stripped to `"do thing"` (mirror `msgArgP`'s `T.strip`). One explicit assertion.
- `parseSlashCommand "/bg x"` ⇒ `Just (CmdBg "x")`; case-insensitive keyword (`/BG x`).
- Explicit `/help` test asserts `shouldContain "/bg"` (the existing non-`GroupTab`
  help test at `SlashCommandsSpec.hs:~1693` auto-covers it, but pin it explicitly so a
  future regrouping can't silently drop it). `/bg <prompt>` is excluded from the
  `<`-filtering round-trip help test, so WU1 adds its own `parseSlashCommand "/bg x"`
  round-trip assertion.
- `executeSlashCommand` `CmdBg` fallback emits the "background tasks require the
  tabbed-chat dispatcher" message; ctx unchanged. (Mandatory arm — build won't warn.)
- Red tests committed first.

### WU2 — Background-tab marking + completion push (Tab.Ai)
**Files**: `src/PureClaw/Handles/Tab.hs`, `src/PureClaw/Tab/Ai.hs`,
`test/Tab/AiSpec.hs`, `test/Handles/TabSpec.hs`, `test/Routing/RegistrySpec.hs`,
`test/Routing/DispatcherSpec.hs` (the last three only to add `_ai_background = False`
at existing `AiSpawnArgs` sites).

- Add `_ai_background :: !Bool` to `AiSpawnArgs`; set `False` at **all 12** existing
  construction sites — **1 prod** (`Dispatcher.parseArgsForKind:193`) + **11 test**
  (`TabSpec.hs:226,266,278,293,304,324,412`; `AiSpec.hs:163,601`; `RegistrySpec.hs:306`;
  `DispatcherSpec.hs:240`). Build will NOT warn on a missed site — update each by hand.
- Add `_ats_background :: !Bool` to `AiTabState`; initialise it in the `allocState`
  record literal (`Ai.hs:236`). Thread the flag from `_ai_background args` — change
  `allocState :: AgentEnv -> RoutingConfig -> Bool -> IO AiTabState` (sole caller is
  `mkTabAi`, which already has `args` in scope).
- Add a named top-level helper `emitBgCompletion :: AgentEnv -> TabIndex -> Text -> IO ()`
  (so HPC counts it) that emits `(SrcDispatcher, BannerLine ("[bg /" <> n <> " done] " <> body))`.
- In `runOneTurn`, on `Right response`: if `_ats_background state && not focusedNow`,
  call `emitBgCompletion env idx body` where `body = responseText response`, or
  `"(no response)"` when `T.null (T.strip body)` (covers both the empty-content case
  AND the tool-call-only case, since `Tab.Ai` does not execute tool calls and
  `responseText` is `""` for tool-only content). Existing transcript + context updates
  unchanged.

**DoD**
- New `AiSpawnArgs`/`AiTabState` field defaults to `False`; existing tab behavior unchanged.
- A **background** tab whose turn completes while **not focused** enqueues exactly one
  `SrcDispatcher BannerLine` equal to `"[bg /N done] " <> responseText` (assert the
  **exact** confirmed wording, including `done`).
- A **background** tab that **is focused** streams normally and pushes **no** bg banner.
- A **non-background** tab never pushes a bg banner (focused or not).
- Blank provider response ⇒ banner body is `(no response)`. **Also** a tool-call-only
  response (MockProvider returns `ToolUse`-only `_crsp_content`) ⇒ `(no response)` — tested.
- A bg-tab **provider error** ⇒ the existing `SrcDispatcher errorBanner idx`
  (`"/N: provider error — please try again"`) surfaces to the channel (it already uses
  `SrcDispatcher`, so it reaches a non-focused user). One test asserts a failing-provider
  bg tab emits that banner. (No bg-framed error wording — accepted, documented.)
- A bg-tab with **no provider configured** ⇒ the existing `SrcDispatcher`
  `"(no provider configured for this tab)"` banner surfaces. One test (use the
  silent/broken-provider fixtures at `AiSpec.hs:~660`).
- Red tests committed first. New arms covered by new tests at ≥95% per
  `.coverage-thresholds.json` — the new bg arms must NOT hide behind `Tab.Ai`'s
  existing staged waiver.

### WU3 — Dispatcher + AutoSpawn wiring (`handleBg`)
**Files**: `src/PureClaw/Routing/AutoSpawn.hs`, `src/PureClaw/Routing/Dispatcher.hs`,
`test/Routing/AutoSpawnSpec.hs`, `test/Routing/DispatcherSpec.hs`.
**Depends on**: WU1 (`CmdBg`), WU2 (background spawn args).

- `AutoSpawn.handleBg :: AgentEnv -> SpawnIO -> BannerEmit -> IORef (Map Int SpawnArgs)
  -> Text -> IO ()` (exported). Uses a **fixed AI `TabKind`**
  (`TkSession (SkProvider placeholderProviderSpec)` — `placeholderProviderSpec` already
  exists in `AutoSpawn`). Spawns via the injected `SpawnIO`; on `Left`, emit redacted
  `"/bg: " <> unPublicTabError (toPublicTabError e)`; on `Right idx`, `rememberArgs`
  with that AI kind (so X1 retry via the normal factory respins a valid AI tab),
  **do not** touch `_env_focus`, `enqueuePayloadOn idx prompt`, emit
  `"/bg: running in tab /N"`.
- `Dispatcher.ratelimitedSpawnBg env ds uid _kind _args`: consume one S7 token, then
  `spawnTabWith env bgFactory aiKind []` where `aiKind = TkSession (SkProvider <ph>)` and
  `bgFactory _ idx _ = TabAi.mkTabAi env idx AiSpawnArgs{ _ai_requestedName = "", _ai_background = True }`.
  Add a comment noting this **intentionally bypasses `_ds_factory`** (the synthetic
  test factory) because it must inject `_ai_background = True`; WU3 tests therefore
  exercise the real `TabAi.mkTabAi` (see the integration test below).
- `Dispatcher.dispatchSlash`: add explicit `CmdBg prompt -> AutoSpawn.handleBg env
  (ratelimitedSpawnBg env ds uid) (emitDispatcherBanner env) (_ds_spawnArgs ds) prompt`
  (explicit arm — the `_` catch-all would otherwise silently mis-route; build won't warn).

**DoD**
- `dispatchOne env ds uid "/bg do a thing"` spawns exactly one tab, **leaves
  `_env_focus` unchanged** (assert the pre-call value is preserved), enqueues the prompt
  on the new tab, and emits a `SrcDispatcher` banner `"/bg: running in tab /N"`.
- `handleBg` does not write `_env_focus` (direct unit test asserting focus unchanged).
- **S7 rate-limit** exhaustion ⇒ redacted `"/bg: ..."` banner, no tab spawned.
- **S6 max-tabs** full registry ⇒ redacted `"/bg: ..."` banner
  (`toPublicTabError (TabLimitExceeded _)`), no tab spawned. Explicit test.
- **Integration test** (proves the async push crosses the module boundary): boot the
  channel-out writer (`startChannelOut`) and drive a `/bg` through the real
  `TabAi.mkTabAi` factory + a controllable MockProvider, following `AiSpec.hs`'s
  fork/drive pattern; assert the channel ultimately receives the `"[bg /N done] ..."`
  banner AND the spawned tab is a `TkSession (SkProvider _)` whose completion pushed
  (i.e. `_ats_background = True`). This is the only place WU2+WU3 are exercised together.
- `/bg /new` (a prompt that is itself a recognised slash command): documented edge —
  it enqueues as `UserText`, the tab loop re-parses it as a slash command and runs it
  in the bg tab, so **no** provider turn and **no** `[bg /N done]` push occurs. One test
  asserts the spawn+enqueue path does not crash and the banner `"/bg: running in tab /N"`
  is still emitted.
- Red tests committed first. New arms covered by new tests at ≥95% per
  `.coverage-thresholds.json` — must NOT hide behind the existing `Dispatcher`/`AutoSpawn`
  staged waivers.

## Cross-cutting

- **Coverage**: `.coverage-thresholds.json` is the source of truth — thresholds are
  **95%** (lines/branches/functions/statements), and it carries `stagedWaivers` for
  `Tab.Ai`, `Dispatcher`, and `AutoSpawn` (filledBy #51 WUs). The new `/bg` arms land in
  all three of those modules and **must be covered by the new WU tests** — they may not
  rely on the existing waivers, and this work adds **no new waivers**.
- **Imports/style**: qualified-as imports, `-Wall -Werror`, hlint clean. Note
  `-Wincomplete-patterns`/`-Wmissing-fields` are OFF (see Build-warning caveat above).
- **TDD**: each WU writes failing tests first (committed separately), then implements.
- **No `AgentEnv` field added** — explicitly avoided.
- **Docs**: add a one-line `/bg` entry to `docs/tabbed-chat.md` (if a command list
  exists there); otherwise `/help` is the user-facing surface.

## Known limitations (accepted for v1, documented for the user)
- **Permanent slot consumption**: every `/bg` consumes a tab slot for the life of the
  process (the bg tab is never auto-closed). Repeated `/bg` can exhaust the 36-tab cap
  (`_rc_maxTabs`), after which `/bg` is refused with the S6 banner. Users reclaim slots
  with `/tab close <N>`.
- **S9 active-count cap is dormant project-wide**: `Tab.Ai.withActive` does not currently
  touch `_env_activeCount` (deferred since #51 WU6), so `/bg` turns are throttled only by
  S6 (max-tabs) and S7 (spawn rate), not by the concurrent-active cap. `/bg` inherits this
  existing gap; fixing S9 is out of scope here.
- **Focus race (TOCTOU)**: `focusedNow` is read once at turn start. If the user switches
  focus to/from the bg tab mid-turn, the "focused → no banner / unfocused → banner"
  guarantee holds only relative to turn-start focus. Matches the existing D4 producer-side
  optimisation semantics; acceptable for v1.

## Out of scope (possible follow-ups)
- Persisting bg results to a dedicated notification log.
- `/bg` for non-AI default kinds (harness/shell) — `/bg` is AI-prompt semantics.
- Auto-closing the bg tab after completion (it remains switchable via `/N`).
- Forcing a `/`-leading bg prompt to be treated as literal model input (currently it
  runs as a slash command in the bg tab).
