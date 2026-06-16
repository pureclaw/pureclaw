# Uniform `/tab` command dispatch across TUI, channels, and web

**Status:** Design approved by user 2026-06-16 (decisions captured below)
**Branch:** feat/web-frontend-slash-dispatch (extends the slash-dispatch PR #85)

## Problem (two symptoms, one root cause)

`/tab rename` and `/tab close` behave inconsistently by surface:

| Symptom | Root cause |
|---|---|
| Web frontend `/tab rename`/`/tab close` silently fail | `executeSlashCommand (CmdTab _)` is a dead **no-op stub** (`SlashCommands.hs:1224`) that emits "Tab commands require the tabbed-chat dispatcher (`PureClaw.Routing.Dispatcher.runDispatcher`)" — a module that does not exist. |
| TUI `/tabs rename 0 x` silently lists instead of renaming | The flat-verb matcher `("/tabs" : _) -> cmdTabs` (`TabDispatch.hs:233`) greedily matches `/tabs` and **ignores trailing args**. (Singular `/tab rename`/`/rename` work; the user typed plural `/tabs rename`.) |

Tab commands are dispatched by an ad-hoc tangle of flat-verb matchers in `TabDispatch` (the only place with the real logic) and a dead stub in `executeSlashCommand` (the path the web frontend uses). There is no single uniform dispatch.

## Decisions (from the user)

1. **Shared implementation, keep entry points.** Keep `/tab rename`, `/rename`, `/tabs`, `/close`, the web chat box, etc., but route them ALL through one shared tab-command function. Identical results on every surface; minimal behavior change.
2. **`/tabs <sub> …` aliases to `/tab <sub> …`** (so `/tabs rename 0 x` renames). Bare `/tabs` still lists.
3. **Defer** the web tab-UI rename affordance (a `POST /api/tabs/{n}/rename` endpoint + button) to a separate follow-up. (Also: the user reports not seeing a *close* button in the web UI — tracked as a separate frontend follow-up, out of scope here.)

## Key findings (verified)

- The canonical handlers (`cmdClose`/`closeSlot`, `cmdRename`/`doRename`, `cmdTabs`, `cmdTabNew`/`bindNewTab`, `cmdTab` wizard) all live in `TabDispatch.hs` and operate on `Ctx = TabDispatchDeps + ConversationKey`.
- `TabDispatchDeps` is built by `Wiring.mkTabDispatchDeps` from the **same** `AgentEnv` cells: `_td_tabs = _env_tabRegistry`, `_td_cursors = _env_cursors`, `_td_ensure/_td_release/_td_sendTo` over `_env_exec`, `_td_onTabsChanged = _env_onTabsChanged`, `_td_spawnHarness = _env_startHarness`, `_td_routingConfig = _env_routingConfig`. So a shared function over these cells mutates exactly the state `TabDispatch` mutates. The web `FrontendEnv` shares the same cells too.
- **`ConversationKey` dependency** (the only `_ctx_conv` uses): the `(focused)` marker + relay line in `cmdTabs`; auto-focus in `cmdTabNew` (`bindNewTab` → `setCursorTo`); bare-`/close`/`/rename` target resolution; the wizard (keyed by conversation). **All global mutations** (close-by-index, rename-by-index, append, and the *global* cursor cleanup `closeSlot` already does across all cursors on the closed ref) are key-independent.
- **The web/`executeSlashCommand` path has no `ConversationKey`** (`AgentEnv` carries none; a web `sid` is a session id, not a `(ChannelKind, ConversationId)` cursor key). So the shared function must accept `Maybe ConversationKey`.
- On the **TUI/channel** side the conversation key IS available — both at the flat-verb handlers (`_ctx_conv`) and at the `fallthrough` boundary (`Wiring.fallthrough env store convKey cmd`).
- Import direction: `SlashCommands` must not depend on `Routing.TabDispatch`/`Tabs.Wiring`. Solve with an `AgentEnv` callback seam (mirroring `_env_onTabsChanged`/`_env_startHarness`).

## Design

### 1. Shared function `runTabCommand`

In `PureClaw.Routing.TabDispatch` (sibling to `handleInbound`):

```haskell
runTabCommand
  :: TabDispatchDeps        -- the shared seams (registry/cursors/exec/emit/factories/onTabsChanged/spawnHarness)
  -> Maybe ConversationKey  -- Just k for TUI/channels (conv-relative focus/marker/relay/wizard);
                            -- Nothing for the web (global mutations only)
  -> Slash.TabSlashCommand  -- parsed CmdTab payload: TabListCmd | TabCloseCmd | TabRenameCmd | TabNewCmd | TabFocusCmd | TabResumeCmd
  -> IO ()
```

Internals reuse the existing helpers. The conversation-relative parts are gated on the key:
- `TabListCmd`: render the list; include the `(focused)` marker + relay line ONLY when `Just k` (with `Nothing`, omit the marker / use the default relay line).
- `TabNewCmd`: append + spawn unconditionally; auto-focus (`setCursor k`) ONLY when `Just k`.
- `TabCloseCmd idx`: `closeSlot` by explicit index (global; global cursor cleanup unchanged). (Bare-close target resolution is the flat-verb layer's concern — see §2.)
- `TabRenameCmd idx name`: `doRename` by explicit index (global; no key needed).
- `TabFocusCmd idx`: set THIS conversation's cursor — requires `Just k`; with `Nothing` (web), emit a "tab focus isn't available from the web client" message (the web UI navigates tabs itself, like the `/N` carveout).
- `TabResumeCmd`: as today; conversation-relative focus gated on `Just k`.

Existing `Ctx`-based flat-verb handlers become thin adapters that parse their args into a `TabSlashCommand` (or keep arg parsing and call shared sub-helpers) and call `runTabCommand deps (Just (_ctx_conv ctx)) cmd`.

### 2. Call sites (all route through `runTabCommand`)

- **TUI/channel flat-verbs** (`handleNonWizard`): `cmdClose`/`cmdRename`/`cmdTabs`/`cmdTabNew` call `runTabCommand deps (Just convKey) …`. (Bare `/close`/`/rename` — no index — resolve the target slot from the cursor here, where the key is in scope, then call `runTabCommand` with an explicit index.)
- **TUI/channel grammar path** (`Wiring.fallthrough`): add `Slash.CmdTab sub -> runTabCommand deps (Just convKey) sub` so `/tab focus`, `/tab resume`, and any `/tab` form not caught by a flat verb run with the conversation key (today they hit the dead stub).
- **Web** (`executeSlashCommand (CmdTab sub)`): replace the stub with `_env_runTabCommand env Nothing sub` (the new seam). The web `runSlashInput`/`handleSend` need no change beyond this — they already route `CmdTab` to `executeSlashCommand`.

### 3. `AgentEnv` seam

Add to `AgentEnv` (mirroring `_env_onTabsChanged`/`_env_startHarness`):

```haskell
, _env_runTabCommand :: Maybe ConversationKey -> Slash.TabSlashCommand -> IO ()
```

- Default (`noRunTabCommand`): a stub that reports tab commands aren't wired (for tests/non-CLI construction), like `noStartHarness`.
- Production: wired in `Tabs.Wiring`/`CLI.Commands` to `runTabCommand deps` (the deps built by `mkTabDispatchDeps`). This keeps `SlashCommands` free of any `TabDispatch`/`Wiring` import — it just calls the callback. Every `AgentEnv` construction site must set the field (`-Werror`); the shared `mkTestAgentEnv` uses the default.

### 4. `/tabs <sub>` alias

- In `Parse.parseTabFamily`: add a `"/tabs " `T.isPrefixOf`` arm that strips `/tabs ` and delegates to `parseTabAction`, exactly like the existing `/tab ` arm. This is the single canonical parser used by both `parseInput` (TUI/channels) and `classifyInput` (web), so `/tabs rename 0 x` parses to `CmdTab (TabRenameCmd 0 "x")` everywhere at once.
- In `TabDispatch.handleNonWizard`: change `("/tabs" : _) -> cmdTabs` so that `/tabs` with a recognized subcommand routes to the same handler as `/tab <sub>` (bare `/tabs` still lists). This keeps the TUI flat-verb fast-path consistent with the parser (the flat matcher runs before the grammar).

## Behavior after the change

- `/tab rename N x`, `/tab close N`, `/tabs rename N x`, `/tabs close N`, `/rename`, `/close` work identically on TUI, channels, and the web chat box.
- `/tab new`, `/tab list`/`/tabs`, `/tab focus`, `/tab resume` go through the shared function too (no more dead stub). On the web, `/tab focus` returns a "navigate via the UI" message (conv-relative, like `/N`); list/new/close/rename perform their global effects.
- TUI/channel behavior is unchanged (still `Just convKey`, full conv-relative behavior).

## Concurrency note (for review)

The web path becomes a second writer to the `TabRegistry`/cursors alongside the dispatcher thread — but the web **already** mutates the registry concurrently via the existing REST endpoints (`handleCloseTab`/`handleNewTab` call `registryRemove`/`registryAppend`). So this introduces no new concurrency exposure; reuse the registry's existing atomic ops, and prefer `atomicModifyIORef'` for any cursor/registry mutation the shared function performs.

## Testing (TDD)

- **Parser**: `/tabs rename 0 x` and `/tabs close 0` parse to `CmdTab (TabRenameCmd …/TabCloseCmd …)` (via `parseInput` and `classifyInput`); bare `/tabs` still parses to `TabListCmd`.
- **Shared function**: `runTabCommand deps Nothing (TabRenameCmd 0 "x")` renames slot 0 in the registry; `(TabCloseCmd 0 …)` removes it; `Nothing` omits the focus/marker; `Just k` sets the cursor. Unit tests over a test `TabDispatchDeps`.
- **TUI regression**: the existing TabDispatch flat-verb specs still pass (cmdClose/cmdRename behavior unchanged); `/tabs rename` now renames instead of listing.
- **Web integration** (APISpec): `POST /send {"message":"/tab rename 0 x"}` and `/tab close 0` (and the `/tabs` plural forms) actually mutate the shared `TabRegistry` (assert the registry/state after the request); `kind:"slash"`; provider not called.
- Coverage: new logic ≥95% (`.coverage-thresholds.json`).

## Affected files

`src/PureClaw/Routing/TabDispatch.hs` (extract `runTabCommand`; refactor flat-verbs), `src/PureClaw/Tabs/Wiring.hs` (`fallthrough` CmdTab arm; wire `_env_runTabCommand`), `src/PureClaw/Agent/SlashCommands.hs` (replace the `CmdTab` stub), `src/PureClaw/Agent/Env.hs` (`_env_runTabCommand` field + default), `src/PureClaw/Routing/Parse.hs` (`/tabs <sub>` alias), `src/PureClaw/CLI/Commands.hs` (wire the seam at the production `AgentEnv`), tests + `test/Support/AgentEnv.hs` (default seam).
