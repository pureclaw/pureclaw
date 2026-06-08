# Tabs-as-View Refactor — Implementation Plan

> **For agentic workers:** Decomposed into work units (WUs) with explicit file scope, dependencies, DoD, and TDD test strategy. Execute via the chosen execution method. Every WU is red/green TDD; commit per green step; **every WU ends with a green `-Werror` build** (no WU leaves the tree un-buildable). Coverage gate `.coverage-thresholds.json` (**95%** lines/branches/functions/statements) is blocking.

**Goal:** Re-found the tab layer as a first-class `TabRegistry` where a tab is a pure binding over ground truth (Session/Harness), with per-conversation persisted focus, chat-driven creation, and notified harness-death removal.

**Architecture:** New leaf modules `PureClaw.Tabs` (+ `.Wizard`, `.Relay`, `.SessionPool`, `.Persist`) own an ordered, persisted list of `Tab` bindings and per-`ConversationKey` cursors. The legacy per-tab-loop (`Tab.{Ai,Harness,Backend}`, `Routing.{AutoSpawn,Dashboard,Registry}`, `Handles.Tab`) and the global `_env_focus`/`_env_session` fields and the `ChannelOut` focus gate are all retired **together** in one coordinated cutover (WU8), so the tree goes green→green. The dispatcher remains the sole writer of tab/cursor state; the reconcile thread hands harness-death events to it via a queue. A refcounted `SessionId → SessionHandle` pool replaces the `_env_session` global.

**Tech Stack:** Haskell GHC 9.12.1 (GHC2021), `nix develop . --command cabal {build,test}`, hand-written Aeson codecs, IORef-by-default, Handle pattern, `-Wall -Werror`, hlint clean.

**Spec:** `docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md` (design-review-gate PASSED). Section refs below (§N) point there.

**Commands:**
- Build: `nix develop . --command cabal build`
- Test: `nix develop . --command cabal test`
- Coverage gate: `nix develop . --command cabal test --enable-coverage` (must meet `.coverage-thresholds.json` = 95%)
- Lint: `nix develop . --command hlint src test`
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

**Sequencing principle (drives the whole plan):** WU1–WU7 are **purely additive** — they create new modules + tests and the existing tree keeps compiling and passing untouched. **WU8 is the coordinated cutover** that rewires the dispatcher onto the new model and, in the same WU, removes the global fields and deletes every legacy module that referenced them — the only point at which old code is removed. WU9–WU11 finish on top of the new model. This guarantees no intermediate WU breaks `-Werror`.

---

## File Structure

**New:**
- `src/PureClaw/Tabs/Types.hs` — `Tab`, `TabRef`, `TabStatus`, `TabList` + pure registry ops; `ConversationKey`, `RelayMode`, `CursorState` + pure cursor ops.
- `src/PureClaw/Tabs.hs` — `TabRegistry` handle (IORef wrapper) + re-export surface.
- `src/PureClaw/Tabs/Persist.hs` — `state/` dir, `tabs.json` codec, boot restore/reconcile.
- `src/PureClaw/Tabs/SessionPool.hs` — refcounted `SessionId → SessionHandle` pool.
- `src/PureClaw/Tabs/Wizard.hs` — `/tab` attach wizard state machine.
- `src/PureClaw/Tabs/Relay.hs` — per-conversation output relay engine.
- `test/PureClaw/Tabs/*Spec.hs` — one spec per module.

