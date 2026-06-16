# Unified pre-inference slash-command dispatch for the web frontend

**Status:** Design approved 2026-06-15 — pending design-review gate
**Author:** brainstormed with the user, 2026-06-15

## Problem

PureClaw exposes the same agent through several end-user surfaces: the TUI,
chat channels (Telegram/Signal/CLI), and a web frontend. The TUI and channels
route every inbound message through a shared classification stage
(`PureClaw.Routing.Parse.parseInput`) that **short-circuits** slash commands —
parsing and executing them *before* any LLM call. The web frontend does not: its
`handleSend` (`src/PureClaw/Frontend/API.hs`) passes the raw user text straight
to `doCompletion` (or to a harness), so a `/help` typed in the web UI is sent to
the model as ordinary chat.

This breaks two guarantees the project wants:

1. **No slash input should silently reach LLM inference.** `/`-commands are a
   short-circuit point where deterministic processing runs first, so we can
   apply heuristics about when paying the LLM cost is warranted.
2. **All end-user chat paths should go through the same handling.** Behavior
   should not diverge by surface.

## Goals

- Route the web frontend's `handleSend` through the *same* classification and
  short-circuit stage the TUI/channels use, so `/`-commands never reach the LLM.
- Reuse the existing command implementations (`executeSlashCommand`) rather than
  reimplementing them for the web — behavior stays identical and in one place.
- Do this through a **transport-agnostic dispatch seam** so the same entry point
  can later back an "expose slash commands to LLM agents as tool calls" feature.

## Non-goals (this spec)

- **Interactive (prompting) commands** in the web UI — commands that call
  `_ch_prompt` / `_ch_promptSecret` / `_ch_readSecret` mid-execution (e.g.
  `/provider add`, `/vault set`, Signal register). These require a bidirectional
  streaming channel and frontend prompt UI; deferred to a tracked follow-up
  (see "Deferred: interactive commands").
- **Cross-session send from the web UI** (the `Inject` / `/N payload` routing
  form). Short-circuited with a message for now.
- The future **standalone-gateway** topology, in which the frontend would run as
  a separate process from the agent loop. This spec targets the current
  **bundled** mode, where they share a process and IORefs.

## Key findings that shape the design

1. **Frontend and agent loop share a process and IORefs (bundled mode).** In
   `src/PureClaw/CLI/Commands.hs:804`, `FrontendEnv` is built from the very cells
   the `AgentEnv` (`env`, in scope just above) uses: `_fe_provider = providerRef`,
   `_fe_model = modelRef`, `_fe_harnesses = harnessRef`,
   `_fe_harnessRegistry = harnessReg`, `_fe_tabRegistry`, `_fe_cursors`,
   `_fe_registry = fullRegistry`, etc. So slash commands that mutate state
   (`/provider`, `/agent`, `/tab new`) act on the *same* state the TUI mutates —
   no split-brain in bundled mode.

2. **No import cycle.** `Agent.SlashCommands`, `Agent.Env`, `Routing.*`, and
   `Tabs.*` do not import `Frontend.API` (the `_env_startHarness` /
   `_env_onTabsChanged` seams exist precisely to keep `Routing`/`Tabs`
   independent of `Frontend`). Therefore `Frontend.API` may call the slash
   dispatch without creating a cycle.

3. **The grammar already separates routing from commands.**
   `Routing.Parse.parseInput` (`src/PureClaw/Routing/Parse.hs:97`) classifies:
   - `Default` — no leading `/`; ordinary chat.
   - `Switch` (`/0`, `/a`) and `Inject` (`/3 run tests`) — the **positional
     routing layer**: single index char (`[0-9a-z]`) at a whitespace/EOI
     boundary. These answer *"which conversation does this input go to."*
   - `ParsedSlashCmd` — letter-*word* forms (`/help`, `/tab new`, `/provider …`)
     via `parseSlashCommandForm` → `parseSlashCommand`.
   - `Left ParseError…` — malformed/unknown slash input (`/foo`, `/tab resume
     <bad-id>`). **The TUI surfaces these as errors; it never sends them to the
     LLM.**

   The web request already carries *which conversation* via its `{sid}` URL, so
   the positional routing layer (`Switch`/`Inject`) is **transport-level** and
   handled natively by the transport. Only the **command layer** is shared. This
   is why bare `/0` "not making sense in the web UI" is not a one-off special
   case — the whole positional layer is out of band for the web transport.

4. **Slash output is display-only, never LLM context.** In the TUI a command
   emits via `_ch_send` to the terminal; the text is shown but not added to the
   message history. The web frontend rebuilds LLM context by replaying the
   transcript (`loadRecentMessages`, `src/PureClaw/Session/Handle.hs:747` — every
   `Request`→`User`, every `Response`→`Assistant`), and there is **no
   display-only entry kind**. So recording slash output as a transcript entry
   would feed it back to the model. Decision: web slash output is **transient,
   not persisted** (matches TUI ephemerality), sidestepping this entirely.

