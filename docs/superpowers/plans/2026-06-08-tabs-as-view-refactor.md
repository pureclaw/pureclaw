# Tabs-as-View Refactor — Implementation Plan

> **For agentic workers:** This plan is decomposed into work units (WUs) with explicit file scope, dependencies, DoD, and TDD test strategy. Execute via the chosen execution method (metaswarm orchestrated-execution, superpowers:subagent-driven-development, or superpowers:executing-plans). Every WU is red/green TDD; commit per green step. 100% coverage gate (`.coverage-thresholds.json`) is blocking.

**Goal:** Re-found the tab layer as a first-class `TabRegistry` where a tab is a pure binding over ground truth (Session/Harness), with per-conversation persisted focus, chat-driven creation, and notified harness-death removal.

**Architecture:** New leaf modules `PureClaw.Tabs` (+ `.Wizard`, `.Relay`) own an ordered, persisted list of `Tab` bindings and per-`ConversationKey` cursors. The dispatcher remains the sole writer of tab/cursor state; the reconcile thread hands harness-death events to it via a queue. Tabs reference ground truth; a refcounted `SessionId → SessionHandle` pool replaces the `_env_session` global. Output is fanned out per conversation by a `RelayMode` engine replacing the single-focus `ChannelOut` gate.

**Tech Stack:** Haskell GHC 9.12.1 (GHC2021), `nix develop . --command cabal {build,test}`, hand-written Aeson codecs, IORef-by-default, Handle pattern, `-Wall -Werror`, hlint clean.

**Spec:** `docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md` (design-review-gate PASSED). Section refs below (§N) point there.

**Commands (use everywhere):**
- Build: `nix develop . --command cabal build`
- Test (one suite): `nix develop . --command cabal test`
- Coverage gate: `nix develop . --command cabal test --enable-coverage`
- Lint: `nix develop . --command hlint src test`
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure (decomposition locked here)

**New:**
- `src/PureClaw/Tabs.hs` — re-export surface + `TabRegistry` handle.
- `src/PureClaw/Tabs/Types.hs` — `Tab`, `TabRef`, `TabStatus`, `ConversationKey`, `ConversationId`, `RelayMode`, pure registry/cursor core.
- `src/PureClaw/Tabs/Persist.hs` — `state/` dir, `tabs.json` codec, boot restore/reconcile.
- `src/PureClaw/Tabs/Wizard.hs` — `/tab` attach wizard state machine.
- `src/PureClaw/Tabs/Relay.hs` — per-conversation output relay engine.
- `src/PureClaw/Tabs/SessionPool.hs` — refcounted `SessionId → SessionHandle` pool.
- `test/PureClaw/Tabs/*Spec.hs` — one spec per module.

**Modified:**
- `src/PureClaw/Core/Types.hs` — add `ConversationId` to `MessageSource` (required arg).
- `src/PureClaw/Agent/Env.hs` — replace `_env_focus`/`_env_session` with `TabRegistry` + pool refs.
- `src/PureClaw/Routing/Dispatcher.hs` — per-conversation dispatch; lifecycle-event queue.
- `src/PureClaw/Routing/ChannelOut.hs` — replaced by `Tabs.Relay` (gate removed).
- `src/PureClaw/Agent/SlashCommands.hs` + `src/PureClaw/Routing/Parse.hs` — flat verbs; retire `/tab <sub>` family.
- Channel handles (`src/PureClaw/Channels/*`, Telegram/Signal/CLI/Web) — supply `ConversationId`.
- `src/PureClaw/Harness/Reconcile.hs` — `_rd_evict` hand-off to dispatcher queue (consume existing seam; no new event system).
- `src/PureClaw/CLI/Config.hs` + `Routing/Config.hs` — `[tabs]` config (`notifyOnHarnessDeath`, default relay).
- `.coverage-thresholds.json` — delete retired modules' staged waivers.
- `test/Integration/CLISpec.hs` — end-to-end chat surface.

**Retired (deleted as superseded):** `src/PureClaw/Routing/AutoSpawn.hs`, `src/PureClaw/Routing/Registry.hs`, `src/PureClaw/Routing/Dashboard.hs`, `src/PureClaw/Tab/{Ai,Harness,Backend}.hs`, `src/PureClaw/Handles/Tab.hs` (its `TabStatus`/`TabIndex` either move to `Tabs/Types.hs` or are re-exported — see WU1).

