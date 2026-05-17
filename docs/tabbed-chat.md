# Tabbed Chat — Mobile-Optimized Multiplexing

**Issue:** [#51](https://github.com/pureclaw/pureclaw/issues/51)
**Status:** design — pending Design Review Gate
**Branch:** `feat/terminal-backends-design`
**Authors:** Doug Beardsley, Claude
**Builds on:** [Terminal / Backend Abstractions](terminal-backend-abstractions.md) — Tabbed Chat's per-tab targets can be local processes, ssh sessions, or tmux attachments via the `BackendHandle` factories already on this branch.

## Naming note

The user-facing primitive is a **tab**. A tab is a sub-stream within the user's single chat thread — analogous to a browser tab or a tmux window. Each tab has an integer index (mobile-friendly: `/0`, `/1`, ...), an optional friendly name, a kind (AI agent, shell harness, terminal backend), and its own session transcript. The internal type is `TabHandle`. We rejected `Route`, `Slot`, `Pane`, and `Window` in favor of `Tab` because the browser-tab mental model is universal and not tmux-specific.

## Motivation

PureClaw users on mobile (Telegram, Signal) currently manage a single agent per chat thread. Power users routinely want to drive *multiple* concurrent agents — a coding agent, a shell, an SSH session into prod, a test runner — but a chat thread is single-stream. Today they either run multiple bots (each in its own thread) or context-switch with `/target <harness>` and lose the parallel-execution benefit.

The Context Gap:

1. **Identification** — which agent is which when responses arrive?
2. **Routing** — how do I direct a message to a specific agent without typing long names?
3. **Mobile UX** — Telegram/Signal native chat UIs are constrained; complex slash-command vocabulary is unfriendly on a phone keyboard.

Tabbed Chat treats the chat thread as a **multiplexer**: a small numeric-index routing layer sits between the channel and the agent loop, exposing `/0 ... /9` as the primary navigation primitive and a unified `TabHandle` abstraction over heterogeneous targets (AI agents, harnesses, terminal backends).

## Use Cases

**UC-1 (agent-facing) — concurrent coding + shell.** User pins an AI tab `/0` on long-running code work and a shell tab `/1` for quick lookups. They direct-inject `/1 ls -la /var/log` without leaving `/0`, get the response inline, continue typing in `/0` context.

**UC-2 (agent-facing) — multi-environment ops.** A site reliability user runs `/0` (local dev shell), `/1` (ssh to staging), `/2` (ssh+tmux attach to a prod incident session). `/2 status` direct-injects into the prod incident channel.

**UC-3 (agent-facing) — multi-agent parallelism.** User runs `/0` (Anthropic Opus for hard reasoning), `/1` (Haiku for quick lookups), routes accordingly.

**UC-4 (developer-facing) — backend smoke test.** The terminal-backend factories (WU0–WU11 just landed) get their first end-to-end consumer via Tabbed Chat, exercising `BackendHandle` lifecycle under realistic concurrent use.

## Routing Grammar (v1)

All routing happens in the slash-command preprocessor — **before** any provider call — preserving the LLM-free invariant for `/`-prefixed input.

```
input            ::= switch | inject | default | slash-cmd
switch           ::= '/' DIGITS                           e.g. /0, /12
inject           ::= '/' DIGITS WS payload                e.g. /0 run tests
default          ::= payload                              -- to current focus
slash-cmd        ::= '/' WORD ...                         -- existing commands
                 |   '/tabs'                              -- new: dashboard
                 |   '/tab' WS DIGITS [WS kind [WS args]] -- new: spawn
                 |   '/close' WS DIGITS                   -- new: close
                 |   '/focus' WS DIGITS                   -- new: explicit switch
DIGITS           ::= [0-9]+                               -- not /word
WS               ::= one or more spaces/tabs
payload          ::= rest of line, free text
kind             ::= 'ai' | 'shell' | 'tmux' | 'ssh'
```

Notes:

* `/12` parses as tab 12 (not `/1` + payload `2`). Digits are greedy up to whitespace.
* `/1 0 run` parses as tab 1, payload `"0 run"`.
* `/word` (non-numeric) routes to existing slash-command dispatch unchanged.
* `/0` on a non-existent tab triggers auto-spawn (see Auto-spawn).
* Switch shows a short recap of the destination tab's recent messages (configurable count, default 3).

## Acceptance Criteria (v1)

Each criterion becomes one or more failing tests in WU0 (red-phase scaffold), flipping green as work units land.

### Parser (LLM-free preprocessing)

1. `parseInput "/0"` → `Switch 0`.
2. `parseInput "/12"` → `Switch 12`.
3. `parseInput "/0 run tests"` → `Inject 0 "run tests"`.
4. `parseInput "/0 0 run"` → `Inject 0 "0 run"` (preserves payload digits).
5. `parseInput "hello world"` → `Default "hello world"`.
6. `parseInput "/tabs"` → `SlashCmd CmdTabsList`.
7. `parseInput "/tab 3"` → `SlashCmd (CmdTabSpawn 3 Nothing)`.
8. `parseInput "/tab 3 shell"` → `SlashCmd (CmdTabSpawn 3 (Just KindShell))`.
9. `parseInput "/close 3"` → `SlashCmd (CmdTabClose 3)`.
10. `parseInput "/help"` (existing) routes to existing `SlashCommand` ADT unchanged — no regressions.

### TabHandle abstraction

11. `TabHandle` is a record of IO actions (Handle pattern), constructed via `mkTabAi`, `mkTabHarness`, `mkTabBackend` factories.
12. Each factory takes a `TabIndex`, optional friendly name, kind-specific arg, and returns `IO (Either TabError TabHandle)`.
13. `_t_send :: Text -> IO ()` enqueues input to the tab; never blocks the dispatcher.
14. `_t_status :: IO TabStatus` returns current status (`Active`, `Idle`, `Crashed e`, `Closing`).
15. `_t_close :: IO ()` is idempotent and drains the tab's input queue before terminating.

### Dispatcher / registry

16. `TabRegistry` lives in `AgentEnv` as `_env_tabs :: IORef (IntMap TabHandle)` plus `_env_focus :: IORef (Maybe TabIndex)`.
17. The dispatcher reads each incoming message exactly once and routes per the parsed grammar.
18. Concurrent tabs run in their own forked threads; AI tabs hold their own provider/model/session state.
19. Outgoing messages are serialized through a single output mutex so cross-tab streams don't garble.
20. Each cross-tab message is prefixed with `/N: ` so the user can see which tab produced it. The currently-focused tab's responses are prefix-less (or configurable via `routing.always_prefix_focus`).

### Auto-spawn

21. `/3` when tab 3 doesn't exist triggers an interactive spawn prompt unless `routing.default_kind` is set in config, in which case it spawns with default and shows a one-line confirmation.
22. `/tab 3` (no kind) **always** prompts, regardless of default config — this is the force-prompt escape hatch.
23. `/tab 3 shell` spawns explicitly and skips the prompt.
24. After a tab is closed, its index becomes immediately reusable; new spawn allocates the lowest free index by default (but explicit `/tab 7 ai` always honors the requested index).
25. Spawn prompts include a "set as default for future" affordance (channel-specific UX: inline keyboard on Telegram, numbered text reply on Signal/CLI).

### Dashboard (`/tabs`)

26. `/tabs` lists all tabs with index, kind, name, status, and a marker for the focused tab.
27. Empty registry: `/tabs` shows `No tabs open. Use /N or /tab N <kind> to create one.`
28. The dashboard is reachable from any channel, regardless of pinned-message capability (v1.5 adds pinned-mode for capable channels).

### LLM-free invariant

29. No `/`-prefixed input reaches a provider for v1's routing grammar. (Existing invariant; explicit test ensures the new commands don't bypass it.)

