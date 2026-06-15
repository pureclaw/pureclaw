# Gateway as the Single Source of Truth for Tab State

**Status:** Design intent (captured 2026-06-15). Not yet through the design review
gate. Owner: Doug. Branch context: `feat/tabs-as-view-refactor`.

Related: [tabbed-chat.md](tabbed-chat.md),
[session-tab-unification.md](session-tab-unification.md),
[superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md](superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md).

## Decision

**The gateway runs as a standalone server process and is the single source of
truth for tab state.** Every other surface — the TUI, the web frontend, and the
chat channels — is a *client* that connects to a separately-running gateway and
drives it; none of them owns tab state.

Concretely:

- You launch **one** gateway process. It owns the `TabRegistry`, the cursor
  state, the web frontend, and the channel connections (Signal, etc.).
- The **TUI is a separate client process** that connects to an already-running
  gateway. It does **not** embed, spawn, or auto-start a gateway, and it does
  **not** run its own `TabRegistry`, dispatch loop, or frontend server. If no
  gateway is running, the TUI connects-or-fails (it does not silently start its
  own state); exact behavior is an open question below.

This is explicitly **not** "TUI-as-gateway." The gateway is standalone; the TUI
is a thin client of it.

## Why — the problem this fixes

Today both `pureclaw tui` and `pureclaw gateway run` go through `runChat`
(`src/PureClaw/CLI/Commands.hs`), which starts a frontend server *and* a tabbed
dispatch loop, each backed by an **in-process** `TabRegistry`. Within a single
process that registry is shared correctly — `runChat` wires both
`_env_tabRegistry` and `_fe_tabRegistry` to the same `_ts_tabRegistry`, and
`Frontend.API._fe_tabRegistry` is documented as sharing the SAME `TabRegistry`
so "both views observe the same state." So **one** process is always
self-consistent.

The failure is **multi-process**. Running the TUI and the gateway at the same
time gives you two processes, each of which:

1. loads `~/.pureclaw/state/tabs.json` once at startup into a *private* in-memory
   `TabRegistry`,
2. mutates that private copy independently, and
3. overwrites the file on save.

Nothing syncs the two registries and nothing reloads from disk, so they drift
and clobber each other (last-writer-wins).

Observed on 2026-06-15:

- The web frontend (served by the **tui** process, which won the `:8080` bind)
  showed tab 0 = `"nojoke"`.
- Signal (served by the **gateway** process) showed tab 0 = `"joke"`.
- The gateway's own frontend could not bind `:8080` because the TUI already held
  it — the port collision is the same "two processes, one resource" problem.

## Target architecture

```
                 +---------------------------+
                 |   gateway (standalone)    |
                 |  - TabRegistry  (truth)   |
                 |  - cursor / relay state   |
                 |  - channels (Signal, ...) |
                 |  - HTTP/WS API + frontend |
                 +-------------+-------------+
                               ^
        connect/drive (HTTP/WS or IPC), never own state
          |                    |                    |
   +------+------+      +------+------+      +-------+------+
   |  TUI client |      | web frontend|      | chat channels|
   +-------------+      +-------------+      +--------------+
```

- The gateway is the only process that mutates the `TabRegistry` and persists
  `tabs.json`.
- Clients issue **operations** (switch/focus, rename, close, resume, new, relay
  mode, send text) to the gateway and **render** state the gateway reports
  (snapshots + change events).

## What this requires that does not exist yet

The gateway's HTTP API today exposes some tab lifecycle endpoints
(`POST /api/tabs/new`, `/{n}/close`, `/dismiss`, `/release`, `/destroy`,
`/acknowledge`, `/restart`) and a `GET /api/tabs` list, but it does **not**
expose the full set of tab *operations* the dispatcher supports, and chat input
is not dispatched as commands:

- `Frontend.API.handleSend` routes a message only to the LLM (`doCompletion`) or
  to a harness — it never reaches `TabDispatch`. So `/tab` commands typed into
  the web frontend (or a future TUI client that posts chat) do nothing.
- There is **no rename endpoint**, and no focus/resume/relay endpoints.

So this change must give the gateway a single, authoritative command surface for
tab operations (rename / close / focus / resume / new / relay) that **all**
clients use. A useful side effect: doing so also closes the current gap where the
web frontend cannot run `/tab` commands at all.

## Open design questions (for the design review gate)

1. **Transport.** Reuse the existing HTTP + WebSocket API the web frontend
   already speaks, or introduce a dedicated local IPC/socket for the TUI?
2. **Command surface.** A REST endpoint per operation, or one "dispatch this
   input line" endpoint that runs the existing `TabDispatch` grammar
   server-side? The latter keeps one parser/dispatcher and avoids drift.
3. **Gateway discovery & lifecycle.** How does the TUI locate the running
   gateway (fixed port, config, discovery file)? What is the behavior when none
   is running — clear error and exit, retry/wait, or a guided "start the gateway
   first" message? (Decision: do **not** auto-start or embed one.)
4. **Conversation identity.** The TUI client needs a stable `ConversationKey`
   (channel + conversation id) so the gateway tracks its cursor/relay the same
   way it tracks Signal/CLI conversations.
5. **Live updates.** The TUI must reflect changes made by other clients
   (e.g. a rename from Signal) in real time — presumably by subscribing to the
   gateway's existing lists/activity stream rather than polling.
6. **Safety guard.** Should starting a second *stateful* process (another
   `gateway run`, or the old embedded-TUI path) fail loudly (port-in-use /
   lock file) instead of silently diverging?

## Operational stopgap (until implemented)

Run a **single** process. `gateway run` already serves Signal **and** the web
frontend on `:8080` from one shared registry, so those surfaces stay consistent.
Do not run a standalone `tui` alongside it; that is the configuration that
produces the split-brain described above.