**Modified:**
- `src/PureClaw/Core/Types.hs` — define `ConversationId` (leaf home, avoids cycle); add it as a required field of `MessageSource`/`mkMessageSource`.
- Channel ingress: `src/PureClaw/Handles/Channel.hs` (incl. `noopChannelHandle`), `src/PureClaw/Channels/*`, Telegram/Signal/Web/CLI — supply transport-derived `ConversationId`.
- `src/PureClaw/Agent/Env.hs` — (WU8) replace `_env_focus`/`_env_session` with `TabRegistry` + `CursorState` refs + `SessionPool` + lifecycle queue.
- `src/PureClaw/Routing/Dispatcher.hs` — (WU8) per-conversation dispatch; flat command handlers; wizard interception; lifecycle-queue drain.
- `src/PureClaw/Agent/SlashCommands.hs` + `src/PureClaw/Routing/Parse.hs` — (WU8) flat verbs; retire `/tab <sub>` family.
- `src/PureClaw/Agent/Loop.hs`, `src/PureClaw/CLI/Commands.hs` — (WU8) move off `_env_session`/legacy factory onto `SessionPool`/`TabRegistry`.
- `src/PureClaw/Harness/Reconcile.hs` — (WU9) `_rd_evict` enqueues a lifecycle event (consume existing seam; no new event system).
- `src/PureClaw/CLI/Config.hs` + `src/PureClaw/Routing/Config.hs` — (WU10) `[tabs]` config.
- `.coverage-thresholds.json` — (WU11) delete **retired** modules' staged waivers; bring **modified** modules to threshold.
- `test/Integration/CLISpec.hs` — (WU11) end-to-end chat surface.

**Retired in WU8 (deleted, superseded):** `src/PureClaw/Routing/AutoSpawn.hs`, `src/PureClaw/Routing/Registry.hs`, `src/PureClaw/Routing/Dashboard.hs`, `src/PureClaw/Routing/ChannelOut.hs` (gate logic → `Tabs.Relay`), `src/PureClaw/Routing/LegacyDispatch.hs` (its `dispatchLegacyTabCmd` wiring in `Agent/Loop.hs` is rewired onto the new dispatcher), `src/PureClaw/Tab/{Ai,Harness,Backend}.hs`.

**Slimmed, NOT deleted, in WU8:** `src/PureClaw/Handles/Tab.hs` — it mixes legacy runtime (`TabHandle`, the per-tab factory, `TabStatus(Active|Idle|Crashed)`) with **surviving spec/value types** (`TabKind`, `TabError`, `TabIndex`) that are consumed by out-of-scope/surviving modules: `Frontend/API.hs` (the POST `/api/tabs/new` path — frontend is out of scope, must stay untouched), `Routing/Types.hs` (`_rc_defaultKind :: TabKind`, `RoutingTabError`, `Switch !TabIndex`), `Routing/Config.hs` (`tabKindCodec`), `Routing/PromptRenderer.hs` (`TabIndex`). WU8 removes ONLY the legacy runtime parts and keeps `TabKind`/`TabError`, **re-exporting `TabIndex`** from `Tabs/Types.hs`. Update/retire `src/PureClaw/Handles/Tab.hs-boot` to match the slimmed module. Because the spec types survive in place, `Frontend/API.hs`, `Routing/Types.hs`, `Routing/Config.hs`, and `Routing/PromptRenderer.hs` need **no edits** (scope respected).

---

## Dependency DAG

```
Additive (tree stays green):
  WU1 ─► WU2 ─► WU3
   │      └────► WU6 (wizard pure)
   │      └────► WU7 (relay pure)
   WU4 (ConversationId; independent)
   WU5 (SessionPool module; needs WU1)

Cutover:
  WU1..WU7  ─►  WU8 (CUTOVER: rewire dispatcher; remove globals; delete legacy)

Finish:
  WU8 ─► WU9 (harness death) ─► WU10 (config + WARN + docs) ─► WU11 (integration + waivers + gate)
```

---

## WU1 — Core registry types & pure operations

**Files:**
- Create: `src/PureClaw/Tabs/Types.hs`, `src/PureClaw/Tabs.hs`
- Modify: `src/PureClaw/Core/Types.hs` (define `ConversationId` here — leaf home)
- Test: `test/PureClaw/Tabs/TypesSpec.hs`
- Reference: `src/PureClaw/Routing/Registry.hs` (`packAfterRemove`/`firstFree` — copy the pure arithmetic), `src/PureClaw/Handles/Tab.hs` (`TabIndex`, `mkTabIndex`, `unTabIndex`), `src/PureClaw/Session/Kind.hs` (`SessionId`, `HarnessId`)

**Dependencies:** none.

