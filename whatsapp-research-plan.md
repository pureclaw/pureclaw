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

## Q2. `ChannelHandle` fit and v1 feature scope — **DECIDED: single-DM, no extensions**

Decision (2026-05-14): v1 is single-DM only — one specific E.164 peer, plain text in/out, no groups, no media, no reactions surfaced to the agent. **No `ChannelHandle` extensions needed.**

### Why single-DM

`ChannelHandle` (`src/PureClaw/Handles/Channel.hs:43`):
- `_ch_receive :: IO IncomingMessage` returns a single stream
- `_ch_send :: OutgoingMessage -> IO ()` writes to an implicit "current" target
- Both Signal (`Channels/Signal.hs:46`) and Telegram (`Channels/Telegram.hs:46`) hold the most recent sender in an `IORef` and reply there
- `IncomingMessage = { _im_userId :: UserId, _im_content :: Text }` — text-only, no media, no metadata

`Agent.Loop.runAgentLoopWith` (`src/PureClaw/Agent/Loop.hs:53`) is a tight `receive → respond → receive` loop owning a single `Context` (transcript). Two interleaved chats would corrupt context. **One agent loop = one conversation.**

Multi-chat / group support would require either (a) per-chat agent loops and session contexts, or (b) routing metadata threaded through `IncomingMessage`/`OutgoingMessage`. Both are nontrivial cross-cutting changes — out of scope for v1.

### v1 feature matrix

| Feature | v1? | Why / how |
|---|---|---|
| Inbound text from a single configured E.164 | ✅ | webhook → allowlist filter → `IncomingMessage` |
| Outbound text replies, chunked | ✅ | shell out `wacli send text --to <E.164> --message …`; reuse `chunkMessage` from Signal |
| Connection lifecycle logging | ✅ | `--events` `connected`/`disconnected` → `LogHandle` |
| DM allowlist (allow_from) | ✅ | mirrors `SignalConfig._sc_allowFrom`; reject anything not from the configured peer |
| Groups (in or out) | ❌ | requires multi-chat routing; defer to v2 |
| Media (in or out) | ❌ | `IncomingMessage` is text-only; defer to v2 with a richer message type |
| Reactions (receive) | ❌ | `ParsedMessage.ReactionEmoji` ignored in v1 |
| Reactions (send) | ❌ | no use case in v1 (agent emits text) |
| Reply quoting / mentions | ❌ | `ParsedMessage.ReplyToID`/`ReplyToDisplay` ignored in v1 |
| Multi-account | ❌ | one `default` account per pureclaw instance for v1 |
| History sync exposure | ❌ | data lands in `wacli.db`; v1 doesn't read it |
| Self-chat mode (linked number = configured peer) | ❌ | OpenClaw concept; defer until needed |

**Inbound filtering (the dropping rules):**
- `ParsedMessage.FromMe == true` → drop (echo of our own send)
- `ParsedMessage.Chat` not a DM (group/channel JID) → drop
- `ParsedMessage.SenderJID` E.164 not in `allow_from` → log + drop
- Otherwise: push `IncomingMessage { _im_userId = UserId <senderE164>, _im_content = ParsedMessage.Text }` onto the inbox queue

**Output:** ready for the design doc — module boundaries from Q3 hold, no new types in `Handles.Channel.*`.

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

## Q4. Auth & credentials — **DECIDED: delegate to wacli, `--store ~/.pureclaw/credentials/whatsapp/default`**