---

## Dependency DAG

```
WU1 ──► WU2 ──► WU3
  │        │       │
  │        ├──► WU6 ──► WU7 ──► WU8
  │        │     │        │
  WU5 ─────┘     ├──► WU9 ─┴──► WU10 ──► WU11 ──► WU12
  WU4 ───────────┘
```
- WU1 (core types) and WU4 (ConversationId plumbing) have no inter-dep and may run first/parallel.
- WU12 is the final integration + cleanup; depends on all.

---

## WU1 — Core registry types & pure operations

**Files:**
- Create: `src/PureClaw/Tabs/Types.hs`, `src/PureClaw/Tabs.hs`
- Test: `test/PureClaw/Tabs/TypesSpec.hs`
- Reference: `src/PureClaw/Routing/Parse.hs` (`parseTabIndexChar`, `mkTabIndex`, `TabIndex`), `src/PureClaw/Session/Kind.hs` (`SessionId`, `HarnessId`)

**Dependencies:** none (leaf; imports `Session.Kind` only).

**Interfaces to define (contract for all later WUs):**
```haskell
newtype ConversationId = ConversationId Text                 -- opaque, server-derived
data TabRef  = BoundSession !SessionId | BoundHarness !HarnessId
  deriving stock (Eq, Ord, Show)
data TabStatus = Live | Dead                                  -- Dead = harness exited, pending notify
  deriving stock (Eq, Show)
data Tab = Tab { _tab_slot :: !TabIndex, _tab_ref :: !TabRef
               , _tab_name :: !Text,    _tab_status :: !TabStatus }
  deriving stock (Eq, Show)
-- Pure ordered core (slot == list index); registry handle wraps an IORef of this.
newtype TabList = TabList [Tab]                               -- invariant I1: slots == [0..length)
appendTab   :: TabRef -> Text -> TabList -> Either TabsError (TabIndex, TabList)  -- I2 dedup + I1 + 36-cap
removeSlot  :: TabIndex -> TabList -> TabList                 -- compaction, renumber (packAfterRemove)
lookupSlot  :: TabIndex -> TabList -> Maybe Tab
lookupRef   :: TabRef   -> TabList -> Maybe TabIndex
setStatus   :: TabRef -> TabStatus -> TabList -> TabList
data TabsError = SlotsFull | AlreadyBound !TabIndex
```

**TDD steps:**
- [ ] **Step 1 — failing test (I1 contiguity):** in `TypesSpec.hs`, property test: for any sequence of `appendTab`/`removeSlot`, `map _tab_slot (toList tl) == [0 .. n-1]`. Run `nix develop . --command cabal test 2>&1 | tail` → expect compile/fail.
- [ ] **Step 2 — define types + `appendTab`/`removeSlot`** in `Tabs/Types.hs` (reuse `packAfterRemove`/`firstFree` arithmetic from old `Routing/Registry.hs` — copy the pure logic, then that module is retired in WU12). Make Step 1 pass.
- [ ] **Step 3 — failing test (I2 uniqueness/dedup):** `appendTab` of an already-bound `TabRef` returns `Left (AlreadyBound i)`; never two tabs with same ref. Run → fail.
- [ ] **Step 4 — implement dedup** in `appendTab`. Pass.
- [ ] **Step 5 — failing test (36-cap):** appending the 37th distinct ref returns `Left SlotsFull`. Run → fail.
- [ ] **Step 6 — implement cap** (`TabIndex` max 35 via `mkTabIndex`). Pass.
- [ ] **Step 7 — failing test (compaction):** removing slot 1 of `[0,1,2]` shifts slot 2 → 1, `lookupRef` of the shifted ref returns the new slot. Pass after `removeSlot`.
- [ ] **Step 8 — `Tabs.hs` handle:** `data TabRegistry = TabRegistry (IORef TabList)`; `newTabRegistry`, `readTabs`, plus thin IO wrappers over the pure ops. Smoke test. Commit.

**DoD:** I1/I2/36-cap/compaction property-tested; pure core 100% covered; `Tabs.hs` handle compiles; `-Werror`/hlint clean.

---

## WU2 — Cursors, ConversationKey, RelayMode (pure)

**Files:**
- Modify: `src/PureClaw/Tabs/Types.hs` (extend), `src/PureClaw/Tabs.hs`
- Test: `test/PureClaw/Tabs/CursorSpec.hs`