**Interfaces (contract for later WUs):**
```haskell
-- in Core.Types (leaf — so MessageSource can reference it without a cycle):
newtype ConversationId = ConversationId Text deriving stock (Eq, Ord, Show)

-- in Tabs/Types.hs:
data TabRef  = BoundSession !SessionId | BoundHarness !HarnessId deriving stock (Eq, Ord, Show)
data TabStatus = Live | Dead deriving stock (Eq, Show)
data Tab = Tab { _tab_slot :: !TabIndex, _tab_ref :: !TabRef, _tab_name :: !Text, _tab_status :: !TabStatus }
  deriving stock (Eq, Show)
newtype TabList = TabList [Tab]                 -- invariant I1: slots == [0..length)
data TabsError = SlotsFull | AlreadyBound !TabIndex deriving stock (Eq, Show)
appendTab  :: TabRef -> Text -> TabList -> Either TabsError (TabIndex, TabList)
removeSlot :: TabIndex -> TabList -> TabList
lookupSlot :: TabIndex -> TabList -> Maybe Tab
lookupRef  :: TabRef   -> TabList -> Maybe TabIndex
setStatus  :: TabRef -> TabStatus -> TabList -> TabList
```
`TabIndex` + `mkTabIndex`/`unTabIndex` move from `Handles/Tab.hs` into `Tabs/Types.hs` so the validated 0–35 arithmetic is retained. **`Handles/Tab.hs` MUST re-export them (mandatory, not optional)** — 10+ surviving importers (`Routing/Parse.hs`, `Routing/Types.hs`, `Routing/PromptRenderer.hs`, `Frontend/API.hs`, …) depend on `Handles.Tab.TabIndex`, so without the re-export WU1 itself ends red. `parseTabIndexChar` stays in `Routing/Parse.hs` (importing `TabIndex` from `Tabs/Types.hs`).

**TDD steps:**
- [ ] **Step 1 — failing test (I1 contiguity):** property — after any `appendTab`/`removeSlot` sequence, `map _tab_slot list == [0..n-1]`.
- [ ] **Step 2 — define types + `appendTab`/`removeSlot`** (reuse `packAfterRemove`/`firstFree`). Pass.
- [ ] **Step 3 — failing test (I2 dedup):** `appendTab` of an already-bound ref → `Left (AlreadyBound i)`.
- [ ] **Step 4 — implement dedup.** Pass.
- [ ] **Step 5 — failing test (36-cap):** 37th distinct ref → `Left SlotsFull`.
- [ ] **Step 6 — implement cap.** Pass.
- [ ] **Step 7 — failing test (compaction):** remove slot 1 of `[0,1,2]` → ref of old slot 2 now at slot 1 via `lookupRef`. Pass.
- [ ] **Step 8 — `Tabs.hs` handle** (`TabRegistry = TabRegistry (IORef TabList)` + IO wrappers); `ConversationId` in Core.Types. Build clean + commit.

**DoD:** I1/I2/cap/compaction property-tested; pure core ≥95%; `ConversationId` compiles in `Core.Types`; existing tree still green.

---

## WU2 — Cursors, ConversationKey, RelayMode (pure)

**Files:** Modify `src/PureClaw/Tabs/Types.hs`, `src/PureClaw/Tabs.hs`; Test `test/PureClaw/Tabs/CursorSpec.hs`
**Dependencies:** WU1. Imports `Core.Types` (`ChannelKind`, `ConversationId`).

**Interfaces:**
```haskell
type ConversationKey = (ChannelKind, ConversationId)
data RelayMode = FocusedOnly | ActivityDigest | Firehose deriving stock (Eq, Show)
data CursorState = CursorState { _cs_cursors :: !(Map ConversationKey TabRef)
                               , _cs_relay   :: !(Map ConversationKey RelayMode) }
setCursor :: ConversationKey -> TabRef -> CursorState -> CursorState
clearCursor :: ConversationKey -> CursorState -> CursorState
resolveCursorSlot :: ConversationKey -> CursorState -> TabList -> Maybe TabIndex   -- I3
conversationsOn :: TabRef -> CursorState -> [ConversationKey]
pruneDangling :: TabList -> CursorState -> CursorState
relayModeFor :: ConversationKey -> RelayMode -> CursorState -> RelayMode  -- 2nd arg = global default
```

