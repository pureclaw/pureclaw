# Unified pre-inference slash-command dispatch for the web frontend

**Status:** Design approved 2026-06-15; revised 2026-06-16 after design-review gate (round 1)
**Author:** brainstormed with the user, 2026-06-15

## Problem

PureClaw exposes the same agent through several end-user surfaces: the TUI,
chat channels (Telegram/Signal/CLI), and a web frontend. The TUI and channels
route every inbound message through a shared classification stage
(`PureClaw.Routing.Parse.parseInput`) that **short-circuits** slash commands —
parsing and executing them *before* any LLM call. The web frontend does not: its
`handleSend` (`src/PureClaw/Frontend/API.hs:1951`) passes the raw user text
straight to `doCompletion` (or to a harness), so a `/help` typed in the web UI is
sent to the model as ordinary chat.

This breaks two guarantees the project wants:

1. **No slash input should silently reach LLM inference.** `/`-commands are a
   short-circuit point where deterministic processing runs first, so we can
   apply heuristics about when paying the LLM cost is warranted.
2. **All end-user chat paths should go through the same handling.** Behavior
   should not diverge by surface.

## Acceptance statement (user-facing)

> Typing `/help`, `/status`, `/tab list`, etc. in the web UI runs the same
> command the TUI and chat channels run, shows its output, and **never charges an
> LLM call**. Web executes the *same* slash-command set as the TUI and chat; the
> only inputs web drops are the positional routing forms (`/N` Switch and
> `/N payload` Inject), which the web transport already expresses through the
> per-conversation request URL.

## Goals

- Route the web frontend's `handleSend` through the *same* classification and
  short-circuit stage the TUI/channels use, so `/`-commands never reach the LLM.
- **Full command parity** across web / TUI / chat — reuse the existing
  `executeSlashCommand` implementations rather than reimplementing or
  subsetting them, so behavior stays identical and lives in one place.
- Do this through a **transport-agnostic dispatch seam** so the same entry point
  can later back an "expose slash commands to LLM agents as tool calls" feature.
- Make the web transport's **trust boundary explicit** (default localhost) so
  full command parity does not silently expand the network attack surface.

## Non-goals (this spec)

- **Interactive (prompting) commands** completing in the web UI — commands that
  call `_ch_prompt` / `_ch_promptSecret` / `_ch_readSecret` mid-execution (e.g.
  `/provider add`, `/vault set`, Signal register). They are still *recognized and
  short-circuited* (never sent to the LLM); they return a deferral message rather
  than completing. Full interactive support is a tracked follow-up (see
  "Deferred: interactive commands").
- **Positional routing forms on web** (`Switch` = `/0`; `Inject` = `/3 run
  tests`). Short-circuited with a message; never inferred.
- A general **web authentication/pairing model**. Out of scope; the trust
  boundary here is the bind interface (default localhost). Auth remains a
  separate future effort (noted in "Trust model").

## Key findings (verified against code during the design-review gate)

1. **Frontend and agent loop share a process and IORefs (bundled mode).** In
   `src/PureClaw/CLI/Commands.hs:804`, `FrontendEnv` is built from the same cells
   the `AgentEnv` (`env`, built at `Commands.hs:709`, with `sessionRef` at
   `:687`) uses: `_fe_provider = providerRef`, `_fe_model = modelRef`,
   `_fe_harnesses = harnessRef`, `_fe_harnessRegistry = harnessReg`,
   `_fe_tabRegistry`, `_fe_cursors`, `_fe_registry = fullRegistry`, etc. (Note:
   `_fe_provider` / `_env_provider` are both `IORef (Maybe SomeProvider)`,
   `_fe_model` / `_env_model` both `IORef (Maybe ModelId)`.) So slash commands
   that mutate state (`/provider`, `/agent`, `/tab new`) act on the *same* state
   the TUI mutates — no split-brain in bundled mode.

2. **No import cycle.** `Agent.SlashCommands`, `Agent.Env`, `Routing.*`, and
   `Tabs.*` do not import `Frontend.API`. `Agent.Env`'s dependency on
   `Frontend.StreamBroker` is a leaf module and introduces no cycle. So
   `Frontend.API` may import `Agent.SlashDispatch` / `Agent.Env` / `Routing.Parse`.

