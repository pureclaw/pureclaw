# WhatsApp-for-pureclaw — Research Plan

## Goal of the research phase
Decide *how* to bring WhatsApp into pureclaw before committing to a design. The OpenClaw integration assumes a JS runtime and a much richer `ChannelHandle` than pureclaw exposes today — neither is automatic here. Output of the research phase: a written design proposal that answers Q1–Q9 with evidence, ready for `/review-design`.

## Non-goals (yet)
- Picking specific Haskell libraries.
- Writing any production code.
- Choosing PR scope / work-unit decomposition (that's the planning phase).

---

## Use cases (v1)

> **WHO**: a pureclaw user whose family/clients/contacts are on WhatsApp and refuse to migrate to Signal or Telegram
> **WANTS TO**: have their agent respond from their own WhatsApp number
> **SO THAT**: they don't have to migrate their contacts to a different messenger or run separate accounts

> **WHO**: a pureclaw user already using Signal/Telegram channels
> **WANTS TO**: reach the agent over a third channel that matches where their existing conversations happen
> **SO THAT**: agent access mirrors the rest of their messaging life — no platform-switching tax

> **WHO**: a developer evaluating pureclaw against OpenClaw
> **WANTS TO**: see WhatsApp parity at the basic-DM level
> **SO THAT**: pureclaw is a viable swap for a single-channel WhatsApp workflow

Explicitly **not** addressed in v1: group-chat agents, broadcast bots, business-API customer-service workflows. Those want fundamentally different shapes (multi-conversation routing, public webhook, message templates) and belong to v2+ proposals if/when demand surfaces.

## Product success metrics

For a feature with material downside risk (Meta TOS / account-ban exposure), we should be able to tell if it's actually helping users vs. hurting them. Surface these in `pureclaw doctor` output and logs:

1. **Time-to-first-paired-message** — from `/channel whatsapp pair` to first successful inbound. A long tail here suggests the QR-scanning UX is broken (e.g. terminal renders aren't scannable).
2. **Outbound success rate** — `wacli send` invocations that exit 0 vs. non-zero. A drop signals wacli session loss / WhatsApp rate-limiting.
3. **Observable account-loss signal** — wacli emits `disconnected` with status `401` / `logged-out` on de-link. Surface as a warn-level log; count per session.
4. **Process-restart count** — how often pureclaw's "let it die" model fires for this channel. If users restart >1x/day, the supervision model needs reconsidering.

No telemetry phones home — these are all visible in `LogHandle` output and `pureclaw doctor`.

## TOS / account-ban disclosure (user-facing)

WhatsApp's linked-device protocol is the same mechanism WhatsApp Web uses, but automated clients are against WhatsApp's TOS and Meta has banned accounts in the past. This must be surfaced to users at three points (not just in this research doc):

1. **First-run** in `/channel whatsapp pair` output, before showing the QR — a single paragraph explaining the risk, with a Y/N confirmation in interactive mode.
2. **README** section on the WhatsApp channel — same paragraph plus a link to OpenClaw's gap-analysis doc for context.
3. **`pureclaw doctor`** — if the channel is configured, surface a one-liner reminder that the linked account carries ban risk.

---

## Design Review — Iteration 2 (2026-05-15)

The first design-review-gate iteration returned NEEDS_REVISION from 4 of 5 reviewers (Architect approved). Key blockers and the resolutions folded into this revision:

| Blocker | Source | Resolution |
|---|---|---|
| No use cases | PM | Added "Use cases (v1)" section above |
| Success metrics absent | PM | Added "Product success metrics" section above |
| TOS/ban risk only in research doc | PM + Security | Added "TOS / account-ban disclosure" section; surfaced in pair flow + README + doctor |
| `allow_from = exactly 1` unjustified | PM + Designer | Relaxed in Q2 — multi-peer DM is in-scope for v1 (no architectural blocker) |
| `/whatsapp pair` invents a slash namespace | Designer | Moved to `/channel whatsapp pair` (extends existing `ChannelSubCommand`) |
| Argv vs shell unspecified for `wacli send` | Security | Q3 explicitly mandates `proc`-with-argv, mirroring Signal |
| HMAC secret leaks via `ps` (--webhook-secret argv) | Security | Spike confirmed wacli only accepts argv; upstream PR scoped as Work Unit 0; v1 documents limitation |
| Constant-time HMAC compare unspecified | Security | Q3 mandates `Data.ByteArray.constEq` |
| `qr_code` event payload routed to logs | Security | Q4 specifies QR payload renders to terminal only, never to `LogHandle` |
| Unbounded webhook inbox queue | Security | Q3 uses `TBQueue` with bounded capacity 1000; overflow → 429 + log warn |
| Bare `ByteString` for HMAC secret | Security | New `WebhookSecret` newtype in Q3, modeled on `Security/Secrets.hs` |
| 100% coverage strategy hand-wavy | CTO | **Spike found existing codebase is at ~51% coverage; Signal.Transport at 35%**. `.coverage-thresholds.json`'s "100% blocking" is orchestrator policy, not build gate, and has never been met. Resolution: pursue Option A — match Signal's de-facto bar (pure helpers fully covered; IO glue not). Updating `.coverage-thresholds.json` to reflect reality is Work Unit -1 (precedes WhatsApp work) |
| `qrcode` Hackage availability unverified | Designer + CTO | Spike: use `qrcode-core ^>= 0.9`. Hackage + nixpkgs both have it. Write a ~20-line half-block (`▀▄█`) renderer in new module `Channels.WhatsApp.QR` (no Hackage package does terminal half-block) |
| Embedded Warp port-allocation race | Architect + Security + CTO | Q3 specifies `Network.Socket.bind` to port 0 + `getsockname` + `Warp.runSettingsSocket`. No "scan then bind" TOCTOU |
| `PURECLAW_WACLI_INTEGRATION` env-gate is a new pattern | CTO | Q9 dropped env-gate; integration test uses hspec `runIO . lookupEnv` + `pendingWith` with manual recipe in docstring |

Non-blocking suggestions also rolled in:
- `chunkMessage` promoted to a shared module before WhatsApp imports it (Designer)
- `--events` reader EOF propagates to make `_ch_receive` throw (Architect zombie detection)
- `mkInboxApp :: WebhookSecret -> TBQueue ParsedMessage -> Application` exposed as a testable seam (Architect)
- `newtype E164 = E164 Text` for recipient slot (Designer)
- Partial E.164 redaction in warn logs (Security)
- Time Machine / FileVault assumption documented in user docs (Security)
- Tests assert no message body or `qr_code` payload leaks via `--events` (Security)
- `Channels.WhatsApp.Webhook` renamed to `Channels.WhatsApp.Inbox` (Architect)

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
| Inbound text DMs from peers in `allow_from` | ✅ | webhook → allowlist filter → `IncomingMessage`; `allow_from` accepts 1+ E.164 entries (mirrors Signal) |
| Outbound text replies, chunked | ✅ | shell out `wacli send text --to <E.164> --message …`; chunking via shared `Channels.Common.Chunking.chunkMessage` (promoted from `Signal.Transport`) |
| Connection lifecycle logging | ✅ | `--events` `connected`/`disconnected` → `LogHandle` |
| DM allowlist (allow_from) | ✅ | mirrors `SignalConfig._sc_allowFrom`; reject anything not from a configured peer |
| Groups (in or out) | ❌ | requires multi-chat routing; defer to v2 |
| Media (in or out) | ❌ | `IncomingMessage` is text-only; defer to v2 with a richer message type |
| Reactions (receive) | ❌ | `ParsedMessage.ReactionEmoji` ignored in v1 |
| Reactions (send) | ❌ | no use case in v1 (agent emits text) |
| Reply quoting / mentions | ❌ | `ParsedMessage.ReplyToID`/`ReplyToDisplay` ignored in v1 |
| Multi-account | ❌ | one `default` account per pureclaw instance for v1 |
| History sync exposure | ❌ | data lands in `wacli.db`; v1 doesn't read it |
| Self-chat mode (linked number = configured peer) | ❌ | OpenClaw concept; defer until needed |

**Multi-peer DM is in scope** (iteration 2 revision): single-peer was originally proposed as a v1 restriction but PM + Designer review correctly flagged this as unjustified — multi-peer single-loop DM is exactly what Signal already does (`SignalConfig._sc_allowFrom :: AllowList UserId`), and the agent loop's "one conversation at a time" invariant is preserved because `lastSender :: IORef` routes replies to whichever peer most recently messaged. Group support remains deferred because *that* genuinely needs multi-conversation routing.

**Inbound filtering (the dropping rules):**
- `ParsedMessage.FromMe == true` → drop (echo of our own send)
- `ParsedMessage.Chat` not a DM (group/channel JID — i.e. `@g.us` or `@newsletter`) → drop
- `ParsedMessage.SenderJID` E.164 not in `allow_from` → log + drop (partial redaction: `+1555***4567`)
- Otherwise: push `IncomingMessage { _im_userId = UserId <senderE164>, _im_content = ParsedMessage.Text }` onto the inbox queue; update `lastSender :: IORef Text` so the next `_ch_send` routes back

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

- **Inbound (messages):** pureclaw allocates a free local port with `Network.Socket.bind` to `0` + `getsockname` (no scan-then-bind TOCTOU), generates a fresh `WebhookSecret` (see below), starts Warp via `Warp.runSettingsSocket` on the already-bound `127.0.0.1` socket, and launches wacli with `sync --follow --webhook http://127.0.0.1:<port>/wacli --webhook-secret <secret>`. The handler validates `X-Wacli-Signature: sha256=<hmac>` (from `internal/app/webhook.go:128`) using **`Data.ByteArray.constEq`** (not `==`, which is timing-leaky). Validated payloads parse to `ParsedMessage`, apply pureclaw's allowlist, push to a **bounded `TBQueue ParsedMessage`** (capacity 1000; overflow returns HTTP 429 + `LogHandle.logWarn`) consumed by `_ch_receive`. Local-loopback only — no public webhook exposure.
- **Inbound (lifecycle/errors):** consume `--events` NDJSON from wacli's stderr in a reader thread. Map `connected`/`disconnected` to channel state; route `warning` and `event_handler_panic` to `LogHandle.logWarn`/`logError`. Keep this separate from the message path — it's logging, not control flow. **The events reader must not be able to push to the message inbox** — enforce by giving each their own queue type (`TBQueue ParsedMessage` vs `TQueue WaEvent`). **Reader EOF → throw `IOException` from `_ch_receive`** so a dead wacli doesn't leave a zombie channel that silently never receives.
- **Outbound:** shell out to `wacli send text|file|sticker|voice|react …` per send using `typed-process`'s **`proc` with an argv list — never `shell` with string interpolation** (the `--message` value is LLM-controlled and would be a shell-injection RCE if concatenated). Mirror `Channels.Signal.Transport.mkSignalCliTransport`'s argv pattern. Locking guarantees (`docs/sync.md:30`) ensure the long-running `sync --follow` process owns the WhatsApp session, and `send` delegates to it instead of spawning a second session.
- **State queries (v2+):** read-only SQLite over `<store>/wacli.db` for history search, contact lookup, etc. Out of scope for v1.

### Secret handling

```haskell
-- New module Channels.WhatsApp.Secret (mirrors Security.Secrets pattern)
newtype WebhookSecret = WebhookSecret ByteString
instance Show WebhookSecret where show _ = "<WebhookSecret>"

useWebhookSecret :: WebhookSecret -> (ByteString -> IO a) -> IO a
useWebhookSecret (WebhookSecret bs) k = k bs

genWebhookSecret :: IO WebhookSecret  -- getRandomBytes 32 from Crypto.Random
```

**Known limitation (v1)**: wacli only accepts the webhook secret via `--webhook-secret <value>` argv (confirmed in `cmd/wacli/sync.go:121`; no env-var or stdin support). This means the secret appears in `ps auxw` / `/proc/<pid>/cmdline` for the lifetime of the wacli subprocess, visible to other local users. On single-user laptops this is acceptable; on shared hosts it's a privilege-isolation gap. **Mitigation:** Work Unit 0 of the implementation plan files an upstream PR adding `WACLI_WEBHOOK_SECRET` env-var support; once landed and the new wacli version is pinned in `nix/wacli.nix`, we switch to env-var passing. Until then, document the limitation in the README and `pureclaw doctor`.

### Testable seam — `mkInboxApp`

Per Architect feedback: extract the WAI `Application` from the lifecycle so it's testable without binding a real port.

```haskell
-- Channels.WhatsApp.Inbox
mkInboxApp
  :: WebhookSecret
  -> TBQueue ParsedMessage
  -> LogHandle
  -> Application
```

Tests use `Network.Wai.Test.runSession` to drive `mkInboxApp` with valid/invalid signatures, oversized payloads, malformed JSON, etc. — all pure-IO, no real socket. Coverage of HMAC + parse + queue-push branches lives here.

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

Pureclaw flow uses the existing slash-command pattern — **`/channel whatsapp pair`** (extends `ChannelSubCommand` with a `ChannelPair` constructor — see `src/PureClaw/Agent/SlashCommands.hs:147-149`; *not* a new `/whatsapp` namespace):

1. User invokes `/channel whatsapp pair` from the CLI/TUI channel.
2. Non-CLI channels (Signal/Telegram/gateway): respond via `_ch_send` with "WhatsApp pairing must be initiated from the TUI/CLI — run `pureclaw` interactively, then `/channel whatsapp pair`." (Routed message, not a hard error like Signal's current `userError`.)
3. CLI: print TOS/ban-risk paragraph + Y/N confirmation. On N → abort. On Y → continue.
4. Spawn `wacli auth --store <dir> --qr-format text --events` via `proc` argv.
5. Read NDJSON from stderr; on `qr_code` event extract `data.code` (raw payload).
6. **Render QR locally via new module `Channels.WhatsApp.QR`** (see below) — write to terminal directly, never to `LogHandle`. The raw `qr_code` payload is a one-time linking credential; persisting it to logs is a credential leak.
7. On `authenticated` / process exit success → `LogHandle.logInfo` "WhatsApp paired as +<phone>" (the phone *number* is OK to log; the QR *payload* is not).

Auth state check on channel startup: shell out `wacli auth status --json --store <dir>` (`cmd/wacli/auth.go:198`); refuse to start `sync --follow` if not authenticated; tell the user to run `/channel whatsapp pair`. (`withWhatsAppChannel` also fails fast on unauthenticated state — don't rely on dispatch alone.)

### QR rendering — `Channels.WhatsApp.QR`

Spike-confirmed library choice: **`qrcode-core ^>= 0.9`** (`qrcode-core 0.9.11`, released 2026-02-04, pure Haskell, GHC 9.12-compatible, ships in nixpkgs `hackage-packages.nix`).

No Hackage package renders QR codes to terminal half-blocks, so this is a new ~20-line module. Half-blocks (`▀▄█`) double the vertical density per terminal cell — required for modern phone cameras to focus on the QR. wacli does the same with Go's `qrterminal.GenerateHalfBlock` (`cmd/wacli/auth.go:178`).

```haskell
-- Channels.WhatsApp.QR
import qualified Codec.QRCode as QR

renderHalfBlock :: QR.QRImage -> Text  -- pure, fully testable
printPairingQR :: Handle -> Text -> IO ()  -- IO wrapper, integration-tested
```

Error-correction level `L` matches `qrterminal`'s default; add a 2-module quiet zone. `renderHalfBlock` is pure → 100% covered with property tests (input QR matrix → output text; check size matches `2*n×n` cells; check character set is exactly `{' ', '▀', '▄', '█'}`).

### Permissions & secrets

- `<store>` dir created with mode `0700`.
- HMAC webhook secret: wrapped in `WebhookSecret` newtype (Q3); generated fresh per session via `Crypto.Random.getRandomBytes 32`. Not persisted across runs.
- The webhook listener binds to `127.0.0.1` only — never `0.0.0.0`.

### At-rest threat model — assumes disk encryption

wacli's `session.db` (signal-protocol keys) is not encrypted at rest in v1 (vault wrapping deferred above). The 0700 mode protects against other unprivileged users on the same machine but does NOT protect against:
- Lost/stolen laptop without FileVault / LUKS
- Time Machine / restic / rsync backups that pierce 0700
- Cloud sync tools that follow `$HOME` (rare for `~/.pureclaw` but worth excluding explicitly)

The README must say: *"WhatsApp session keys are stored unencrypted at `~/.pureclaw/credentials/whatsapp/`. Protect with full-disk encryption (FileVault on macOS, LUKS on Linux). Exclude this path from cloud-sync tooling. v2 will integrate the encrypted vault."*

**Output:** ready for the design doc — store layout + pair flow + permissions all specified.

---

## Q5. Lifecycle & reconnect — **DECIDED: inherit Signal's "let it die" model**

Decision (2026-05-15): pureclaw does not auto-restart wacli. Mirror `Channels.Signal.readerLoop`'s explicit comment (`src/PureClaw/Channels/Signal.hs:87` — *"Don't restart — let the channel die, agent loop will get IOError"*). The agent loop already handles `IOException` from `_ch_receive` cleanly (`src/PureClaw/Agent/Loop.hs:75`).

### Failure model

| Failure | Owner | Pureclaw response |
|---|---|---|
| WhatsApp Web socket drops (network blip, server-side disconnect) | wacli `sync --follow` | nothing — wacli reconnects internally with its own backoff |
| App-state LTHash mismatch | wacli | log the `warning` event from `--events` stream; wacli requests recovery automatically |
| wacli process crashes (panic, OOM, signal) | OS | `--events` reader sees EOF on stderr → set a `terminated :: TVar Bool` → next `_ch_receive` reads `terminated` and throws `IOException` → agent loop exits cleanly → user restarts pureclaw |
| Webhook listener crashes (Warp exception) | pureclaw | propagate to channel handle so the whole channel tears down — partial state (wacli running but no inbox consumer) would be worse than a clean restart |
| `--events` reader thread crashes *but wacli still running* | pureclaw | log; do not bring down the channel — events are auxiliary, the webhook path keeps working. Distinct from EOF-on-wacli-exit above |
| Zombie state (wacli dead, webhook listener still listening) | pureclaw | the EOF detection above prevents this — the `terminated` flag is the single source of truth for "wacli is gone" |

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
# Required: E.164 phone numbers allowed to DM the agent. Mirrors
# Signal's allow_from semantics — accepts one or more entries. Empty
# list rejects the configuration at startup with a clear error.
allow_from = ["+15551234567", "+15557654321"]

# Optional: where wacli's session.db + wacli.db live. Created with mode 0700
# on first run if missing. Default: ~/.pureclaw/credentials/whatsapp/default
# store_dir = "~/.pureclaw/credentials/whatsapp/default"

# Optional: explicit wacli binary path. Default: lookup "wacli" on $PATH
# (the nix dev shell provides it; brew install steipete/tap/wacli also works).
# wacli_path = "wacli"

# Optional: outbound message chunking, mirrors Signal. WhatsApp's hard limit
# is ~64k chars; 6000 is a safe default that splits on paragraph boundaries.
# text_chunk_limit = 6000

# Optional: webhook inbox capacity. If wacli posts faster than the agent
# consumes, excess inbound messages return HTTP 429 and are logged at warn.
# webhook_queue_size = 1000
```

And the existing `default_channel` enum (`FileConfig._fc_defaultChannel`) gains `"whatsapp"`:

```toml
default_channel = "whatsapp"
```

**Haskell side** (`src/PureClaw/CLI/Config.hs`):

```haskell
data FileWhatsAppConfig = FileWhatsAppConfig
  { _fwac_allowFrom        :: Maybe [Text]
  , _fwac_storeDir         :: Maybe Text
  , _fwac_wacliPath        :: Maybe Text
  , _fwac_textChunkLimit   :: Maybe Int
  , _fwac_webhookQueueSize :: Maybe Int
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
  { _wat_inboundWebhook :: TBQueue ParsedMessage   -- consumed by ChannelHandle._ch_receive (bounded; DoS protection)
  , _wat_inboundEvents  :: TQueue  WaEvent         -- consumed by the events reader thread
  , _wat_send           :: E164 -> Text -> IO ()   -- newtype E164 prevents swapped-arg bugs
  , _wat_authStatus     :: IO Bool                 -- did wacli report authenticated?
  , _wat_terminated     :: TVar Bool               -- set true when wacli exits; observed by _ch_receive
  , _wat_close          :: IO ()
  }
```

- **Real implementation** (`mkWacliTransport`): allocates a free port via `bind 0` + `getsockname`, generates `WebhookSecret`, spawns `wacli sync --follow --webhook http://127.0.0.1:<port>/wacli --webhook-secret <hex> --events` via `proc` argv, runs `Warp.runSettingsSocket` with `mkInboxApp`, runs the events reader. `_wat_send` shells out `wacli send text --to E.164 --message …` via `proc` argv (never `shell`). `_wat_authStatus` shells out `wacli auth status --json`.
- **Mock implementation** (`mkMockWhatsAppTransport`): caller pushes pre-built `ParsedMessage` values into `_wat_inboundWebhook` and `WaEvent` values into `_wat_inboundEvents`; `_wat_send` writes to a `TQueue (E164, Text)` the test inspects. Used everywhere except the manual integration test.

### Test surfaces (mock-backed, run in CI)

1. **HMAC validation** (`Channels.WhatsApp.WebhookSpec`) — driven via `Network.Wai.Test.runSession` against `mkInboxApp`:
   - Valid signature → payload accepted.
   - Wrong/missing signature → 401, no inbox push, warning logged.
   - Constant-time-compare check: a signature that differs only in the last byte takes the same code path as a signature that differs in the first byte (assert via property test, not timing).
2. **`ParsedMessage` parsing** (`Channels.WhatsApp.WebhookSpec`):
   - Text-only DM → `IncomingMessage { _im_userId, _im_content }`.
   - Media-only → drop (v1: log + skip).
   - Group JID (`@g.us`) → drop.
   - Channel JID (`@newsletter`) → drop.
   - `FromMe = true` → drop (self-echo).
   - Sender not in `allow_from` → drop with partially-redacted-E.164 log (`+1555***4567`).
   - **Multi-peer `allow_from`**: messages from any listed peer accepted; `lastSender` updated per inbound.
   - Oversized payload (>1MB) → 413, no parse.
   - `TBQueue` full → 429, log warn.
3. **Outbound routing** (`Channels.WhatsApp.WacliSpec`):
   - `_ch_send` calls `_wat_send` with the `lastSender` E.164 and the message text.
   - Chunking at `text_chunk_limit` splits a long message on paragraph boundaries — call into the *shared* `Channels.Common.Chunking.chunkMessage` (promoted from `Signal.Transport`).
4. **`--events` ingestion** (`Channels.WhatsApp.EventsSpec`):
   - `connected` / `disconnected` → log entries at info / warn.
   - `warning` event → log error with `code` + `message` fields.
   - Malformed JSON line → log warn, skip, continue reading.
   - **EOF on stderr → `terminated` set true**; subsequent `_ch_receive` throws `IOException`.
   - **Leak test**: a synthetic `event_handler_panic` event whose `stack` field contains a message body must NOT cause the body to appear in `LogHandle` output above debug level.
5. **QR pair flow** (`Channels.WhatsApp.QRSpec` + `Channels.WhatsApp.PairSpec`):
   - `renderHalfBlock` for a fixed-seed QR → exact-byte-equal output (golden test).
   - `printPairingQR` writes only to its supplied `Handle`, never to `LogHandle` (test asserts `LogHandle` mock receives zero entries during pair).
   - `qr_code` event payload does not appear in any `LogHandle` invocation.
6. **Lifecycle** (`Channels.WhatsApp.LifecycleSpec`):
   - `withWhatsAppChannel` cleans up Warp and the (mocked) subprocess on normal exit.
   - `withWhatsAppChannel` cleans up on exception in the action.
   - `withWhatsAppChannel` fails fast if `_wat_authStatus` returns false (don't rely on CLI dispatch alone).

### Integration test (manual)

`test/Integration/WhatsAppFlowSpec.hs` — uses hspec `runIO . lookupEnv "PURECLAW_WACLI_INTEGRATION" >>= pendingWith ...` to skip cleanly in CI without introducing a new env-gate harness pattern. The docstring documents the manual recipe:

1. `mkdir -p ~/.pureclaw/credentials/whatsapp/test`
2. `nix develop . --command wacli --store ~/.pureclaw/credentials/whatsapp/test auth` — scan QR with burner phone
3. `PURECLAW_WACLI_INTEGRATION=1 nix develop . --command cabal test pureclaw-test --test-options="--match=WhatsApp"`
4. From the burner phone, message the linked account; verify the test sees an `IncomingMessage` and `wacli send` produces an outbound message visible in the chat.

### Coverage policy — match Signal's de-facto bar

**Spike finding (2026-05-15)**: `.coverage-thresholds.json` nominally requires 100% lines/branches/functions/statements, but `cabal test --enable-coverage` exits 0 regardless (it's orchestrator policy, not a build gate). The existing codebase sits at ~51% expression coverage; `Channels.Signal.Transport` specifically is at **35% expression coverage** (69/194). The CTO blocker as written assumed Signal achieved 100% — it doesn't.

**Decision (option A, user-confirmed)**: match Signal's pattern rather than pursue a 100% bar that no module in the codebase currently meets:

- **Pure helpers covered to 100%**: `chunkMessage`, JID classification, HMAC verify (via `mkInboxApp`), NDJSON parse, `renderHalfBlock`, `WebhookSecret` constructor + accessor, allowlist check, partial-redaction formatter.
- **IO glue not separately covered**: `mkWacliTransport` lifecycle wiring, `Warp.runSettingsSocket` invocation, `proc` invocations, process-exit handlers. These exist on the Signal side at low coverage and pureclaw has shipped accepting that.
- **Lifecycle covered via mocks**: `withWhatsAppChannel` cleanup paths covered via `mkMockWhatsAppTransport`.

**Work Unit -1** (precedes WhatsApp work): update `.coverage-thresholds.json` to reflect the observed reality — either drop the 100% claim to match measured baseline, or split into per-module/per-namespace thresholds (pure modules = 100%, channel-IO modules = no minimum). This is a one-PR scope change with no implementation risk.

---

## Research phase — **COMPLETE (iteration 2)**

All nine questions resolved; iteration 1 review feedback fully addressed.

| Q | Topic | Outcome |
|---|---|---|
| Q1 | Protocol / runtime | wacli sidecar; Nix recipe landed in `nix/wacli.nix` |
| Q2 | `ChannelHandle` fit, v1 scope | Multi-peer DM, text-only; no channel-type extensions |
| Q3 | IPC contract | Webhook (loopback Warp + HMAC via `bind 0` + constant-time compare + bounded `TBQueue`) for messages; `--events` NDJSON for lifecycle; `proc`-argv for sends; `WebhookSecret` newtype |
| Q4 | Auth & credentials | wacli owns its store at `~/.pureclaw/credentials/whatsapp/default` (0700); QR via `qrcode-core` + half-block renderer; `/channel whatsapp pair` slash command; vault wrapping deferred |
| Q5 | Lifecycle & reconnect | wacli owns reconnect; pureclaw inherits Signal's "let it die" model with explicit zombie-detection on `--events` EOF |
| Q6 | Inbound filters | Subsumed by Q2 |
| Q7 | Multi-account | Deferred to v2 |
| Q8 | Config schema | Flat `[whatsapp]` TOML block; multi-peer `allow_from`; codec mirrors `FileSignalConfig` |
| Q9 | Testing | `WhatsAppTransport` mock, six spec files (`Webhook`, `Wacli`, `Events`, `QR`, `Pair`, `Lifecycle`); `pendingWith`-gated integration test; coverage matches Signal's de-facto pattern (pure helpers 100%, IO glue no minimum) |

### Iteration 2 changes

All 15 blockers from iteration 1 addressed inline in their respective Q sections; the "Design Review — Iteration 2" table near the top of this document indexes blocker → resolution. Net additions:
- Use cases, success metrics, TOS disclosure surfaces (PM blockers)
- `WebhookSecret` newtype, constant-time compare, `proc`-argv mandate, bounded inbox, `bind 0` port allocation, QR log redaction (Security blockers)
- `/channel whatsapp pair` slash command form, `qrcode-core` + custom half-block renderer (Designer blockers)
- Coverage policy reset to match Signal baseline, `pendingWith` integration gate, `bind`-on-socket + `runSettingsSocket` (CTO blockers)
- `mkInboxApp` testable seam, zombie detection on EOF, `chunkMessage` promotion, `E164` newtype, `Inbox` module rename (non-blocking suggestions)

### Two follow-on work units identified by the review

- **Work Unit -1**: update `.coverage-thresholds.json` to match observed reality. Single-PR scope. Precedes WhatsApp implementation.
- **Work Unit 0**: file upstream PR on wacli adding `WACLI_WEBHOOK_SECRET` env-var support. Blocks the long-term fix to Security blocker #7 but doesn't block v1 (v1 documents the `ps` exposure as a known limitation).

### Ready for `/review-design` iteration 2

The plan is now executable for the second design-review-gate pass. Expected outcome: APPROVED with minor non-blocking polish suggestions, or one more round of fine-tuning. After approval, next step is `superpowers:writing-plans` for the work-unit decomposition.