**TDD steps:**
- [ ] **Step 1 — failing test (I3 under compaction):** `setCursor` → `resolveCursorSlot` tracks the ref across `removeSlot` shifts. Pass.
- [ ] **Step 2 — `pruneDangling`** clears cursors whose ref is gone. Test + impl.
- [ ] **Step 3 — `conversationsOn`** returns exactly the keys on a ref. Test + impl.
- [ ] **Step 4 — `relayModeFor`** override-or-default. Test + impl. Commit.

**DoD:** I3 property-tested; cursor helpers ≥95%; tree green.

---

## WU3 — Persistence: `state/` + `tabs.json` + boot reconcile

**Files:** Create `src/PureClaw/Tabs/Persist.hs`, `test/PureClaw/Tabs/PersistSpec.hs`; Reference `src/PureClaw/Security/Path.hs` (`ensureRuntimeRoot` 0700), `src/PureClaw/Harness/Registry.hs`
**Dependencies:** WU1, WU2.

**Interfaces:**
```haskell
data PersistDeps = PersistDeps { _pd_stateDir :: FilePath, _pd_harnessLive :: HarnessId -> IO Bool
                               , _pd_discoveryReady :: IO () }
saveTabs :: FilePath -> TabList -> CursorState -> IO ()        -- tabs.json 0600 under state/ 0700
loadTabs :: PersistDeps -> IO (TabList, CursorState)           -- decode-fail -> fresh; await discovery; reconcile; prune
```

**TDD steps:**
- [ ] **Step 1 — round-trip** (hand-written Aeson). Test + impl.
- [ ] **Step 2 — perms** (`tabs.json` 0600, `state/` 0700). Test (`System.Posix.Files`) + impl via `ensureRuntimeRoot`.
- [ ] **Step 3 — decode failure → fresh** (no exception). Test + impl.
- [ ] **Step 4 — boot reconcile:** drop harness tab whose `_pd_harnessLive` is False (silent), prune its cursor, keep provider tabs, await `_pd_discoveryReady` before pruning. Test + impl.
- [ ] **Step 5 — no-secrets assertion:** serialize a tab and assert JSON keys contain no token/path fields. Commit.

**DoD:** round-trip/perms/fresh-start/reconcile/no-secrets tested; injected deps give ≥95% without real tmux; tree green.

---

## WU4 — `ConversationId` through `MessageSource` (server-derived)

**Files:** Modify `src/PureClaw/Core/Types.hs` (`MessageSource`, `mkMessageSource`), `src/PureClaw/Handles/Channel.hs` (**incl. `noopChannelHandle`**), Telegram/Signal/Web/CLI ingress; Test `test/PureClaw/Core/MessageSourceSpec.hs`
**Dependencies:** WU1 (for `ConversationId`). Do early — wide `-Werror` blast radius. **Additive** (does not remove any global).

**TDD steps:**
- [ ] **Step 1 — forgery test:** a `conversation_id` in message *fields/body* is ignored; the id comes only from the transport arg. Fail → add `_ms_conversation :: ConversationId` as a **required positional** arg to `mkMessageSource`; fix **every** call site (compiler-driven, incl. `noopChannelHandle`). Pass.
- [ ] **Step 2 — per-channel derivation tests:** CLI → `"cli"`; Telegram → `_tm_chat` (NOT `_tm_from`); Signal → contact/group; Web → server-minted token. One each. Pass.
- [ ] **Step 3 — group-chat shared cursor:** two senders, one Telegram chat id → same `ConversationKey`. Pass.
- [ ] **Step 4 — build + commit** (clean `-Werror`).

**DoD:** forgery/per-channel/group tests pass; all `mkMessageSource` sites supply transport-derived ids; tree green.

---

## WU5 — Session-handle pool (additive module)

**Files:** Create `src/PureClaw/Tabs/SessionPool.hs`, `test/PureClaw/Tabs/SessionPoolSpec.hs`
**Dependencies:** WU1. **Additive** — the module is built and unit-tested here; it is **wired in** (and `_env_session` removed) in WU8.