5. **`executeSlashCommand` needs a full `AgentEnv`**
   (`src/PureClaw/Agent/SlashCommands.hs:944`,
   `executeSlashCommand :: AgentEnv -> SlashCommand -> Context -> IO Context`).
   Nearly every `AgentEnv` field is process-global shared state the frontend
   already holds. Only a few vary per web request: `_env_channel` (must capture
   output instead of writing to a terminal) and `_env_session` (must point at the
   request's `{sid}`).

6. **`ChannelHandle` is a record of IO actions** (`src/PureClaw/Handles/Channel.hs`),
   so a capture channel is straightforward: `_ch_send` appends to an `IORef`;
   `mkSessionHandle` (`src/PureClaw/Session/Handle.hs:177`) builds a per-`{sid}`
   `SessionHandle` from on-disk meta (which `handleSend` already loads).

## Design

### Reuse strategy: a transport-agnostic dispatch seam

New module `PureClaw.Agent.SlashDispatch` exposing:

```haskell
data SlashResult
  = SlashHandled !Text      -- command (or routing/parse error) handled;
                            -- text is the user-facing output. Do NOT infer.
  | SlashPassThrough !Text  -- ordinary chat; caller proceeds to inference.

-- The env passed in must already be scoped to the target conversation:
-- _env_channel = a capture channel, _env_session = the request's session.
runSlashInput :: AgentEnv -> Text -> IO SlashResult
```

`runSlashInput` calls `parseInput (_env_routingConfig env) raw` and maps:

| `parseInput` result        | `runSlashInput` result |
|----------------------------|------------------------|
| `Right (Default raw)`      | `SlashPassThrough raw` |
| `Right (ParsedSlashCmd c)` | run `executeSlashCommand env c ctx` against the capture channel; `SlashHandled <captured>` |
| `Right (Switch _)`         | `SlashHandled "Tab switching is done through the web UI, not by typing /N."` |
| `Right (Inject _ _)`       | `SlashHandled "Cross-tab send isn't available from the web client yet."` |
| `Left parseErr`            | `SlashHandled <render parseErr>` (e.g. "Unknown command", "Invalid session id") |

Only `SlashPassThrough` ever continues to inference. Every leading-`/` input is
short-circuited — satisfying goal #1 — and classification is identical to the
TUI because it is literally the same `parseInput`.

`ctx` for the command: most web-relevant commands ignore `Context` or use it
read-only (`/status` reads message/token counts; `/help`, `/provider`, `/tab*`
ignore it). To keep read-only commands accurate, the caller builds `ctx` from
the request session's transcript via `loadRecentMessages` (the same source
`doCompletion` uses) rather than `emptyContext`, so `/status` reflects real
history. The returned `Context` is **discarded** — output is transient and the
frontend rebuilds LLM context from the transcript on the next turn, so in-memory
`Context` mutations (e.g. `/new` clearing messages) do not need to round-trip
here. (If a future command needs to mutate persisted history from the web, that
is handled by the command's own transcript side-effects, not by the returned
`Context`.)

Why a seam rather than inlining in `handleSend`: the user wants to later expose
slash commands to LLM agents as tool calls. A tool wrapper would reuse exactly
this `runSlashInput` (env scoped to the agent's session, capture channel,
text in → text out). Inlining would force a reimplementation later.

### Capture channel

In `PureClaw.Handles.Channel`:

```haskell
data InteractiveUnsupported = InteractiveUnsupported !Text  -- the prompt label
  deriving Show
instance Exception InteractiveUnsupported

mkCaptureChannelHandle :: IO (ChannelHandle, IO Text)
```

- `_ch_streaming = False` so commands use `_ch_send` (full message), not chunks.
- `_ch_send`, `_ch_sendError`, `_ch_sendChunk` append to a shared `IORef`
  buffer; the returned `IO Text` reads and concatenates the buffered output
  (messages joined by newlines).
- `_ch_prompt`, `_ch_promptSecret`, `_ch_readSecret` **throw**
  `InteractiveUnsupported <label>`. This is the runtime partition between
  interactive and non-interactive commands — no command enumeration needed.

`runSlashInput` wraps `executeSlashCommand` in `try @InteractiveUnsupported`. On
catch it returns `SlashHandled` with a precise deferral message, e.g.
*"`/provider add` needs interactive input, which the web UI doesn't support yet
(tracking: <issue>). Use the CLI for now."* Any already-buffered output (text
emitted before the prompt) is included.

### Per-request env scoping

`runSlashInput`'s caller supplies a base `AgentEnv` with two fields swapped:

- `_env_channel` → the capture channel from `mkCaptureChannelHandle`.
- `_env_session` → an `IORef` over a `SessionHandle` built via `mkSessionHandle`
  for the request's `{sid}` (meta loaded from `_fe_sessionsDir`, broker =
  `_fe_broker`, logger = `_fe_logger`).

All other fields are the shared base env. To make the base env reachable from
the frontend, add one field to `FrontendEnv`:

