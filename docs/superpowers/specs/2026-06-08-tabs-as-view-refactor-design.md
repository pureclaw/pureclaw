# Tabs-as-View Refactor — Design

**Status:** Draft for design-review gate
**Date:** 2026-06-08
**Related:** GitHub #56 (Tab/Session Creation matrix), epic pureclaw-9sp (Session/Tab Unification)
**Scope of this spec:** Backend + chat/CLI. Frontend parity is a tracked sibling follow-up.

## 1. Summary

Re-found the tab layer as a clean, first-class abstraction in which **a tab is nothing but a view onto ground truth** (a Session, or a Harness-backed Session). The current tab infrastructure (WU1–WU10) predates the solidified Session/Harness design; we redesign around the new model and keep existing pieces only where they slot in perfectly.

The user-facing behavior we are completing/finishing:

- Single-character tab slots `/0`–`/9`, `/a`–`/z` for switching (already built) — now backed by a clean model.
- **Chat-driven creation** that was never finished: `/new` (instant default-provider session) and an interactive `/tab` wizard to attach to a running harness or reopen a past session.
- **Per-conversation active tab**: each chat conversation independently tracks which tab it is focused on, persisted so a backend restart does not surprise the user.
- **Tabs as pure views**: closing a tab never destroys ground truth; harness processes keep running when detached and can be re-attached.

## 2. Goals / Non-Goals

### Goals
- A first-class `TabRegistry` (`Tabs`) abstraction: an ordered, persisted list of bindings with a strict contiguity invariant and compaction on removal.
- Per-conversation focus (active tab) keyed by stable identity, persisted across restart.
- Chat command surface: `/new`, `/tab` (wizard), `/close`, `/tabs`, `/rename`, `/relay`, plus the existing `/N`, `/N <text>`, default text, and `/bg`.
- Per-conversation output relay with three modes (`FocusedOnly` default, `ActivityDigest`, `Firehose`).
- Harness-death handling that **guarantees one notification** before a harness-backed tab disappears.
- Clean on-disk separation of mutable runtime state (`~/.pureclaw/state/`) from version-controllable content.

### Non-Goals (explicitly deferred)
- **Harness creation from chat** — harnesses are created explicitly elsewhere (frontend today); chat can only *attach* to already-running harnesses.
- **Branch-to-new-tab command** — `/bg` already covers the one-shot ephemeral branch (no tab); a first-class branch command is future work.
- **Frontend parity** (ActiveTabs left bar + NewTabComposer mapped to the new model, web cursor + relay over the websocket) — tracked sibling issue in the same epic.
- Migrating other mutable files (e.g. `history`) into `state/` — follow-up.

## 3. Vocabulary & Core Model

The word "view" describes the *rationale* only; it is **never** a code noun. The user-facing noun is **Tab**.

| Concept | Meaning |
|---|---|
| **Session** | Ground truth. Append-only, persisted on disk, never deleted except by explicit GC. Either `SkProvider` or `SkHarness`. *(Unchanged.)* |
| **Harness** | Ground truth. A live process with durable identity in the Harness registry; backs an `SkHarness` session; has its own lifetime independent of any tab. *(Unchanged.)* |
| **Tab** | A binding `{ slot, ref, name, status }`. The only thing a "tab" is. Does **not** own a runtime handle — it *references* ground truth. |
| **`TabRef`** | A tab's stable identity = its bound ref: `BoundSession SessionId \| BoundHarness HarnessId`. Since a session/harness lives in ≤1 tab, the ref *is* the tab id. |
| **`Tabs` / `TabRegistry`** | The first-class, process-wide, **persisted** ordered collection of tabs. Owns the contiguity invariant, compaction, and persistence. |
| **`ConversationKey`** | `(ChannelKind, ConversationId)` — identifies one chat conversation (a Telegram chat, a Signal contact/group, the CLI, a web client). |
| **Cursor** | A conversation's active tab, stored as a `TabRef` (not a slot number), persisted. `/N` resolves to "the tab currently at slot N". |