**Interfaces:**
```haskell
data PoolDeps = PoolDeps { _pool_open :: SessionId -> IO SessionHandle, _pool_close :: SessionHandle -> IO () }
data SessionPool = SessionPool (IORef (Map SessionId (Int, SessionHandle)))
newSessionPool :: SessionPool
acquire :: PoolDeps -> SessionPool -> SessionId -> IO SessionHandle   -- open-on-first, ++refcount
release :: PoolDeps -> SessionPool -> SessionId -> IO ()              -- --refcount, close-on-last
```

**TDD steps:**
- [ ] **Step 1 — refcount:** two `acquire` of one id → injected open counter == 1, refcount 2; one `release` keeps open; second closes (close counter == 1). Test + impl.
- [ ] **Step 2 — shared handle:** two ids... two tabs same id resolve same handle. Test + impl. Commit.

**DoD:** refcount + shared-handle tested via injected seams; ≥95%; tree green (module not yet wired).

---

## WU6 — Attach wizard state machine (additive, pure)

**Files:** Create `src/PureClaw/Tabs/Wizard.hs`, `test/PureClaw/Tabs/WizardSpec.hs`
**Dependencies:** WU1, WU2. **Additive** — interception into the dispatcher happens in WU8.

**Interfaces:**
```haskell
data WizardTarget = AttachHarness !HarnessId | ReopenSession !SessionId deriving stock (Eq, Show)
data WizardState  = WizardState { _wz_options :: [(Char, WizardTarget)] }   -- snapshot, stable numbering
data WizardStep   = Prompt !Text | Done !WizardTarget | Cancelled | Reprompt !Text | RunCommand !Text
data WizardEnv = WizardEnv { _wz_live :: HarnessId -> IO Bool }
stepWizard :: WizardEnv -> WizardState -> Text -> IO (Maybe WizardState, WizardStep)
mkWizardSnapshot :: [(HarnessId, Text)] -> [(SessionId, Text)] -> WizardState   -- cap at [0-9a-z]
```

**TDD steps:**
- [ ] **Step 1 — valid pick binds snapshot id** (not position re-resolved) → `Done`. Test + impl.
- [ ] **Step 2 — vanished target** (`_wz_live` False) → `Reprompt "that target is gone — list refreshed"`. Test + impl.
- [ ] **Step 3 — cancel paths:** `0` → `Cancelled`; `/`-prefixed → `RunCommand`; invalid → `Reprompt`. Test + impl.
- [ ] **Step 4 — overflow/query cap** at `[0-9a-z]`; `/tab <query>` sanitized substring filter. Test + impl. Commit.

**DoD:** full state-machine matrix tested; ≥95%; tree green.

---

## WU7 — Relay engine (additive, pure with injected sink)

**Files:** Create `src/PureClaw/Tabs/Relay.hs`, `test/PureClaw/Tabs/RelaySpec.hs`
**Dependencies:** WU2. **Additive** — replaces `ChannelOut` gate in WU8.

**Interfaces:**
```haskell
data RelayDeps = RelayDeps { _rl_sink :: ConversationKey -> Text -> IO () }   -- injected sink
relayOutput :: RelayDeps -> CursorState -> RelayMode -> TabList -> TabRef -> Text -> IO ()  -- single writer, fans out
```

**TDD steps:**
- [ ] **Step 1 — FocusedOnly:** output from T reaches only conversations whose cursor == T. Test (recorder sink) + impl.
- [ ] **Step 2 — ActivityDigest:** focused gets full content; others get a name-first activity ping for T (once per burst). Test + impl.
- [ ] **Step 3 — Firehose:** Firehose conversation gets full content from all live tabs. Test + impl.
- [ ] **Step 4 — ordering:** single writer preserves emission order across sinks. Test + impl. Commit.

**DoD:** RelayMode × fg/bg × multi-conversation matrix + ordering tested via injected sink; ≥95%; tree green.

---

## WU8 — CUTOVER: rewire dispatcher; remove globals; delete legacy

> **This is the one large, coordinated WU.** It is the only place old code is removed. The tree is green before (old model) and green after (new model). Recommended to execute with extra checkpoints. Internal steps are TDD for the new behavior; the `-Werror` build is re-green at the **end** of the WU.