### Coexistence with existing `/session`, `/target`

30. `/session new` creates a new SessionHandle and, if invoked while a tab exists, attaches it to the current focused tab (preserves existing UX). The reverse — creating a new tab spawns a new SessionHandle automatically.
31. `/target <name>` continues to work; it sets the focused tab's target if the tab is an AI tab, or errors otherwise.

## The Abstraction

### `TabHandle` (Handle pattern, mirrors `BackendHandle`)

```haskell
-- src/PureClaw/Handles/Tab.hs

data TabIndex = TabIndex !Int
  deriving (Eq, Ord, Show)

data TabKind
  = KindAi       -- LLM agent loop (provider + model + session)
  | KindHarness  -- HarnessHandle (e.g. tmux harness, existing)
  | KindBackend  -- BackendHandle (Local/SSH/Tmux factories from #49)
  deriving (Eq, Show)

data TabStatus
  = Active                   -- processing a message right now
  | Idle UTCTime             -- last input timestamp
  | Crashed Text             -- short error label
  | Closing                  -- _t_close called, draining
  deriving (Eq, Show)

data TabHandle = TabHandle
  { _t_index    :: !TabIndex
  , _t_name     :: !Text                -- friendly label, e.g. "claude-opus" / "shell-local"
  , _t_kind     :: !TabKind
  , _t_session  :: !SessionHandle       -- per-tab transcript
  , _t_status   :: IO TabStatus
  , _t_send     :: Text -> IO ()        -- enqueue input
  , _t_close    :: IO ()
  }
```