One-line model: **`Tabs` is a global ordered list of bindings; each conversation has a cursor (by stable ref) into that list; a tab never owns or destroys ground truth.**

```
Tab { slot :: Int        -- 0..35, display coordinate, VOLATILE (renumbers)
    , ref  :: TabRef      -- BoundSession SessionId | BoundHarness HarnessId, STABLE
    , name :: Text        -- display label
    , status :: TabStatus -- Live | Dead (harness exited, pending notify)
    }
```

## 4. Invariants (the test oracle)

- **I1 — Contiguity:** slots are exactly `[0..N)` at all times (`N` = tab count).
- **I2 — Uniqueness:** each `SessionId`/`HarnessId` appears in **≤1** tab. Binding an already-bound ref does not duplicate — it moves the requesting conversation's cursor to the existing tab (switch, not create).
- **I3 — Cursor validity:** a conversation cursor is either empty or resolves (by `TabRef`) to a live tab.
- **I4 — Tabs never destroy ground truth:** closing a tab leaves the provider session on disk (reopenable) and leaves the harness running (re-attachable).
- **I5 — Harness-backed tab ⇔ live harness:** when a harness dies/disconnects its tab is removed — but only after a guaranteed death notification (see §7).

## 5. Lifecycle

### 5.1 Creation paths (increasing keystrokes)
1. `/new` → create a new **default-provider** Session (ground truth, from `config.toml` default provider/model/agent) → append a tab at the next free slot → set this conversation's cursor to it. If no default is configured, `/new` fails with a one-line hint rather than guessing.
2. `/tab` (wizard) → bind a tab to an existing **running harness** or **reopen a past session** (continue/append) → append at the next slot → set cursor.
3. *(Harness creation: frontend only — deferred from chat.)*

### 5.2 Reopen semantics
Reopening a past session is **continue/append**: bind the tab to the same `SessionId` and keep appending to its existing history. A session lives in at most one tab; reopening one already in a tab just switches to it (I2). Branching into a new session is out of scope (`/bg` covers the ephemeral case).

### 5.3 Removal & compaction
Two triggers: explicit `/close`, and harness death (§7). Either way the tab is removed and higher slots shift down by one (reusing the existing renumber arithmetic). Because cursors are stored by `TabRef`, they survive compaction automatically; only display slots change.

### 5.4 Sharing
Two conversations may point at the same tab/session simultaneously — an intentional shared workspace. No single-writer lock (stated as a deliberate decision, not an accident).

## 6. Chat command surface

**Critical grammar rule:** a single `[0-9a-z]` after `/` is **always a tab switch** (`/a` = switch to slot 12). Commands are therefore **multi-character** — there are **no single-letter command aliases**. Minimal keystrokes is achieved with short whole words. (The existing parser already enforces single-char → switch, multi-char token → command.)

| Command | Effect |
|---|---|
| `/N` / `/N <text>` | Switch this conversation's active tab to slot N / switch **and** send `<text>` to tab N |
| `<text>` (no prefix) | Send to this conversation's active tab |
| `/new` | Create a new default-provider session, bind a tab at the next slot, switch to it |
| `/tab` | Launch the **attach wizard** (running harness or past session) |
| `/close [N]` | Remove a tab view (default: active tab). Never harms ground truth |
| `/tabs` | List tabs (slot, name, kind, status) |
| `/rename [N] <name>` | Relabel a tab |
| `/relay <mode>` | Set this conversation's relay mode (`focused` \| `activity` \| `all`); no arg shows current |
| `/bg <prompt>` | Existing ephemeral branch, no tab *(unchanged)* |

Deliberate singular/plural split: **`/tab` = make/attach one** (wizard); **`/tabs` = list them all**. The old `/tab <subcommand>` family is retired in favor of these flat verbs.

`/close` is unified: for a provider session it drops the view (session persists, reopenable); for a harness it detaches (process keeps running, re-attachable). Tabs cannot kill ground truth, so no separate "kill" verb exists.