3. **Slash classification is independent of tab kind, and precedes harness
   routing.** In the TUI, `routeGrammar` (`TabDispatch.hs:536-544`) calls
   `parseInput` *before* any tab-kind decision; `ParsedSlashCmd` always runs
   `executeSlashCommand` (`Wiring.hs:667-679`), an unrecognized `/foo` becomes
   `Left ParseErrorMalformed` and is shown as an error, and only `Default`
   (non-slash) text is relayed to the active tab — to a harness runtime when the
   ref is `BoundHarness` (`doDefault`, `TabDispatch.hs:582-600`). The web design
   short-circuiting slashes **before** its harness branch therefore matches the
   TUI exactly. **Intentional behavior change:** today the web forwards
   `/anything` into a harness pane (so claude-code-native slashes reach the
   harness); after unification it intercepts them like the TUI. This is the
   desired consistency. (A future "escape hatch to forward a literal slash to the
   active harness" is out of scope.)

4. **Slash output is display-only, never LLM context.** In the TUI a command
   emits via `_ch_send`; the text is shown but not added to message history. The
   web frontend rebuilds LLM context by replaying the transcript
   (`loadRecentMessages`, `src/PureClaw/Session/Handle.hs:747` — every
   `Request`→`User`, every `Response`→`Assistant`); there is **no display-only
   entry kind**. Decision: web slash output is **transient, not persisted**
   (matches TUI ephemerality), sidestepping any feedback into the model.

5. **`executeSlashCommand` needs a full `AgentEnv`**
   (`src/PureClaw/Agent/SlashCommands.hs:944`,
   `:: AgentEnv -> SlashCommand -> Context -> IO Context`) and emits via
   `_ch_send` on `_env_channel`. Nearly every `AgentEnv` field is process-global
   shared state the frontend already holds; only `_env_channel` (must capture
   output) and `_env_session` (must point at the request's `{sid}`) vary per
   request.

6. **Capture is trivial; per-`{sid}` sessions are cheap to build.**
   `ChannelHandle` (`src/PureClaw/Handles/Channel.hs:57`) is a record of IO
   actions. `mkSessionHandle` (`src/PureClaw/Session/Handle.hs:177`) builds a
   `SessionHandle` from on-disk meta — but it has filesystem side effects
   (`createDirectoryIfMissing`, `setFileMode 0o700`, `saveMeta` rewriting
   `session.json`) on **every** call, so it must be built lazily (see design).

7. **Web API trust posture today (drives the trust-model decision).**
   `mkFrontendSettings` (`src/PureClaw/Frontend/Server.hs:66-70`) sets only port
   + timeout — **no `setHost`**, so Warp binds `0.0.0.0` (all interfaces). There
   is **no authentication** on `/api/*`, and `Stream.hs:290-296` documents LAN
   reach as intended ("any client able to reach the configured bind address can
   hit the HTTP routes today"). Chat channels, by contrast, gate *who* may issue
   commands via a per-user allow-list. Reusing the full command surface on web
   without a comparable boundary would make `/mcp connect` (which runs an
   arbitrary local program — `SlashCommands.hs:1291`) a network-reachable RCE.

## Trust model

Full command parity is safe **because the web transport's default trust boundary
is the local user**, who already has shell access (so `/mcp connect` is no
escalation for them):

- **Default bind: `127.0.0.1`.** Add `Warp.setHost` to `mkFrontendSettings`,
  driven by a new `FrontendConfig` field (default `"127.0.0.1"`).
- **Configurable bind interface.** A new CLI flag (and config field) lets the
  user choose the bind host — a specific interface, or `0.0.0.0` (e.g. when the
  machine is reachable only over a trusted VPN). Choosing a non-loopback host is
  an explicit, documented opt-in: the help text / docs state that it **exposes
  the full slash-command surface (including local code execution via
  `/mcp connect`) to anything that can reach that address**; use only on trusted
  networks.
- **Fail loud on non-loopback bind.** When the configured bind host is not a
  loopback address, emit a startup `WARN` to stderr (mirroring the existing
  channel allow-list `AllowAll` warning pattern and the project's "fail loud"
  principle) so an operator who opts into wide exposure gets a runtime reminder,
  not just docs. The danger is also stated inline in the CLI flag's `--help`
  text (the closest point-of-decision), not only in prose.
- **CORS must follow the bind host.** `corsMiddleware`
  (`Server.hs:75-91`) currently hard-codes `Allow-Origin` to
  `http://localhost:<port>`. For a non-loopback bind the frontend's own requests
  would otherwise be rejected, making the opt-in unusable; the allowed origin
  must reflect the configured host so the opt-in path actually works.
- This closes the design-review security blocker without subsetting commands:
  wide exposure becomes an informed choice rather than a silent default. A proper
  per-caller **auth/pairing model** for non-loopback binds is acknowledged as a
  separate future effort and is out of scope here.

## Design

### Reuse strategy: a transport-agnostic dispatch seam

New module `PureClaw.Agent.SlashDispatch` exposing:

```haskell
data SlashResult
  = SlashHandled !Text      -- command (or routing/parse error) handled;
                            -- text is the user-facing output. Do NOT infer.
  | SlashPassThrough !Text  -- ordinary chat; caller proceeds to inference.

-- The env passed in must already be scoped to the target conversation:
-- _env_channel = a capture channel, _env_session = a FRESH IORef over the
-- request's SessionHandle (never the shared process-global session ref).
runSlashInput :: AgentEnv -> Text -> IO SlashResult
```

`runSlashInput` calls `parseInput (_env_routingConfig env) raw` and maps:

| `parseInput` result        | `runSlashInput` result |
|----------------------------|------------------------|
| `Right (Default raw)`      | `SlashPassThrough raw` |
| `Right (ParsedSlashCmd c)` | run `executeSlashCommand env c ctx` against the capture channel; `SlashHandled <captured>` |
| `Right (Switch _)`         | `SlashHandled "Tab switching isn't typed as /N in the web client — use the tab controls."` |
| `Right (Inject _ _)`       | `SlashHandled "Cross-tab send isn't available from the web client yet."` |
| `Left parseErr`            | `SlashHandled <user-friendly render>` (e.g. "Unknown command: /foo. Try /help.") |

Only `SlashPassThrough` ever continues to inference. Every leading-`/` input is
short-circuited — satisfying goal #1 — and classification is identical to the
TUI because it is literally the same `parseInput`. `ParseError` values are
rendered to **user-friendly** strings (not constructor names like
`ParseErrorMalformed`), including the distinct `ParseErrorInvalidSessionId` arm
for `/tab resume <bad-id>`.

Why a seam rather than inlining in `handleSend`: the future "expose slash
commands to LLM agents as tool calls" path reuses exactly this `runSlashInput`
(env scoped to the agent's session, capture channel, text in → text out). The
seam keeps that one entry point. (Interactive commands are unavailable to the
tool-call path too — they throw `InteractiveUnsupported`, same as on web — so the
reuse story holds end to end.)

### `Context` handling

The caller builds `ctx` from the request session's transcript via
`loadRecentMessages` (the same source `doCompletion` uses), so read-only commands
like `/status` report accurate message/token counts. The `Context` *returned* by
`executeSlashCommand` is **discarded**: output is transient and the frontend
rebuilds LLM context from the transcript next turn, so in-memory `Context`
mutations do not round-trip.

Consequence to document and test (not a regression in the LLM-context guarantee):
`/new` (`SlashCommands.hs:969-971`) returns `clearMessages ctx` and emits
"Session cleared"; discarding the returned `ctx` means over the web `/new`
**emits the message but does not itself clear persisted history**. `/session new`
(`SlashCommands.hs:2349-2364`) writes `_env_session` and returns a fresh context;
run against the per-request (fresh, discarded) session ref it **creates a new
on-disk session that appears in the session list, but the web client does not
auto-switch to it**. Both are documented as the observed v1 behavior and pinned
by tests, not special-cased.

### Capture channel

In `PureClaw.Handles.Channel`:

```haskell
data InteractiveUnsupported = InteractiveUnsupported !Text  -- the prompt label
  deriving Show
instance Exception InteractiveUnsupported

-- Returns the handle plus a reader for the accumulated output.
mkCaptureChannelHandle :: IO (ChannelHandle, IO Text)
```

- `_ch_streaming = False` so commands use `_ch_send` (full message), not chunks.
- `_ch_send`, `_ch_sendError`, `_ch_sendChunk` append to a shared `IORef`
  buffer; the reader concatenates buffered output (joined by newlines). (`_ch_sendError`
  output is captured too; a future refinement may tag it so the frontend can
  style command errors distinctly — see Suggestions.)
- `_ch_prompt`, `_ch_promptSecret`, `_ch_readSecret` **throw**
  `InteractiveUnsupported <label>`. This is the runtime partition between
  interactive and non-interactive commands — no command enumeration needed.
- `_ch_receive` must be total under `-Wall`: it `throwIO`s a clear error
  (no command should ever pull input from a capture channel).

`runSlashInput` wraps **only** `executeSlashCommand` in
`try @InteractiveUnsupported`. On catch it returns `SlashHandled` with a precise
deferral message — *"`/provider add` needs interactive input, which the web UI
doesn't support yet (tracking: <issue-url>). Use the CLI for now."* — that
**includes any output buffered before the throw** (the buffer is read after the
catch). The `<issue-url>` is the real follow-up issue (a hard requirement: no
dangling placeholder ships).

### Per-request env scoping

`runSlashInput`'s caller supplies the shared base `AgentEnv` with two fields
swapped, **lazily, only once classification yields `ParsedSlashCmd`** (so plain
pass-through chat and the harness path never pay a `session.json` rewrite):

- `_env_channel` → the capture channel from `mkCaptureChannelHandle`.
- `_env_session` → **a fresh `IORef`** (`newIORef =<< mkSessionHandle …`) over a
  `SessionHandle` for the request's `{sid}` (meta from `_fe_sessionsDir`, broker
  `_fe_broker`, logger `_fe_logger`). It MUST be a new ref — never `writeIORef`
  into the shared process-global session ref — or concurrent web requests and the
  TUI would clobber each other's active session. (`doCompletion` already builds a
  fresh `SessionHandle` per call: `API.hs:1772`, `:1637`.)

To reach the base env from the frontend, add one field to `FrontendEnv`:

```haskell
, _fe_agentEnv :: AgentEnv   -- shared base env; channel/session overridden
                             -- per request by runSlashInput's caller. LAZY —
                             -- a back-edge mirroring the existing
                             -- _env_onTabsChanged / _env_startHarness thunks
                             -- in the Commands.hs recursive let; no bang.
```

populated in `src/PureClaw/CLI/Commands.hs:804` where `env :: AgentEnv` is
already in scope. `-Werror` (`-Wincomplete-record-updates` / missing-field) means
**all four `FrontendEnv` construction sites** must add the field:
`Commands.hs:804` (production), `test/Frontend/APISpec.hs:3391`,
`test/Frontend/StreamHarness.hs:87`, `test/Frontend/ActivityProbeSpec.hs:132`.

**Concurrency note (accepted):** several v1 commands mutate the *shared* base-env
refs — `/provider`/`/target` write `_env_provider`/`_env_model`/`_env_target`
(`SlashCommands.hs:1067,1077,1480,1481`). Two concurrent web requests could
interleave these. This is last-writer-wins, identical to the TUI's accepted
single-process model and benign under the default single-user-local trust
boundary. Documented here so it is a stated decision, not an unflagged race.

### `handleSend` integration

Classification happens **first**, before both the harness branch and the provider
branch, so `/`-commands work in harness-backed sessions and on instances with no
provider configured:

```
handleSend:
  validate sid (isValidSessionId); ensure transcript exists; decode {message, model?}
  res <- runSlashInput (scope baseEnv to capture-channel + fresh {sid} session) message
         -- the scoping (capture channel + mkSessionHandle) is built lazily
         -- inside runSlashInput only for the ParsedSlashCmd branch
  case res of
    SlashHandled out  -> respond 200 {"response": out, "kind": "slash"}   -- transient, NOT persisted
    SlashPassThrough _ -> <existing logic unchanged>:
        harness branch (SkHarness) | provider branch (doCompletion), each → {"kind":"assistant"}
```

The existing harness/provider path is untouched for non-slash input.

### Response envelope (server-authoritative discriminator)

The send response gains an explicit `kind` field so the client never re-derives
"was this a slash result" by re-parsing the request:

```json
{ "response": "<text>", "kind": "slash" | "assistant" }
```

`handleSend` sets `kind` from the `SlashResult` constructor (`slash` for
`SlashHandled`, `assistant` for the `doCompletion`/`sendToHarness` paths). The
frontend keys rendering off `kind`, removing the brittle client-side
"message started with `/`" heuristic and its coupling to the routing grammar.

### Frontend (`frontend/src/`)

- **`useApi.ts` / `useSendMessage`** currently ignore the success body and render
  assistant turns from the transcript stream. Slash responses never enter the
  transcript, so the hook must **read the 200 body**, and when `kind === "slash"`
  surface the text through a **separate transient-bubble state** that lives
  outside the transcript-derived `useMemo` (which is rebuilt from entries on every
  refresh).
- That transient path **bypasses the optimistic pending/thinking machinery** in
  `App.tsx` (the `pending-user` / `pending-thinking` blocks cleared by
  `entries.length` growth). A slash send adds no transcript entry, so reusing that
  machinery would strand a "thinking" indicator forever. No thinking indicator is
  shown for slash dispatch.
- The slash bubble renders as a muted **system/command** style with a small
  "command output — not saved" affordance, so its disappearance on reload is not
  surprising. The transient state holds an **ordered list** appended in send
  order (so `/help` then `/status` shows both, newest last), interleaved with
  real turns by time. In v1, output emitted via `_ch_sendError` renders in the
  same muted bubble as success output (no distinct error styling — a conscious
  v1 decision; styling is the S5 future refinement).
- The client treats `kind` as an **open enum**: unknown values fall back to
  default (assistant) rendering rather than asserting the two-value union, so the
  future interactive path can add a third kind (e.g. `slash-prompt`) without
  breaking older clients.

> Module layering: `Frontend.API` imports `Agent.SlashDispatch` / `Agent.Env` /
> `Routing.Parse`; none import `Frontend.API` (finding #2). No cycle.

## Command coverage

**All recognized slash commands execute** (full parity), reusing
`executeSlashCommand`. This includes side-effecting ones (`/provider`, `/agent`,
`/mcp`, `/harness`, `/tab*`, `/bg`, `/msg`), which is safe under the
default-localhost trust boundary. The only inputs web does **not** execute:

- `Switch` / `Inject` (`/0`, `/3 …`) — short-circuited with a message (transport
  expresses conversation selection via the `{sid}` URL).
- Interactive commands — recognized and short-circuited, but return the deferral
  message instead of completing (deferred; see below).

## Deferred: interactive commands (follow-up GitHub issue)

A command like `/provider add anthropic` is a single blocking IO action that
pauses mid-execution at each prompt and may chain several prompts (a wizard inside
one `executeSlashCommand` call). Supporting it over the web needs a
**bidirectional streaming channel**, not just output capture:

1. Run the command on a **background thread** so the HTTP request returns
   immediately.
2. On each `_ch_prompt`, publish a *prompt* event via the existing
   `StreamBroker`/SSE (browser shows an input box) and **block** the command
   thread on a per-session rendezvous (`MVar`/`TBQueue`).
3. Add an **uplink endpoint** (`POST /api/sessions/{sid}/prompt-reply`) that fills
   the rendezvous and resumes the thread. (Its auth posture must be revisited with
   the trust model — it resumes a blocked privileged command.)
4. Correlate replies to the pending prompt; handle abandonment (tab closed
   mid-wizard) via cancellation/timeout.
5. Add **frontend UI** to render the inline prompt and send the reply.

The v1 seam swaps this channel in **without reworking the dispatch**:
`runSlashInput` is unchanged; only the channel implementation and surrounding
execution model change. Filed as a GitHub issue as part of this work; its URL is
embedded in the v1 deferral message.

## Testing (TDD, coverage per `.coverage-thresholds.json`)

Red-first; CLISpec-style integration plus unit. The new pure modules
(`SlashDispatch`, the capture channel) are unit-testable (text in → `SlashResult`
out; `IORef` buffer) and should reach ~100% deterministically. The `handleSend`
glue lands in `Frontend.API` (already coverage-waived), but **new decision logic
must be exercised** via CLISpec/APISpec, not hidden under the waiver. Watch HPC
for unreachable arms (e.g. exercise every `parseInput` variant; the project's
convention of collapsing structurally-unreachable branches into `error` applies).

Test infrastructure: there is no shared `mkTestAgentEnv` today (every test inlines
a ~30-field `AgentEnv` literal). **Extract `mkTestAgentEnv`** so the three
`FrontendEnv` test helpers can supply `_fe_agentEnv` without three large literals.

Cases:

- `POST /send` with `/help` returns the help text with `kind:"slash"` **and the
  provider is not called** (no new `Request`/`Response` transcript entries).
- `/status` succeeds with **no provider configured** (no 503) — short-circuit
  precedes the provider guard — and reflects real counts (ctx from transcript).
- A plain message still routes to the provider (and to a harness for `SkHarness`)
  unchanged, with `kind:"assistant"`.
- **Harness session + slash**: in a `SkHarness` session, `/help` short-circuits
  **before** the harness branch (does not relay into the harness); plain text
  still relays to the harness.
- `/tab new` runs against the shared `TabRegistry` (observable from the registry
  the TUI shares); `/0` (Switch) and `/foo` (parse error) short-circuit with a
  message and do not call the provider; `/tab resume <bad-id>` yields the distinct
  `ParseErrorInvalidSessionId` render.
- **Interactive**: `/provider add` returns the deferral message (with the issue
  URL) and does not hang; a command that emits `_ch_send` output **then** throws
  `InteractiveUnsupported` includes the buffered text in the deferral.
- `/new` over web emits "Session cleared" but leaves the transcript unchanged
  (observed-behavior pin); `/session new` creates an on-disk session without
  auto-switching.
- **Concurrency**: two requests with different `{sid}` use independent fresh
  session refs and do not cross-contaminate (per-request `_env_session` isolation).
- **Capture channel unit**: buffers **multiple** `_ch_send` messages joined by
  newline; `_ch_sendError` and `_ch_sendChunk` also append; `_ch_streaming` is
  `False`; `_ch_prompt`/`_ch_promptSecret`/`_ch_readSecret` throw
  `InteractiveUnsupported`; `_ch_receive` throws.
- **Bind config**: default settings bind `127.0.0.1`; a configured bind host is
  honored by `mkFrontendSettings` (`setHost`); CLI flag parses into the config.
- **Dispatch unit**: each `parseInput` variant
  (`Default`/`ParsedSlashCmd`/`Switch`/`Inject`/`Left`) maps to the correct
  `SlashResult`.

## Affected surface

- `src/PureClaw/Handles/Channel.hs` — `mkCaptureChannelHandle`,
  `InteractiveUnsupported`.
- `src/PureClaw/Agent/SlashDispatch.hs` — new module: `SlashResult`,
  `runSlashInput`.
- `src/PureClaw/Frontend/API.hs` — `_fe_agentEnv` field; `handleSend`
  short-circuit; `kind` in the response envelope.
- `src/PureClaw/Frontend/Server.hs` + `FrontendConfig` — `setHost` driven by a
  configurable bind host (default `127.0.0.1`).
- `src/PureClaw/CLI/Commands.hs` — populate `_fe_agentEnv` from `env`; new
  bind-host CLI flag → config.
- `frontend/src/useApi.ts`, `frontend/src/App.tsx` — read the success body;
  transient system/command bubble keyed on `kind`, outside the optimistic
  machinery; "not saved" affordance.
- Tests: `mkTestAgentEnv` helper; updates to the 3 `FrontendEnv` test helpers
  (`APISpec.hs:3391`, `StreamHarness.hs:87`, `ActivityProbeSpec.hs:132`); new
  CLISpec/APISpec + unit specs per the cases above.
- A follow-up GitHub issue for interactive commands (URL embedded in the v1
  deferral message).