**Files:**
- Modify: `src/PureClaw/Agent/Env.hs` (remove `_env_focus`, `_env_session`; add `TabRegistry`, `CursorState` ref, `SessionPool`, lifecycle `TQueue`), `src/PureClaw/Routing/Dispatcher.hs` (per-conversation dispatch + flat command handlers + wizard interception + queue drain stub), `src/PureClaw/Agent/SlashCommands.hs` + `src/PureClaw/Routing/Parse.hs` (flat verbs; retire `/tab <sub>`), `src/PureClaw/Agent/Loop.hs` (rewire off `dispatchLegacyTabCmd`/`LegacyDispatch` onto the new dispatcher; onto `SessionPool`) + `src/PureClaw/CLI/Commands.hs` (onto `SessionPool`/`TabRegistry`), `src/PureClaw/Handles/Tab.hs` + `src/PureClaw/Handles/Tab.hs-boot` (**slim**: delete legacy `TabHandle`/factory/`TabStatus`; keep `TabKind`/`TabError`; re-export `TabIndex` from `Tabs/Types.hs`), `*.cabal` (drop deleted modules + their specs).
- Delete: `src/PureClaw/Routing/{AutoSpawn,Registry,Dashboard,ChannelOut,LegacyDispatch}.hs`, `src/PureClaw/Tab/{Ai,Harness,Backend}.hs` (and their test specs).
- Untouched by design (spec types survive in slimmed `Handles.Tab`): `src/PureClaw/Frontend/API.hs`, `src/PureClaw/Routing/{Types,Config,PromptRenderer}.hs`.
- Test: `test/PureClaw/Routing/DispatchSpec.hs`, `test/PureClaw/Routing/TabCommandsSpec.hs`

**Dependencies:** WU1–WU7.

**TDD steps:**
- [ ] **Step 1 — `AgentEnv` swap:** replace `_env_focus`/`_env_session` with the new refs + pool + lifecycle queue; wire `Tabs.Relay` as the output path replacing `ChannelOut.shouldEmit`; wire `SessionPool.acquire/release` into the AI tab loop. (Red until the legacy modules are deleted in Step 2.)
- [ ] **Step 2 — delete legacy + slim `Handles.Tab`:** delete `Routing.{AutoSpawn,Registry,Dashboard,ChannelOut,LegacyDispatch}` + `Tab.{Ai,Harness,Backend}` + their specs + `.cabal` entries; **slim** `Handles.Tab` (drop `TabHandle`/factory/`TabStatus`; keep `TabKind`/`TabError`; re-export `TabIndex`) and update its `.hs-boot`; rewire `Agent/Loop.hs` off `dispatchLegacyTabCmd` onto the new dispatcher; fix every dangling import in `Dispatcher.hs:137,149-151`, `Agent/Loop.hs:37,136`, `CLI/Commands.hs`, `SlashCommands.hs`. Verify `Frontend/API.hs` + `Routing/{Types,Config,PromptRenderer}.hs` still compile **unchanged** (they use only the surviving `TabKind`/`TabError`/`TabIndex`). Build must be clean here.
- [ ] **Step 3 — per-conversation dispatch tests:** `/2` from conversation A sets A's cursor only (B unchanged); plain text → active tab; empty cursor → `no active tab — /new to start one or /tab to attach`; `/5` of 3 tabs → `/5: out of range — you have 3 tabs (/0–/2); /tabs to list`. Implement against `CursorState`. Pass.
- [ ] **Step 4 — `/new` reset (+ no-default + at-36):** `/new` rebinds the active tab's slot to a fresh session, prior session persists (I4); with no active tab it creates one; **`/new` still works at 36 slots**; with no default provider configured → `no default provider configured — set one with /target default <name> (or config.toml)`. Tests for each. Implement. Pass.
- [ ] **Step 5 — `/nt` (+ exhaustion):** appends + switches; at 36 → `all 36 tab slots in use — /close one first`, no state change; no-default-provider hint as in Step 4. Tests + impl. Pass.
- [ ] **Step 6 — `/close` / `/tabs` / `/rename` / `/relay`:** `/close` default active, preserves ground truth (I4), `--force` → `/close has no --force (...)`; `/tabs` lists incl. relay mode + Dead tombstones; `/rename` sanitized (ESC/CSI stripped — round-trip assert); `/relay` sets mode, no-arg → `relay mode: focused (focused | activity | all)`. Tests + impl. Pass.
- [ ] **Step 7 — wizard interception:** while a conversation has `WizardState`, its next message goes to `stepWizard` **before** `parseInput` (bare `1` is a menu choice); `RunCommand`/`Cancelled`/`Reprompt`/`Done` handled; `Done` binds the tab + switches (reopen = continue/append, dedups per I2). Tests + impl. Pass.
- [ ] **Step 8 — Dead-tombstone deferred routing:** plain text with cursor on a `Dead` tab → deferred warning, **drop** the message, **zero bytes reach the harness send seam** (assert injected sink), clear cursor. Test + impl.
- [ ] **Step 9 — concurrency (spec §6.5/§15):** two `ConversationKey`s sending to the same `TabRef` both reach the tab input queue, none dropped. Test + impl.
- [ ] **Step 10 — full green:** `cabal build` `-Werror` clean; the per-conversation focus model fully replaces `_env_focus`. Commit.