## 7. Harness death — notified two-phase removal

`TabStatus` carries a `Dead` (tombstone) state. When a harness dies/disconnects and a tab tracks it:

1. The tab enters **`Dead`**; it is **not** immediately compacted away — it is retained as a stable referent so the user can be told about *this* tab.
2. **Notification (configurable):**
   - **Enabled** → immediately emit a death notice ("⚠ harness *name* (/N) exited") to every conversation focused on that tab, then remove + compact + clear those cursors.
   - **Disabled** → retain the tombstone silently; on the user's **next message** while focused on that tab, emit the warning *first* (do **not** misroute the message into a dead harness), then remove + compact.
3. Either path guarantees **exactly one** death notification before the tab disappears.

The setting is **`notifyOnHarnessDeath`**: a global default (**ON**) in `config.toml`, optionally overridden per `ChannelKind`. This notice is a lifecycle event and is delivered **independent of `RelayMode`**.

## 8. Routing & per-conversation relay

Every inbound message carries its `ConversationKey`. Parsing uses the existing grammar; resolution is against *this* conversation's cursor + the global `Tabs`.

**Inbound:**
- `/N` → resolve slot N → set this conversation's cursor to that tab's ref (error if `N ≥ count`).
- `/N <text>` → set cursor to N **and** enqueue text to tab N.
- `<text>` (default) → enqueue to this conversation's active tab. If the cursor is empty → emit the spawn/switch hint. If the cursor points at a `Dead` tombstone → emit the deferred death warning instead of routing, then clear.
- slash command → mutate global `Tabs` and/or this conversation's cursor.

**Output relay** — a tab can be foreground for conversation A and background for conversation B at once. Per-conversation **`RelayMode`** (persisted per `ConversationKey` in `state/tabs.json`; global default in `config.toml`, default **`FocusedOnly`**):

1. **`FocusedOnly`** (`/relay focused`, *default*) — deliver output **only** from the conversation's focused tab. No background breadcrumbs.
2. **`ActivityDigest`** (`/relay activity`) — full content from the focused tab; a small activity ping for any *other* live tab that produces output (once per background-output burst; the ping's slot is that conversation's current display slot for the tab).
3. **`Firehose`** (`/relay all`) — full content from all live tabs.

Terminology within relay: "focused tab" = the conversation's cursor; "live tabs" = all tabs in the registry. The `Dead`-tombstone deferred warning and the harness-death notice are lifecycle events, always delivered to focused conversations regardless of `RelayMode`.

## 9. Persistence & on-disk layout

Mutable, machine-local runtime state is separated from version-controllable content:

```
~/.pureclaw/
  config.toml          # VCS-friendly
  sessions/<id>/...     # VCS-friendly (ground truth)
  agents/<name>/...     # VCS-friendly
  state/                # NEW — mutable, machine-local, NOT for VCS
    tabs.json           #   the TabRegistry + per-conversation cursors + RelayMode
```

- `state/tabs.json` holds: the ordered tabs (`slot`, `ref`, `name`), the `ConversationKey → cursor` map, and the `ConversationKey → RelayMode` map. Hand-written JSON codec per project convention.
- Ship `.gitignore` guidance that `state/` is excluded, so a user can `git init` `~/.pureclaw/` to version sessions/agents/skills without tab churn.

**Boot restore/reconcile:**
1. Load `state/tabs.json`.
2. For harness-backed tabs, reconcile against the live Harness registry — drop any whose harness is gone (honoring I5).
3. Restore provider-session tabs as-is (session on disk).
4. Clear any dangling cursors (I3).

Wizard state is **runtime-only** (a mid-wizard restart simply forgets it).

## 10. The attach wizard (`/tab`)

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

