# Tabs-as-View Refactor — Design

**Status:** Draft — revision 2 (post design-review round 1)
**Date:** 2026-06-08
**Related:** GitHub #79 (this work), #56 (Tab/Session Creation matrix), epic pureclaw-9sp (Session/Tab Unification)
**Scope of this spec:** Backend + chat/CLI. Frontend parity is a tracked sibling follow-up.

## 1. Summary

Re-found the tab layer as a clean, first-class abstraction in which **a tab is nothing but a view onto ground truth** (a Session, or a Harness-backed Session). The current tab infrastructure (WU1–WU10) predates the solidified Session/Harness design; we redesign around the new model and keep existing pieces only where they slot in perfectly.

User-facing behavior we are completing:

- Single-character tab slots `/0`–`/9`, `/a`–`/z` for switching (already built) — now backed by a clean model.
- **Chat-driven creation** that was never finished: `/new` (reset the current tab to a fresh session), `/nt` (new tab with a fresh default session), and a `/tab` wizard to attach to a running harness or reopen a past session.
- **Per-conversation active tab**: each chat conversation independently tracks which tab it is focused on, persisted so a backend restart does not surprise the user.
- **Tabs as pure views**: closing a tab never destroys ground truth; harness processes keep running when detached and can be re-attached.

## 2. Trust model & security boundary