### Per-kind state (hidden inside factories)

* **`KindAi`**: a `TQueue Text` for input, a forked agent-loop thread, IORefs for provider+model. The loop reads from the queue, runs one provider+tools round, emits output through the global output mux.
* **`KindHarness`**: wraps the existing `HarnessHandle`. Input is sent to harness stdin; output is captured via the harness's existing capture mechanism, forwarded to the channel with a `/N: ` prefix.
* **`KindBackend`**: wraps a `BackendHandle` (one of `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle`). Input → `_bh_send`; a forked drainer pulls from `_bh_recv` and emits.

### `AgentEnv` additions

```haskell
data AgentEnv = AgentEnv
  { ... existing fields ...
  , _env_tabs   :: !(IORef (IntMap TabHandle))   -- registry, key = unTabIndex
  , _env_focus  :: !(IORef (Maybe TabIndex))     -- Nothing when no tabs exist
  , _env_outMux :: !(MVar ())                    -- serialize channel writes
  , _env_routingConfig :: !RoutingConfig         -- defaults, prefix policy
  }
```

`_env_target`, `_env_harnesses`, `_env_session`, `_env_provider`, `_env_model` remain — they become *focused-tab projections* (read-only mirrors) updated when focus changes. This preserves binary compatibility with existing slash commands that read those fields directly until they migrate to tab-aware variants.

### `RoutingConfig`

```haskell
data RoutingConfig = RoutingConfig
  { _rc_defaultKind        :: Maybe TabKind   -- if Just, /N auto-spawns silently
  , _rc_defaultAi          :: AiDefaults      -- provider, model, system prompt
  , _rc_defaultShell       :: ShellDefaults
  , _rc_alwaysPrefixFocus  :: Bool            -- default False
  , _rc_switchRecap        :: Int             -- recent msgs shown on /N switch (default 3)
  , _rc_maxTabs            :: Int             -- default 10 for v1
  }
```

Loaded from `~/.pureclaw/config.toml` under `[routing]`. Mutable via future `/config` slash command (v1.5 surface; v1 keeps it static).

## Dispatcher and Concurrency Model

### Single dispatcher, per-tab loops

```
                            ┌──────────────┐
        ChannelHandle ─────▶│  Dispatcher  │   (one thread, reads channel)
                            └──────┬───────┘
                                   │ parses, routes
                ┌──────────────────┼──────────────────┐
                ▼                  ▼                  ▼
            Tab 0 loop         Tab 1 loop        Tab N loop
            (own thread)       (own thread)      (own thread)
                │                  │                  │
                └──────────────────┴──────────────────┘
                                   │
                                   ▼
                            ┌──────────────┐
                            │  Output mux  │   (MVar serializes _ch_send)
                            └──────────────┘
                                   │
                                   ▼
                            ChannelHandle out
```

### Why per-tab threads

* AI tabs can run a long provider call without blocking other tabs' input.
* Harness/backend tabs are already independent processes; their drainers run concurrently anyway.
* Direct-inject (`/0 long task` while focused on `/1`) is meaningful: the user can switch focus and `/1` stays responsive.

### Output mux semantics

* All writes to `_ch_send` go through `withMVar _env_outMux`.
* Prefix policy: cross-tab messages prefixed `/N: `; focus's own messages unprefixed unless `_rc_alwaysPrefixFocus = True`.
* Streaming chunks (`_ch_sendChunk`) are flushed per chunk; the mux holds the lock for one logical message at a time, so streams of different tabs don't interleave mid-token.

### Error isolation

* A tab loop catches all exceptions, sets `_t_status` to `Crashed e`, emits an error message via the mux, and exits its thread.
* The dispatcher does not crash when a tab does; the registry entry persists with `Crashed` status until `/close N` or respawn.

## Auto-spawn behavior