**Dependencies:** WU1. Imports `Core.Types` for `ChannelKind`.

**Interfaces:**
```haskell
type ConversationKey = (ChannelKind, ConversationId)
data RelayMode = FocusedOnly | ActivityDigest | Firehose  deriving stock (Eq, Show)
data CursorState = CursorState
  { _cs_cursors :: !(Map ConversationKey TabRef)
  , _cs_relay   :: !(Map ConversationKey RelayMode) }
setCursor    :: ConversationKey -> TabRef -> CursorState -> CursorState
clearCursor  :: ConversationKey -> CursorState -> CursorState
resolveCursorSlot :: ConversationKey -> CursorState -> TabList -> Maybe TabIndex   -- I3
conversationsOn   :: TabRef -> CursorState -> [ConversationKey]
pruneDangling :: TabList -> CursorState -> CursorState        -- drop cursors whose ref is gone
relayMode    :: ConversationKey -> RelayMode -> CursorState -> RelayMode  -- 2nd arg = global default
```

**TDD steps:**
- [ ] **Step 1 — failing test:** `setCursor` then `resolveCursorSlot` returns the bound tab's current slot; after `removeSlot` shifts it, resolution returns the new slot (I3 survives compaction because cursors key by `TabRef`). Run → fail.
- [ ] **Step 2 — implement `CursorState` + `setCursor`/`resolveCursorSlot`.** Pass.
- [ ] **Step 3 — failing test:** `pruneDangling` clears a cursor whose ref no longer exists; keeps valid ones. Pass after impl.
- [ ] **Step 4 — failing test:** `conversationsOn ref` returns exactly the keys focused on that ref (used by relay + death notify). Pass.
- [ ] **Step 5 — failing test:** `relayMode` returns the per-conversation override or the supplied global default. Pass.
- [ ] **Step 6 — commit.**

**DoD:** I3 cursor-validity-under-compaction property-tested; `conversationsOn`, `pruneDangling`, `relayMode` covered; pure 100%.

---

## WU3 — Persistence: `state/` + `tabs.json` + boot reconcile

**Files:**
- Create: `src/PureClaw/Tabs/Persist.hs`, `test/PureClaw/Tabs/PersistSpec.hs`
- Reference: `src/PureClaw/Security/Path.hs` (`ensureRuntimeRoot` 0700 pattern), `src/PureClaw/Harness/Registry.hs` (liveness read)

**Dependencies:** WU1, WU2.

**Interfaces:**
```haskell
data PersistDeps = PersistDeps                 -- injected for deterministic tests
  { _pd_stateDir       :: FilePath
  , _pd_harnessLive    :: HarnessId -> IO Bool  -- probe live registry
  , _pd_discoveryReady :: IO ()                 -- block until one discovery pass done
  }
saveTabs :: FilePath -> TabList -> CursorState -> IO ()           -- writes tabs.json 0600 under state/ 0700
loadTabs :: PersistDeps -> IO (TabList, CursorState)             -- decode-fail -> fresh; reconcile; prune
```

**TDD steps:**
- [ ] **Step 1 — failing test (round-trip):** `saveTabs` then `loadTabs` (with all-live probe) returns the same tabs+cursors. Hand-written Aeson `ToJSON`/`FromJSON` (no generic deriving). Run → fail.
- [ ] **Step 2 — implement codec + `saveTabs`/`loadTabs`.** Pass.
- [ ] **Step 3 — failing test (perms):** after `saveTabs`, `getFileMode tabs.json == 0o600` and `state/ == 0o700` (use `System.Posix.Files`). Pass via `ensureRuntimeRoot` reuse + `setFileMode`.
- [ ] **Step 4 — failing test (decode failure → fresh):** corrupt `tabs.json` → `loadTabs` returns empty registry, no exception. Pass.
- [ ] **Step 5 — failing test (boot reconcile):** a harness-backed tab whose `_pd_harnessLive` returns False is dropped (silent); its cursor pruned; provider tabs kept. Assert `_pd_discoveryReady` is awaited before pruning. Pass.
- [ ] **Step 6 — commit.**

**DoD:** round-trip + perms + fresh-start + reconcile tested; injected deps give 100% without real tmux; no secrets/paths serialized (assert JSON keys).

---