**PureClaw runs as a single trusted operator.** Every conversation that reaches the runtime (CLI, the operator's own Telegram/Signal/web client) is treated as the **same principal**. The **channel allow-list (PR #73) is the security boundary** — it decides who may talk to the runtime at all. Within that boundary, tabs are an intentionally **shared global workspace**: any conversation may switch to, send to, close, or relay any tab. This is a feature (drive the same tabs from your laptop CLI and your phone), not a gap.

**Multi-tenant / mutually-distrusting use is explicitly OUT OF SCOPE and unsafe.** Because the `Tabs` registry is global and slots are small contiguous integers, `/N` is a direct reference to a shared tab; there is intentionally **no per-tab ACL**. Do not expose a PureClaw instance to parties who should not see each other's sessions/harnesses. If multi-tenant isolation is ever required, it is a separate future design: per-tab owner/ACL, ACL-filtered slot resolution, default-private tabs, and relay scoped to authorized tabs (recorded here so the decision is explicit, not implicit).

**Hardening that still applies under the single-operator model** (cheap, and prevents accidental leakage / corruption regardless of trust):

- **ConversationId is always derived server-side** from the authenticated channel transport — **never** read from message body or any client-supplied field (see §9.1). A forged or stray id must not be able to mint or hijack a cursor.
- **`state/tabs.json` holds no secrets** — no tokens, API keys, or absolute filesystem paths; only tab refs, names, cursors, relay modes. File mode `0600`, directory `state/` mode `0700` (§10).
- **User-supplied text is sanitized** (`/rename`, `/tab <query>`) before it is persisted or echoed, reusing `normalizeText` / `maxSourceLen` from `Core.Types`, to prevent terminal-escape injection into the CLI/transcript and oversized-entry DoS on the JSON file.

## 3. Goals / Non-Goals

### Goals
- A first-class `TabRegistry` (`Tabs`) abstraction: an ordered, persisted list of bindings with a strict contiguity invariant and compaction on removal.
- Per-conversation focus (active tab) keyed by stable identity, persisted across restart.
- Chat command surface: `/new`, `/nt`, `/tab` (wizard), `/close`, `/tabs`, `/rename`, `/relay`, plus the existing `/N`, `/N <text>`, default text, and `/bg`.
- Per-conversation output relay with three modes (`FocusedOnly` default, `ActivityDigest`, `Firehose`).
- Harness-death handling that **guarantees one notification** before a harness-backed tab disappears.
- Clean on-disk separation of mutable runtime state (`~/.pureclaw/state/`) from version-controllable content.

### Non-Goals (explicitly deferred)
- **Multi-tenant tab isolation / per-tab ACLs** — out of scope per §2.
- **Harness creation from chat** — harnesses are created explicitly elsewhere (frontend today); chat can only *attach* to already-running harnesses.
- **Branch-to-new-tab command** — `/bg` already covers the one-shot ephemeral branch (no tab); a first-class branch command is future work.
- **Frontend parity** — tracked sibling issue in the same epic.
- Migrating other mutable files (e.g. `history`) into `state/` — follow-up.

## 4. Vocabulary & Core Model

The word "view" describes the *rationale* only; it is **never** a code noun. The user-facing noun is **Tab**.

| Concept | Meaning |
|---|---|
| **Session** | Ground truth. Append-only, persisted on disk, never deleted except by explicit GC. Either `SkProvider` or `SkHarness`. *(Unchanged.)* |
| **Harness** | Ground truth. A live process with durable identity in the Harness registry; backs an `SkHarness` session; has its own lifetime independent of any tab. *(Unchanged.)* |
| **Tab** | A binding `{ slot, ref, name, status }`. Does **not** own a runtime handle — it *references* ground truth. |
| **`TabRef`** | A tab's stable identity = its bound ref: `BoundSession SessionId \| BoundHarness HarnessId`. A session/harness lives in ≤1 tab, so the ref *is* the tab id. **New type.** |
| **`Tabs` / `TabRegistry`** | The first-class, process-wide, **persisted** ordered collection of tabs. Owns the contiguity invariant, compaction, and persistence. |
| **`ConversationKey`** | `(ChannelKind, ConversationId)` — identifies one chat conversation. |
| **Cursor** | A conversation's active tab, stored as a `TabRef` (not a slot number), persisted. `/N` resolves to "the tab currently at slot N". |

`slot :: TabIndex` is the **volatile display coordinate** (renumbers on compaction). The existing validated `TabIndex` + `parseTabIndexChar` / `mkTabIndex` machinery (`Routing/Parse.hs`) is retained for `slot` and `/N` resolution; only the global-focus model around it is replaced.

```
Tab { slot :: TabIndex   -- 0..35, display coordinate, VOLATILE (renumbers)
    , ref  :: TabRef      -- BoundSession SessionId | BoundHarness HarnessId, STABLE
    , name :: Text        -- display label
    , status :: TabStatus -- Live | Dead (harness exited, pending notify)
    }
```

One-line model: **`Tabs` is a global ordered list of bindings; each conversation has a cursor (by stable ref) into that list; a tab never owns or destroys ground truth.**

## 5. Invariants (the test oracle)

- **I1 — Contiguity:** slots are exactly `[0..N)` at all times (`N` = tab count).
- **I2 — Uniqueness:** each `SessionId`/`HarnessId` appears in **≤1** tab. Binding an already-bound ref does not duplicate — it moves the requesting conversation's cursor to the existing tab (switch, not create).
- **I3 — Cursor validity:** a conversation cursor is either empty or resolves (by `TabRef`) to a live tab.
- **I4 — Tabs never destroy ground truth:** closing a tab, or `/new` rebinding a tab, leaves the prior provider session on disk (reopenable) and leaves any harness running (re-attachable).
- **I5 — Harness-backed tab ⇔ live harness:** when a harness dies/disconnects its tab is removed — but only after a guaranteed death notification (§8), except the documented boot-reconcile drop (§10.2).

## 6. Lifecycle

### 6.1 Creation & reset paths
- `/new` → **reset the active tab**: create a fresh default-provider Session and rebind the *current* tab's `ref` to it (same slot). The previous session persists on disk (I4). If the conversation has **no** active tab, `/new` creates one (cold-start convenience). Mirrors the `/new` users know from other CLI tools.
- `/nt` → **new tab**: create a fresh default-provider Session, append a tab at the next free slot, switch this conversation's cursor to it.
- `/tab` (wizard) → bind a *new* tab to an existing **running harness** or **reopen a past session** (continue/append), at the next free slot; switch cursor.
- *(Harness creation: frontend only — deferred from chat.)*

"Default-provider" = the configured default provider/model/agent (`config.toml`). If none is configured, `/new`/`/nt` fail with a one-line actionable hint naming the remedy (§14), rather than guessing.

### 6.2 Slot exhaustion
The slot namespace is `[0-9a-z]` → max **36** tabs. When all 36 slots are bound, `/nt` and the `/tab` attach wizard **reject** with a one-line hint (§14) and make **no** change — preserving I1. (`/new` is always allowed: it rebinds an existing slot, never grows `N`.) Tests assert the 37th-tab rejection and that the wizard caps its option list at the `[0-9a-z]` namespace, using the `/tab <query>` path for overflow.

### 6.3 Reopen semantics
Reopening a past session is **continue/append**: bind the tab to the same `SessionId` and keep appending to its existing history. A session lives in at most one tab; reopening one already in a tab just switches to it (I2). Branching into a new session is out of scope (`/bg` covers the ephemeral case).

### 6.4 Removal & compaction
Two triggers: explicit `/close`, and harness death (§8). The tab is removed and higher slots shift down by one (reusing the existing `packAfterRemove`/`firstFree` arithmetic). Because cursors are stored by `TabRef`, they survive compaction automatically; only display slots change.

### 6.5 Sharing
Two conversations may point at the same tab/session simultaneously — an intentional shared workspace under the single-operator trust model (§2). No single-writer lock; concurrent sends from two conversations interleave at the tab's input queue (both delivered, none dropped — §15 pins this with a test).

## 7. Chat command surface

**Critical grammar rule:** a single `[0-9a-z]` after `/` is **always a tab switch** (`/a` = switch to slot 12). Commands are therefore **multi-character** — there are **no single-letter command aliases**. Minimal keystrokes is achieved with short whole words / digraphs (`/nt`). The existing parser already enforces single-char → switch, multi-char token → command (`Routing/Parse.hs`).

| Command | Effect |
|---|---|
| `/N` / `/N <text>` | Switch this conversation's active tab to slot N / switch **and** send `<text>` to tab N |
| `<text>` (no prefix) | Send to this conversation's active tab |
| `/new` | Reset the active tab to a fresh default-provider session (same slot); creates one if none active |
| `/nt` | Create a new default-provider session in a new tab at the next slot, switch to it |
| `/tab` | Launch the **attach wizard** (running harness or past session) |
| `/close [N]` | Remove a tab view (default: active tab). Never harms ground truth |
| `/tabs` | List tabs (slot, name, kind, status, **+ this conversation's relay mode**) |
| `/rename [N] <name>` | Relabel a tab (text sanitized) |
| `/relay <mode>` | Set this conversation's relay mode (`focused` \| `activity` \| `all`); no arg shows current |
| `/bg <prompt>` | Existing ephemeral branch, no tab *(unchanged)* |

Deliberate split: **`/tab` = make/attach one** (wizard); **`/tabs` = list them all**. The old `/tab <subcommand>` family is retired in favor of these flat verbs.

`/close` is unified: for a provider session it drops the view (session persists, reopenable); for a harness it detaches (process keeps running, re-attachable). Tabs cannot kill ground truth, so there is no destructive variant — the old `/tab close <N> --force` flag is **intentionally dropped** (a `--force` now parses as an error with a one-line note).

## 8. Harness death — notified two-phase removal

`TabStatus` carries a `Dead` (tombstone) state. The "death event" the tab layer consumes is the existing reconcile loop's injectable **`_rd_evict :: HarnessId -> Text -> IO ()`** seam (`Harness/Reconcile.hs`), which fires from the **reconcile thread** after `defaultOrphanGraceTicks` consecutive orphaned/exited ticks. Because that thread is **not** the dispatcher thread, the tab layer must not mutate cursor/registry state directly from the callback — it **enqueues a lifecycle event onto a dispatcher-owned queue** (or an STM hand-off), and the dispatcher applies it on its single thread (§9.3). This keeps the dispatcher the sole writer of tabs/cursors.

When the event is applied and a tab tracks the dead harness:

1. The tab transitions to **`Dead`** (tombstone); it is **not** immediately compacted — retained as a stable referent.
2. **Notification (configurable):**
   - **Enabled** → immediately emit a death notice (named by **tab name** first, slot second, since slots renumber — §14) to every conversation focused on that tab, then remove + compact + clear those cursors.
   - **Disabled** → retain the tombstone silently; on the user's **next message** while focused on that tab, emit the warning *first*, **drop** that triggering message (do **not** misroute it into the dead harness; the user re-sends after seeing the warning — §14), then remove + compact.
3. Either path guarantees **exactly one** death notification before the tab disappears (the single exception is the boot-reconcile drop, §10.2).

Tombstones are visible in `/tabs` (everything-visible principle) until removed. The setting **`notifyOnHarnessDeath`** has a global default (**ON**) in `config.toml`, optionally overridden per `ChannelKind`; it is config-only for v1 (a runtime toggle is a noted follow-up). The death notice and the deferred warning are lifecycle events, delivered **independent of `RelayMode`**.

## 9. Routing & per-conversation relay

### 9.1 ConversationId provenance (per channel)
`ConversationKey = (ChannelKind, ConversationId)`. Today `MessageSource` (`Core.Types`) carries `_ms_channel` + a *sender* `_ms_userId` but **no conversation id**; this work adds a typed `ConversationId` sourced **only** from the authenticated transport:

| Channel | ConversationId source | Notes |
|---|---|---|
| CLI | constant (`"cli"`) | single local conversation |
| Telegram | **chat id** from the authenticated Bot API payload (`_tm_chat`) | **not** the user id — avoids the UserId conflation the allow-list work warns about; a group chat shares one cursor across senders |
| Signal | contact/group id from `signal-cli` | server-derived |
| Web | **server-minted** session/client id bound to the authenticated session | **never** read from a client-supplied field; a forged id must not steal a cursor |

Threading this is a `Core.Types`/`MessageSource` change with wide (compile-time, `-Werror`) blast radius — flagged as a deliberate plumbing cost.

### 9.2 Inbound
Every inbound message carries its `ConversationKey`. Parsing uses the existing grammar; resolution is against *this* conversation's cursor + the global `Tabs`:
- `/N` → resolve slot N → set this conversation's cursor to that tab's ref (out-of-range hint if `N ≥ count`, §14).
- `/N <text>` → set cursor to N **and** enqueue text to tab N.
- `<text>` (default) → enqueue to this conversation's active tab. Empty cursor → spawn/switch hint. Cursor on a `Dead` tombstone → emit the deferred death warning, drop the message, then clear (§8).
- slash command → mutate global `Tabs` and/or this conversation's cursor.
- **Wizard interception:** while a conversation is mid-`/tab`, its next message is consumed by the wizard *before* `parseInput` sees it; a `/`-prefixed input cancels the wizard and runs that command; any other non-matching reply re-prompts (§11).

### 9.3 Output relay
A tab can be foreground for conversation A and background for B at once, so the single-focus gate in `ChannelOut` (`shouldEmit :: Maybe TabIndex -> OutputSource -> Bool`) is replaced by a **per-conversation relay engine** (`PureClaw.Tabs.Relay`). Per output event it enumerates conversations and, for each, reads `(cursor, RelayMode)` from the same `IORef`-held snapshot the dispatcher writes, then targets that conversation's output sink.

> **Plumbing note (largest concrete change):** `_env_channel` is a single `ChannelHandle` with no conversation-addressed send. The relay engine needs a **conversation-addressable output sink** (a map of `ConversationKey → send`, or a `ChannelHandle` extended with a conversation parameter). This is the biggest rewire and is called out as its own work unit.

Per-conversation **`RelayMode`** (persisted per `ConversationKey` in `state/tabs.json`; global default in `config.toml`, default **`FocusedOnly`**):
1. **`FocusedOnly`** (`/relay focused`, *default*) — deliver output **only** from the conversation's focused tab. No background pings.
2. **`ActivityDigest`** (`/relay activity`) — full content from the focused tab; a small activity ping for any *other* live tab that produces output (once per background-output burst; the ping's slot is that conversation's current display slot for the tab).
3. **`Firehose`** (`/relay all`) — full content from all live tabs.

"Focused tab" = the conversation's cursor; "live tabs" = all tabs in the registry. (Under §2 single-operator trust, `Firehose`/`ActivityDigest` spanning all tabs is intended, not a leak.)

## 10. Persistence & on-disk layout

### 10.1 Layout & permissions
Mutable, machine-local runtime state is separated from version-controllable content:

```
~/.pureclaw/
  config.toml          # VCS-friendly
  sessions/<id>/...     # VCS-friendly (ground truth)
  agents/<name>/...     # VCS-friendly
  state/                # NEW — mode 0700, mutable, machine-local, NOT for VCS
    tabs.json           #   mode 0600 — TabRegistry + per-conversation cursors + RelayMode
```

- `state/tabs.json` holds: ordered tabs (`slot`, `ref`, `name`, `status`), the `ConversationKey → cursor` map, and the `ConversationKey → RelayMode` map. Hand-written JSON codec per project convention. **No secrets, tokens, or absolute paths** (§2).
- Reuse the existing `ensureRuntimeRoot` 0700 pattern (`Security/Path.hs`) for `state/`; write `tabs.json` 0600.
- Ship `.gitignore` guidance excluding `state/`, so a user can `git init` `~/.pureclaw/` to version sessions/agents/skills without tab churn.

### 10.2 Boot restore / reconcile
1. Load `state/tabs.json` (fresh-start on decode failure — see migration below).
2. **Wait for one completed harness discovery/reconcile pass** before pruning harness-backed tabs, so a still-alive harness that is transiently absent at boot is not wrongly dropped.
3. For harness-backed tabs, reconcile against the live Harness registry — drop any whose harness is gone. This boot drop is **silent** (no §8 death notice): it is the single documented exception to I5's "exactly one notification", since there is no live death event at boot.
4. Restore provider-session tabs as-is (session on disk).
5. Clear any dangling cursors (I3).

Wizard state is **runtime-only** (a mid-wizard restart simply forgets it).

### 10.3 Migration
`state/tabs.json` is net-new. Any pre-existing WU1–WU10 runtime tab/focus state is **not** migrated — a fresh start (empty `Tabs`) on first boot of the new code is acceptable and explicit; a decode failure on an unrecognized file is treated as fresh-start, not a crash.

## 11. The attach wizard (`/tab`)

Per-conversation, transient — occupies **no** slot until a choice is made. Single-keystroke replies drawn from the `[0-9a-z]` namespace (≤36 options):

```
Attach a tab — reply with a number:
 Running harnesses
  1  claude-code · work:claude (idle)
  2  codex · side:codex (thinking)
 Recent sessions
  3  "refactor routing"  · 20260607-1431 (anthropic)
  4  "vault work"        · 20260606-0903
 0  cancel
```

- The option list is snapshotted when shown; a reply binds to the **exact harness/session id captured in the snapshot**, never re-resolved by list position. If the chosen target has vanished since the snapshot (harness exited, session gone), the wizard **re-prompts** with a refreshed list and a one-line notice (§14) rather than attaching to nothing.
- **No modal lock-in:** an invalid reply re-prompts; `0`/`cancel` exits; any `/`-prefixed command cancels the wizard and runs that command (§9.2).
- **Overflow:** show all running harnesses + the *N* most-recent sessions (N=8); older sessions reachable by `/tab <query>` (sanitized substring match on name/id).

## 12. Reuse vs rebuild

**Kept (fits perfectly):**
- The `/0-9a-z` parse grammar (`parseTabIndexChar`; single-char → switch, multi-char → command) and the validated `TabIndex` smart constructor.
- The compaction arithmetic (`packAfterRemove` / `firstFree`).
- The Session ground-truth layer (`PureClaw.Session.*`) — untouched.
- The Harness registry (`PureClaw.Harness.Registry`) — untouched; we consume the reconcile loop's existing `_rd_evict` seam (no new event system).
- `/bg` (`CmdBg`); channel/transcript plumbing (output relay is rewired around it).

**Rebuilt / replaced (and their staged-waiver cleanup):**
- Global `_env_focus :: IORef (Maybe TabIndex)` → per-conversation cursor store.
- `TabSlashCommand` `/tab <sub>` family → flat verbs (§7).
- `AutoSpawn` handlers → `TabRegistry` operations; `Routing.Registry` (`_env_tabs` IntMap) → the new `TabRegistry`.
- `ChannelOut` single-focus gate → the `RelayMode` engine.
- `Handles.Tab` `TabStatus` (`Active|Idle|Crashed`) and the per-tab runtime-handle ownership → new `Tab`/`TabStatus` (`Live|Dead`) in `PureClaw.Tabs`; tabs become bindings that reference ground truth.

The retired modules currently hold `stagedWaivers` in `.coverage-thresholds.json` (e.g. `Routing.AutoSpawn`, `Routing.Dispatcher`, `Routing.Dashboard`, `Tab.{Ai,Harness,Backend}`, `Handles.Tab`). The WU decomposition must **delete or justify** each corresponding waiver as its module is retired, so `stagedWaivers.modules` ends empty or explicitly justified per the coverage protocol.

## 13. Module structure & test seams

New, small, single-purpose modules (leaf discipline — depend on `Session.Kind` + `Harness.Registry` only):
- `PureClaw.Tabs` — `TabRegistry` type, invariants I1–I5, compaction, `ConversationKey` cursors, `RelayMode`, persistence to `state/tabs.json`.
- `PureClaw.Tabs.Wizard` — the `/tab` wizard state machine.
- `PureClaw.Tabs.Relay` — per-conversation output relay engine.

**Test seams (to hit 100% / the `.coverage-thresholds.json` gate without a live tmux server):** `PureClaw.Tabs` and `PureClaw.Tabs.Relay` take an **injected deps record** (harness-liveness probe, death-event source, clock, output sink) — mirroring the existing `ReconcileDeps`/`ClaudeCodeDeps` pattern — so the relay engine, two-phase harness-death removal, and boot reconcile are driven deterministically in unit tests.

**Session-handle lifecycle (resolved ground truth):** since tabs no longer own handles and §6.5 sharing means two cursors may resolve the same `SessionId`, there is exactly **one** resolved `SessionHandle` per live `SessionId`, held in a `Map SessionId SessionHandle` resource pool owned by the tab layer (not the tab). The pool opens a handle when a tab first binds a session and closes it when the last tab unbinds — superseding the old one-handle-per-tab assumption in `closeAllTabs`/`_env_runners`. The L7 resume snapshot limitation (`Dispatcher.hs:887-893`) is removed by this pooling.

**Plumbing:** each channel handle is touched to supply its `ConversationId` (§9.1).

## 14. Message copy (pinned for testability)

These strings are the primary teaching surface and are asserted by CLI integration tests:

- Empty cursor + default text: `no active tab — /new to start one or /tab to attach`
- `/N` out of range (e.g. 3 tabs): `/5: out of range — you have 3 tabs (/0–/2); /tabs to list`
- Slot exhaustion (`/nt` / wizard) at 36: `all 36 tab slots in use — /close one first`
- `/new`/`/nt` with no default provider: `no default provider configured — set one with /target default <name> (or config.toml)`
- Harness death (notify enabled): `⚠ "<tab name>" (harness, was /N) exited — tab closed`
- Deferred death warning (notify disabled, on next send): `⚠ "<tab name>" exited while you were away — message not sent; resend when ready`
- Wizard target vanished: `that target is gone — list refreshed`
- `--force` on `/close`: `/close has no --force (tabs never destroy sessions or harnesses)`

(Copy may be refined in spec review; the *contracts* — actionable, names-before-slots, no silent no-ops — are fixed.)

## 15. Testing & DoD

TDD throughout; coverage gate per `.coverage-thresholds.json`.

- **Property tests** for I1–I5: contiguity after arbitrary create/`/new`/close sequences; uniqueness; cursor validity under compaction; ground-truth preservation (session file survives `/close` and `/new` rebind); harness⇔tab.
- **Slot exhaustion:** 37th tab via `/nt` rejected with no state change; wizard caps options at `[0-9a-z]`; `/new` still works at 36.
- **`/new` vs `/nt`:** `/new` rebinds same slot + preserves old session on disk; `/new` with no active tab creates one; `/nt` appends + switches.
- **Wizard state machine:** valid choice binds snapshot id; vanished-target re-prompt; invalid re-prompt; `0` cancel; slash-cancel; overflow/query; pre-`parseInput` interception.
- **`RelayMode` matrix:** `FocusedOnly`/`ActivityDigest`/`Firehose` × foreground/background output × multiple conversations, via the injected output sink.
- **Harness death:** notify-enabled (immediate notice + removal) and notify-disabled (tombstone + deferred warning **+ assert zero bytes reach the harness send seam** + message dropped); per-channel override; tombstone visible in `/tabs`.
- **ConversationId provenance:** a forged conversation id in message *content* cannot set or steal a cursor (server-derived id only); group-chat senders share one cursor.
- **Persistence:** `tabs.json` round-trip; mode 0600 / `state/` 0700; decode-failure → fresh start; boot reconcile waits for a discovery pass, drops dead-harness tabs silently, clears dangling cursors.
- **Concurrency:** two conversations sending into one shared tab — both delivered, none dropped.
- **CLI integration** (`test/Integration/CLISpec.hs`): drive the real binary through `/new`, `/nt`, `/tab`, `/close`, `/N`, `/relay`, asserting on the §14 copy.

### Definition of Done
- [ ] `TabRegistry` with I1–I5 enforced and property-tested.
- [ ] Per-conversation cursors + `RelayMode`, persisted in `state/tabs.json` (0600, under `state/` 0700), restored + reconciled at boot.
- [ ] `ConversationId` threaded through `MessageSource`, server-derived per channel (§9.1); forgery test passes.
- [ ] Chat surface `/new`, `/nt`, `/tab` (wizard), `/close`, `/tabs`, `/rename`, `/relay` over CLI; `/N`, `/N <text>`, default routed per conversation; §14 copy asserted.
- [ ] Harness-death notified two-phase removal via the reconcile `_rd_evict` seam with a thread-safe hand-off; global + per-channel `notifyOnHarnessDeath`.
- [ ] Single-operator trust model + "multi-tenant out of scope" documented in code/docs (§2).
- [ ] `~/.pureclaw/state/` introduced with `.gitignore` guidance; no VCS churn from tab state.
- [ ] Retired modules' `stagedWaivers` deleted or justified; coverage gate green; `-Wall -Werror` clean; hlint clean.
- [ ] Keystroke-minimization preserved (`/new`, `/nt` are single tokens; attach is one token + one digit).
- [ ] Frontend-parity follow-up issue filed in the epic.

## 16. Open questions / follow-ups
- Frontend parity (sibling issue): left bar reflecting the new model, NewTabComposer mapped to `TabRegistry` operations, web `ConversationKey` + relay over the websocket.
- Runtime toggle for `notifyOnHarnessDeath` (config-only in v1).
- First-class branch-to-tab command (future).
- Multi-tenant tab isolation / per-tab ACLs, if ever required (§2).
- Migrating other mutable files (`history`, etc.) into `state/`.
