# Tabbed Chat — Mobile-Friendly Multiplexing

**Issue:** [#51](https://github.com/pureclaw/pureclaw/issues/51)
**Status:** design — revised after design-review round 1
**Branch:** `feat/terminal-backends-design`
**Authors:** Doug Beardsley, Claude
**Builds on:** [Terminal / Backend Abstractions](terminal-backend-abstractions.md) — Tabbed Chat's `KindBackend` tabs wrap `BackendHandle` factories landing on this branch.

**Revision note (this doc, round 1 → 2):** Resolves three architectural questions raised by the design review gate. The biggest is *focused-only channel display*: non-focused tabs never write to chat in v1. This eliminates the output-mux head-of-line block, the cross-tab DoS surface, and the cross-tab visibility plumbing that reply-to-route depended on. Reply-to-route is dropped entirely. `_t_*` Handle prefix migrates to `_th_*` for convention parity. DoDs are renumbered, split where coarse, and rephrased behaviorally. Test seams and security checks are now explicit.

## Naming Note

The user-facing primitive is a **tab**. A tab is a sub-stream within the user's single chat thread — analogous to a browser tab or a tmux window. Each tab has an integer index (mobile-friendly: `/0`, `/1`, ...), an optional friendly name, a kind (AI agent, shell harness, terminal backend), and its own transcript. The internal type is `TabHandle`. We rejected `Route`, `Slot`, `Pane`, and `Window` in favor of `Tab` because the browser-tab mental model is universal.

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
switch           ::= '/' DIGITS                              -- e.g. /0, /12
inject           ::= '/' DIGITS WS payload                   -- e.g. /0 run tests
default          ::= payload                                 -- to current focus
slash-cmd        ::= '/' WORD ...                            -- existing commands
                 |   '/tab' WS action [WS args]              -- new: tab family
                 |   '/tabs'                                 -- alias for `/tab list`
action           ::= 'new' | 'list' | 'close' | 'focus' | 'resume' | 'rename'
DIGITS           ::= [1-9][0-9]* | '0'                       -- no leading zeros except "0" itself
WS               ::= one or more spaces/tabs
payload          ::= rest of line, free text
```

### Parser invariants

* `/12` parses as tab 12 (greedy digits, no leading zeros except `0`).
* `/01` is a **parse error** (`ParseErrorLeadingZero`) — disambiguates intent.
* `/0 0 run` parses as `Inject 0 "0 run"` (payload digits preserved).
* `/word` (non-numeric after `/`) routes to existing slash-command dispatch unchanged.
* `/0@botname` (Telegram group-chat bot mention): the `@botname` suffix is stripped by the channel's incoming preprocessor before parser sees the message. Parser invariant: never receives `@` characters.
* `TabIndex` is bounded at parse time: `0 <= n < _rc_maxTabs` (default 10). Out-of-range produces `ParseErrorIndexOutOfRange`.
* Trailing-whitespace-only payload (`/0 ` with only space after) → `Switch 0` (treat as bare switch).
* Multi-line payload (`/0\nfoo`) → `Switch 0` followed by `Default "foo"` as a separate incoming message; the channel layer is responsible for splitting at newlines if applicable, otherwise parser sees one input with embedded `\n` and treats the body after `/0` (incl. `\n`) as payload, i.e. `Inject 0 "\nfoo"`.

### Channel autocomplete (Telegram-specific)

Telegram's BotFather command list only autocompletes registered word-prefixed commands. To deliver real autocomplete on mobile, the channel-startup code registers these commands:

* `/0`, `/1`, `/2`, `/3`, `/4`, `/5`, `/6`, `/7`, `/8`, `/9` — "Switch to tab N (auto-spawns if missing)"
* `/tab` — "Tab family: new/list/close/focus/resume/rename"
* `/tabs` — "List all tabs"

For `N >= 10`, mobile autocomplete is not available; users must type the full index. This is acceptable because `_rc_maxTabs = 10` by default — power users opting into more set the cap explicitly.

## Acceptance Criteria (v1)

**Test labels match these numbers exactly.** WU0 (red-phase scaffold) commits one failing test per DoD; the count below is the WU0 enumerated total.

### Parser & LLM-free invariant (P-series)

| #   | DoD                                                                                                         |
|-----|-------------------------------------------------------------------------------------------------------------|
| P1  | `parseInput "/0"` → `Switch (TabIndex 0)`.                                                                  |
| P2  | `parseInput "/12"` → `Switch (TabIndex 12)`.                                                                 |
| P3  | `parseInput "/0 run tests"` → `Inject (TabIndex 0) "run tests"`.                                            |
| P4  | `parseInput "/0 0 run"` → `Inject (TabIndex 0) "0 run"` (preserves payload digits).                         |
| P5  | `parseInput "hello world"` → `Default "hello world"`.                                                       |
| P6  | `parseInput "/01"` → `Left ParseErrorLeadingZero`.                                                          |
| P7  | `parseInput "/9999"` when `_rc_maxTabs == 10` → `Left ParseErrorIndexOutOfRange`.                           |
| P8  | `parseInput "/tabs"` → `SlashCmd CmdTabList`.                                                               |
| P9  | `parseInput "/tab list"` → `SlashCmd CmdTabList` (alias of /tabs).                                          |
| P10 | `parseInput "/tab new 3"` → `SlashCmd (CmdTabNew (TabIndex 3) Nothing Nothing)` (kind+args slot empty).      |
| P11 | `parseInput "/tab new 3 shell"` → `SlashCmd (CmdTabNew (TabIndex 3) (Just KindShell) Nothing)`.             |
| P12 | `parseInput "/tab close 3"` → `SlashCmd (CmdTabClose (TabIndex 3) ForceNo)`.                                |
| P13 | `parseInput "/tab close 3 --force"` → `SlashCmd (CmdTabClose (TabIndex 3) ForceYes)`.                       |
| P14 | `parseInput "/tab focus 3"` → `SlashCmd (CmdTabFocus (TabIndex 3))` (alias of `/3`).                        |
| P15 | `parseInput "/tab resume <session-id>"` → `SlashCmd (CmdTabResume <id>)`.                                   |
| P16 | `parseInput "/tab rename 3 my-shell"` → `SlashCmd (CmdTabRename (TabIndex 3) "my-shell")`.                 |
| P17 | **No-regression — existing slash commands route unchanged**: for each of `/help`, `/status`, `/session`, `/target`, `/provider`, `/model`, `/vault`, `/harness`, `/mcp`, `/channel`, `/transcript`, `/agent`, `/new`, `/last`, `parseInput` returns the existing `SlashCommand` constructor (the parser does not steal them). One assertion per command (~14 sub-cases). |
| P18 | **LLM-free invariant (property test)**: for every input matching the routing grammar `switch | inject | slash-cmd`, the recorded `Provider.complete` invocations is empty. A fake `Provider` recording every `CompletionRequest` is required test seam (see T1). Only `Default <text>` inputs reach the provider. |

### TabHandle abstraction (H-series)

| #   | DoD                                                                                                          |
|-----|--------------------------------------------------------------------------------------------------------------|
| H1  | `TabHandle` is a record of IO actions with `_th_*` field prefix matching the universal Handle convention.    |
| H2  | Factories `mkTabAi`, `mkTabHarness`, `mkTabBackend` exist; each returns `IO (Either TabError TabHandle)`.    |
| H3  | `TabError` is an ADT with constructors enumerated below; no free-`Text` constructors; `Show TabError` is redacted. Constructors: `TabIndexInUse !TabIndex`, `TabIndexOutOfRange !Int`, `TabLimitExceeded !Int`, `TabBackendConstructFailed !BackendError`, `TabSessionCreateFailed !SessionError`, `TabSpawnAuthDenied !PublicAuthError`. `PublicTabError` mirror + `toPublicTabError` projection for channel-bound errors. |
| H4  | `_th_send :: Text -> IO ()` enqueues to the tab's input queue and never blocks the dispatcher (`TBQueue` with bounded backpressure capacity `_rc_inputQueueBound`, default 64). On overflow, returns to dispatcher which emits `tab input queue full` PublicError. |
| H5  | `_th_status :: IO TabStatus` returns `Active`, `Idle UTCTime`, or `Crashed PublicTabError`. (Two runtime states + exception state. `Active` covers provider call AND tool execution; the dashboard does not distinguish.) |
| H6  | `_th_close` is **idempotent**.                                                                               |
| H7  | `_th_close` **never throws**. (Parallel to `_bh_close` contract in `BackendHandle`.)                         |
| H8  | `_th_close` semantics are kind-specific: for `KindAi`, archives the session (calls `_sh_save`) and removes from registry. For `KindHarness` and `KindBackend`, destroys (calls `_hh_stop` or `_bh_close` respectively). |
| H9  | `_th_close --force` on `KindAi` skips archive (deletes transcript). On other kinds it is a no-op (close is already destructive). |
| H10 | `_th_close` cancels any in-flight provider call or backend recv via `throwTo … AsyncCancelled`; cleanup runs in a `bracket` wrapper so per-kind resources (BackendHandle, HarnessHandle, SessionHandle) are released even on exception. |
| H11 | `_th_name` redacts hostnames, filesystem paths, and ssh-stderr fragments. (Test: a tab spawned against `ssh prod-db.internal` exposes `_th_name = "ssh tab"` or a safe label, NOT the host.) Same bar as terminal-backend-abstractions's `Information Disclosure / Redaction`. |
| H12 | `_th_kind` is a pure field (parallel to `_bh_kind`); no IO read.                                             |

### Registry & AgentEnv (E-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| E1  | `AgentEnv` gains `_env_tabs :: IORef (IntMap TabHandle)` (key = `unTabIndex`), `_env_focus :: IORef (Maybe TabIndex)`, `_env_routingConfig :: RoutingConfig`. |
| E2  | Existing `_env_target`, `_env_session`, `_env_provider`, `_env_model` remain in `AgentEnv` as **focused-tab projections**. Reads of these fields are valid only inside the dispatcher's message-processing window. The dispatcher updates them when focus changes; tab loops do NOT read these fields (they hold their own per-tab state). |
| E3  | **Focus invariant** (key safety property): `_env_focus` is written **only** by the dispatcher, **only** between message cycles. Slash-command handlers that mutate focused-tab projection fields (`_env_target`, etc.) execute synchronously in the dispatcher thread and complete before the next message is read. This eliminates TOCTOU between handler reads/writes. **Test**: a property-based test fakes a tab-state-mutating command, runs it under simulated concurrent input, asserts no observable race. |
| E4  | `_env_fork :: IO () -> IO ThreadId` is part of AgentEnv (test seam; defaults to `forkIO`). All tab-spawning code paths use `_env_fork`, never bare `forkIO`. Test infrastructure substitutes a synchronous variant for deterministic tests. |

### Concurrency & exception safety (C-series)

| #   | DoD                                                                                                                 |
|-----|---------------------------------------------------------------------------------------------------------------------|
| C1  | **Tabs run in their own threads.** Behavioral test (using a fake `Provider` that blocks on a `TMVar`): two AI tabs `/0` and `/1`; `/0` is given a slow request, immediately followed by `/1 ping`; `/1`'s response is observed in `/1`'s transcript *before* `/0`'s response completes. |
| C2  | **AI tab state isolation.** Two AI tabs each hold distinct `IORef (Maybe ModelId)`. `/0 /target sonnet` (per-tab) does not change `/1`'s model. |
| C3  | **Tab spawn is exception-safe.** Spawning uses `mask` so a partial registration cannot leak a half-initialised tab in `_env_tabs` on async exception. Test: a spawn whose factory throws mid-construction leaves `_env_tabs` unchanged AND any partially-allocated resource (e.g. a started BackendHandle) is closed. |
| C4  | **Dispatcher death cancels all tabs.** Dispatcher uses `withAsync` (or equivalent `bracket`+`uninterruptibleCancel`) for each tab so dispatcher termination triggers `_th_close` on every live tab. Test: simulate dispatcher exception; assert all forked tab threads receive `AsyncCancelled` and `_th_close` runs. |
| C5  | **Crash isolation.** A tab loop catches all exceptions, sets `_th_status` to `Crashed`, attempts a single channel emit of the PublicError (gated on focus), and exits its thread. The dispatcher does not crash when a tab does; the registry entry persists with `Crashed` status until `/tab close N` or `/tab resume <session>`. Test: a tab whose factory throws after registration leaves dispatcher alive and registry consistent. |

### Channel emission & focused-only display (D-series)

| #   | DoD                                                                                                                      |
|-----|--------------------------------------------------------------------------------------------------------------------------|
| D1  | **Only the focused tab writes to channel** (chat). Behavioral test: `/0` and `/1` both producing output; `_env_focus = Just 0`; the channel (a fake `ChannelHandle` recording every `_ch_send` / `_ch_sendChunk`) sees only `/0`'s output. |
| D2  | **Non-focused tab output still lands in its transcript.** Same test as D1: `/1`'s transcript (`_sh_transcript` on the tab's `SessionHandle`) contains its complete response even though the channel saw none of it. |
| D3  | **Channel writes are serialized.** Single output-writer thread consumes from a `TQueue (Source, ChannelEvent)` where `Source = SrcDispatcher | SrcTab TabIndex`. The writer drops `SrcTab N` events when `readIORef _env_focus /= Just N`. `SrcDispatcher` events (switch confirms, dashboard, command errors) always emit. Test: concurrent emits from 3 tabs + dispatcher produce no garbled output; only `SrcDispatcher` + the focused-tab's events reach the channel. |
| D4  | **Focus snapshot per emit.** Each tab loop's emit checks `_env_focus` at chunk granularity. If focus changes mid-stream, the rest of the stream is silently elided from the channel (transcript still records). Test: simulate focus change after first chunk; assert second chunk doesn't reach channel but does reach transcript. |
| D5  | **No proactive non-focus notifications.** When a non-focused tab finishes work, crashes, or changes status, no channel message is emitted. The user must `/tabs` or `/M` to observe. Test: `/0` (non-focused) crashes; channel sees zero new messages. |

### Auto-spawn behavior (A-series)

`_rc_defaultKind` ships pre-set to `KindAi` (with provider/model defaults from `_rc_defaultAi`) so the common case is one keystroke.

| #   | Scenario                                              | DoD                                                                                                  |
|-----|-------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| A1  | `/3`, N exists                                        | switch focus, emit recap of last `_rc_switchRecap` messages from N's transcript                       |
| A2  | `/3 payload`, N exists                                | enqueue `payload` to N's input, focus unchanged, channel sees no immediate output                    |
| A3  | `/3`, N missing, default set                          | spawn with default kind, focus, emit one-line confirmation                                            |
| A4  | `/3`, N missing, default unset                        | dispatcher returns `NeedsKindPrompt 3 Nothing`; dispatcher renders prompt UI via channel-specific renderer |
| A5  | `/3 payload`, N missing, default set                  | spawn with default, focus, enqueue payload, single-message confirmation                              |
| A6  | `/3 payload`, N missing, default unset                | dispatcher returns `NeedsKindPrompt 3 (Just "payload")`; payload is buffered, enqueued after user picks kind |
| A7  | `/tab new 3` (no kind), N missing                     | **force-prompt** — ignores `_rc_defaultKind`; renders prompt UI                                        |
| A8  | `/tab new 3` (no kind), N exists                      | error: `/3 already exists. Use /tab close 3 to replace.`                                              |
| A9  | `/tab new 3 shell`, N missing                         | spawn with KindShell, focus                                                                          |
| A10 | `/tab new 3 shell`, N exists                          | error as A8                                                                                          |
| A11 | `/tab new 11` when `_rc_maxTabs = 10`                 | `Left TabLimitExceeded 10` as `PublicError`; no process spawned                                       |
| A12 | After `/tab close 3`, index 3 is **immediately reusable**. Next `/tab new <kind>` (no explicit index) allocates the lowest free index. |

### Close / lifecycle (L-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| L1  | `/tab close 3` on `KindAi`: archives session (transcript saved via `_sh_save`); registry entry removed; index freed; `_th_close` runs. |
| L2  | `/tab close 3` on `KindHarness`: destructive — `_hh_stop` runs; registry entry removed; transcript NOT archived. |
| L3  | `/tab close 3` on `KindBackend`: destructive — `_bh_close` runs; registry entry removed; transcript NOT archived. |
| L4  | `/tab close 3 --force` on `KindAi`: skips archive (transcript deleted from disk); registry entry removed.        |
| L5  | `/tab close 99` (non-existent index): `Left TabNotFound 99` as PublicError; no side effects.                      |
| L6  | `/tab close` of focused tab: new focus is the highest-indexed remaining tab, or `Nothing` if empty.              |
| L7  | `/tab resume <session-id>` on an AI tab archived in L1: creates a new tab with the saved session, allocates lowest free index, focuses. |

### Crashed tab UX (X-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| X1  | `/3` on a tab with `_th_status = Crashed e`: dispatcher emits a one-line PublicError summary (`/3 crashed: <redacted message>`) plus prompt `[1] retry [2] close`. |
| X2  | Retry on `KindAi` re-runs the spawn factory with the original args; the session/transcript is preserved (continuation, not new). |
| X3  | Retry on `KindHarness`/`KindBackend` re-runs the spawn factory with original args; status returns to `Active`. The previous process is gone — no continuation. |

### Dashboard (B-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| B1  | `/tabs` (or `/tab list`) with empty registry: emits `"No tabs open. Use /N or /tab new N <kind> to create one."` |
| B2  | `/tabs` with N tabs: emits one line per tab containing index, kind, redacted name, status, and an asterisk marker for the focused tab. Test: dashboard output for 3 tabs matches a golden-file render. |
| B3  | `/tabs` rendering for ≥ 8 tabs uses bullets (no fixed-width table) so it wraps cleanly on small mobile screens.   |

### Security (S-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| S1  | **Spawn authorization (local)**: `/tab new N shell <cmd...>` calls `authorize cmd _env_policy` BEFORE any subprocess. Test: `cmd` not in `_sp_allowedCommands` → `Left TabSpawnAuthDenied`; no process spawned; channel error is PublicError. |
| S2  | **Spawn authorization (remote/tmux-over-ssh)**: `/tab new N ssh <host> <cmd...>` calls `authorizeRemote cmd _env_policy` and `mkSshHost host`. Test: rejected `host` strings (whitespace, leading `-`, NUL, shell metachars) all produce `Left BackendInvalidOption` as PublicError; no ssh subprocess. |
| S3  | **Smart-constructor validation**: every kind-specific spawn arg passes through its smart constructor (`mkSshHost`, `mkTmuxSession`, `mkTmuxWindow`, `mkTmuxPane`, `mkLocalCommand`). Rejection produces `BackendInvalidOption`. Property test enumerates rejected patterns from terminal-backend-abstractions's adversarial list. |
| S4  | **SSH identity sourcing**: ssh tabs source their `SafeKeyPath` from a Vault slot named by `_rc_sshIdentityKey` (config field, default `"default-ssh-key"`). Identities are NEVER typed inline by the user. Test: `/tab new 3 ssh user@host` with no Vault slot present → PublicError; user-supplied identity arg is rejected by the parser. |
| S5  | **Crashed PublicError**: `Crashed e` is the *internal* representation; channel emit goes through `toPublicTabError`. Test: a tab whose backend factory returns `BackendSshConnectFailed (SshHostKeyMismatch ...)` produces a channel message containing neither the host string, nor any path, nor any ssh stderr. |
| S6  | **Max-tab cap enforced at spawn**: covered by A11; cross-referenced here for security audit traceability. |
| S7  | **Spawn rate limit**: each chat-user is limited to `_rc_spawnRateLimit` spawns/minute (default 10). Token-bucket implementation. Exceeding it → PublicError; no spawn. Defends against close-spawn cycling resource leak. |
| S8  | **User-allowlist invariant**: the user-allowlist check (e.g. `_sc_allowFrom` in Signal channel) is the canonical gate. The dispatcher reads from `_ch_receive` only — no other input path exists. Test: no code path in `Routing/Dispatcher.hs` reads input from anywhere except `ChannelHandle._ch_receive`. (Static grep + a runtime test that fakes a non-allowlisted user and verifies the dispatcher never sees the message.) |

### Coexistence with existing slash commands (K-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| K1  | `/session new` while a focused tab exists: creates a new SessionHandle and **attaches to the focused tab** (per K2, if focused tab is `KindAi`). If the focused tab is `KindHarness`/`KindBackend`, `/session new` errors with a PublicError explaining "this tab does not own a session." |
| K2  | `/tab new N ai` automatically creates a new SessionHandle for the tab. (Tab-creation → session-creation direction.) |
| K3  | `/session new` with empty registry implicitly spawns a `KindAi` tab at the lowest free index (default behavior). |
| K4  | `/target <name>` while focused on a `KindAi` tab: sets that tab's target via the focused-tab projection. Does NOT persist across pureclaw restarts (per-tab target is in-memory). To make a tab spawn with a specific target on restart, edit defaults in config. |
| K5  | `/target <name>` while focused on a `KindHarness` or `KindBackend` tab: PublicError "tab kind does not support /target." |
| K6  | `/provider`, `/model`, `/vault`, `/transcript`, `/agent`, `/new`, `/last` while focused on `KindAi`: operate on the focused tab. (One DoD per command at parser level; semantic preservation tested behaviorally per command.) |

### Test seams (T-series)

| #   | DoD                                                                                                              |
|-----|------------------------------------------------------------------------------------------------------------------|
| T1  | `Test.Fake.Provider` exists: a `Provider` impl backed by a `TVar [CompletionRequest]` recording every `complete` invocation and serving canned responses (including TMVar-blocking variants for concurrency tests). Used by P18, C1, D-series. |
| T2  | `Test.Fake.ChannelHandle` exists: a `ChannelHandle` impl backed by a `TVar [(UTCTime, ChannelEvent)]` recording every emit. Provides `_ch_receive` from an injected `TQueue` of inputs. Used by D1, D3, D4, D5, B-series. |
| T3  | `Test.Fake.TabFactory` exists: pure factories `mkFakeTabAi`, `mkFakeTabHarness`, `mkFakeTabBackend` that produce `TabHandle`s without external resources. Used by dispatcher/registry tests. |
| T4  | `_env_fork :: IO () -> IO ThreadId` substitution: tests use a synchronous variant that runs the action inline. Where concurrency is essential to the test, tests use the real `forkIO` variant with deterministic synchronization via `TMVar`. |

### Total: 65 DoDs across 11 series (P/H/E/C/D/A/L/X/B/S/K/T).

WU0 commits 65 failing tests (or `pending` tests, for ones whose factories haven't landed yet), structured to mirror these series.

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
  { _th_index   :: !TabIndex
  , _th_name    :: !Text          -- pre-redacted friendly label
  , _th_kind    :: !TabKind       -- pure field
  , _th_session :: !SessionHandle -- per-tab transcript
  , _th_status  :: IO TabStatus
  , _th_send    :: Text -> IO ()  -- enqueue via TBQueue, never blocks the dispatcher
  , _th_close   :: IO ()          -- idempotent, never-throws, kind-specific
  }

data TabError
  = TabIndexInUse !TabIndex
  | TabIndexOutOfRange !Int
  | TabLimitExceeded !Int
  | TabBackendConstructFailed !BackendError
  | TabSessionCreateFailed !SessionError
  | TabSpawnAuthDenied !PublicAuthError
  | TabNotFound !Int
  deriving (Eq, Show)
-- Show instance is redacted. Internal-only.

data PublicTabError = ... -- mirror with channel-safe field set
toPublicTabError :: TabError -> PublicTabError
```

### Per-kind state (hidden inside factories)

* **`KindAi`**: holds a `TBQueue Text` input queue, a forked agent-loop thread, IORefs for provider/model/target/Context (per-tab Context — not shared with dispatcher). The loop reads from the queue, runs one provider+tools turn, writes output to its transcript (always) and to the channel mux (focus-gated).
* **`KindHarness`**: wraps an existing `HarnessHandle`. `_th_send` writes to harness stdin; an internal drainer thread reads from harness stdout, writes to transcript + channel mux.
* **`KindShell` / `KindSsh` / `KindTmux`**: wraps a `BackendHandle` from `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle`. `_th_send` writes via `_bh_send`; an internal drainer reads from `_bh_recv` (respecting the BackendHandle concurrency contract: one writer + one reader thread, never concurrent reads or concurrent writes).

### Per-tab state for AI tabs (illustrative; not exported)

```haskell
data AiTabState = AiTabState
  { _ats_inputQ   :: TBQueue Text
  , _ats_provider :: IORef SomeProvider
  , _ats_model    :: IORef ModelId
  , _ats_target   :: IORef MessageTarget
  , _ats_context  :: IORef Context           -- per-tab conversation history
  , _ats_thread   :: ThreadId                -- the loop's thread; used for cancel
  }
```

### `AgentEnv` additions

```haskell
data AgentEnv = AgentEnv
  { ... existing fields ...
  , _env_tabs          :: !(IORef (IntMap TabHandle))   -- key = unTabIndex
  , _env_focus         :: !(IORef (Maybe TabIndex))     -- Nothing when empty registry
  , _env_routingConfig :: !RoutingConfig
  , _env_fork          :: !(IO () -> IO ThreadId)        -- test seam; default forkIO
  , _env_channelOutQ   :: !(TQueue (OutputSource, ChannelEvent)) -- writer-thread input
  }

data OutputSource = SrcDispatcher | SrcTab !TabIndex
```

Existing `_env_target`, `_env_session`, `_env_provider`, `_env_model`, `_env_harnesses` remain — they become **focused-tab projections**, updated by the dispatcher on focus change and read by existing slash-command handlers. They are NOT read by tab loops; tab loops use their own internal state. This is transitional architecture; see v1.5 deferred (retire projections).

### `RoutingConfig`

```haskell
data RoutingConfig = RoutingConfig
  { _rc_defaultKind        :: !TabKind            -- pre-shipped as KindAi
  , _rc_defaultAi          :: !AiDefaults
  , _rc_defaultShell       :: !ShellDefaults
  , _rc_switchRecap        :: !Int                -- default 3 recent messages on /N switch
  , _rc_maxTabs            :: !Int                -- default 10
  , _rc_inputQueueBound    :: !Int                -- default 64
  , _rc_spawnRateLimit     :: !Int                -- default 10 spawns/minute
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

* `_env_channelOutQ :: TQueue (OutputSource, ChannelEvent)` — a single STM queue.
* A dedicated writer thread consumes from the queue and calls `_ch_send`/`_ch_sendChunk`.
* For `SrcTab n` events: writer reads `_env_focus` and drops the event if `Just n /= focus`.
* For `SrcDispatcher` events: always emit.
* Per-event focus snapshot, not per-stream. If focus changes mid-stream, the rest of the stream is silently elided from the channel; the user catches up via switch + recap.

Trade-off: a user who switches to `/1` mid-stream from `/0` sees an abrupt cut. The recap on `/0` switch-back shows the full message from transcript. We judge this acceptable for v1 — alternative behaviors (continue streaming, pause, switch-and-resume) all add complexity for a corner case.

### Async exception discipline

* Each tab is spawned under `mask`: `mask_ $ do { ref <- ...; addToRegistry; eventually <- _env_fork tabLoop; ... }`. Half-registered tabs are rolled back on async exception.
* Each tab loop runs inside `bracket` so per-kind resources release on cancel (`_bh_close`, `_hh_stop`, `_sh_save`).
* Dispatcher uses `withAsync` per spawned tab. If the dispatcher itself dies, all tab threads receive `AsyncCancelled` and run their bracketed cleanup.

### Focus invariant

`_env_focus` is mutated **only** by the dispatcher, **only** at message boundaries. Slash-command handlers run synchronously in the dispatcher thread. This means slash-command handlers that read/write focused-tab projections do so against a stable focus snapshot — no TOCTOU. The dispatcher does NOT process the next incoming message until the previous handler returns.

## Auto-spawn behavior

`_rc_defaultKind = KindAi` is the shipped default. So:

* **First-time user types `/0`** → silently spawns `KindAi` with default provider/model from `_rc_defaultAi`. One-line confirmation: `/0: ai (claude-opus-4-7) ready.`
* **First-time user types `/tab new 0`** → force-prompt: `Spawn /0 as: [1] AI [2] shell [3] tmux [4] ssh`. User taps 1-4.
* **User wants a shell as a first tab**: types `/tab new 0 shell`. Single command, no prompt.
* **User wants to change the default**: edit `~/.pureclaw/config.toml` directly, or `/config routing.default_kind=shell` once that command lands (v1.5).

This default eliminates the 3-tap auto-spawn flow that Designer flagged as a blocker. The "set as default" inline affordance from the round-1 design is dropped — users who want a non-AI default set it once in config.

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
| `/N` (digits only)               | switch (or auto-spawn) focus to tab N                                     |
| `/N <payload>`                   | direct-inject payload to tab N (no focus change)                           |
| `/tabs`                          | alias for `/tab list`                                                     |
| `/tab list`                      | dashboard: list all tabs with status                                       |
| `/tab new N [kind] [args]`       | spawn; no kind → force-prompt; with kind → explicit                        |
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

User: /tab new 1 shell
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

### Crashed tab

```
User: /tab new 2 ssh user@prod-db.internal
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
    Parse.hs                -- parseInput, mkTabIndex, parser invariants
    Dispatcher.hs           -- runDispatcher :: AgentEnv -> IO ()
    Registry.hs             -- tab CRUD over IORef IntMap; spawnTab indirection
    ChannelOut.hs           -- writer thread + TQueue + focus-gated emit
    AutoSpawn.hs            -- /N + missing-tab UX, prompt rendering
    Config.hs               -- RoutingConfig load
  Tab/
    Ai.hs                   -- mkTabAi :: ... -> IO (Either TabError TabHandle)
                            --   contains the AI loop body (formerly runAgentLoop's go)
    Harness.hs              -- mkTabHarness
    Backend.hs              -- mkTabBackend (wraps BackendHandle)
  Agent/
    Env.hs                  -- (modified) _env_tabs, _env_focus, _env_routingConfig,
                            --   _env_fork, _env_channelOutQ
    SlashCommands.hs        -- (modified) CmdTabNew, CmdTabList, CmdTabClose, CmdTabFocus,
                            --   CmdTabResume, CmdTabRename. Imports Routing.Registry
                            --   for spawn/CRUD indirection (NOT Tab.Ai directly).
    Loop.hs                 -- (modified) main loop becomes runDispatcher wrapper

test/
  Test/Fake/Provider.hs
  Test/Fake/ChannelHandle.hs
  Test/Fake/TabFactory.hs
```

**Import DAG (no cycles):**

```
Handles.Tab  (leaf types)
  ↑
Routing.Types  (parser ADTs, RoutingConfig — leaf)
  ↑
Routing.Parse, Routing.Registry, Routing.ChannelOut
  ↑
Tab.Ai, Tab.Harness, Tab.Backend  (factories; depend on Handles.Tab + Routing.Registry)
  ↑
Routing.Dispatcher  (orchestrates registry + parser + spawn indirection)
  ↑
Agent.Loop  (top-level: starts dispatcher)
  ↑
Agent.SlashCommands  (existing + new tab commands; depends on Routing.Registry)
```

The key inversion: `Agent.SlashCommands` does NOT import `Tab.Ai`. Instead it calls `Routing.Registry.spawnTab :: AgentEnv -> TabKind -> [Text] -> IO (Either TabError TabIndex)`, which internally dispatches to the right factory. This kills the circular-import risk Architect B8 flagged.

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

## Open Questions (remaining after round 1 revisions)

These are NON-blocking and can be revisited during implementation, with sensible v1 defaults stated:

1. **Recap on self-switch.** `/N` when N is the focused tab. v1 default: emit recap anyway (consistent with non-self switch). Open: should it be a no-op? Decided in WU09 (auto-spawn) if it becomes friction.
2. **Idle-timeout for Active → Idle transition.** When does the status flip from Active to Idle if there's no explicit signal? v1 default: when the loop returns from a provider/tool call, set status to `Idle <now>`. Open: a watchdog-driven transition might be cleaner if loops can hang.
3. **Channel-bound name for ssh tabs.** `_th_name` is redacted (H11) — what's a good default label? v1 default: `"ssh tab #N"`. Open: maybe encode `kind` only in dashboard rendering, not in name.
4. **Recap window size.** `_rc_switchRecap = 3`. Open: should be channel-dependent (Telegram can do more lines than Signal)? Not in v1.

## Terminology

* **Tab** — a routing slot; user-facing primitive.
* **TabIndex** — the integer the user types after `/`; 0-based, bounded by `_rc_maxTabs`.
* **TabHandle** — Handle-pattern record of IO actions for one tab.
* **TabKind** — `KindAi | KindHarness | KindShell | KindSsh | KindTmux`.
* **TabStatus** — runtime state: `Active | Idle | Crashed`.
* **Focus** — the tab whose output reaches the channel.
* **Direct-inject** — sending payload to a non-focused tab via `/N <payload>`.
* **Auto-spawn** — creating a tab on first reference to its index (uses `_rc_defaultKind`).
* **Force-prompt** — `/tab new N` with no kind argument; ignores default.
* **Dispatcher** — the single thread reading from the channel, classifying, and routing.
* **ChannelOut writer** — the single thread serializing channel writes; gated on focus for `SrcTab` events.
* **Focused-only display** — invariant: non-focused tab output reaches each tab's transcript but never the channel during v1.
* **Focused-tab projections** — `_env_target`/`_env_session`/etc. mirrors of the focused tab's state; transitional v1 architecture, retired in v1.5.

## Relationship to terminal-backends (#49)

Tabbed Chat is the first agent-loop-level consumer of the terminal backends shipped on this branch. Specifically:

* `KindShell`, `KindSsh`, `KindTmux` factories (`mkTabBackend` family) wrap `BackendHandle` returned by `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle`. Tabbed Chat exercises the backend lifecycle (`_bh_send`, `_bh_recv`, `_bh_close`) in a real concurrent workload with `AuthorizedCommand` / `RemoteCommand` flowing through actual policy gates (S1, S2).
* The drainer pattern from `PureClaw.Backend.Pty` (WU7) is reused at the tab level for `_th_send`/recv pumping.
* The `AutonomyLevel`-aware close semantics (`TmuxCloseAction`, WU10) carry through unchanged.

**This is the rationale for landing Tabbed Chat on the same branch as #49** — it stress-tests the backend abstraction with a non-trivial concurrent consumer before that work leaves the branch. (Note: this is a *delivery* rationale, not a user-facing use case, hence its placement here rather than in UCs.)