```haskell
, _fe_agentEnv :: AgentEnv   -- the shared base env; channel/session are
                             -- overridden per request by runSlashInput's caller
```

populated in `src/PureClaw/CLI/Commands.hs` where `env :: AgentEnv` is already
in scope at the `FrontendEnv { … }` construction site.

> Module layering note: `Frontend.API` will import `Agent.Env`, `Agent.SlashDispatch`,
> and `Routing.Parse`. None of these import `Frontend.API` (verified — see finding
> #2), and `Agent.Env`'s existing dependency on `Frontend.StreamBroker` is a leaf
> module, so no cycle is introduced.

### `handleSend` integration

Classification happens **first**, before both the harness branch and the
provider branch, so `/`-commands work in harness-backed sessions and on
instances with no provider configured:

```
handleSend:
  validate sid; ensure transcript exists; decode {message, model?}
  scoped <- baseEnv with capture channel + {sid} session
  res <- runSlashInput scoped message
  case res of
    SlashHandled out  -> respond 200 {"response": out}      -- transient, NOT persisted
    SlashPassThrough _ -> <existing logic unchanged>:
        harness branch (SkHarness) | provider branch (doCompletion)
```

The existing harness/provider code path is untouched for non-slash input.

### Frontend rendering (`frontend/src/App.tsx`)

Slash responses are rendered as a distinct **system/command bubble**, visually
separate from assistant turns, and are **not** written to the transcript — so
they vanish on reload, matching TUI scrollback ephemerality. (The send response
shape `{"response": …}` is unchanged; the frontend distinguishes a slash
response by the fact that the message began with `/`.)

## What runs in v1 vs. deferred

**Works in v1 (non-interactive — emit via `_ch_send` and return):**
`/help`, `/status`, `/new`, `/start`, `/provider` (switch/list), `/target`,
`/agent`, `/mcp`, `/transcript`, `/harness` (non-prompting arms), `/bg`, `/msg`,
`/tab new|close|rename|list`, and the routing/parse-error short-circuits (`/0`,
`/foo`).

**Deferred (interactive — call `_ch_prompt*` mid-execution):**
`/provider add`, `/vault set|delete|unlock`, Signal register, and any other arm
that prompts. These return the deferral message in v1.

## Deferred: interactive commands (follow-up GitHub issue)

A command like `/provider add anthropic` is a single blocking IO action that
pauses mid-execution at each prompt and may chain several prompts in sequence
(a wizard inside one `executeSlashCommand` call). Supporting it over the web
needs a **bidirectional streaming channel**, not just output capture:

1. Run the command on a **background thread** so the HTTP request returns
   immediately.
2. On each `_ch_prompt`, publish a *prompt* event via the existing
   `StreamBroker`/SSE (browser shows an input box) and **block** the command
   thread on a per-session rendezvous (`MVar`/`TBQueue`).
3. Add an **uplink endpoint** (`POST /api/sessions/{sid}/prompt-reply`) that
   fills the rendezvous and resumes the thread.
4. Correlate replies to the pending prompt; handle abandonment (tab closed
   mid-wizard) via cancellation/timeout.
5. Add **frontend UI** to render the inline prompt and send the reply.

The v1 seam is built so this channel **swaps in without reworking the
dispatch**: `runSlashInput` is unchanged; only the channel implementation (and
the surrounding execution model) changes. This will be filed as a GitHub issue
as part of this work.

## Testing (TDD, 100% coverage per `.coverage-thresholds.json`)

Red-first tests, CLISpec-style integration plus unit:

- `POST /api/sessions/{sid}/send` with `/help` returns the help text **and the
  provider is not called** (no new `Request`/`Response` transcript entries).
- `/status` succeeds with **no provider configured** (no 503) — proving the
  short-circuit precedes the provider guard.
- A plain (non-slash) message still routes to the provider (and to a harness for
  `SkHarness` sessions) unchanged.
- `/tab new` runs against the shared `TabRegistry` (observable from the registry
  the TUI shares).
- `/0` (Switch) and `/foo` (parse error) short-circuit with a message and **do
  not** call the provider.
- An interactive command (e.g. `/provider add`) returns the deferral message and
  does not hang.
- Unit: `mkCaptureChannelHandle` buffers `_ch_send` output and its prompt
  functions throw `InteractiveUnsupported`; `runSlashInput` maps each
  `parseInput` variant to the correct `SlashResult`.

## Affected surface

- `src/PureClaw/Handles/Channel.hs` — `mkCaptureChannelHandle`,
  `InteractiveUnsupported`.
- `src/PureClaw/Agent/SlashDispatch.hs` — new module: `SlashResult`,
  `runSlashInput`.
- `src/PureClaw/Frontend/API.hs` — `_fe_agentEnv` field; `handleSend`
  short-circuit.
- `src/PureClaw/CLI/Commands.hs` — populate `_fe_agentEnv` from `env`.
- `frontend/src/App.tsx` — system/command bubble rendering.
- Tests under `test/` (CLISpec integration + unit specs).
- A follow-up GitHub issue for interactive commands.
