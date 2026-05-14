# WhatsApp-for-pureclaw — Research Plan

## Goal of the research phase
Decide *how* to bring WhatsApp into pureclaw before committing to a design. The OpenClaw integration assumes a JS runtime and a much richer `ChannelHandle` than pureclaw exposes today — neither is automatic here. Output of the research phase: a written design proposal that answers Q1–Q9 with evidence, ready for `/review-design`.

## Non-goals (yet)
- Picking specific Haskell libraries.
- Writing any production code.
- Choosing PR scope / work-unit decomposition (that's the planning phase).

---

## Q1. Protocol/runtime choice — **DECIDED: wacli sidecar**

Decision (2026-05-13): pureclaw uses [`wacli`](https://github.com/openclaw/wacli) as an external sidecar, exactly mirroring how `Channels.Signal` uses `signal-cli`. wacli is a ~15k LOC Go CLI maintained by Peter Steinberger (openclaw author) that wraps `whatsmeow` and ships as a single binary with Homebrew distribution. We write **no Go** ourselves.

Decision history (for future readers):
- **A. Node sidecar wrapping Baileys** — rejected: adds a Node runtime dependency (or 50MB+ bundled blob).
- **B. Custom Go sidecar wrapping `whatsmeow`** — rejected: maintaining bespoke Go glue when wacli already exists is duplicative.
- **C. WhatsApp Cloud API (Meta)** — explicitly ruled out by user (2026-05-07): wrong product shape (separate business number, templates for proactive messages, public webhook).
- **D. Port `whatsmeow` to Haskell** — rejected: ~124k LOC + Signal protocol implementation; person-years scope, cryptographic-correctness risk that conflicts with pureclaw's security-by-construction pitch.
- **E. wacli sidecar (chosen)** — already does QR pairing, send (text/file/sticker/voice/react with mentions/replies/link-previews), `--events` NDJSON lifecycle stream, `sync --webhook` live inbound delivery, read-only SQLite store as the documented companion-tool integration surface. Multi-account built in. Locking model: while `sync --follow` runs, `send` delegates to that process.

**Nix packaging:** done. `nix/wacli.nix` (buildGoModule, pinned v0.8.0, `sqlite_fts5` build tag, MIT) is wired into `flake.nix` via overlay and added to `shell.buildInputs`. `nix develop . --command wacli --version` returns `wacli 0.8.0`.

**Residual risks worth tracking:**
1. **Bus factor** — wacli is one maintainer. Worth periodic check of release cadence and contributor count.
2. **CLI/JSON-schema drift** — pre-1.0; pin a version and write enough integration tests against `--events` JSON shapes to catch breaks early.
3. **TOS posture** — linked-device mode carries account-ban risk from Meta. Document this for users.

---

## Q2. `ChannelHandle` fit and gap analysis
Pureclaw's `ChannelHandle` is single-sender, plaintext, no media, no streaming. WhatsApp adds: groups, mentions, reactions, replies/quotes, media, polls, typing, read receipts, multi-chat fan-out.

**Investigate:**
- Read `src/PureClaw/Handles/Channel.hs` and `src/PureClaw/Channels/Telegram.hs` and `Signal.hs`. Confirm the `lastSender :: IORef` pattern is universal — it is what makes "groups" awkward.
- Decide *minimum viable* WhatsApp surface for v1. Strawman: text-only, DMs only, single-account, no groups, no media, no reactions. Add the rest as later work units.
- Identify which features need `ChannelHandle` extensions vs. which can live entirely inside `Channels.WhatsApp.*` (e.g. reactions/quotes can be sidecar-local; groups need a routing change).
- Check `Agent.Loop` and `Session.Handle` to see whether multi-conversation (group + multiple DMs concurrently) is even representable today, or whether one agent loop = one conversation.

**Output:** a "what fits, what doesn't" table; a v1 feature scope; a list of `ChannelHandle` extensions (if any) that v1 needs.

---

## Q3. wacli IPC contract — **DECIDED: dual-channel (webhook for messages, `--events` for lifecycle)**

Decision (2026-05-14): inbound message payloads come from `wacli sync --follow --webhook URL` POSTing JSON to a pureclaw-hosted local Warp endpoint; lifecycle/warnings come from the `--events` NDJSON stream on stderr; outbound uses `wacli send …`.

### Why webhook beats `--events` for message data

Reading `internal/app/sync_events.go:183` (`handleLiveSyncMessage`) and `internal/out/events.go`:
- The `--events` NDJSON stream emits lifecycle (`connected`, `disconnected`), sync progress (every 25 messages — *not* per message), `history_sync` (count only), `warning`, `event_handler_panic`, `app_state_*`. **No per-message inbound event.**
- Message data is delivered via two surfaces only: (a) SQLite write to `wacli.db`, (b) `--webhook` POST of `wa.ParsedMessage` (`internal/wa/messages.go:24`).
- Polling `wacli.db` works but adds latency and couples us to a schema marked "may evolve between releases" in `docs/integrations.md`. Webhook is push-driven and the payload is a stable struct.

### Architecture

- **Inbound (messages):** pureclaw spins up an embedded Warp listener on `127.0.0.1:<random-free-port>` per WhatsApp session, generates a fresh HMAC secret, and launches wacli with `sync --follow --webhook http://127.0.0.1:<port>/wacli --webhook-secret <secret>`. The handler validates `X-Wacli-Signature: sha256=<hmac>` (from `internal/app/webhook.go:128`), parses the `ParsedMessage` JSON, applies pureclaw's allowlist, pushes to a `TQueue` consumed by `_ch_receive`. Local-loopback only — no public webhook exposure needed because wacli runs on the same machine.
- **Inbound (lifecycle/errors):** consume `--events` NDJSON from wacli's stderr in a reader thread. Map `connected`/`disconnected` to channel state; route `warning` and `event_handler_panic` to `LogHandle.logWarn`/`logError`. Keep this separate from the message path — it's logging, not control flow.
- **Outbound:** shell out to `wacli send text|file|sticker|voice|react --json …` per send. Locking guarantees (`docs/sync.md:30`) ensure the long-running `sync --follow` process owns the WhatsApp session, and `send` delegates to it instead of spawning a second session.
- **State queries (v2+):** read-only SQLite over `<store>/wacli.db` for history search, contact lookup, etc. Out of scope for v1.

### Event/payload reference

`wa.ParsedMessage` (`internal/wa/messages.go:24`):
```
Chat            types.JID   // group/DM/channel JID
ID              string      // WhatsApp message id
SenderJID       string
Timestamp       time.Time
FromMe          bool
Text            string
Media           *Media      // type/caption/filename/mime/key/sha — nil for text-only
PushName        string
ReplyToID       string
ReplyToDisplay  string
ReactionToID    string
ReactionEmoji   string
IsForwarded     bool
ForwardingScore uint32
StarredKnown    bool
Starred         bool
Revoked         bool
```

`--events` envelope (`out/events.go:17`):
```
{"event": "<name>", "data": {...} | omitted, "ts": <unix-ms>}
```
Event kinds we consume in v1: `connected`, `disconnected`, `warning` (+`code`/`message`), `event_handler_panic`. Ignore in v1: `progress`, `history_sync`, `app_state_*` (informational; webhook covers the data).

### Why this works for both CLI and gateway modes

The webhook listener is embedded *in the WhatsApp channel itself*, not in `Gateway.Server`. The channel is self-contained: `withWhatsAppChannel` brings up the local Warp listener, spawns wacli, returns a `ChannelHandle`, tears both down on exit. Works identically whether pureclaw is in TUI/CLI mode or running the user-facing gateway.

### Output

A `Channels.WhatsApp` module set:
- `Channels.WhatsApp` — `withWhatsAppChannel`, `ChannelHandle` instance.
- `Channels.WhatsApp.Wacli` — `WacliProcess` + lifecycle (`startWacliSync`, `stopWacliSync`); shells out for `send …`.
- `Channels.WhatsApp.Webhook` — Warp listener, HMAC validation, `ParsedMessage` JSON parsing, `TQueue` push.
- `Channels.WhatsApp.Events` — `--events` NDJSON reader thread, `LogHandle` routing.

Test seam: a `WacliTransport` record (mirroring `SignalTransport`) so tests inject canned `ParsedMessage` POSTs and assert on captured `wacli send` invocations.

---

## Q4. Auth & credentials
wacli owns its own store (`<store>/session.db` + `wacli.db`, default `~/.wacli` on macOS, `~/.local/state/wacli` on Linux, override via `--store DIR` or `WACLI_STORE_DIR`). For v1 we delegate credential management entirely to wacli — same model as `signal-cli`.

**Investigate:**
- Confirm `wacli accounts add NAME` / `--account NAME` is the right multi-account seam, or if we point each pureclaw "account" at a separate `--store` dir.
- Decide pureclaw's view of the wacli store path. Strawman: `~/.pureclaw/credentials/whatsapp/<accountId>/` passed to wacli as `--store`, so all integration creds live under `~/.pureclaw` regardless of channel.
- QR pairing UX: pureclaw shells out to `wacli auth --events` and forwards the QR (wacli renders ASCII to stdout already; we may need to capture and rerender). CLI-only flow for v1 — gateway/Telegram/Signal channels can't render QR.

**Output:** the `--store` layout decision + a "first-time pair" flow that the user runs from `pureclaw channels pair --channel whatsapp`.

**Deferred:** wrapping wacli's session keys in pureclaw's vault. wacli expects to own its store; integration would require wacli changes. Park until there's user demand.

---

## Q5. Lifecycle & reconnect
wacli's `sync --follow` owns the reconnect loop internally — read `internal/app/sync.go` and `sync_status.go` to confirm. Pureclaw just needs to:
- launch and supervise the wacli subprocess (mirror `Channels.Signal.Transport`'s `startProcess` / `stopProcess`),
- surface "connected"/"disconnected" lifecycle events from the NDJSON stream into pureclaw logs,
- decide whether the subprocess dying is fatal (Signal's model) or auto-restarted (wacli's locking makes this safe — only one process owns the store).

No watchdog/backoff porting needed on the Haskell side.

---

## Q6. Inbound semantics — access control, mentions, debouncing
OpenClaw has substantial pre-agent filtering (DM/group policies, pairing flow, mention gating, 60s history-grace window, debouncing). Pureclaw's Signal channel has only an `AllowList UserId` check.

**Decide for v1:**
- DM allow-list parity (already trivial — copy the Signal pattern).
- Skip pairing-flow, group-policies, mention gating until groups land (Q2).
- Debouncing: confirm whether typing/streaming behavior in pureclaw makes debouncing necessary or whether we can defer.

**Output:** a list of inbound filters v1 will and won't implement, with rationale.

---

## Q7. Multi-account
OpenClaw is multi-account from the ground up (account id keys the connection-controller registry). Pureclaw's Signal/Telegram channels are single-account.

**Investigate:**
- How hard is it to make the existing `withSignalChannel` shape multi-account? Look for assumptions of single inbox, single `lastSender`.
- For v1, propose single-account with a future-friendly config schema (`[whatsapp.accounts.<id>]` even if only `default` is supported).

---

## Q8. Config schema
Mirror the existing `FileSignalConfig` / `FileTelegramConfig` pattern in `src/PureClaw/CLI/Config.hs`:

```toml
[whatsapp]
account = "default"            # passed to wacli --account
allow_from = ["+1555..."]      # pureclaw-side allowlist, mirrors Signal
dm_policy = "allowlist"        # "allowlist" | "open" | "disabled"
text_chunk_limit = 6000
store_dir = "~/.pureclaw/credentials/whatsapp/default"  # → wacli --store
wacli_path = ""                # blank = $PATH lookup; nix dev shell provides it
```

**Investigate:** read `CLI/Config.hs` and `CLI/Commands.hs` resolution layer; sketch the new codec; extend the `default_channel` enum to include `"whatsapp"`.

---

## Q9. Testing strategy
- Mirror `mkMockSignalTransport` for WhatsApp — a `WhatsAppTransport` mock that feeds canned wacli `--events` NDJSON into the inbox and captures outbound `send` invocations. Inbound-parse specs and outbound-routing specs all run against the mock — no wacli subprocess.
- Real-wacli integration tests: not feasible in CI (pairing requires a real phone scanning a QR). Document a manual smoke-test ritual against a burner WhatsApp account.
- Coverage thresholds: review `.coverage-thresholds.json` to confirm what bar this module is held to before we estimate test scope.

---

## Suggested research order
1. **Q1** — DONE. wacli sidecar, Nix recipe landed.
2. **Q3** — DONE. Webhook for messages, `--events` for lifecycle, embedded local Warp listener.
3. **Q2** + **Q4** in parallel — v1 feature scope and `--store` layout.
4. **Q5–Q9** — refinements that fit into the design doc once the big shape is settled.

## Exit criteria for the research phase
- A design doc that:
  - ~~names the chosen runtime (Q1)~~ — DONE.
  - lists v1 features in scope with explicit "deferred to v2" items (Q2, Q6),
  - ~~documents the wacli IPC choice and event-kind ingestion table (Q3)~~ — DONE.
  - documents the `--store` layout and QR-pairing UX (Q4),
  - states subprocess supervision policy (Q5),
  - shows the TOML config schema (Q8),
  - shows the mock transport plan (Q9).
- Ready to invoke `/review-design` per the project's design-review-gate.