**DoD:** legacy modules deleted; globals removed; all routing + command + wizard-interception + tombstone + concurrency tests pass; §14 copy asserted; tree green at WU end.

---

## WU9 — Harness-death notified two-phase removal

**Files:** Modify `src/PureClaw/Harness/Reconcile.hs` (`_rd_evict` → enqueue lifecycle event), `src/PureClaw/Routing/Dispatcher.hs` (drain queue, apply), `src/PureClaw/Tabs/Types.hs` (status transitions); Test `test/PureClaw/Tabs/DeathSpec.hs`
**Dependencies:** WU8.

**TDD steps:**
- [ ] **Step 1 — notify enabled:** evict event → `⚠ "<name>" (harness, was /N) exited — tab closed` (slot snapshotted at notify) to focused conversations, then remove + compact + clear cursors. Drive via queue (no real tmux). Test + impl.
- [ ] **Step 2 — notify disabled:** tab → `Dead`; next focused message → `⚠ "<name>" exited while you were away — message not sent; resend when ready`, **drops** message (zero bytes to harness sink), then removes. Test + impl.
- [ ] **Step 3 — per-channel override** resolves global vs per-`ChannelKind` (config value stubbed; real read in WU10). Test + impl.
- [ ] **Step 4 — tombstone visible in `/tabs`** until removed. Test.
- [ ] **Step 5 — background tombstone via ActivityDigest** still delivers the single death notification. Test + impl.
- [ ] **Step 6 — no double-delete:** assert the tab layer does NOT call `Reg.deleteEntry` (reconcile already did). Test.
- [ ] **Step 7 — boot-drop emits zero death notices** (the documented I5 exception): the WU3 boot reconcile path triggers NO `⚠` notice. Test. Commit.

**DoD:** enabled/disabled/per-channel/no-misroute/tombstone/background/no-double-delete/boot-silent tested; exactly-one-notification for live deaths guaranteed; thread-safe hand-off; tree green.

---

## WU10 — Config `[tabs]` + AllowAll boot WARN + §2 docs + `.gitignore`

**Files:** Modify `src/PureClaw/CLI/Config.hs`, `src/PureClaw/Routing/Config.hs`, boot path `src/PureClaw/CLI/Commands.hs`, allow-list warning seam (per `channel-allowlist-warning`); doc/code comment for §2; `.gitignore` guidance; Test `test/PureClaw/CLI/TabsConfigSpec.hs`
**Dependencies:** WU8, WU9.