| User input              | Tab N exists? | Default set? | Action                                                                |
|-------------------------|---------------|--------------|-----------------------------------------------------------------------|
| `/N`                    | yes           | n/a          | switch focus, show recap                                              |
| `/N <payload>`          | yes           | n/a          | inject payload, don't change focus                                    |
| `/N`                    | no            | yes          | spawn with default, focus, confirmation line                          |
| `/N`                    | no            | no           | prompt for kind (with "set as default" affordance)                    |
| `/N <payload>`          | no            | yes          | spawn with default, focus, enqueue payload                            |
| `/N <payload>`          | no            | no           | prompt for kind, then enqueue payload after kind chosen               |
| `/tab N`                | yes           | n/a          | refocus + emit info line (idempotent)                                 |
| `/tab N`                | no            | n/a          | **force-prompt**, ignore default                                      |
| `/tab N <kind> [args]`  | no            | n/a          | spawn with kind, focus                                                |
| `/tab N <kind>`         | yes           | n/a          | error: `/N already exists. /close N first to replace.`                |

## Channel Feature Matrix

| Feature                  | Telegram | Signal | CLI            |
|--------------------------|----------|--------|----------------|
| Numeric switch `/N`      | ✓        | ✓      | ✓              |
| Direct-inject `/N <p>`   | ✓        | ✓      | ✓              |
| On-demand dashboard      | ✓        | ✓      | ✓              |
| Tab-prefix on output     | ✓        | ✓      | ✓              |
| Inline-keyboard spawn UI | ✓        | (text) | (text)         |
| Pinned dashboard         | v1.5     | v1.5   | n/a            |
| Reply-to-route           | v1.5     | v1.5   | n/a            |

CLI special case: tabs work, but the dashboard renders as plain text and the dispatcher still uses concurrent per-tab threads. Output is naturally serial because there's only one stdout, so the output mux is uncontended.

## Slash Command Surface (additions)

| Command                  | Behavior                                                       |
|--------------------------|----------------------------------------------------------------|
| `/N` (digits only)       | switch (or auto-spawn) focus to tab N                          |
| `/N <payload>`           | direct-inject payload to tab N, no focus change                |
| `/tabs`                  | dashboard: list all tabs with status                           |
| `/tab N`                 | force-prompt spawn (ignores default), or refocus if N exists   |
| `/tab N <kind> [args]`   | explicit-kind spawn                                            |
| `/close N`               | close tab N (idempotent, drains queue, frees index)            |
| `/focus N`               | explicit switch synonym for `/N` (autocomplete-discoverable)   |