- Reply `1` → attach to that running harness; `3` → reopen that session (continue/append). Either way: create the tab, switch to it, confirm.
- Option list is snapshotted when shown so numbering is stable for the reply.
- **No modal lock-in:** an invalid reply re-prompts; `0`/`cancel` exits; any `/`-prefixed command cancels the wizard and runs that command instead.
- **Overflow:** show all running harnesses + the *N* most-recent sessions (N=8); older sessions reachable via `/tab <query>` (substring match on name/id).

## 11. Reuse vs rebuild

**Kept (fits perfectly):**
- The `/0-9a-z` parse grammar (`parseTabIndexChar`; single-char → switch, multi-char → command).
- The renumber/compaction **arithmetic** (index-shift logic).
- The Session ground-truth layer (`PureClaw.Session.*`) — untouched.
- The Harness registry (`PureClaw.Harness.Registry`) — untouched ground truth; we add a death-event subscription.
- `/bg` (`CmdBg`); channel/transcript plumbing (output relay is rewired around it).

**Rebuilt / replaced:**
- Global `_env_focus :: IORef (Maybe TabIndex)` → per-conversation cursor store.
- `TabSlashCommand` `/tab <sub>` family → flat verbs (§6).
- `AutoSpawn` handlers → `TabRegistry` operations (create / attach / close / compact).
- `ChannelOut` focus-gate → the `RelayMode` engine.
- Tabs stop owning runtime handles → become bindings that reference ground truth (biggest structural change).

## 12. Module structure (new, small, single-purpose)

- `PureClaw.Tabs` — `TabRegistry` type, invariants I1–I5, compaction, `ConversationKey` cursors, `RelayMode`, persistence to `state/tabs.json`.
- `PureClaw.Tabs.Wizard` — the `/tab` wizard state machine.
- `PureClaw.Tabs.Relay` — per-conversation output relay engine.

**Plumbing:** each channel handle is touched to supply its `ConversationId` (CLI = constant; web = client id; Telegram = chat id; Signal = contact/group), so messages carry a `ConversationKey`.

## 13. Testing & DoD

TDD throughout; 100% coverage gate per `.coverage-thresholds.json`.

- **Property tests** for I1–I5: contiguity after arbitrary create/close sequences; uniqueness; cursor validity under compaction; ground-truth preservation; harness⇔tab.
- **Wizard state-machine tests:** valid choice, invalid re-prompt, cancel, command-cancel, overflow/query, snapshot stability.
- **`RelayMode` matrix:** `FocusedOnly` / `ActivityDigest` / `Firehose` × foreground/background output × multiple conversations.
- **Harness-death tests:** notify-enabled (immediate notice + removal) and notify-disabled (tombstone + deferred warning on next send + no misroute); per-channel override.
- **Persistence tests:** `tabs.json` round-trip; boot reconcile drops dead-harness tabs and clears dangling cursors.
- **CLI integration tests** (`test/Integration/CLISpec.hs`): drive the real binary through `/new`, `/tab`, `/close`, `/N`, `/relay`.

### Definition of Done
- [ ] `TabRegistry` with I1–I5 enforced and property-tested.
- [ ] Per-conversation cursors + `RelayMode`, persisted in `state/tabs.json`, restored + reconciled at boot.
- [ ] Chat surface `/new`, `/tab` (wizard), `/close`, `/tabs`, `/rename`, `/relay` working over CLI; `/N`, `/N <text>`, default text routed per conversation.
- [ ] Harness-death notified two-phase removal with global + per-channel `notifyOnHarnessDeath`.
- [ ] `~/.pureclaw/state/` introduced with `.gitignore` guidance; no VCS churn from tab state.
- [ ] 100% coverage; `-Wall -Werror` clean; hlint clean.
- [ ] Frontend-parity follow-up issue filed in the epic.

## 14. Open questions / follow-ups
- Frontend parity (sibling issue): left bar reflecting the new model, NewTabComposer mapped to `TabRegistry` operations, web `ConversationKey` + relay over the websocket.
- First-class branch-to-tab command (future).
- Migrating other mutable files (`history`, etc.) into `state/` (future).