Decision (2026-05-14): pureclaw passes wacli `--store ~/.pureclaw/credentials/whatsapp/default`. We do not use `wacli accounts` (that's wacli's own multi-account config layer; we'd just be coordinating two systems that mean the same thing). Vault wrapping is explicitly deferred.

### Why not `wacli accounts`

`docs/accounts.md`: `--store DIR` and `--account NAME` are mutually exclusive; `--account` resolves through wacli's `<base>/config.yaml`. For pureclaw v1 (single account) using `--store` directly is one less coordination surface — the path *is* the identifier.

For v2 multi-account, we revisit: we either keep using bare `--store` (one path per pureclaw account) or adopt `wacli accounts add` and hand wacli's config the source of truth.

### Why not vault-wrapped credentials

`Security/Vault.hs:54` — `VaultHandle` is a `Text → ByteString` key/value store designed for small secrets (API tokens, passphrases). The vault holds at most a few KB per key. wacli's `session.db` is a SQLite database with whatsmeow's signal-protocol key store — multi-MB, mutated continuously by the running sidecar.

To wrap this we'd need wacli to accept its store contents over stdin/socket on startup and stream changes back out. That's a wacli upstream change. For v1: wacli owns the store on disk; pureclaw owns the *path*. The store dir lives under `~/.pureclaw` so it sits next to vault data and inherits the same backup/permissions story even if not encrypted.

Set the dir to mode `0700` on creation (mirrors how vault paths are protected). That's the security boundary for v1.

### QR pairing flow

`wacli auth --events --qr-format text` (confirmed in `cmd/wacli/auth.go:163`):
- Emits `auth_starting`, then `qr_code` (with raw payload), then on completion exits with `authenticated: true`
- Also emits `pair_code` events if `--phone PHONE` supplied (alternative pairing — defer for v1 unless trivial)

Pureclaw flow:
1. New slash command `/whatsapp pair` (CLI channel only — gated by `_ch_streaming || isCLI`).
2. Spawn `wacli auth --store <dir> --qr-format text --events`.
3. Read NDJSON from stderr; on `qr_code` event extract `data.code` (raw payload).
4. Render ASCII QR locally — Haskell library options: [`qrcode`](https://hackage.haskell.org/package/qrcode) (pure Haskell). Add to cabal deps.
5. Display QR in the terminal via `_ch_send` (use `OutgoingMessage` with embedded ASCII).
6. On `authenticated` / process exit success → log "WhatsApp paired as +<phone>".
7. On non-CLI channels: refuse with "WhatsApp pairing must be initiated from the TUI/CLI".

Auth state check on channel startup: shell out `wacli auth status --json --store <dir>` (`cmd/wacli/auth.go:198`); refuse to start `sync --follow` if not authenticated; tell the user to run `/whatsapp pair`.

### Permissions & secrets

- `<store>` dir created with mode `0700`
- HMAC webhook secret: generated fresh per session via `getRandomBytes 32`, base64-encoded, passed to wacli via `--webhook-secret`. Not persisted.
- The webhook listener binds to `127.0.0.1` only — never `0.0.0.0`.

**Output:** ready for the design doc — store layout + pair flow + permissions all specified.

---

## Q5. Lifecycle & reconnect — **DECIDED: inherit Signal's "let it die" model**

Decision (2026-05-15): pureclaw does not auto-restart wacli. Mirror `Channels.Signal.readerLoop`'s explicit comment (`src/PureClaw/Channels/Signal.hs:87` — *"Don't restart — let the channel die, agent loop will get IOError"*). The agent loop already handles `IOException` from `_ch_receive` cleanly (`src/PureClaw/Agent/Loop.hs:75`).

### Failure model

| Failure | Owner | Pureclaw response |
|---|---|---|
| WhatsApp Web socket drops (network blip, server-side disconnect) | wacli `sync --follow` | nothing — wacli reconnects internally with its own backoff |
| App-state LTHash mismatch | wacli | log the `warning` event from `--events` stream; wacli requests recovery automatically |
| wacli process crashes (panic, OOM, signal) | OS | reader thread sees EOF on stderr → log → channel handle's `receive` throws `IOException` → agent loop exits cleanly → user restarts pureclaw |
| Webhook listener crashes (Warp exception) | pureclaw | propagate to channel handle so the whole channel tears down — partial state (wacli running but no inbox consumer) would be worse than a clean restart |
| `--events` reader thread crashes | pureclaw | log; do not bring down the channel — events are auxiliary, the webhook path keeps working |

### What we do build

- `withWhatsAppChannel` brackets:
  - spawn wacli `sync --follow …` (via `typed-process`, same as Signal)
  - start Warp on `127.0.0.1:<port>` for the webhook
  - start the `--events` reader thread
  - return `ChannelHandle`
  - cleanup: kill wacli, shut Warp, kill reader thread
- One supervised-failure point: if wacli exits non-zero, log its last 50 lines of stderr (so the user can diagnose) before the channel handle throws.

### What we don't build

- No watchdog/backoff/auth-unstable porting from OpenClaw's `monitorWebChannel`.
- No subprocess auto-restart loop.
- No state-machine for "linked but disconnected" vs "linked and connected" — wacli's `connected`/`disconnected` events are surfaced to logs only.

---

## Q6. Inbound semantics — **SUBSUMED by Q2**

The inbound filter rules are now specified in Q2's "Inbound filtering" section: drop self-echoes (`FromMe`), drop non-DM chats (group/channel JIDs), drop senders not in `allow_from`. No debouncing in v1 (pureclaw's agent loop is synchronous — there's no streaming-into-mid-response problem to debounce). No pairing-flow (handled by `/whatsapp pair`, not inbound). No mention gating (no groups in v1).

---

## Q7. Multi-account — **DEFERRED to v2**

Single-account in v1 (decided in Q4). Config schema in Q8 uses a flat `[whatsapp]` block — no `[whatsapp.accounts.<id>]` nesting yet. When v2 needs multi-account, the path forward is either (a) nest under `[whatsapp.accounts.<id>]` TOML tables and route by id, or (b) adopt `wacli accounts add` and let wacli's own config.yaml be the source of truth. That decision waits until there's a real second-account use case to ground it.

---

## Q8. Config schema — **FINAL TOML**

```toml
[whatsapp]
# Required: the single E.164 peer this channel will DM with. v1 is single-DM
# (Q2); the channel refuses to start if this list is empty or has != 1 entry.
# Field name matches Signal's allow_from for parity and to keep the door open
# for multi-peer in v2 without a rename.
allow_from = ["+15551234567"]

# Optional: where wacli's session.db + wacli.db live. Created with mode 0700
# on first run if missing. Default: ~/.pureclaw/credentials/whatsapp/default
# store_dir = "~/.pureclaw/credentials/whatsapp/default"

# Optional: explicit wacli binary path. Default: lookup "wacli" on $PATH
# (the nix dev shell provides it; brew install steipete/tap/wacli also works).
# wacli_path = "wacli"

# Optional: outbound message chunking, mirrors Signal. WhatsApp's hard limit
# is ~64k chars; 6000 is a safe default that splits on paragraph boundaries.
# text_chunk_limit = 6000
```

And the existing `default_channel` enum (`FileConfig._fc_defaultChannel`) gains `"whatsapp"`:

```toml
default_channel = "whatsapp"
```

**Haskell side** (`src/PureClaw/CLI/Config.hs`):

```haskell
data FileWhatsAppConfig = FileWhatsAppConfig
  { _fwac_allowFrom      :: Maybe [Text]
  , _fwac_storeDir       :: Maybe Text
  , _fwac_wacliPath      :: Maybe Text
  , _fwac_textChunkLimit :: Maybe Int
  }
```

Plus the codec entry in `fileConfigCodec`:

```haskell
<*> Toml.dioptional (Toml.table fileWhatsAppConfigCodec "whatsapp") .= _fc_whatsapp
```

And the resolver in `CLI/Commands.hs` mirrors `resolveSignalConfig`:

```haskell
resolveWhatsAppConfig :: FileConfig -> WhatsAppConfig
```

returning a fully-resolved `WhatsAppConfig` with defaults applied. The CLI dispatch (`case effectiveChannel of "whatsapp" -> ...`) checks `wacli auth status --json` before spawning `sync --follow`, prints a "run /whatsapp pair" message if unauthenticated, and falls back to CLI channel — same pattern as the existing signal-cli not-installed branch.

---

## Q9. Testing strategy — **FINAL**

### Transport seam

A `WhatsAppTransport` record mirrors `SignalTransport` (`src/PureClaw/Channels/Signal/Transport.hs:27`):

```haskell
data WhatsAppTransport = WhatsAppTransport
  { _wat_inboundWebhook :: TQueue ParsedMessage   -- consumed by ChannelHandle._ch_receive
  , _wat_inboundEvents  :: TQueue WaEvent         -- consumed by the events reader thread
  , _wat_send           :: Text -> Text -> IO ()  -- recipient E.164 -> body -> IO ()
  , _wat_authStatus     :: IO Bool                -- did wacli report authenticated?
  , _wat_close          :: IO ()
  }
```

- **Real implementation** (`mkWacliTransport`): spawns `wacli sync --follow --webhook 127.0.0.1:<port> --webhook-secret <hex> --events`, runs Warp on the local port, parses HMAC-signed `ParsedMessage` JSON into `_wat_inboundWebhook`, parses NDJSON from stderr into `_wat_inboundEvents`. `_wat_send` shells out `wacli send text --to E.164 --message …`. `_wat_authStatus` shells out `wacli auth status --json`.
- **Mock implementation** (`mkMockWhatsAppTransport`): caller pushes pre-built `ParsedMessage` values into `_wat_inboundWebhook` and `WaEvent` values into `_wat_inboundEvents`; `_wat_send` writes to a `TQueue (Text, Text)` the test inspects. Used everywhere except a single integration smoke test.

### Test surfaces (mock-backed, run in CI)

1. **HMAC validation** (`Channels.WhatsApp.WebhookSpec`):
   - Valid signature → payload accepted.
   - Wrong/missing signature → 401, no inbox push, warning logged.
2. **`ParsedMessage` parsing** (`Channels.WhatsApp.WebhookSpec`):
   - Text-only DM → `IncomingMessage { _im_userId, _im_content }`.
   - Media-only → drop (v1: log + skip).
   - Group JID (`@g.us`) → drop.
   - Channel JID (`@newsletter`) → drop.
   - `FromMe = true` → drop (self-echo).
   - Sender not in `allow_from` → drop with allow-list-block log.
3. **Outbound routing** (`Channels.WhatsApp.WacliSpec`):
   - `_ch_send` calls `_wat_send` with the configured E.164 and the message text.
   - Chunking at `text_chunk_limit` splits a long message on paragraph boundaries (reuse `chunkMessage` from `Signal.Transport`).
4. **`--events` ingestion** (`Channels.WhatsApp.EventsSpec`):
   - `connected` / `disconnected` → log entries at info / warn.
   - `warning` event → log error with `code` + `message` fields.
   - `qr_code` event (when paired in `auth` mode) → captured for the QR-pair flow.
   - Malformed JSON line → log warn, skip, continue reading.
5. **Lifecycle** (`Channels.WhatsApp.LifecycleSpec`):
   - `withWhatsAppChannel` cleans up Warp and the (mocked) subprocess on normal exit.
   - `withWhatsAppChannel` cleans up on exception in the action.

### Integration test (gated, manual)

One `test/Integration/WhatsAppFlowSpec.hs` test that runs only when `PURECLAW_WACLI_INTEGRATION=1` is set, asserting end-to-end against a real wacli at a paired test store. Skipped in CI. Documented in the test file's docstring as the manual smoke-test recipe:

1. `mkdir -p ~/.pureclaw/credentials/whatsapp/test`
2. `nix develop . --command wacli --store ~/.pureclaw/credentials/whatsapp/test auth` — scan QR with burner phone
3. `PURECLAW_WACLI_INTEGRATION=1 nix develop . --command cabal test pureclaw-test --test-options="--match=WhatsApp"`
4. From the burner phone, message the linked account; verify the test sees an `IncomingMessage` and `wacli send` produces an outbound message visible in the chat.

### Coverage gate

`.coverage-thresholds.json` requires **100% lines / branches / functions / statements** with `cabal test --enable-coverage`. Mock-backed specs above plus the existing test patterns in `test/Channels/SignalSpec.hs` and `test/Channels/SignalTransportSpec.hs` should be sufficient — the real `mkWacliTransport` is the only piece that resists unit coverage (live process + sockets), so it needs structuring such that all branching logic lives in pure-ish helpers tested separately (HMAC verify, NDJSON parse, chunking, JID classification), leaving `mkWacliTransport` itself as thin wiring.

---

## Research phase — **COMPLETE**

All nine questions resolved. The full picture:

| Q | Topic | Outcome |
|---|---|---|
| Q1 | Protocol / runtime | wacli sidecar; Nix recipe landed in `nix/wacli.nix` |
| Q2 | `ChannelHandle` fit, v1 scope | Single-DM, text-only; no channel-type extensions |
| Q3 | IPC contract | Webhook (loopback Warp + HMAC) for messages; `--events` NDJSON for lifecycle |
| Q4 | Auth & credentials | wacli owns its store at `~/.pureclaw/credentials/whatsapp/default` (0700); vault wrapping deferred |
| Q5 | Lifecycle & reconnect | wacli owns reconnect; pureclaw inherits Signal's "let it die" model |
| Q6 | Inbound filters | Subsumed by Q2 |
| Q7 | Multi-account | Deferred to v2 |
| Q8 | Config schema | Flat `[whatsapp]` TOML block; codec mirrors `FileSignalConfig` |
| Q9 | Testing | `WhatsAppTransport` mock, five spec files, gated integration test, 100% coverage gate |

### Ready for `/review-design`

The plan is now executable as a design document for the metaswarm design-review gate (5-agent parallel review: PM, Architect, Designer, Security, CTO). Once that passes, the next step is `superpowers:writing-plans` for the work-unit decomposition.