Existing `/session`, `/target`, `/provider`, `/model`, etc. continue to operate on the **focused tab** (if it's an AI tab). Errors gracefully if the focused tab is a harness or backend.

## LLM-free invariant

`parseInput` runs in the slash-command preprocessor before any provider call. The dispatcher classifies input as `Switch | Inject | Default | SlashCmd`. Only the `Default` case (no leading `/`) ever reaches a provider. Test ID #29 explicitly asserts no `/`-prefixed input touches the LLM.

## Examples

### Mobile flow: spawn, focus, inject

```
User: /0
Bot:  /0 is empty. Spawn as:
      [1] AI agent (claude-opus-4-7)
      [2] Shell (local)
      [3] Tmux session
      [4] SSH host
      (reply 1-4, or 1*/2*/... to set as default)
User: 1
Bot:  /0: claude-opus-4-7 ready and focused.
User: explain RFC 7807
Bot:  RFC 7807 is "Problem Details for HTTP APIs"...

User: /1 ls /var/log
Bot:  /1 doesn't exist. Spawn as: ...
User: 2*
Bot:  /1: shell (local) ready. (default kind set to shell)
      /1: total 384
      drwxr-xr-x  ... ...

User: /tabs
Bot:    /0  claude-opus-4-7  (focus)  idle  3s
        /1  shell (local)             idle  1s
```

### Concurrent direct-inject

```
User: /0 write a haiku about merge conflicts
Bot:  /0: ... (streaming)
User: /1 free -h
Bot:  /0: ... (streaming, continued)
      /1: total used free shared ...
Bot:  /0: ⟨haiku⟩
```

(Mux serializes per-message, but streams from /0 and replies from /1 interleave at message-boundaries.)

## Module Layout

```
src/PureClaw/
  Handles/
    Tab.hs                  -- TabHandle, TabIndex, TabKind, TabStatus
  Routing/
    Parse.hs                -- parseInput :: Text -> ParsedInput
    Dispatcher.hs           -- runDispatcher :: AgentEnv -> IO ()
    Registry.hs             -- tab CRUD over IORef IntMap
    OutputMux.hs            -- emit prefixed messages serialized via MVar
    AutoSpawn.hs            -- /N + missing-tab UX, prompt rendering
    Config.hs               -- RoutingConfig parsing
  Tab/
    Ai.hs                   -- mkTabAi :: ... -> IO (Either TabError TabHandle)
    Harness.hs              -- mkTabHarness
    Backend.hs              -- mkTabBackend (wraps BackendHandle)
  Agent/
    Env.hs                  -- (modified) _env_tabs, _env_focus, _env_outMux
    SlashCommands.hs        -- (modified) CmdTabsList, CmdTabSpawn, CmdTabClose
    Loop.hs                 -- (modified) refactor into per-tab loops
```

The existing `Agent/Loop.hs` `runAgentLoop` is decomposed into:
* `runDispatcher` — top-level message-router thread.
* `runAiTabLoop` — per-tab AI loop body (formerly the body of `runAgentLoop`).

Harness and backend tabs use small forked drainers in `Tab.Harness` / `Tab.Backend`.

## v1.5 Deferred Work

| Feature                       | Why deferred                                                            |
|-------------------------------|-------------------------------------------------------------------------|
| Reply-to-route                | Requires extending `IncomingMessage` with `replyTo :: Maybe MessageId` plus per-channel plumbing (Telegram echoes outgoing message_ids; Signal's reply API differs; CLI has no concept). |
| Pinned dashboard              | Channel-feature matrix work — Telegram supports `pinChatMessage`; Signal doesn't; needs `ChannelCapability` abstraction. |
| `/config dashboard=off`       | Needs runtime-mutable config plumbing. Static config OK for v1.        |
| Spawn options inline (`--model=sonnet`, `--system=...`) | Defer parser complexity until v1 UX validated.                |
| Cross-tab broadcast (`/* msg`)| Future power-user feature.                                              |

## Open Questions (to be resolved in design review)

1. **Output prefix style.** Is `/N: ...` the right rendering, or do we want a richer banner (e.g. `[/0 claude-opus-4-7]\n...`)? Probably channel-dependent.
2. **Streaming and the output mux.** Holding the mux for the entire stream blocks other tabs' messages for the duration. Alternative: chunk-grained mux with per-tab buffers. v1 favors message-grained (simpler); revisit if streaming feels laggy.
3. **AI-tab provider/model overrides at spawn time.** v1 takes defaults from config; should `/tab 3 ai claude-sonnet` accept a model token positionally? Probably yes — minor parser extension.
4. **Status semantics for AI tabs.** "Active" while a provider call is in flight, "Idle" otherwise — but tool execution is part of the loop. Do we expose a third status `Tool`? Or keep two states for v1?
5. **CLI behavior** when the user types `/0` while focused on `/0`: no-op? Print recap anyway? Probably print recap for consistency.
6. **Max tabs.** `_rc_maxTabs = 10` for v1. Higher? Make it lazy (no cap)? Telegram inline keyboards have row/column limits but our spawn UX doesn't depend on that.
7. **Session lifecycle on close.** When `/close N` runs, do we delete the SessionHandle or archive it? Archive (preserve transcripts) is the safer default; close is non-destructive.

## Terminology

* **Tab** — a routing slot; user-facing primitive.
* **TabIndex** — the integer the user types after `/`; 0-based.
* **TabHandle** — Handle-pattern record of IO actions for one tab.
* **TabKind** — `KindAi | KindHarness | KindBackend`.
* **Focus** — the tab to which un-prefixed user input is routed.
* **Direct-inject** — sending payload to a non-focused tab via `/N <payload>`.
* **Auto-spawn** — creating a tab on first reference to its index.
* **Force-prompt** — `/tab N` with no kind argument; always prompts.
* **Dispatcher** — the single thread reading from the channel, classifying, and routing.
* **Output mux** — `MVar` serializing channel writes; prevents stream interleaving.

## Relationship to terminal-backends (#49)

Tabbed Chat is the first agent-loop-level consumer of the terminal backends shipped on this branch. Specifically:

* `mkTabBackend` (kind `KindBackend`) wraps `BackendHandle` returned by `mkLocalBackendHandle`, `mkSshBackendHandle`, `mkTmuxBackendHandle` — Tabbed Chat exercises the backend lifecycle (`_bh_send`, `_bh_recv`, `_bh_close`) in a real concurrent workload, which is exactly the integration test the backends doc identifies as missing in #49's v1 surface notes.
* The drainer pattern from `PureClaw.Backend.Pty` (WU7) is reused at the tab level.
* The `AutonomyLevel`-aware close semantics (`TmuxCloseAction`, WU10) carry through unchanged.

This is the rationale for landing Tabbed Chat on the same branch as #49: it stress-tests the abstraction with a non-trivial consumer before it leaves the branch.
