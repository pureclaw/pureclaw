# Tabbed Chat — Mobile-Friendly Multiplexing

**Issue:** [#51](https://github.com/pureclaw/pureclaw/issues/51)
**Status:** design — APPROVED by all 5 review-gate agents (PM, Architect, Designer, Security, CTO) over rounds 1–5
**Branch:** `feat/terminal-backends-design`
**Authors:** Doug Beardsley, Claude
**Builds on:** [Terminal / Backend Abstractions](terminal-backend-abstractions.md) — Tabbed Chat's `KindBackend` tabs wrap `BackendHandle` factories landing on this branch.

**Revision note (this doc, round 1 → 2):** Resolves three architectural questions raised by the design review gate. The biggest is *focused-only channel display*: non-focused tabs never write to chat in v1. This eliminates the output-mux head-of-line block, the cross-tab DoS surface, and the cross-tab visibility plumbing that reply-to-route depended on. Reply-to-route is dropped entirely. DoDs are renumbered, split where coarse, and rephrased behaviorally. Test seams and security checks are now explicit.

**Revision note (this doc, round 2 → 3):** Round 2 found: a `_th_*` field-name collision with `TranscriptHandle`; a path-traversal hole in `/tab resume`; a missing per-tab `Context` flow into existing slash-command handlers; an unbounded `TQueue` memory-DoS surface; a missing concurrent-active-tab cap (the focused-only-display fix solved cross-tab muxing but opened a quota-burn surface); a `withAsync`/`throwTo` mismatch in the `_env_fork` test seam; an import cycle still present in the Module Layout; a coarse `K6` collapsing 7 commands into one DoD; a `D3`/`D4` focus-gating conflict; and a parser-signature ambiguity in `P7`. All addressed in this revision. Field prefix changes to `_tabHandle_*` (full handle-name preferred for new handles; see Naming Convention).

## Naming Convention (new Handle records)

The existing codebase uses two-letter prefixes per handle (`_bh_` BackendHandle, `_ch_` ChannelHandle, `_hh_` HarnessHandle, `_sh_` SessionHandle, `_th_` **TranscriptHandle**, `_fh_` FileHandle, `_ph_` ProcessHandle). The two-letter space is nearly exhausted; TabHandle would have collided with TranscriptHandle's `_th_*`.

**Preferred for new Handle records going forward**: `_<handleName>_*` — full handle name, lowercased. So `TabHandle` → `_tabHandle_*`. Existing two-letter-prefixed handles may migrate as opportunity arises but are not required to migrate as part of this work.

## Naming Note

The user-facing primitive is a **tab**. A tab is a sub-stream within the user's single chat thread — analogous to a browser tab or a tmux window. Each tab has an integer index (mobile-friendly: `/0`, `/1`, ...), an optional friendly name, a kind (AI agent, shell harness, terminal backend), and its own transcript. The internal type is `TabHandle`. We rejected `Route`, `Slot`, `Pane`, and `Window` in favor of `Tab` because the browser-tab mental model is universal.

## TL;DR — What does this look like to a user?

```
User: explain RFC 7807                       ← plain text on empty registry: K3 first-run
Bot:  /0: ai (claude-opus-4-7) ready.       ← implicit spawn of default kind at /0
      RFC 7807 is "Problem Details ..."

User: /tab new shell                         ← spawns at next free slot (/1)
Bot:  /1: shell ready.
User: /1 uptime                              ← direct-inject; stays on /0
Bot:  (no visible reply — /1's output goes to /1's transcript)
User: /1                                     ← switch to /1
Bot:  /1: 10:32 up 14 days, ...              ← recap of last messages

User: /tabs
Bot:  * /1  shell                idle  3s
        /0  ai                   idle  12s
```

Numeric switches (`/0`, `/1`, ...) and a `/tab <verb>` family are the entire user surface. Only the focused tab's responses appear in chat; the others accumulate silently and surface on switch. No cross-tab muxing, no proactive notifications.

## Evolution (post-merge, v1.5)

The implementation that landed after PR #51 made three semantic changes from the originally-approved design. They are summarised here so readers can reconcile the rest of the doc with the code; the affected sections below have been rewritten to match.

1. **Index grammar widened to letters.** The index is now exactly one character drawn from `[0-9a-z]` (36 values) rather than a greedy decimal run. `/12`, `/aa`, `/1a`, `/01` are all `ParseErrorMalformed` (multi-char). `_rc_maxTabs` default is `36` (was `10`). `ParseErrorLeadingZero` no longer exists — it became structurally unreachable.
2. **Tabs are always packed at the lowest free slot (tmux model).** `/tab new` no longer accepts a user-specified index — it always allocates at `Registry.lowestFreeIndex`. `/tab close N` shifts every remaining tab `> N` down by one (matches tmux `renumber-windows on`). The `TabHandle._tabHandle_index` field becomes advisory after a renumber — the authoritative current slot is the registry key.
3. **`/N` no longer auto-spawns on a missing index.** Because tabs are always packed in the lowest slots, a `/N` referring to an empty slot is unambiguously user error. The dispatcher emits an error banner (`"/N: no such tab — use /tab new to create one"`) and discards any payload. The K3 first-run UX (empty registry + plain `Default` text → auto-spawn at `/0`) is preserved.

Where the rest of this doc says "switch (or auto-spawn)" or "`/tab new N`", read "switch only" and "`/tab new`" respectively. A-series, L-series, the parser grammar, and the slash-command surface table have been updated in place.

## Motivation

PureClaw users on mobile (Telegram, Signal) currently manage a single agent per chat thread. Power users want to drive *multiple* concurrent agents — a coding agent, a shell, an SSH session into prod, a test runner — but a chat thread is single-stream. Today they either run multiple bots (each in its own thread) or context-switch with `/target <harness>` and lose parallel-execution benefits.

**Value proposition:** Tabbed Chat lets one mobile user drive N concurrent agents from a single chat thread with one-character routing prefixes (`/0`, `/1`, ...), replacing N bots or constant `/target` switching.

The Context Gap this addresses:

1. **Identification** — which agent is which when responses arrive?
2. **Routing** — how do I direct input to a specific agent without typing long names?
3. **Mobile UX** — Telegram/Signal native chat UIs are constrained; complex slash-command vocabulary is unfriendly on a phone keyboard.

## Use Cases

> Each UC names a target persona and marks evidence as `[assumption-to-validate post-v1]` where we don't yet have user research backing it. Validation gate: post-v1, qualitative feedback from at least 3 power users in the target personas. If a UC's pain isn't confirmed, it gets de-prioritized in v2 planning.

**UC-1 — Coding agent + shell, parallel** (Persona: mobile-first developer pairing with PureClaw from a phone). User pins an AI tab `/0` on long-running code work and a shell tab `/1` for quick lookups. They direct-inject `/1 ls -la /var/log` without leaving `/0`'s context, switch to `/1` later to read the response. *[assumption-to-validate post-v1]*

**UC-2 — Multi-environment ops** (Persona: SRE on-call). User runs `/0` (local dev shell), `/1` (ssh to staging), `/2` (ssh+tmux attach to a prod incident session). `/2 status` direct-injects into the prod incident session; user reads output when switching to `/2`. *[assumption-to-validate post-v1]*

**UC-3 — Multi-model parallelism** (Persona: cost-conscious agent operator). User runs `/0` (Anthropic Opus for hard reasoning), `/1` (Haiku for quick lookups), routes accordingly to manage spend. *[assumption-to-validate post-v1]*

## Non-Goals

- **Tabbed Chat does NOT replace `/session`, `/target`, `/provider`, `/model`, `/vault`, `/harness`, `/mcp`** — it composes with them. Existing commands operate on the focused tab.
- **Single-tab users see no UX change.** A user who never types `/N` or `/tab` sees the existing PureClaw chat experience unchanged. (Implicit DoD: no behavioral regression for the empty-registry case.)
- **No cross-tab display in v1.** Only the focused tab's output appears in chat. Non-focused tab output accumulates in each tab's transcript and is shown when the user switches via `/N`. There are no proactive notifications, no pinned dashboards, no message-prefix tagging.
- **No multi-user channel partitioning in v1.** A bot is assumed single-user (per existing PureClaw `_cfg_allowedUsers` model). Group-chat multi-user tab partitioning is v2+.

## Routing Grammar (v1)

All routing happens in the slash-command preprocessor — **before** any provider call — preserving the LLM-free invariant for `/`-prefixed input.

```
input            ::= switch | inject | default | slash-cmd
switch           ::= '/' IDX                                 -- e.g. /0, /a
inject           ::= '/' IDX WS payload                      -- e.g. /0 run tests
default          ::= payload                                 -- to current focus
slash-cmd        ::= '/' WORD ...                            -- existing commands
                 |   '/tab' WS action [WS args]              -- new: tab family
                 |   '/tabs'                                 -- alias for `/tab list`
action           ::= 'new' | 'list' | 'close' | 'focus' | 'resume' | 'rename'
IDX              ::= [0-9a-z]                                -- exactly one char (digit or lowercase letter)
WS               ::= one or more spaces/tabs
payload          ::= rest of line, free text
```

The index is exactly one character: `'0'..'9'` maps to tab indices `0..9`; `'a'..'z'` maps to tab indices `10..35`. The mapping is case-sensitive — uppercase letters are not part of the index alphabet. Multi-char shapes (`/12`, `/01`, `/aa`, `/1a`) are all `ParseErrorMalformed`; there is no greedy digit run any more.

The single index character must be followed by **end-of-input or whitespace**; otherwise the input falls through to the slash-command parser. So `/s` parses as `/session` (slash command), not as tab 28 — the disambiguator is whether the second byte is alphanumeric (slash command) or blank/EOI (switch).

### Parser signature

```haskell
parseInput :: RoutingConfig -> Text -> Either ParseError ParsedInput
```

The parser is two-argument because `_rc_maxTabs` bounds-checks the index. `mkTabIndex` takes the bound from `RoutingConfig` and constructs the validated newtype.

### Parser invariants

* `/a` parses as tab 10; `/z` parses as tab 35 (single-char letter alphabet).
* `/12`, `/aa`, `/1a`, `/01` are all `ParseErrorMalformed` (multi-char index; the grammar admits no greedy run).
* `/0 0 run` parses as `Inject 0 "0 run"` (payload digits preserved).
* `/word` (non-numeric after `/`) routes to existing slash-command dispatch unchanged.
* **Single index char must be followed by EOI or whitespace.** `/s` is the `/session` slash command (the index char `s` would map to tab 28, but it's followed by `e` — a non-blank byte — so the parser falls through to the slash-command form). This is what makes letters in the index alphabet safe.
* `/0@botname` (Telegram group-chat bot mention): the `@botname` suffix is stripped by the channel's incoming preprocessor before parser sees the message. Parser invariant: never receives `@` characters.
* `TabIndex` is bounded at parse time using the `RoutingConfig` argument: `0 <= n < _rc_maxTabs` (default 36 — matches the single-char alphabet size). Out-of-range can only arise via the decimal `/tab new` / `/tab close` / `/tab focus` paths because single-char `/N` always lands in `0..35`; rejection is `ParseErrorIndexOutOfRange`.
* Trailing-whitespace-only payload (`/0 ` with only space after) → `Switch 0` (treat as bare switch).
* Multi-line payload (`/0\nfoo`) → `Switch 0` followed by `Default "foo"` as a separate incoming message; the channel layer is responsible for splitting at newlines if applicable, otherwise parser sees one input with embedded `\n` and treats the body after `/0` (incl. `\n`) as payload, i.e. `Inject 0 "\nfoo"`.

### Channel autocomplete (Telegram-specific)

Telegram's BotFather command list only autocompletes registered word-prefixed commands. To deliver real autocomplete on mobile, the channel-startup code registers these commands:

* `/0`–`/9`, `/a`–`/z` — 36 single-char tab switches, each described as "Switch to tab N"
* `/tab` — "Tabs: new, list, close, focus, resume, rename"
* `/tabs` — "List all tabs"
* `/start` — "Tabbed Chat — see /help for tab commands"

Telegram's `setMyCommands` accepts up to 100 entries per bot; 39 total (36 + 3 long-form + `/start`) fits comfortably under the limit. Because the entire index alphabet `[0-9a-z]` fits in single-char shortcuts, mobile autocomplete now covers every reachable tab index — there is no "above-N type the digits manually" caveat any more.

## Acceptance Criteria (v1)

**Test labels match these numbers exactly.** WU0 (red-phase scaffold) commits one failing test per DoD; the count below is the WU0 enumerated total.

### Parser & LLM-free invariant (P-series)

> Notation: tests are written as `parseInput rc input → result` where `rc :: RoutingConfig` is the test's RoutingConfig. P-series examples below elide `rc` for brevity and assume `rc = defaultRoutingConfig` (with `_rc_maxTabs = 36`) unless otherwise specified.

| #   | DoD                                                                                                         |
|-----|-------------------------------------------------------------------------------------------------------------|
| P1  | `parseInput "/0"` → `Right (Switch (TabIndex 0))`.                                                          |
| P2  | `parseInput "/12"` → `Left ParseErrorMalformed` (multi-char index; no greedy digit run).                    |
| P3  | `parseInput "/0 run tests"` → `Inject (TabIndex 0) "run tests"`.                                            |
| P4  | `parseInput "/0 0 run"` → `Inject (TabIndex 0) "0 run"` (preserves payload digits).                         |
| P5  | `parseInput "hello world"` → `Default "hello world"`.                                                       |
| P6  | `parseInput "/01"` → `Left ParseErrorMalformed` (multi-char index; `ParseErrorLeadingZero` no longer exists — it became structurally unreachable under the single-char grammar). |
| P7  | `parseInput "/9999"` → `Left ParseErrorMalformed` (multi-char index). `ParseErrorIndexOutOfRange` can only arise via the decimal `/tab new` / `/tab close` / `/tab focus` paths, never via `/N`. |
| P7a | `parseInput "/a"` → `Switch (TabIndex 10)` (letter alphabet: `'a'` → 10, `'z'` → 35).                       |
| P7b | `parseInput "/z"` → `Switch (TabIndex 35)`.                                                                  |
| P7c | `parseInput "/aa"` → `Left ParseErrorMalformed` (multi-char).                                               |
| P7d | `parseInput "/s"` → `SlashCmd CmdSession` (single index char must be followed by EOI/WS; `s` is followed by `e` so the input falls through to the slash-command parser). |
| P8  | `parseInput "/tabs"` → `SlashCmd CmdTabList`.                                                               |
| P9  | `parseInput "/tab list"` → `SlashCmd CmdTabList` (alias of /tabs).                                          |
| P10 | `parseInput "/tab new"` → `SlashCmd (CmdTabNew Nothing Nothing)` — no index argument (tmux packing model; handler allocates lowest free slot). |
| P11 | `parseInput "/tab new shell"` → `SlashCmd (CmdTabNew (Just KindShell) Nothing)`.                            |
| P12 | `parseInput "/tab close 3"` → `SlashCmd (CmdTabClose (TabIndex 3) ForceNo)`.                                |
| P13 | `parseInput "/tab close 3 --force"` → `SlashCmd (CmdTabClose (TabIndex 3) ForceYes)`.                       |
| P14 | `parseInput "/tab focus 3"` → `SlashCmd (CmdTabFocus (TabIndex 3))` (alias of `/3`).                        |
| P15 | `parseInput "/tab resume <session-id>"` → `SlashCmd (CmdTabResume <id>)` when `<session-id>` matches `[a-zA-Z0-9_-]+`. (Validation happens in parser via `mkSessionId`.) |
| P15a | `parseInput "/tab resume ../etc/passwd"` → `Left ParseErrorInvalidSessionId`. Same for inputs containing `/`, `\`, `..`, NUL, or any char outside `[a-zA-Z0-9_-]`. Test corpus enumerates these adversarial cases. |
| P16 | `parseInput "/tab rename 3 my-shell"` → `SlashCmd (CmdTabRename (TabIndex 3) "my-shell")`. (Semantic-level sanitization happens at handler-level per S10, but parser-level: rename payload is captured as raw `Text` and validated at handler time.) |
| P17 | **No-regression — existing slash commands route unchanged**: for each of `/help`, `/status`, `/session`, `/target`, `/provider`, `/model`, `/vault`, `/harness`, `/mcp`, `/channel`, `/transcript`, `/agent`, `/new`, `/last`, `parseInput` returns the existing `SlashCommand` constructor (the parser does not steal them). One assertion per command (~14 sub-cases). |
| P18 | **LLM-free invariant (property test)**: for every input matching the routing grammar `switch | inject | slash-cmd`, the recorded `Provider.complete` invocations is empty. A fake `Provider` recording every `CompletionRequest` is required test seam (see T1). Only `Default <text>` inputs reach the provider. |

### TabHandle abstraction (H-series)

| #   | DoD                                                                                                          |
|-----|--------------------------------------------------------------------------------------------------------------|
| H1  | `TabHandle` is a record of IO actions with `_tabHandle_*` field prefix matching the universal Handle convention.    |
| H2  | Factories `mkTabAi`, `mkTabHarness`, `mkTabBackend` exist; each returns `IO (Either TabError TabHandle)`.    |
| H3  | `TabError` is an ADT with constructors enumerated below; no free-`Text` constructors; `Show TabError` is implemented manually per H14. Constructors: `TabIndexInUse !TabIndex`, `TabIndexOutOfRange !Int`, `TabLimitExceeded !Int`, `TabBackendConstructFailed !BackendError`, `TabSessionCreateFailed !SessionError`, `TabSpawnAuthDenied !PublicAuthError`, `TabNotFound !Int`, `TabConcurrencyLimit !Int`, `TabInvalidName !NameError`, `TabUnsupportedCommand !SlashCommand` (for `_tabHandle_enqueueSlash` on non-AI tabs per H13). `NameError = NameTooLong | NameContainsControlBytes | NameContainsAnsi | NameRedactedToEmpty` — a redacted ADT, not raw input. `PublicTabError` mirror + `toPublicTabError` projection for channel-bound errors. |
| H4  | `_tabHandle_send :: Text -> IO ()` enqueues to the tab's input queue and never blocks the dispatcher (`TBQueue` with bounded backpressure capacity `_rc_inputQueueBound`, default 64). On overflow, returns to dispatcher which emits `tab input queue full` PublicError. |
| H5  | `_tabHandle_status :: IO TabStatus` returns `Active`, `Idle UTCTime`, or `Crashed PublicTabError`. (Two runtime states + exception state. `Active` covers provider call AND tool execution; the dashboard does not distinguish.) |
| H6  | `_tabHandle_close` is **idempotent**.                                                                               |
| H7  | `_tabHandle_close` **never throws**. (Parallel to `_bh_close` contract in `BackendHandle`.)                         |
| H8  | `_tabHandle_close` semantics are kind-specific: for `KindAi`, archives the session (calls `_sh_save`) and removes from registry. For `KindHarness` and `KindBackend`, destroys (calls `_hh_stop` or `_bh_close` respectively). |
| H9  | `_tabHandle_close --force` on `KindAi` skips archive (deletes transcript). On other kinds it is a no-op (close is already destructive). |
| H10 | `_tabHandle_close` cancels any in-flight provider call or backend recv via `throwTo … AsyncCancelled`; cleanup runs in a `bracket` wrapper so per-kind resources (BackendHandle, HarnessHandle, SessionHandle) are released even on exception. |
| H11 | `_tabHandle_name` is constructed via the shared `sanitizeTabName :: Text -> Either NameError Text` function which enforces (a) length cap `_rc_maxNameLen` (default 32), (b) reject control bytes `< 0x20` except space, (c) reject ANSI escape sequences (`\\x1b[`, `\\x9b`), AND (d) redact hostnames, filesystem paths, and ssh-stderr fragments per `terminal-backend-abstractions`'s `Information Disclosure / Redaction`. **Every** path that sets `_tabHandle_name` (factory construction AND `/tab rename`, per S10) routes through `sanitizeTabName`. Test: property test asserts `_tabHandle_name` of every constructed tab satisfies all four predicates regardless of input. Specific assertions: a tab spawned against `ssh prod-db.internal` exposes `_tabHandle_name = "ssh tab"` or a safe label, NOT the host; a factory-supplied name carrying `\\x1b[31m` gets stripped or rejected; a 10kB name is rejected. |
| H12 | `_tabHandle_kind` is a pure field (parallel to `_bh_kind`); no IO read.                                             |
| H13 | `_tabHandle_enqueueSlash :: SlashCommand -> IO (Either TabError ())` — enqueues a SlashCmd InputEvent into the tab's input queue. For `KindAi`, the loop processes it via `executeSlashCommand` against its own `_ats_context`; for non-AI kinds, returns `Left TabUnsupportedCommand` immediately (no enqueue). The dispatcher uses this for E5's queue-based Context mutation model — it never reaches into a tab's private state. (No `_tabHandle_context` field needed: all Context reads and writes happen inside the tab loop, the sole writer.) |
| H14 | `Show TabError` is implemented manually (NOT `deriving Show`) to enforce the redacted-error contract: constructor names are shown but argument values are elided (e.g. `TabBackendConstructFailed _`). The redacted projection for channel-bound errors is `toPublicTabError`. Test: `show err` for any `TabError` value contains no path, no hostname, no internal text. |

### Registry & AgentEnv (E-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| E1  | `AgentEnv` gains `_env_tabs :: IORef (IntMap TabHandle)` (key = `unTabIndex`), `_env_focus :: IORef (Maybe TabIndex)`, `_env_routingConfig :: RoutingConfig`, `_env_channelOutQ :: TBQueue (OutputSource, ChannelEvent)` (bounded, capacity `_rc_channelOutQBound = 1024`). |
| E2  | Existing `_env_target`, `_env_session`, `_env_provider`, `_env_model` remain in `AgentEnv` as **focused-tab projections**. Reads of these fields are valid only inside the dispatcher's message-processing window. The dispatcher updates them when focus changes; tab loops do NOT read these fields (they hold their own per-tab state). |
| E3  | **Focus invariant** (key safety property): `_env_focus` is written **only** by the dispatcher, **only** between message cycles. Slash-command handlers that mutate focused-tab projection fields (`_env_target`, etc.) execute synchronously in the dispatcher thread and complete before the next message is read. This eliminates TOCTOU between handler reads/writes. **Test**: spawn N concurrent input emitters writing to a fake channel's input `TBQueue`; run dispatcher for K message cycles; assert focus is consistent at end-of-cycle k against the input sequence accepted at cycle k. |
| E4  | `_env_fork :: IO () -> IO TabRunner` is part of AgentEnv (test seam; default wraps `Control.Concurrent.Async.async`). `data TabRunner = TabRunner { _trun_cancel :: IO (), _trun_wait :: IO () }` exposes cancel + wait. **Rationale**: `IO () -> IO ThreadId` cannot carry an `Async ()` handle for `cancel`, and a synchronous test seam returning a real `ThreadId` is impossible. The `TabRunner` indirection lets the synchronous test variant record start, expose `_trun_cancel` as an `IORef` that the test can observe, and run the action inline. All tab-spawning code paths use `_env_fork`. |
| E5  | **Per-tab Context mutations go through the tab loop's input queue (single-writer model).** `_ats_context` is mutated **only by the tab loop**, never by the dispatcher. When the dispatcher receives a Context-mutating slash command (`/new`, `/last`, `/compact`, `/transcript`, `/agent`) it does NOT call `executeSlashCommand` directly. Instead it enqueues an `InputEvent` into the tab's `_ats_inputQ` (which is now `TBQueue InputEvent`, not `TBQueue Text`) where `data InputEvent = UserText !Text | SlashCmd !SlashCommand`. The tab loop processes events in order, running `executeSlashCommand` against its own `_ats_context` (the canonical writer). This eliminates the dispatcher-thread vs tab-loop concurrent-write race on the Context IORef. **Test**: `/0` is focused, `/0 do task` enqueues `UserText "do task"`, tab loop starts a slow provider call; while it's running, user sends `/new` (focused), dispatcher enqueues `SlashCmd CmdNew`; tab loop completes the slow call, writes its response to context, then dequeues `SlashCmd CmdNew` and clears. Final state: history has one (user, response) pair, then cleared by /new. No lost updates, deterministic ordering. (Compare to the broken alternative where dispatcher writes the cleared context while the tab loop is mid-call — that race is excluded by this design.) |

### Concurrency & exception safety (C-series)

| #   | DoD                                                                                                                 |
|-----|---------------------------------------------------------------------------------------------------------------------|
| C1  | **Tabs run in their own threads.** Behavioral test (using a fake `Provider` that blocks on a `TMVar`): two AI tabs `/0` and `/1`; `/0` is given a slow request, immediately followed by `/1 ping`; `/1`'s response is observed in `/1`'s transcript *before* `/0`'s response completes. |
| C2  | **AI tab state isolation.** Two AI tabs each hold distinct `IORef (Maybe ModelId)`. `/0 /target sonnet` (per-tab) does not change `/1`'s model. |
| C3  | **Tab spawn is exception-safe.** Spawning uses `mask` so a partial registration cannot leak a half-initialised tab in `_env_tabs` on async exception. Test: a spawn whose factory throws mid-construction leaves `_env_tabs` unchanged AND any partially-allocated resource (e.g. a started BackendHandle) is closed. |
| C4  | **Dispatcher death cancels all tabs.** Dispatcher's `runDispatcher` is wrapped in `bracket (newIORef IntMap.empty) cancelAll dispatcherBody` where `_env_runners :: IORef (IntMap (IORef (Maybe TabRunner)))` holds per-tab placeholders and `cancelAll = readIORef _env_runners >>= traverse_ cancelOne` with `cancelOne ref = readIORef ref >>= maybe (pure ()) _trun_cancel`. Each `spawnTab` registers its placeholder (per the bootstrapping section under `mask` BEFORE the fork) so cancelAll always sees an entry. **`withAsync` is NOT used** because it is lexically scoped and doesn't compose for a dynamically-spawned set of tabs over the dispatcher's lifetime. `cancelAll` fires on BOTH exception AND graceful exit (e.g. `_ch_receive` returning end-of-stream). Test: simulate dispatcher exception; assert all forked tab threads receive cancellation and `_tabHandle_close` runs to completion. Separate test: graceful exit (channel returns EOF) also triggers cancelAll. |
| C5  | **Crash isolation.** A tab loop catches `SomeException` **except `AsyncCancelled`** (which propagates through bracketed cleanup unchanged — async cancellation is the normal close path, not a crash). On synchronous exception, the loop sets `_tabHandle_status` to `Crashed`, attempts a single channel emit of the PublicError through `SrcDispatcher` (which the writer-thread emits unconditionally), and exits its thread. The dispatcher does not crash when a tab does; the registry entry persists with `Crashed` status until `/tab close N` or `/tab resume <session>`. Test: a tab whose factory throws `SomeException` after registration leaves dispatcher alive and registry consistent. Separate test: `_tabHandle_close` (which sends `AsyncCancelled` via H10) leaves status `Closing`, not `Crashed`. |
| C6  | **Provider cancellation safety.** A tab close mid-stream that delivers `AsyncCancelled` to the provider call must leave the transcript in one of two states: (a) the full prefix streamed so far, terminated by a cancel-marker entry, OR (b) no partial entry at all. No half-written entries. Test: fake `Provider` that streams 5 chunks then blocks on a `TMVar`; cancel mid-stream; assert transcript state is one of the two valid forms. |

### Channel emission & focused-only display (D-series)

| #   | DoD                                                                                                                      |
|-----|--------------------------------------------------------------------------------------------------------------------------|
| D1  | **Only the focused tab writes to channel** (chat). Behavioral test: `/0` and `/1` both producing output; `_env_focus = Just 0`; the channel (a fake `ChannelHandle` recording every `_ch_send` / `_ch_sendChunk`) sees only `/0`'s output. |
| D2  | **Non-focused tab output still lands in its transcript.** Same test as D1: `/1`'s transcript (`_sh_transcript` on the tab's `SessionHandle`) contains its complete response even though the channel saw none of it. |
| D3  | **Channel writes are serialized.** Single output-writer thread consumes from a **bounded** `TBQueue (Source, ChannelEvent)` (`_env_channelOutQ` with capacity `_rc_channelOutQBound`, default 1024) where `Source = SrcDispatcher | SrcTab TabIndex`. **The writer thread is the authoritative focus gate** — on consume, it reads `_env_focus` and drops `SrcTab N` events when focus `/= Just N`. `SrcDispatcher` events (switch confirms, dashboard, command errors, footer breadcrumbs) always emit. Test: concurrent emits from 3 tabs + dispatcher produce no garbled output; only `SrcDispatcher` + the focused-tab's events reach the channel. |
| D4  | **Producer-side focus pre-check (optimization, not the gate).** Tab loops perform a cheap `_env_focus` check before enqueueing `SrcTab` events. If the loop is non-focused, the emit is silently dropped (transcript still records). This avoids unbounded growth on the writer queue when a non-focused tab streams fast. Authoritative gating is still at the writer per D3. Test: simulate non-focused tab streaming 10,000 chunks; assert `_env_channelOutQ` length never exceeds a small bound. |
| D5  | **Mid-stream switch breadcrumb (AI tabs only)**. `ChannelEvent` is an ADT with constructors `StreamStart !StreamId !TabIndex`, `ChunkOf !StreamId !Text`, `StreamEnd !StreamId`, `FullMsg !TabIndex !Text`, `BannerLine !Text`. **AI tab loops** emit `StreamStart` once per logical message (start of a provider streaming response), then `ChunkOf` per chunk, then `StreamEnd`. **Non-AI tab loops** (KindShell/KindSsh/KindTmux/KindHarness) emit one `FullMsg !TabIndex !Text` per `_bh_recv`/harness-recv return (no streaming, no breadcrumb). The writer maintains `Map StreamId BreadcrumbState` (`Pending | Emitted`). When the writer drops a `ChunkOf sid` because focus has moved away from the stream's owner tab, it checks the map: if `Pending`, emit one `SrcDispatcher BannerLine "/N has new output — /N to view"` (status-neutral wording) and set state to `Emitted`. Subsequent drops with same `sid` are silent. State entries are GC'd on `StreamEnd` reception. **For non-AI tabs**: a dropped `FullMsg` event during non-focused output does NOT trigger a breadcrumb (rationale: shell/ssh output is line-oriented and a per-line breadcrumb would be noisy; v1.5 may add aggregate breadcrumb for backend tabs if user feedback demands it). Test: focus on `/0` (AI), switch to `/1` mid-stream of `/0`'s 10-chunk response (sid = S); writer drops chunks 2–10 under `_env_focus = Just 1`; exactly one `BannerLine` emitted; `/0`'s transcript records all 10 chunks. Separate test: focus on `/0`, switch to `/1` while `/0` (KindShell) is emitting `FullMsg` events; assert zero breadcrumbs; `/0`'s transcript still records all output. |
| D6  | **No other proactive non-focus notifications.** When a non-focused tab finishes work, crashes, or changes status (outside the mid-stream breadcrumb above), no channel message is emitted. The user must `/tabs` or `/M` to observe. Test: `/0` (non-focused) crashes; channel sees zero new messages beyond any in-flight breadcrumb. |

### Auto-spawn behavior (A-series)

`_rc_defaultKind` ships pre-set to `KindAi` (with provider/model defaults from `_rc_defaultAi`) so the common case is one keystroke.

**v1.5 semantics (tmux packing model):** Tabs are always packed at the lowest free slot — the user no longer picks the index. `/N` for an empty slot is unambiguously user error and does NOT auto-spawn; the dispatcher emits an error banner. The K3 first-run UX (empty registry + `Default` text → auto-spawn at `/0` via `_rc_defaultKind`) is preserved as the one and only "implicit spawn" path.

| #   | Scenario                                              | Behavior                                                                                              |
|-----|-------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| A1  | `/3`, N exists                                        | switch focus, emit recap of last `_rc_switchRecap` messages from N's transcript                       |
| A2  | `/3 payload`, N exists                                | enqueue `payload` to N's input, focus unchanged, channel sees no immediate output                    |
| A3  | `/3`, N missing                                       | ERROR banner `"/3: no such tab — use /tab new to create one"`; **no auto-spawn**. Source tag `SrcDispatcher` so the banner emits regardless of current focus. |
| A4  | *(deprecated v1.5)* — was "prompt UI on missing /N, default unset". No longer applicable now that `/N` never spawns. |
| A5  | `/3 payload`, N missing                               | Same as A3: ERROR banner; payload is **discarded** (not buffered). User must explicitly `/tab new` first. |
| A6  | *(deprecated v1.5)* — see A5.                                                                                                                                |
| A7  | `/tab new` (no kind)                                  | **force-prompt** — ignores `_rc_defaultKind`; renders prompt UI for the lowest free slot.            |
| A8  | *(deprecated v1.5)* — was "`/tab new N` (no kind), N exists → error". The user can no longer pick N, so the collision scenario does not arise. |
| A9  | `/tab new shell`                                      | spawn with `KindShell` at lowest free slot, focus, confirmation banner `/<n>: spawned (shell)`.       |
| A10 | *(deprecated v1.5)* — see A8.                                                                                                                                |
| A11 | `/tab new` when `_rc_maxTabs = 36` cap reached        | `Left (TabLimitExceeded 36)` as `PublicError`; no process spawned. (Force-prompt path emits the same redacted error when `Registry.lowestFreeIndex` returns `Nothing`.) |
| A12 | `/tab close N` (any N): tmux-style packing — every remaining tab at index `> N` shifts down by one. After the close, the next `/tab new <kind>` allocates at the new lowest free slot (which may be `N` if the registry had a hole there, or `len(registry)` if everything was contiguous below). |
| A13 | Empty registry + `Default` text input (no slash prefix) → K3 first-run path: implicitly spawn `_rc_defaultKind` at the lowest free slot (typically `/0`), focus it, enqueue the text. This is the only `Default`-text-triggered auto-spawn; once at least one tab exists, plain text routes to the focused tab and `/N` for missing indices errors. |

### Close / lifecycle (L-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| L1  | `/tab close 3` on `KindAi`: archives session (transcript saved via `_sh_save`); registry entry removed; index freed; `_tabHandle_close` runs. |
| L2  | `/tab close 3` on `KindHarness`: destructive — `_hh_stop` runs; registry entry removed; transcript NOT archived. |
| L3  | `/tab close 3` on `KindBackend`: destructive — `_bh_close` runs; registry entry removed; transcript NOT archived. |
| L4  | `/tab close 3 --force` on `KindAi`: skips archive (transcript deleted from disk); registry entry removed.        |
| L5  | `/tab close 99` (non-existent index): `Left TabNotFound 99` as PublicError; no side effects.                      |
| L6  | `/tab close N` (tmux packing): every remaining tab at index `> N` shifts down by one so the registry stays contiguous from `0`. Focus reconciliation: `focus == N` → `Nothing`; `focus > N` → `focus - 1`; `focus < N` → unchanged. When the registry becomes empty (`_env_focus = Nothing`), a subsequent `Default` text input (no slash prefix) implicitly spawns `_rc_defaultKind` at the lowest free slot (typically `/0`) and routes to it — the K3 first-run path. Test: `/tab close 0` on a single-tab registry leaves `_env_focus = Nothing`; the next `Default "hi"` input results in `/0` spawned with `_rc_defaultKind` and `"hi"` enqueued. Separate test: `/tab close 1` on a 3-tab registry shifts `/2` down to `/1`; if `_env_focus = Just 2`, focus becomes `Just 1`. |
| L7  | `/tab resume <session-id>` validates the supplied id and routes it through `Session.resolveSessionRef` (the existing canonical safe path). The parser uses `mkSessionId :: Text -> Either ParseError SessionId` which rejects `/`, `\`, `..`, NUL, and any character not in `[a-zA-Z0-9_-]`. Test: `/tab resume ../../etc/passwd` produces `ParseErrorInvalidSessionId` at parse time with no `Session.resumeSession` call; `/tab resume <valid-id-not-in-registry>` produces `Left SessionNotFound` via `resolveSessionRef`'s `listDirectory` lookup; `/tab resume <valid-archived-id>` creates a new tab with the saved session, allocates lowest free index, focuses. |

### Crashed tab UX (X-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| X1  | `/3` on a tab with `_tabHandle_status = Crashed e`: dispatcher emits a one-line PublicError summary (`/3 crashed: <redacted message>`) plus prompt `[1] retry [2] close`. Source tag: `SrcDispatcher` (not `SrcTab 3`), so the writer emits unconditionally regardless of current focus. `<redacted message>` is `toPublicTabError e`, never the raw `TabError` Show. |
| X2  | Retry on `KindAi` re-runs the spawn factory with the original args; the session/transcript is preserved (continuation, not new). |
| X3  | Retry on `KindHarness`/`KindBackend` re-runs the spawn factory with original args; status returns to `Active`. The previous process is gone — no continuation. |

### Dashboard (B-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| B1  | `/tabs` (or `/tab list`) with empty registry: emits `"No tabs open. Use /tab new <kind> to create one."` (The previous wording suggested `/N` as a creation path — under v1.5's tmux model `/N` only switches and errors on missing tabs, so the hint is gone.) |
| B2  | `/tabs` with N tabs: emits one line per tab containing index, kind, redacted name, status, and an asterisk marker for the focused tab. Test: dashboard output for 3 tabs matches a golden-file render. |
| B3  | `/tabs` rendering for ≥ 8 tabs uses bullets (no fixed-width table) so it wraps cleanly on small mobile screens.   |

### Security (S-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| S1  | **Spawn authorization (local)**: `/tab new shell <cmd...>` calls `authorize cmd _env_policy` BEFORE any subprocess. Test: `cmd` not in `_sp_allowedCommands` → `Left TabSpawnAuthDenied`; no process spawned; channel error is PublicError. |
| S2  | **Spawn authorization (remote/tmux-over-ssh)**: `/tab new ssh <host> <cmd...>` calls `authorizeRemote cmd _env_policy` and `mkSshHost host`. Test: rejected `host` strings (whitespace, leading `-`, NUL, shell metachars) all produce `Left BackendInvalidOption` as PublicError; no ssh subprocess. |
| S3  | **Smart-constructor validation**: every kind-specific spawn arg passes through its smart constructor (`mkSshHost`, `mkTmuxSession`, `mkTmuxWindow`, `mkTmuxPane`, `mkLocalCommand`). Rejection produces `BackendInvalidOption`. Property test enumerates rejected patterns from terminal-backend-abstractions's adversarial list. |
| S4  | **SSH identity sourcing**: ssh tabs source their `SafeKeyPath` from a Vault slot named by `_rc_sshIdentityKey` (config field, default `"default-ssh-key"`). Identities are NEVER typed inline by the user. Test: `/tab new ssh user@host` with no Vault slot present → PublicError; user-supplied identity arg is rejected by the parser. |
| S5  | **Crashed PublicError**: `Crashed e` is the *internal* representation; channel emit goes through `toPublicTabError`. Test: a tab whose backend factory returns `BackendSshConnectFailed (SshHostKeyMismatch ...)` produces a channel message containing neither the host string, nor any path, nor any ssh stderr. |
| S6  | **Max-tab cap enforced at spawn**: covered by A11; cross-referenced here for security audit traceability. |
| S7  | **Spawn rate limit**: each chat-user is limited to `_rc_spawnRateLimit` spawns/minute (default 10). Token-bucket implementation. Exceeding it → PublicError; no spawn. Defends against close-spawn cycling resource leak. |
| S8  | **User-allowlist invariant**: the user-allowlist check (e.g. `_sc_allowFrom` in Signal channel) is the canonical gate. The dispatcher reads from `_ch_receive` only — no other input path exists. Test: a fake non-allowlisted user emits messages into the channel's lower-level input queue; the dispatcher's `runDispatcher` is observed to invoke no handler. (Runtime test; static grep is a code-review checklist item, not a unit test.) |
| S9  | **Concurrent-active-tab cap (atomic, fail-fast)**: `_rc_maxConcurrentActive` (default 4) limits tabs in `Active` status simultaneously. An atomic counter `_env_activeCount :: TVar Int` is maintained in `AgentEnv`. Status transitions to/from `Active` happen inside `atomically` together with `modifyTVar' _env_activeCount`. The cap check + increment is one atomic step using **fail-fast** (NOT STM `retry`, which would block the dispatcher and violate H4): `atomically $ do { n <- readTVar _env_activeCount; if n >= cap then pure (Left TabConcurrencyLimit) else writeTVar _env_activeCount (n+1) >> pure (Right ()) }`. STM `retry` is explicitly NOT used because it would block `_tabHandle_send`'s caller (the dispatcher), violating "never blocks dispatcher" (H4). Concurrency property test: N concurrent direct-injects into N idle tabs with cap=K result in exactly K successful transitions to Active and N-K `TabConcurrencyLimit` errors, regardless of interleaving (verified by repeating M times under randomised `forkIO` schedule). |
| S10 | **`/tab rename N <name>` input sanitization**: user-supplied name passes through `sanitizeTabName` (the same function H11 mandates for every factory-construction path). All four rules apply: length cap, control-byte rejection, ANSI rejection, hostname/path/ssh-stderr redaction. On `Left NameError`: surface as `Left (TabInvalidName err)` PublicError; `_tabHandle_name` unchanged. On `Right safeName`: the new `_tabHandle_name = safeName`, and the user is informed via channel `Renamed /3 to "<safeName>"`. **If redaction stripped fragments**: the bot informs the user by showing the actual new name `Renamed /3 to "<safeName>"` AND, when `safeName /= rawInput`, appends `(redacted host/path fragment)`. **If redaction reduces to empty** (`NameRedactedToEmpty`): rename rejected, `_tabHandle_name` unchanged, user sees `Rename rejected: name would be empty after sanitization. /3 still named "<old-name>".` Test: rename with ESC, NUL, 10kB → `TabInvalidName`; rename `my-shell` succeeds with `Renamed /3 to "my-shell"`; rename `prod-db.internal` → `Renamed /3 to "prod-db" (redacted host/path fragment)`; rename `.internal` → `Rename rejected: name would be empty after sanitization`. |
| S11 | **Provider connection-pool isolation (documented assumption)**: this is NOT a DoD that produces a test, but a documented invariant the design relies on. Per-tab `_ats_provider :: IORef SomeProvider` may reference a `Provider` whose underlying transport (HTTP client pool, etc.) is shared across tabs. Tab isolation is guaranteed at the conversation-state level (`_ats_context`, `_ats_model`, `_ats_target`) but NOT at the HTTP-transport level. Anthropic/OpenAI APIs are stateless per-request, so this is safe for v1. A future stateful-transport provider (e.g. WebSocket-based) must add a per-tab transport instance or a documented "stateless transport" capability constraint. |

### Coexistence with existing slash commands (K-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| K1  | `/session new` while a focused tab exists: creates a new SessionHandle and **attaches to the focused tab** (per K2, if focused tab is `KindAi`). If the focused tab is `KindHarness`/`KindBackend`, `/session new` errors with a PublicError explaining "this tab does not own a session." |
| K2  | `/tab new ai` automatically creates a new SessionHandle for the tab. (Tab-creation → session-creation direction.) |
| K3  | `/session new` with empty registry implicitly spawns a `KindAi` tab at the lowest free index (default behavior). |
| K4  | `/target <name>` while focused on a `KindAi` tab: sets that tab's target via the focused-tab projection. Does NOT persist across pureclaw restarts (per-tab target is in-memory). To make a tab spawn with a specific target on restart, edit defaults in config. |
| K5  | `/target <name>` while focused on a `KindHarness` or `KindBackend` tab: PublicError "tab kind does not support /target." |
| K6.1 | `/provider` while focused on `KindAi`: updates the focused tab's `_ats_provider` IORef via the focused-tab projection; test asserts only the focused tab's provider changes. |
| K6.2 | `/model` while focused on `KindAi`: updates the focused tab's `_ats_model` IORef; same-tab-only assertion. |
| K6.3 | `/vault` operations while focused on `KindAi`: operate on the AgentEnv-level `_env_vault` (which is process-wide, not per-tab); test asserts vault access works from any focused AI tab. |
| K6.4 | `/transcript` while focused on `KindAi`: renders the focused tab's transcript (`_sh_transcript` via the tab's SessionHandle). Test: with two AI tabs, `/transcript` shows the focused tab's history, not the other tab's. |
| K6.5 | `/agent <name>` while focused on `KindAi`: changes the focused tab's agent label (which the spawn factory uses to look up agent-specific defaults). Same-tab-only assertion. |
| K6.6 | `/new` while focused on `KindAi`: per E5/I5, the dispatcher calls `_tabHandle_enqueueSlash focusedTab CmdNew`. The tab loop processes the event by running `executeSlashCommand env CmdNew` against `_ats_context` and writing the cleared context back. Test: `/0 /new` clears `/0`'s history once the tab loop processes the event (use `_trun_wait` or a test-seam synchronization); `/1`'s history intact. |
| K6.7 | `/last` while focused on `KindAi`: read-only. Dispatcher reads `_ats_context` directly (best-effort point-in-time read; the doc accepts a small staleness window if the tab loop is mid-turn). For deterministic-ordering needs, the test can use `_trun_wait` or fence via an `_tabHandle_enqueueSlash CmdNoop` followed by a read. Same-tab-only assertion. |
| K6.8 | `/compact` while focused on `KindAi`: per E5/I5, dispatcher enqueues `CmdCompact` via `_tabHandle_enqueueSlash`; the tab loop calls `compactContext` against `_ats_context` and writes back. Same-tab-only assertion. |
| K7  | `/session resume <id>` while focused on a `KindAi` tab: rather than mutating `_env_session` as today, this command **replaces the focused tab's `_tabHandle_session`** by spawning a new AI tab loop with the resumed session and closing the old one. Index is preserved. (Alternative: error with "use /tab resume to load an archived session into a new tab." Decide before WU0.) v1 default: replace the focused tab's session in place. |
| K8  | `/session last` while focused on a `KindAi` tab: shows the last completion of the focused tab's session; routes through the same path as K6.7 (`/last`). |

### Direct-inject and in-tab-loop slash-command handling (I-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| I1  | **Direct-inject payload handling**: `/N <payload>` enqueues `UserText payload` to tab N's input queue via `_tabHandle_send`. The dispatcher does **not** re-classify the payload. |
| I2  | **AI tab loop processes both event types**: when an AI tab's loop dequeues from `_ats_inputQ`, it handles either constructor: `UserText t` → if `t` starts with `/` after trimming, re-parse via `parseSlashCommand` and treat as if it were a SlashCmd event (re-parse path for direct-inject of slash-shaped payload like `/0 /new`); otherwise feed `t` to the provider as user input, run one turn, write response to `_ats_context`. `SlashCmd cmd` → run `ctx' <- executeSlashCommand env cmd =<< readIORef _ats_context; writeIORef _ats_context ctx'`. **`_ats_context` is mutated only by this code path** (the tab loop thread). |
| I3  | **LLM-free invariant under direct-inject**: a direct-inject of slash-command-shaped payload (`/0 /new`) routed through the AI tab loop and re-parsed (I2) must satisfy P18 — no slash-command-shaped payload reaches the provider. Test: fake `Provider`'s `complete` is never invoked when the AI tab processes `/new` via I2's re-parse path. Also assert `parseSlashCommand` recognised it as `CmdNew`. |
| I4  | **Non-AI tabs treat slash-prefix on direct-inject as opaque text**: a `KindShell`/`KindSsh`/`KindTmux` tab that receives `/0 ls -la` via direct-inject treats the payload as opaque text and writes it to the backend via `_bh_send`. Non-AI tabs do NOT host a slash-command parser. Test: `/0 /pwd` direct-injected to a KindShell tab sends literal `/pwd` to the shell. |
| I5  | **Dispatcher routes E5 commands via `_tabHandle_enqueueSlash`**: when the dispatcher processes a Context-mutating slash command (`/new`, `/last`, `/compact`, `/transcript`, `/agent`) against the focused AI tab, it calls `_tabHandle_enqueueSlash` on that tab. The dispatcher does NOT call `executeSlashCommand` against the tab's context. On `Left TabUnsupportedCommand` (focused tab is non-AI), the dispatcher emits a `SrcDispatcher` PublicError `"/N: tab kind does not support this command"` (mirrors K5's `/target` pattern). Test: dispatcher receives `/new` while focused on /0; `/0`'s input queue receives a `SlashCmd CmdNew` event; dispatcher returns to read the next channel message immediately (no blocking wait for the tab to process). Separate test: same command while focused on a `KindShell` tab produces PublicError, no enqueue. |

### Onboarding (O-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| O1  | **`/start` (Telegram convention)**: the channel-startup handler registers a `/start` slash command whose response includes (a) one-line value prop; (b) `/0` shortcut for AI; (c) `/tab new shell` for shell users; (d) `/tabs` for dashboard. Test: a fresh `/start` from a new user gets a response containing all three slash-prefix mentions. |
| O2  | **`/help`** rendering post-Tabbed-Chat includes a "Tab commands" subsection enumerating `/N`, `/N <payload>`, `/tabs`, `/tab new`, `/tab close`, `/tab focus`, `/tab resume`, `/tab rename`. Test: `/help` output (after this work lands) contains the literal strings "Tab commands" and "/tabs". |
| O3  | **BotFather command descriptions**: the registration list (already enumerated in the "Channel autocomplete" section) ships with the following descriptions: `/0`–`/9` and `/a`–`/z` → "Switch to tab N"; `/tab` → "Tabs: new, list, close, focus, resume, rename"; `/tabs` → "List all tabs"; `/start` → "Tabbed Chat — see /help for tab commands". 39 entries total (36 + 3). Test: BotFather registration payload (a list of `(command, description)` tuples) matches a golden file. |

### Test seams (T-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| T1  | `Test.Fake.Provider` exists: a `Provider` impl backed by a `TVar [CompletionRequest]` recording every `complete` invocation and serving canned responses (including TMVar-blocking variants for concurrency tests). Used by P18, C1, D-series. |
| T2  | `Test.Fake.ChannelHandle` exists: a `ChannelHandle` impl backed by a `TVar [(UTCTime, ChannelEvent)]` recording every emit. Provides `_ch_receive` from an injected `TQueue` of inputs. Used by D1, D3, D4, D5, B-series. |
| T3  | `Test.Fake.TabFactory` exists: pure factories `mkFakeTabAi`, `mkFakeTabHarness`, `mkFakeTabBackend` that produce `TabHandle`s without external resources. Used by dispatcher/registry tests. |
| T4  | `_env_fork :: IO () -> IO TabRunner` substitution: tests use a synchronous variant where `_trun_cancel` writes to an `IORef Bool` the test asserts on, and the body runs inline. Where concurrency is essential to the test (C1, C6), tests use the production async-based variant with deterministic synchronization via `TMVar`. |

### Total: ~115 DoDs across 14 series (P/H/E/C/D/A/L/X/B/S/K/I/O/T).

P-series: 23 (P1–P18 + P15a + P7a–P7d) — parser + LLM-free invariant. (P7a/P7b/P7c/P7d added in v1.5 for letter alphabet + multi-char rejection + slash-command-disambiguation.)
H-series: 14 (H1–H14) — TabHandle abstraction (incl. H13 `_tabHandle_enqueueSlash`, H14 manual `Show TabError`).
E-series: 5 (E1–E5) — registry + AgentEnv + Context flow.
C-series: 6 (C1–C6) — concurrency + exception safety + provider cancel safety.
D-series: 6 (D1–D6) — channel emission + focused-only display + breadcrumb.
A-series: 9 active + 4 deprecated (A1–A13; A4, A6, A8, A10 deprecated in v1.5 because they only made sense under the user-picks-index model) — auto-spawn truth table.
L-series: 7 (L1–L7) — close/lifecycle.
X-series: 3 (X1–X3) — crashed tab UX.
B-series: 3 (B1–B3) — dashboard.
S-series: 11 (S1–S11) — security (S11 is a documented assumption, not a test).
K-series: 15 (K1–K5 + K6.1–K6.8 + K7, K8) — coexistence with existing slash commands.
I-series: 4 (I1–I4) — direct-inject and in-tab-loop slash-command re-parse.
O-series: 3 (O1–O3) — onboarding (`/start`, `/help`, BotFather descriptions).
T-series: 4 (T1–T4) — test seams.

Sum: ~115 DoDs. (S11 is documented-assumption-only, so ~114 produce failing tests in WU0.)

(Final count for WU0 should be re-checked against this doc when WU0 lands; if K6 sub-DoDs combine into a single property test that asserts "for each of these 7 commands, …", the count compresses but the coverage doesn't.)

WU0 commits the failing-test count above (or `pending` tests, for ones whose factories haven't landed yet), structured to mirror these series.

## The Abstraction

### `TabHandle` (Handle pattern, mirrors `BackendHandle`)

```haskell
-- src/PureClaw/Handles/Tab.hs

newtype TabIndex = TabIndex { unTabIndex :: Int }
  deriving (Eq, Ord, Show)

mkTabIndex :: Int -> Maybe TabIndex   -- bounds-checks; constructor not exported

data TabKind = KindAi | KindHarness | KindShell | KindSsh | KindTmux
  deriving (Eq, Show, Bounded, Enum)
-- KindShell/KindSsh/KindTmux are sub-variants of "KindBackend" in conceptual narrative;
-- as constructors they're distinct so the parser can dispatch to the right factory.

data TabStatus
  = Active                       -- provider call or tool execution in flight
  | Idle !UTCTime                -- last input timestamp
  | Crashed !PublicTabError      -- redacted error label
  deriving (Eq, Show)

data TabHandle = TabHandle
  { _tabHandle_index   :: !TabIndex
  , _tabHandle_name    :: !Text          -- pre-redacted friendly label
  , _tabHandle_kind    :: !TabKind       -- pure field
  , _tabHandle_session :: !SessionHandle -- per-tab transcript
  , _tabHandle_status         :: IO TabStatus
  , _tabHandle_send           :: Text -> IO ()
                                       -- enqueue UserText InputEvent; never blocks dispatcher
  , _tabHandle_enqueueSlash   :: SlashCommand -> IO (Either TabError ())
                                       -- enqueue SlashCmd InputEvent (H13); for KindAi only
  , _tabHandle_close          :: IO ()  -- idempotent, never-throws, kind-specific
  }

data InputEvent
  = UserText !Text
  | SlashCmd !SlashCommand
  deriving (Eq, Show)

data TabError
  = TabIndexInUse !TabIndex
  | TabIndexOutOfRange !Int
  | TabLimitExceeded !Int
  | TabBackendConstructFailed !BackendError
  | TabSessionCreateFailed !SessionError
  | TabSpawnAuthDenied !PublicAuthError
  | TabNotFound !Int
  | TabConcurrencyLimit !Int
  | TabInvalidName !NameError       -- NameError is a redacted ADT, never raw input
  | TabUnsupportedCommand !SlashCommand
                                    -- e.g. _tabHandle_enqueueSlash on non-AI kind
  deriving (Eq)
  -- NB: no `deriving Show`. Show is implemented manually per H14 so argument
  -- values are elided (constructor names only). The redacted projection for
  -- channel-bound errors is `toPublicTabError`.

instance Show TabError where
  show e = case e of
    TabIndexInUse{}              -> "TabIndexInUse"
    TabIndexOutOfRange{}         -> "TabIndexOutOfRange"
    TabLimitExceeded{}           -> "TabLimitExceeded"
    TabBackendConstructFailed{}  -> "TabBackendConstructFailed"
    TabSessionCreateFailed{}     -> "TabSessionCreateFailed"
    TabSpawnAuthDenied{}         -> "TabSpawnAuthDenied"
    TabNotFound{}                -> "TabNotFound"
    TabConcurrencyLimit{}        -> "TabConcurrencyLimit"
    TabInvalidName{}             -> "TabInvalidName"
    TabUnsupportedCommand{}      -> "TabUnsupportedCommand"

data NameError
  = NameTooLong | NameContainsControlBytes | NameContainsAnsi | NameRedactedToEmpty
  deriving (Eq, Show)

data PublicTabError = ... -- mirror with channel-safe field set
toPublicTabError :: TabError -> PublicTabError
```

### Per-kind state (hidden inside factories)

* **`KindAi`**: holds a `TBQueue Text` input queue, a forked agent-loop thread, IORefs for provider/model/target/Context (per-tab Context — not shared with dispatcher). The loop reads from the queue, runs one provider+tools turn, writes output to its transcript (always) and to the channel mux (focus-gated).
* **`KindHarness`**: wraps an existing `HarnessHandle`. `_tabHandle_send` writes to harness stdin; an internal drainer thread reads from harness stdout, writes to transcript + channel mux.
* **`KindShell` / `KindSsh` / `KindTmux`**: wraps a `BackendHandle` from `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle`. `_tabHandle_send` writes via `_bh_send`; an internal drainer reads from `_bh_recv` (respecting the BackendHandle concurrency contract: one writer + one reader thread, never concurrent reads or concurrent writes).

### Per-tab state for AI tabs (illustrative; not exported)

```haskell
data AiTabState = AiTabState
  { _ats_inputQ   :: TBQueue InputEvent      -- both user text and slash commands
  , _ats_provider :: IORef SomeProvider
  , _ats_model    :: IORef ModelId
  , _ats_target   :: IORef MessageTarget
  , _ats_context  :: IORef Context           -- per-tab conversation history;
                                             --   ONLY the tab loop writes this.
  , _ats_runner   :: TabRunner               -- holds cancel + wait (see E4)
  }
```

### `AgentEnv` additions

```haskell
data AgentEnv = AgentEnv
  { ... existing fields ...
  , _env_tabs          :: !(IORef (IntMap TabHandle))         -- key = unTabIndex
  , _env_focus         :: !(IORef (Maybe TabIndex))           -- Nothing when empty registry
  , _env_activeCount   :: !(TVar Int)                         -- atomic counter for S9 cap
  , _env_runners       :: !(IORef (IntMap (IORef (Maybe TabRunner))))
                                                              -- per-tab runner placeholders; inner IORef
                                                              -- filled post-fork. cancelAll walks all,
                                                              -- skipping Nothing slots.
  , _env_routingConfig :: !RoutingConfig
  , _env_fork          :: !(IO () -> IO TabRunner)            -- test seam; default = async-based
  , _env_channelOutQ   :: !(TBQueue (OutputSource, ChannelEvent))
                                                              -- bounded; capacity _rc_channelOutQBound
  }

data OutputSource = SrcDispatcher | SrcTab !TabIndex

newtype StreamId = StreamId Word64
  deriving (Eq, Ord, Show)

data ChannelEvent
  = StreamStart !StreamId !TabIndex   -- begin a logical multi-chunk message
  | ChunkOf !StreamId !Text           -- one chunk
  | StreamEnd !StreamId               -- end of logical message
  | FullMsg !TabIndex !Text           -- single-shot non-streaming message
  | BannerLine !Text                  -- dispatcher one-shot line (e.g. breadcrumb)
  deriving (Eq, Show)

data TabRunner = TabRunner
  { _trun_cancel :: IO ()        -- safe to call multiple times (idempotent)
  , _trun_wait   :: IO ()        -- blocks until tab loop exits; in the synchronous
                                 --   test variant, returns () immediately since the
                                 --   body has already run inline.
  }
```

**TabRunner bootstrapping during spawn.** `_tabHandle_close` is established at registration time but must be able to call `_trun_cancel` on a `TabRunner` that doesn't exist until after `_env_fork` returns. To close two race windows (close-during-spawn AND dispatcher-exception-mid-spawn), the placeholder is registered in `_env_runners` BEFORE the fork:

```haskell
spawnTab env kind args = mask $ \restore -> do
  runnerRef <- newIORef Nothing                                    -- placeholder
  modifyIORef' (_env_runners env) (IntMap.insert idx runnerRef)    -- register early
  th <- buildTabHandle env kind args runnerRef                     -- close reads runnerRef
  insertIntoRegistry env th
  -- From this point, dispatcher's cancelAll WILL see the placeholder
  -- (deref Nothing = no-op; deref Just runner = cancel).
  runner <- _env_fork env (restore (tabLoop th))                   -- launch loop
  writeIORef runnerRef (Just runner)                               -- fill placeholder atomically
  pure (Right (_tabHandle_index th))
```

`_env_runners :: IORef (IntMap (IORef (Maybe TabRunner)))` — note the double-IORef: outer for registry mutations, inner for the placeholder. `cancelAll` walks the IntMap, reads each inner IORef, calls `_trun_cancel` on `Just runner` and no-op on `Nothing`. Close-during-spawn (between insert and writeIORef) reads `Nothing` and is a fire-and-forget no-op for v1; the loop launches and runs to natural exit. For v1 this is acceptable per the dispatcher-single-threaded focus invariant (E3) — there is no thread that can issue close concurrently with spawn. v1.5 cross-thread-cancel work (deferred) must revisit this window.

Existing `_env_target`, `_env_session`, `_env_provider`, `_env_model`, `_env_harnesses` remain — they become **focused-tab projections**, updated by the dispatcher on focus change and read by existing slash-command handlers. They are NOT read by tab loops; tab loops use their own internal state. This is transitional architecture; see v1.5 deferred (retire projections).

### `RoutingConfig`

```haskell
data RoutingConfig = RoutingConfig
  { _rc_defaultKind        :: !TabKind            -- pre-shipped as KindAi
  , _rc_defaultAi          :: !AiDefaults
  , _rc_defaultShell       :: !ShellDefaults
  , _rc_switchRecap        :: !Int                -- default 3 recent messages on /N switch
  , _rc_maxTabs            :: !Int                -- default 36 (single-char index alphabet [0-9a-z])
  , _rc_inputQueueBound    :: !Int                -- default 64
  , _rc_channelOutQBound   :: !Int                -- default 1024 (bounded TBQueue)
  , _rc_spawnRateLimit     :: !Int                -- default 10 spawns/minute
  , _rc_maxConcurrentActive:: !Int                -- default 4 (per S9)
  , _rc_maxNameLen         :: !Int                -- default 32 chars (per S10)
  , _rc_sshIdentityKey     :: !Text               -- default "default-ssh-key" (Vault slot)
  }
```

Loaded from `~/.pureclaw/config.toml` under `[routing]`. Runtime-mutable via `/config` slash command is v1.5+.

## Dispatcher and Concurrency Model

### Topology

```
                              ┌──────────────┐
        ChannelHandle ─────▶  │  Dispatcher  │   (one thread, reads channel)
                              └──────┬───────┘
                                     │ parses, routes
                ┌────────────────────┼────────────────────┐
                ▼                    ▼                    ▼
            Tab 0 loop           Tab 1 loop          Tab N loop
            (own thread)         (own thread)        (own thread)
                │                    │                    │
                │ transcript         │ transcript         │ transcript
                ▼                    ▼                    ▼
            _sh_transcript      _sh_transcript      _sh_transcript
                │                    │                    │
                │ channel emit (focus-gated)               │
                └────────────────────┼────────────────────┘
                                     │
                                     ▼
                              ┌──────────────┐
                              │ ChannelOut   │   (one writer thread,
                              │ writer       │    reads _env_channelOutQ,
                              └──────────────┘    drops non-focus SrcTab events)
                                     │
                                     ▼
                              ChannelHandle out
```

### Why per-tab threads (even though only focused displays)

* AI tabs can run a long provider call without blocking other tabs' *input processing* (background work).
* Direct-inject `/0 long task` while focused on `/1` is meaningful: `/0` processes the task in the background, response lands in `/0`'s transcript, user sees it on `/0` switch.
* Harness/backend tabs are already independent processes; per-tab drainers run concurrently anyway.

### Channel emission via `ChannelOut` writer

* `_env_channelOutQ :: TBQueue (OutputSource, ChannelEvent)` — a single bounded STM queue (capacity `_rc_channelOutQBound = 1024`).
* `ChannelEvent` is the ADT defined above: `StreamStart | ChunkOf | StreamEnd | FullMsg | BannerLine`.
* A dedicated writer thread consumes from the queue and calls `_ch_send`/`_ch_sendChunk` against the underlying `ChannelHandle`.
* For `SrcTab n` events: writer reads `_env_focus` and drops the event if `Just n /= focus`. On the first drop per `StreamId`, the writer emits one `SrcDispatcher BannerLine "/N has new output — /N to view"` (per D5) and records the drop state in `Map StreamId BreadcrumbState`. Subsequent drops with the same StreamId are silent. StreamEnd cleans up the map entry.
* For `SrcDispatcher` events: always emit.
* Producer-side optimisation (D4): tab loops do a cheap `_env_focus` check before enqueueing `SrcTab` events; non-focused loops silently drop the event (no enqueue, transcript still records).

Trade-off: a user who switches to `/1` mid-stream from `/0` sees an abrupt cut in the channel, plus one breadcrumb. The recap on `/0` switch-back shows the full message from transcript. We judge this acceptable for v1 — alternative behaviors (continue streaming, pause, switch-and-resume) all add complexity for a corner case.

### Async exception discipline

* Each tab is spawned under `mask`: `mask_ $ do { ref <- ...; addToRegistry; eventually <- _env_fork tabLoop; ... }`. Half-registered tabs are rolled back on async exception.
* Each tab loop runs inside `bracket` so per-kind resources release on cancel (`_bh_close`, `_hh_stop`, `_sh_save`).
* Dispatcher uses `bracket (newIORef IntMap.empty) cancelAll dispatcherBody` (per C4). `_env_runners :: IORef (IntMap (IORef (Maybe TabRunner)))` holds a placeholder per spawned tab; spawnTab registers the placeholder under `mask` BEFORE calling `_env_fork`, then fills it post-fork. On dispatcher exit (exception OR graceful end-of-stream from `_ch_receive`), `cancelAll` iterates the IntMap and calls `_trun_cancel` on every `Just runner` (no-op for `Nothing` placeholders). This pattern composes for a dynamic set of tabs; `withAsync`'s lexical-scope shape does not.

### Focus invariant

`_env_focus` is mutated **only** by the dispatcher, **only** at message boundaries. Slash-command handlers run synchronously in the dispatcher thread. This means slash-command handlers that read/write focused-tab projections do so against a stable focus snapshot — no TOCTOU. The dispatcher does NOT process the next incoming message until the previous handler returns.

## Auto-spawn behavior

`_rc_defaultKind = KindAi` is the shipped default. Under the v1.5 tmux packing model there is exactly one implicit-spawn path; everything else is explicit.

* **First-time user types plain text (no slash)** → K3 first-run path: registry is empty, dispatcher sees a `Default` input, implicitly spawns `_rc_defaultKind` at the lowest free slot (`/0`), focuses, and enqueues the text. One-line confirmation: `/0: ai (claude-opus-4-7) ready.` This is the only auto-spawn path that survives v1.5.
* **First-time user types `/tab new`** → force-prompt: `Spawn /0 as: [1] AI [2] shell [3] tmux [4] ssh`. User taps 1-4. The slot number in the prompt reflects `Registry.lowestFreeIndex`.
* **User wants a shell as a first tab**: types `/tab new shell`. Single command, no prompt. Lands at `/0` (lowest free slot).
* **User types `/0` on an empty registry** → ERROR banner `"/0: no such tab — use /tab new to create one"` — `/N` no longer auto-spawns under tmux packing. Users who don't know about `/tab new` will discover it via the banner; users who type plain text first hit the K3 path and never need to know about it.
* **User wants to change the default**: edit `~/.pureclaw/config.toml` directly, or `/config routing.default_kind=shell` once that command lands (v1.5).

The "set as default" inline affordance from the round-1 design is dropped — users who want a non-AI default set it once in config.

## Channel Feature Matrix

| Feature                       | Telegram | Signal | CLI            |
|-------------------------------|----------|--------|----------------|
| Numeric switch `/N`           | ✓        | ✓      | ✓              |
| Direct-inject `/N <p>`        | ✓        | ✓      | ✓              |
| On-demand dashboard `/tabs`   | ✓        | ✓      | ✓              |
| Per-tab transcript            | ✓        | ✓      | ✓              |
| Focused-only channel display  | ✓        | ✓      | ✓              |
| BotFather command registration | ✓ (`/0`–`/9`, `/tab`, `/tabs`) | n/a | n/a |
| Inline-keyboard spawn prompt  | ✓        | text   | text           |
| Pinned dashboard              | n/a v1   | n/a v1 | n/a            |
| Reply-to-route                | dropped (see Non-Goals) | dropped | dropped |

## Slash command surface (additions)

| Command                          | Behavior                                                                  |
|----------------------------------|---------------------------------------------------------------------------|
| `/N` (one char: digit `0-9` or letter `a-z`) | switch focus to tab N; **errors if missing** — `/N` no longer auto-spawns (use `/tab new`) |
| `/N <payload>`                   | direct-inject payload to tab N (no focus change); errors if N missing      |
| `/tabs`                          | alias for `/tab list`                                                     |
| `/tab list`                      | dashboard: list all tabs with status                                       |
| `/tab new [kind] [args]`         | spawn at the lowest free slot (tmux packing); no kind → force-prompt; with kind → explicit |
| `/tab close N [--force]`         | close (kind-specific semantics; --force on AI skips archive)               |
| `/tab focus N`                   | alias for `/N` (BotFather-autocomplete-discoverable)                       |
| `/tab resume <session-id>`       | re-open an archived AI tab from disk                                       |
| `/tab rename N <new-name>`       | rename a tab's friendly label                                              |

Existing `/session`, `/target`, `/provider`, `/model`, `/vault`, `/transcript`, `/agent`, `/new`, `/last`, `/help`, `/status`, `/harness`, `/mcp`, `/channel` operate on the **focused tab** when relevant; errors gracefully when the focused tab kind doesn't support them (K5).

## Examples

### Mobile flow: spawn AI, switch to shell, dashboard

```
User: /0
Bot:  /0: ai (claude-opus-4-7) ready.
User: explain RFC 7807
Bot:  RFC 7807 is "Problem Details for HTTP APIs"...

User: /tab new shell                         ← lands at /1 (next free slot)
Bot:  /1: shell ready.
User: /1
Bot:  (focused /1; no recap, just-created)
User: ls /var/log
Bot:  total 384
      drwxr-xr-x  ...

User: /tabs
Bot:  * /1  shell        idle  3s
        /0  ai           idle  12s
```

### Background work via direct-inject

```
User: /0 summarise the last 50 PRs
Bot:  (nothing — focused tab is /1; /0's response goes to /0's transcript silently)
User: ls
Bot:  (focused /1 still; /1's response)
        Documents Downloads ...
User: /0
Bot:  (recap of last 3 messages from /0's transcript:)
      /0: PRs cluster into three themes...
      /0: [continued]...
```

### Shell-first workflow (UC-2 SRE persona)

User whose primary use case is shell access, not AI:

```
User: /tab new shell                         ← lands at /0 (empty registry)
Bot:  /0: shell ready.
User: uptime
Bot:  10:32:01 up 14 days, ...

User: /tab new ssh user@staging              ← lands at /1
Bot:  /1: ssh tab ready.
User: /1
Bot:  (focused /1; just-created, no recap)
User: tail /var/log/app.log
Bot:  ...

User: /tab new ai                            ← lands at /2
Bot:  /2: ai (claude-opus-4-7) ready.
User: /2 why is staging emitting 503s for /api/v1/users?
Bot:  (response goes to /2's transcript; channel doesn't see it yet — focused on /1)
User: /2
Bot:  (recap of last 3 messages from /2's transcript:)
      /2: based on the log fragment, ...
```

### Mid-stream switch breadcrumb

```
User: /0 write a 500-word essay on memoization
Bot:  /0: Memoization is a technique...
      (streaming continues...)
User: /1
Bot:  /0 has new output — /0 to view
      (switched to /1)
User: /0
Bot:  (recap of last 3 messages from /0's transcript:)
      /0: ⟨full essay⟩
```

### Crashed tab

```
User: /tab new ssh user@prod-db.internal     ← would have landed at /2
Bot:  /2 crashed: ssh connect failed (host key mismatch).
      [1] retry [2] close
User: 2
Bot:  /2 closed.
```

(Note: the error message is redacted — the literal host name does not appear in the chat. The transcript stored on disk does record it; PublicTabError is the channel-bound view.)

## LLM-free invariant

`parseInput` runs in the slash-command preprocessor before any provider call. The dispatcher classifies input as `Switch | Inject | Default | SlashCmd`. Only `Default` text reaches a provider. P18 (a property test) covers this exhaustively.

Tool outputs from AI tabs are fed back to the agent loop as tool results (a structured `ToolResult`), not through the dispatcher's parser. If a future tool type allows the LLM to post freeform text to the channel (e.g. a hypothetical `send_message` tool), that tool's output bypasses the parser by construction: it goes directly to `_env_channelOutQ` with `SrcDispatcher` (or `SrcTab n`) and is never re-read as an incoming message. The dispatcher reads from `_ch_receive` only.

## Test seams introduced by this work

* `Test.Fake.Provider` — TVar-recorded provider; TMVar-blocking variants. (T1)
* `Test.Fake.ChannelHandle` — TVar-recorded channel; injected input queue. (T2)
* `Test.Fake.TabFactory` — pure factories for testing dispatcher/registry without real resources. (T3)
* Synchronous `_env_fork` substitution. (T4)
* `FakeClock` (already in test infra, from #49's WU3) used for status timestamps in `Idle UTCTime`.

These mirror the discipline of terminal-backend-abstractions's "PTY Test Seam" and "In-Memory Test Backend" sections — every new behavior has a pure or deterministic test seam.

## Module Layout

```
src/PureClaw/
  Handles/
    Tab.hs                  -- TabHandle, TabIndex, TabKind, TabStatus, TabError
                            --   (types only; no factories, no impl)
  Routing/
    Types.hs                -- ParsedInput, SlashCommand additions, RoutingConfig
                            --   (depended on by both Agent.* and Tab.*)
    Parse.hs                -- parseInput, mkTabIndex, mkSessionId, parser invariants
    Registry.hs             -- pure tab CRUD over IORef IntMap (lookup/insert/delete)
                            --   NO factory dispatch; just registry mutations
    ChannelOut.hs           -- writer thread + TBQueue + focus-gated emit
    AutoSpawn.hs            -- /N + missing-tab UX, prompt rendering
    Config.hs               -- RoutingConfig load
    Dispatcher.hs           -- runDispatcher :: AgentEnv -> IO ()
                            --   exports spawnTab :: AgentEnv -> TabKind -> [Text]
                            --                    -> IO (Either TabError TabIndex)
                            --   spawnTab dispatches to Tab.{Ai,Harness,Backend} factories
  Tab/
    Ai.hs                   -- mkTabAi :: ... -> IO (Either TabError TabHandle)
                            --   contains the AI loop body (formerly runAgentLoop's go)
    Harness.hs              -- mkTabHarness
    Backend.hs              -- mkTabBackend (wraps BackendHandle)
  Agent/
    Env.hs                  -- (modified) _env_tabs, _env_focus, _env_routingConfig,
                            --   _env_fork, _env_channelOutQ
    SlashCommands.hs        -- (modified) CmdTabNew, CmdTabList, CmdTabClose, CmdTabFocus,
                            --   CmdTabResume, CmdTabRename. Imports Routing.Dispatcher
                            --   for spawnTab indirection (NOT Tab.* factories directly).
    Loop.hs                 -- (modified) main loop becomes runDispatcher wrapper

test/
  Test/Fake/Provider.hs
  Test/Fake/ChannelHandle.hs
  Test/Fake/TabFactory.hs
```

**Import DAG (no cycles):**

```
Handles.Tab                   (leaf types: TabHandle, TabError, TabRunner, TabIndex, TabKind, TabStatus)
  ↑
Routing.Types                 (parser ADTs, ChannelEvent, OutputSource, StreamId, RoutingConfig — leaf)
  ↑
Agent.Env                     (AgentEnv record; depends on Handles.Tab + Routing.Types because
                               _env_tabs holds TabHandles and _env_channelOutQ carries ChannelEvent)
  ↑
Routing.{Parse, Registry, ChannelOut, AutoSpawn, Config}
                              (independent siblings; depend on Agent.Env + leaves)
  ↑
Tab.{Ai, Harness, Backend}    (factories; depend on Agent.Env + Routing.{Registry, Types})
  ↑
Routing.Dispatcher            (depends on Routing.{Registry, AutoSpawn, ChannelOut} AND
                               Tab.{Ai, Harness, Backend} — orchestrates spawn dispatch via
                               exported spawnTab. This is the ONLY place that imports Tab.*)
  ↑
Agent.SlashCommands           (existing + new tab commands; imports Routing.Dispatcher
                               for the spawnTab/closeTab indirection; does NOT import Tab.*)
  ↑
Agent.Loop                    (top-level: starts dispatcher)
```

**The key inversion**: `spawnTab` lives in `Routing.Dispatcher`, not `Routing.Registry`. Registry stays pure (tab CRUD over `IORef IntMap`). Dispatcher is the only module that imports both Registry and `Tab.*`, so it's the only place where the factory dispatch can happen. `Agent.SlashCommands` imports `Routing.Dispatcher.spawnTab` and gets the indirection without ever importing `Tab.*`. This kills the cycle Architect/CTO flagged in rounds 1 and 2.

## v1.5 Deferred Work

| Feature                                  | Why deferred                                                                  |
|------------------------------------------|-------------------------------------------------------------------------------|
| `/config` runtime mutation               | Needs config-mutation plumbing; v1 keeps static toml + restart.               |
| Pinned dashboard (channels that support it) | Needs `ChannelCapability` abstraction; out-of-scope for v1 since focused-only display is already shipping. |
| `/tab rename` via inline button on Telegram | Need inline-keyboard wiring beyond spawn prompt.                              |
| Inline spawn options (`--model`, `--system`) | Parser complexity; deferred until v1 UX validated.                            |
| Cross-tab broadcast (`/* msg`)           | Power-user feature; not in v1 use cases.                                       |
| **Retire focused-tab projections**       | Rewrite each existing slash command to take an explicit `TabIndex` (or pull from focused tab via API). Remove `_env_target`, `_env_session`, `_env_provider`, `_env_model` mirrors. Transitional debt acknowledged. |
| TUI (multi-pane local) view              | Local terminal-tab visibility could surface all tabs simultaneously without the focused-only channel constraint. v2-level work. |
| Tab persistence across pureclaw restarts | v1 tabs are in-memory only; archived AI sessions survive via `/tab resume <id>` from disk. Harness/Backend tabs are not respawnable on restart. |

## Pre-flight blockers (verify before WU0)

- [ ] Verify `containers` (IntMap), `stm` (TBQueue, TQueue, TMVar), and `async` are in `pureclaw.cabal` build-depends. (Spot-check: `async` is already a dep used by existing code.)
- [ ] Verify `Session.resolveSessionRef` is exported and stable (L7 reuses it).
- [ ] Verify the `Provider` typeclass (or equivalent abstraction in `src/PureClaw/Providers/`) is stable enough for `Test.Fake.Provider` (T1) to live behind it.
- [ ] Confirm whether `_sh_save` is sufficient for AI-tab close, or whether a new `_sh_archive` action is needed (the design currently uses `_sh_save` + `_tabHandle_close` of the transcript; L1 may need a small Session module addition).
- [ ] Confirm whether the current `SlashCommand` ADT can absorb the new `CmdTab*` constructors without breaking exhaustiveness in unrelated handler code (`-Wincomplete-patterns -Werror` cascade risk).

## Open Questions (remaining after round 2 revisions)

These are NON-blocking and can be revisited during implementation, with sensible v1 defaults stated:

1. **Recap on self-switch.** `/N` when N is the focused tab. v1 default: emit recap anyway (consistent with non-self switch). Open: should it be a no-op? Decided in WU09 (auto-spawn) if it becomes friction.
2. **Idle-timeout for Active → Idle transition.** When does the status flip from Active to Idle if there's no explicit signal? v1 default: when the loop returns from a provider/tool call, set status to `Idle <now>`. Open: a watchdog-driven transition might be cleaner if loops can hang.
3. **Channel-bound name for ssh tabs.** `_tabHandle_name` is redacted (H11) — what's a good default label? v1 default: `"ssh tab #N"`. Open: maybe encode `kind` only in dashboard rendering, not in name.
4. **Recap window size.** `_rc_switchRecap = 3`. Open: should be channel-dependent (Telegram can do more lines than Signal)? Not in v1.
5. **Recap output bound vs Telegram 4096-char limit.** Either D-series adds a "recap output ≤ channel max-message-size" DoD, or we trust `_ch_send` chunking. v1 default: trust `_ch_send` chunking; revisit if test reveals truncation issues.
6. **Retry preservation of spawn args.** X2/X3 say retry uses "the original args." Implies the registry retains the spawn args at first creation. v1 default: registry holds the args; retry replays them. Open: does the user expect retry to pick up changed defaults (e.g. `/provider` was changed between spawn and crash)? Probably not — original args is the safer behavior.
7. **CLI channel scope for v1.** The Feature Matrix lists CLI as supporting `/N`, `/tabs`. The CLI channel is structurally single-stream (one terminal). v1 default: CLI supports tabs but uses serialized per-tab forked loops; concurrent processing works; the user just sees output one tab at a time anyway by virtue of having one terminal. Decided not blocking.

## Terminology

* **Tab** — a routing slot; user-facing primitive.
* **TabIndex** — the integer the user references via a single index character `[0-9a-z]` after `/`. At the parse layer the index is one char (digits `'0'-'9'` → 0..9, lowercase letters `'a'-'z'` → 10..35); internally it is represented as an `Int` in the range `0..35`, bounded by `_rc_maxTabs` (default 36).
* **TabHandle** — Handle-pattern record of IO actions for one tab. The `_tabHandle_index` field reflects the creation slot and is advisory after a `/tab close` renumber; the authoritative current slot is the registry key.
* **TabKind** — `KindAi | KindHarness | KindShell | KindSsh | KindTmux`.
* **TabStatus** — runtime state: `Active | Idle | Crashed`.
* **Focus** — the tab whose output reaches the channel.
* **Direct-inject** — sending payload to a non-focused tab via `/N <payload>`.
* **Auto-spawn** — under v1.5 the term refers exclusively to the K3 first-run path: empty registry + plain `Default` text → implicit spawn of `_rc_defaultKind` at `/0`. `/N` for a missing index no longer auto-spawns.
* **Force-prompt** — `/tab new` with no kind argument; ignores `_rc_defaultKind` and renders a kind-picker UI at the lowest free slot.
* **Tmux packing** — tabs are always packed at the lowest free index. `/tab new` allocates at `Registry.lowestFreeIndex`; `/tab close N` shifts every tab `> N` down by one. Matches tmux `renumber-windows on`.
* **Dispatcher** — the single thread reading from the channel, classifying, and routing.
* **ChannelOut writer** — the single thread serializing channel writes; gated on focus for `SrcTab` events.
* **Focused-only display** — invariant: non-focused tab output reaches each tab's transcript but never the channel during v1.
* **Focused-tab projections** — `_env_target`/`_env_session`/etc. mirrors of the focused tab's state; transitional v1 architecture, retired in v1.5.

## Relationship to terminal-backends (#49)

Tabbed Chat is the first agent-loop-level consumer of the terminal backends shipped on this branch. Specifically:

* `KindShell`, `KindSsh`, `KindTmux` factories (`mkTabBackend` family) wrap `BackendHandle` returned by `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle`. Tabbed Chat exercises the backend lifecycle (`_bh_send`, `_bh_recv`, `_bh_close`) in a real concurrent workload with `AuthorizedCommand` / `RemoteCommand` flowing through actual policy gates (S1, S2).
* The drainer pattern from `PureClaw.Backend.Pty` (WU7) is reused at the tab level for `_tabHandle_send`/recv pumping.
* The `AutonomyLevel`-aware close semantics (`TmuxCloseAction`, WU10) carry through unchanged.

**This is the rationale for landing Tabbed Chat on the same branch as #49** — it stress-tests the backend abstraction with a non-trivial concurrent consumer before that work leaves the branch. (Note: this is a *delivery* rationale, not a user-facing use case, hence its placement here rather than in UCs.)