**TDD steps:**
- [ ] **Step 1 — config parse:** `[tabs] notify_on_harness_death`, per-channel overrides, `default_relay`; defaults (notify ON, FocusedOnly) when absent. Test + impl.
- [ ] **Step 2 — AllowAll WARN:** any active channel resolving to `AllowAll` while tabs are shared-global → boot WARN to stderr (reuse PR #73 seam). Test (captured logger) + impl.
- [ ] **Step 3 — §2 trust-model docs:** write the single-operator / multi-tenant-out-of-scope statement into module haddock on `PureClaw.Tabs` and a short note in `docs/` (or CLAUDE.md security section); `.gitignore` guidance names `state/`. Test asserts the gitignore guidance names `state/`. Commit.

**DoD:** config parse + defaults + WARN tested; §2 documented in code/docs; `state/` gitignore guidance shipped; tree green.

---

## WU11 — CLI integration, waiver cleanup, final gate

**Files:** Modify `test/Integration/CLISpec.hs`, `.coverage-thresholds.json`
**Dependencies:** all.

**TDD steps:**
- [ ] **Step 1 — CLI integration:** spawn the real `pureclaw` binary; drive `/new`, `/nt`, `/tab` (wizard happy path), `/close`, `/0`, `/relay`, asserting §14 copy + tab-list output. Run `nix develop . --command cabal test`.
- [ ] **Step 2 — staged-waiver cleanup (precise):** treat `.coverage-thresholds.json` as ground truth for which waivers exist. **Delete** the waivers for **retired** modules **that have one** — confirmed present today: `Routing.AutoSpawn`, `Routing.Dashboard`, `Tab.{Ai,Harness,Backend}`, `Handles.Tab` (note: `Handles.Tab` is slimmed not deleted, but its legacy runtime is gone, so its waiver should be removed and the slimmed module covered; `Routing.Registry`/`Routing.ChannelOut`/`Routing.LegacyDispatch` have **no** waiver entry — nothing to delete). For **modified-not-retired** modules (`Routing.Dispatcher`, `Harness.Reconcile`) bring them to ≥95% as a blocking gate **or** keep/extend a justified waiver — do NOT silently delete. Leave unrelated survivors (`Frontend.*`, `Harness.Tmux`, `Harness.ClaudeCode`) untouched. New `Tabs.*` modules carry **no** waivers (injected seams make them reachable).
- [ ] **Step 3 — full gate:** `cabal test --enable-coverage` meets `.coverage-thresholds.json` (95%); `hlint src test` clean; `cabal build` `-Werror` clean.
- [ ] **Step 4 — file frontend-parity follow-up issue** in the epic, referencing #79. Commit.

**DoD:** end-to-end chat surface green against the real binary; retired waivers removed, modified-module coverage satisfied, survivors intact; coverage/lint/build gates pass; follow-up filed.

---

## Spec coverage map (self-review)

| Spec § | WU |
|---|---|
| §2 trust model + AllowAll WARN + docs | WU10 |
| §4 Tab/TabRef/TabRegistry | WU1 |
| §5 I1–I5 | WU1 (I1,I2), WU2 (I3), WU8 (I4 via `/new`,`/close`), WU9 (I5) |
| §6.1 `/new` vs `/nt`, §6.2 exhaustion (+`/new`@36), §6.4 compaction | WU8, WU1 |
| §6.3 reopen continue/append + dedup | WU8 Step 7 |
| §6.5 concurrency shared-tab | WU8 Step 9 |
| §7 command surface | WU8 |
| §8 harness death | WU9 |
| §9.1 ConversationId | WU4 |
| §9.2 inbound routing | WU8 |
| §9.3 relay engine | WU7 (engine), WU8 (wired) |
| §10 persistence/perms/boot (+boot-drop-zero-notices) | WU3, WU9 Step 7 |
| §11 wizard | WU6 (engine), WU8 (interception) |
| §12 reuse/rebuild + waivers | WU1 (reuse), WU8 (delete legacy), WU11 (waivers) |
| §13 session-handle pool + test seams | WU5 (pool), WU8 (wired); injected deps in WU3/WU5/WU7/WU9 |
| §14 message copy (incl. no-default-provider) | WU8, WU9 (asserted), WU11 (CLI) |
| §15 tests / DoD | every WU (concurrency WU8.9; boot-drop WU9.7) |

**Risk notes:** WU8 is the large coordinated cutover — the only un-removable concentration of risk, justified because `-Werror` forbids leaving legacy code half-wired. It is sequenced after all additive modules exist, so it is purely "swap the wiring + delete the dead." WU4's `-Werror` blast radius is contained by being additive and compiler-driven. Coverage gate is **95%** (`.coverage-thresholds.json`), the authoritative source per CLAUDE.md.