## WU4 — `ConversationId` through `MessageSource` (server-derived)

**Files:**
- Modify: `src/PureClaw/Core/Types.hs` (`MessageSource`, `mkMessageSource`), each channel in `src/PureClaw/Channels/*` and Telegram/Signal/Web/CLI ingress.
- Test: `test/PureClaw/Core/MessageSourceSpec.hs` + per-channel derivation tests.

**Dependencies:** none structurally; do early (wide `-Werror` blast radius). Needed by WU6.

**TDD steps:**
- [ ] **Step 1 — failing test (forgery):** a `MessageSource` built from a payload whose *body/fields* contain a `conversation_id` ignores it; the id comes only from the transport arg. Run → fail (field doesn't exist yet).
- [ ] **Step 2 — add `_ms_conversation :: ConversationId` as a required positional arg to `mkMessageSource`.** Fix all call sites (compiler-driven). Pass forgery test.
- [ ] **Step 3 — failing tests (per-channel derivation):** CLI → constant `"cli"`; Telegram → `_tm_chat` (NOT `_tm_from`/user id); Signal → contact/group; Web → server-minted token (not a client field). One test each. Pass by wiring each ingress.
- [ ] **Step 4 — failing test (group chat shares cursor):** two different senders in one Telegram chat id produce the same `ConversationKey`. Pass.
- [ ] **Step 5 — build + commit** (`cabal build` must be clean given `-Werror`).

**DoD:** forgery + per-channel + group-chat tests pass; every `mkMessageSource` call site supplies a transport-derived id; no client-supplied path.

---

## WU5 — Session-handle pool; remove `_env_session` global

**Files:**
- Create: `src/PureClaw/Tabs/SessionPool.hs`, `test/PureClaw/Tabs/SessionPoolSpec.hs`
- Modify: `src/PureClaw/Agent/Env.hs` (remove `_env_session`, add pool ref), `src/PureClaw/Routing/Dispatcher.hs` (`closeAllTabs`/`_env_runners` callers).

**Dependencies:** WU1.

**Interfaces:**
```haskell
data SessionPool = SessionPool (IORef (Map SessionId (Int, SessionHandle)))  -- refcount
acquire :: SessionPool -> SessionId -> IO SessionHandle  -- open on first, ++refcount otherwise
release :: SessionPool -> SessionId -> IO ()             -- --refcount, close on last
```

**TDD steps:**
- [ ] **Step 1 — failing test:** `acquire` twice for one `SessionId` opens the handle once (injected opener counter == 1) and refcount == 2; `release` once keeps it open; second `release` closes (closer counter == 1). Run → fail.
- [ ] **Step 2 — implement pool** with injected open/close seams. Pass.
- [ ] **Step 3 — remove `_env_session :: IORef SessionHandle`** from `Agent/Env.hs`; route the AI tab loop through `acquire`/`release`. Fix `Dispatcher.hs:887-893` L7 path (delete the snapshot swap). Build clean.
- [ ] **Step 4 — failing test:** two tabs bound to the same `SessionId` resolve the *same* `SessionHandle`. Pass.
- [ ] **Step 5 — commit.**

**DoD:** refcount open/close + shared-handle tested; `_env_session` global gone; build green.

---

## WU6 — Per-conversation dispatch (replace global `_env_focus`)

**Files:**
- Modify: `src/PureClaw/Routing/Dispatcher.hs`, `src/PureClaw/Agent/Env.hs` (swap `_env_focus` → `TabRegistry`+`CursorState` refs + lifecycle queue), `src/PureClaw/Routing/Parse.hs` (unchanged grammar; confirm).
- Test: `test/PureClaw/Routing/DispatchSpec.hs`

**Dependencies:** WU1, WU2, WU4, WU5.

**TDD steps:**
- [ ] **Step 1 — failing test (switch):** `/2` from conversation A sets A's cursor to slot-2's ref; conversation B's cursor unchanged (per-conversation isolation of focus). Run → fail.
- [ ] **Step 2 — replace `_env_focus` reads/writes** with `setCursor`/`resolveCursorSlot` keyed by the inbound `ConversationKey`; dispatcher stays sole writer. Pass.
- [ ] **Step 3 — failing test (default routing):** plain text routes to the conversation's active tab; empty cursor emits §14 copy `no active tab — /new to start one or /tab to attach`. Pass.
- [ ] **Step 4 — failing test (out of range):** `/5` with 3 tabs emits `/5: out of range — you have 3 tabs (/0–/2); /tabs to list`. Pass.
- [ ] **Step 5 — failing test (tombstone deferred warning):** with cursor on a `Dead` tab, plain text emits the deferred warning, **drops** the message, and **zero bytes reach the harness send seam** (assert via injected sink), then clears cursor. Pass.
- [ ] **Step 6 — add lifecycle-event queue** (`TQueue`/`Chan`) field to `AgentEnv`, drained on the dispatcher thread (consumer wired in WU10). Stub producer. Pass smoke. Commit.

**DoD:** per-conversation switch/default/out-of-range/tombstone routing tested; dispatcher sole writer preserved; lifecycle queue plumbed.

---

## WU7 — Command surface: `/new`, `/nt`, `/close`, `/tabs`, `/rename`, `/relay`

**Files:**
- Modify: `src/PureClaw/Agent/SlashCommands.hs` (retire `TabSlashCommand` `/tab <sub>`; add flat verbs), `src/PureClaw/Routing/Parse.hs`, `src/PureClaw/Routing/Dispatcher.hs` (handlers).
- Test: `test/PureClaw/Routing/TabCommandsSpec.hs`

**Dependencies:** WU1, WU2, WU6.

**TDD steps (one red/green per verb — show test, then handler):**
- [ ] **Step 1 — `/new` reset:** test — `/new` with active tab on session S rebinds the *same slot* to a new session S'; S still on disk (I4); cursor follows. With no active tab, `/new` creates one. Implement. Pass.
- [ ] **Step 2 — `/nt` new tab:** test — appends at next slot, switches cursor; at 36 slots returns `all 36 tab slots in use — /close one first` with no state change. Implement. Pass.
- [ ] **Step 3 — `/close [N]`:** test — closes active tab by default; provider session persists, harness keeps running (I4); compaction applies. `--force` → `/close has no --force (tabs never destroy sessions or harnesses)`. Implement. Pass.
- [ ] **Step 4 — `/tabs`:** test — lists slot/name/kind/status **and this conversation's relay mode**; Dead tombstones shown. Implement. Pass.
- [ ] **Step 5 — `/rename [N] <name>`:** test — relabels; name passed through `normalizeText`/`maxSourceLen`; ESC/CSI bytes stripped. Implement. Pass.
- [ ] **Step 6 — `/relay <mode>`:** test — sets per-conversation mode; no-arg emits `relay mode: focused (focused | activity | all)`. Implement. Pass.
- [ ] **Step 7 — retire `/tab <sub>` family:** delete `TabSlashCommand` constructors + parsers (`/tab list/new/close/focus/resume/rename`); `/tab` bare now routes to the wizard stub (WU8). Build clean. Commit.

**DoD:** every verb tested incl. §14 copy assertions, `/new` session-preservation, slot exhaustion, sanitization; old `/tab <sub>` removed.

---

## WU8 — Attach wizard (`/tab`)

**Files:**
- Create: `src/PureClaw/Tabs/Wizard.hs`, `test/PureClaw/Tabs/WizardSpec.hs`
- Modify: `src/PureClaw/Routing/Dispatcher.hs` (wizard interception before `parseInput`).

**Dependencies:** WU6, WU7. Reads `Harness.Registry` (running harnesses) + `Session.Handle` (recent sessions).

**Interfaces:**
```haskell
data WizardState = WizardState { _wz_options :: [(Char, WizardTarget)] }  -- snapshot, stable numbering
data WizardTarget = AttachHarness !HarnessId | ReopenSession !SessionId
data WizardStep = Prompt !Text | Done !TabRef | Cancelled | Reprompt !Text
stepWizard :: WizardEnv -> Maybe WizardState -> Text -> IO (Maybe WizardState, WizardStep)
```

**TDD steps:**
- [ ] **Step 1 — failing test (snapshot + valid pick):** `/tab` snapshots `[harnesses ++ recent sessions]`, numbers them; reply `1` binds the **exact** id captured (not position-re-resolved) → `Done (BoundHarness h)`. Run → fail. Implement. Pass.
- [ ] **Step 2 — vanished target:** reply selects a harness whose liveness probe now returns False → `Reprompt "that target is gone — list refreshed"` with a refreshed snapshot. Pass.
- [ ] **Step 3 — cancel paths:** `0` → `Cancelled`; a `/`-prefixed reply → `Cancelled` + the command runs (dispatcher); invalid reply → `Reprompt`. Pass.
- [ ] **Step 4 — interception:** test that while `WizardState` is set for a conversation, its next message is consumed by `stepWizard` **before** `parseInput` (a bare `1` is a menu choice, not `Default` text). Wire in dispatcher. Pass.
- [ ] **Step 5 — overflow/query:** `>36` candidates capped; `/tab <query>` filters by sanitized substring on name/id. Pass.
- [ ] **Step 6 — reopen continue:** `ReopenSession s` binds a tab to the same `SessionId` (continue/append), dedups if already open (I2). Pass. Commit.

**DoD:** full wizard state-machine matrix tested; replies bind snapshot ids; interception ordering proven; wizard state runtime-only.

---

## WU9 — Relay engine (replace `ChannelOut` gate)

**Files:**
- Create: `src/PureClaw/Tabs/Relay.hs`, `test/PureClaw/Tabs/RelaySpec.hs`
- Modify: `src/PureClaw/Routing/ChannelOut.hs` (remove single-focus gate), channel handle for a conversation-addressable sink.

**Dependencies:** WU2, WU6. (Conversation-addressable sink is the largest rewire — keep it a labeled sub-step with its own coverage entry.)

**Interfaces:**
```haskell
data RelayDeps = RelayDeps { _rl_sink :: ConversationKey -> Text -> IO () }   -- injected for tests
relayOutput :: RelayDeps -> CursorState -> RelayMode -> TabRef -> Text -> IO ()  -- single writer, fans out
```

**TDD steps:**
- [ ] **Step 1 — failing test (FocusedOnly):** output from tab T reaches only conversations whose cursor == T; background conversations get nothing. Inject `_rl_sink` recorder. Run → fail. Implement single-writer fan-out. Pass.
- [ ] **Step 2 — ActivityDigest:** focused conversation gets full content; a conversation focused elsewhere gets a name-first activity ping (once per burst) for T. Pass.
- [ ] **Step 3 — Firehose:** a Firehose conversation gets full content from all live tabs. Pass.
- [ ] **Step 4 — ordering:** a single writer thread preserves emission order across sinks (assert recorder order). Pass.
- [ ] **Step 5 — remove `ChannelOut.shouldEmit` global-focus gate**; route tab output through `relayOutput`. Build clean. Commit.

**DoD:** RelayMode × foreground/background × multi-conversation matrix tested via injected sink; ordering preserved; old gate removed.

---

## WU10 — Harness-death notified two-phase removal

**Files:**
- Modify: `src/PureClaw/Harness/Reconcile.hs` (`_rd_evict` → enqueue lifecycle event), `src/PureClaw/Routing/Dispatcher.hs` (drain queue, apply), `src/PureClaw/Tabs/Types.hs` (status transitions).
- Test: `test/PureClaw/Tabs/DeathSpec.hs`

**Dependencies:** WU3, WU6, WU7, WU9.

**TDD steps:**
- [ ] **Step 1 — failing test (notify enabled):** evict event for harness H whose tab is /N → emit `⚠ "<name>" (harness, was /N) exited — tab closed` (slot snapshotted at notify) to focused conversations, then remove + compact + clear cursors. Drive via the queue (no real tmux). Run → fail. Implement: `_rd_evict` enqueues; dispatcher applies. Pass.
- [ ] **Step 2 — notify disabled:** tab → `Dead` tombstone, no immediate emit; next message while focused emits `⚠ "<name>" exited while you were away — message not sent; resend when ready`, **drops** the message (zero bytes to harness sink), then removes. Pass.
- [ ] **Step 3 — per-channel override:** `notifyOnHarnessDeath` global vs per-`ChannelKind` resolves correctly (config read in WU11; stub the value here). Pass.
- [ ] **Step 4 — tombstone visibility:** a `Dead` tab appears in `/tabs` until removed. Pass.
- [ ] **Step 5 — background tombstone via ActivityDigest:** a background tab that goes `Dead` still delivers the single death notification through the ping path. Pass.
- [ ] **Step 6 — no double-delete:** assert the tab layer does NOT call `Reg.deleteEntry` (reconcile already did). Commit.

**DoD:** enabled/disabled/per-channel/no-misroute/tombstone-visible/background-notify tested; thread-safe hand-off (reconcile→queue→dispatcher); exactly-one-notification guaranteed.

---

## WU11 — Config (`[tabs]`) + `AllowAll` boot WARN + `.gitignore`

**Files:**
- Modify: `src/PureClaw/CLI/Config.hs`, `src/PureClaw/Routing/Config.hs` (parse `[tabs]`), boot path (`src/PureClaw/CLI/Commands.hs`), allow-list warning seam (per `channel-allowlist-warning`).
- Create/append: `.gitignore` guidance for `state/`.
- Test: `test/PureClaw/CLI/TabsConfigSpec.hs`

**Dependencies:** WU9, WU10.

**TDD steps:**
- [ ] **Step 1 — failing test (config parse):** `[tabs] notify_on_harness_death = true`, per-channel overrides, and `default_relay = "focused"` parse into the typed config; defaults applied when absent (notify ON, relay FocusedOnly). Implement. Pass.
- [ ] **Step 2 — failing test (AllowAll WARN):** when any active channel resolves to `AllowAll` and tabs are shared-global, boot emits a WARN to stderr (reuse the PR #73 allow-list-warning seam). Assert via captured logger. Pass.
- [ ] **Step 3 — `.gitignore` guidance:** add `state/` exclusion guidance; test asserts the shipped guidance file/section names `state/`. Commit.

**DoD:** config parse + defaults tested; boot WARN tested; `state/` gitignore guidance shipped.

---

## WU12 — CLI integration, waiver cleanup, final gate

**Files:**
- Modify: `test/Integration/CLISpec.hs`, `.coverage-thresholds.json`.
- Delete: retired modules (see File Structure).

**Dependencies:** all.

**TDD steps:**
- [ ] **Step 1 — CLI integration tests:** spawn the real `pureclaw` binary; drive `/new`, `/nt`, `/tab` (wizard happy path), `/close`, `/0`, `/relay`, asserting on the §14 pinned copy and on tab-list output. Run `nix develop . --command cabal test`.
- [ ] **Step 2 — delete retired modules** (`Routing/AutoSpawn.hs`, `Routing/Registry.hs`, `Routing/Dashboard.hs`, `Tab/{Ai,Harness,Backend}.hs`, `Handles/Tab.hs`); remove from `.cabal`; fix dangling imports. Build clean.
- [ ] **Step 3 — staged-waiver cleanup:** remove the retired modules' entries from `stagedWaivers.modules` in `.coverage-thresholds.json`; ensure remaining entries are empty or justified per the protocol.
- [ ] **Step 4 — full gate:** `nix develop . --command cabal test --enable-coverage` meets thresholds; `nix develop . --command hlint src test` clean; `cabal build` `-Wall -Werror` clean.
- [ ] **Step 5 — file frontend-parity follow-up issue** in the epic; reference #79. Commit.

**DoD:** end-to-end chat surface green against the real binary; retired modules gone + waivers cleaned; coverage/lint/build gates pass; follow-up filed.

---

## Spec coverage map (self-review)

| Spec § | WU |
|---|---|
| §2 trust model + AllowAll WARN | WU11 (+ docs) |
| §4 Tab/TabRef/TabRegistry | WU1 |
| §5 I1–I5 | WU1 (I1,I2), WU2 (I3), WU7 (I4), WU10 (I5) |
| §6.1 `/new` vs `/nt`, §6.2 exhaustion, §6.4 compaction | WU7, WU1 |
| §7 command surface | WU7 |
| §8 harness death | WU10 |
| §9.1 ConversationId | WU4 |
| §9.2 inbound routing | WU6 |
| §9.3 relay engine | WU9 |
| §10 persistence/perms/boot | WU3 |
| §11 wizard | WU8 |
| §12 reuse/rebuild + waivers | WU1 (reuse arithmetic), WU12 (delete/waivers) |
| §13 session-handle pool + test seams | WU5 (pool); injected deps in WU3/WU9/WU10 |
| §14 message copy | WU6, WU7, WU10 (asserted), WU12 (CLI) |
| §15 tests / DoD | every WU |

**Notes:** WU4 and WU1 can start in parallel. The conversation-addressable sink (WU9) and `_env_session` removal (WU5) are the two highest-risk rewires — sequence them before WU10. Each WU ends green + committed; no WU leaves the tree un-buildable.
