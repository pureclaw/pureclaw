# Service Inventory

> Updated by the orchestrator after each work unit commit.
> Coder agents MUST read this before implementing to avoid duplicating existing services.

## Handles (Records of IO actions — project's "service" idiom)

| Handle | File | Responsibility | Key Methods |
|---|---|---|---|
| `StreamBroker` | `src/PureClaw/Frontend/StreamBroker.hs` | In-process pub/sub for `BrokerEvent`s (transcript entries + activity events). Bounded per-subscriber `TBQueue` with STM-atomic overflow protocol; global + per-origin subscriber caps. | `_streamBroker_publish`, `_streamBroker_subscribe`, `_streamBroker_introspect`, `_streamBroker_config` |
| `Subscription` (returned by `_streamBroker_subscribe`) | same | One subscriber's queue + overflow TVar + cleanup action. | `_sub_queue`, `_sub_overflow`, `_sub_cancel` |
| `StreamGuard` | `src/PureClaw/Frontend/API.hs` (type) + `src/PureClaw/Frontend/Stream.hs` (ops) | Per-origin subscriber-cap enforcement for WS upgrades. Lives in `FrontendEnv._fe_streamGuard`. | `tryClaim`, `releaseClaim` |

## Factories

| Factory | File | Creates | Used By |
|---|---|---|---|
| `mkInProcessBroker :: BrokerConfig -> IO StreamBroker` | `src/PureClaw/Frontend/StreamBroker.hs` | In-process broker (one per binary process). | `CLI.Commands.startWithChannel` (top of body, before any `mkSessionHandle`/`resumeSession`) |
| `mkStreamGuard :: Int -> IO StreamGuard` | `src/PureClaw/Frontend/API.hs` | Per-origin counter for WS upgrades. | `CLI.Commands.startWithChannel` |
| `mkBroadcastingFileTranscriptHandle :: Maybe StreamBroker -> SessionId -> LogHandle -> FilePath -> IO TranscriptHandle` | `src/PureClaw/Frontend/BroadcastingTranscript.hs` | File-backed transcript handle that also publishes to the broker (when `Just`); plain handle (when `Nothing`). **THE SOLE WRITE-PATH FACTORY** — every `mkSessionHandle`/`resumeSession`/`handleSend` call site goes through this. | `Session.Handle.mkSessionHandle`, `Session.Handle.resumeSession`, `Frontend.API.handleSend → doCompletion` |

## Modules (no factory, but worth knowing about)

| Module | File | Exports | Used By |
|---|---|---|---|
| `Frontend.Activity.Types` | `src/PureClaw/Frontend/Activity/Types.hs` | `HarnessActivity (..)` + its `ToJSON` instance (moved out of `Frontend.API` so the broker doesn't depend on the WAI layer). | `Frontend.StreamBroker`, `Frontend.Stream`, `Frontend.API` (re-exports for compat) |
| `Frontend.Stream` | `src/PureClaw/Frontend/Stream.hs` | `streamApp :: FrontendEnv -> Application`; wire-types `ServerEvent`, `ClientOp`, `ErrorCode`, `ActivityKind`; `normalizeOrigin`, `originAllowed`; STM ops `tryClaim`, `releaseClaim`. | `Frontend.Server.combinedApp` (via `websocketsOr`) |
| `Frontend.ActivityProbe` | `src/PureClaw/Frontend/ActivityProbe.hs` | `runActivityProbeLoop :: StreamBroker -> IORef (Map Text HarnessHandle) -> LogHandle -> IO ()` — 2 s tick emitting `ActivityChanged sid (SaHarnessStatus _)` per transition. | `CLI.Commands.startWithChannel` (nested `Async.withAsync` inside the WAI server's scope) |

## Established Patterns

<!-- Patterns discovered during implementation that later work units should follow -->

- **STM-atomic publish protocol**: `_streamBroker_publish` opens a single `atomically` block and composes `publishOne :: STM ()` over all subscriber queues. Overflow (full queue → drop oldest + set per-subscriber overflow `TVar` + write new) happens in the same transaction for each subscriber. Subscriber-cap check + subscribe insertion is also a single STM transaction (no TOCTOU). See `Frontend.StreamBroker.publishEvent`.
- **Single broadcasting-handle factory**: `mkFileTranscriptHandle` is now allowlisted to exactly three files (definition, the broadcasting wrapper, and `Tools.SessionSearch` for read-only consumption). Enforced by `scripts/lint-transcript-handles.sh` in CI. Any new write-path call site MUST go through `mkBroadcastingFileTranscriptHandle`.
- **`Async.withAsync` lifecycle for long-running background workers**: `CLI.Commands.startWithChannel` constructs the broker + StreamGuard at the top, then nests `Async.withAsync (runFrontend …)` and `Async.withAsync (runActivityProbeLoop …)` around the body. Both children are cancelled cleanly when `runAgentLoopWith` returns or throws. **No bare `forkIO`** for these.
- **AsyncCancelled re-raise discipline**: every `try @SomeException` in the streaming layer pattern-matches `fromException e :: Maybe AsyncCancelled` and re-raises via `throwIO e`. Synchronous exceptions are logged + handled per the surrounding semantics. See `Frontend.BroadcastingTranscript.publishSafely`, `Frontend.ActivityProbe.runActivityProbeLoop`, `Frontend.Stream.escapeHandler`.
- **Origin allowlist with `normalizeOrigin`**: exact-match string comparison after lowercasing scheme + host, no wildcards, missing Origin → deny. `StreamGuard._streamGuard_perOrigin` keys are the **normalized** origin string. See `Frontend.Stream.normalizeOrigin`.
- **Wire-protocol golden fixtures**: `test/Frontend/fixtures/stream-events/*.json` pin the JSON shape of every server→client event variant and every client→server op. Cross-referenced by `Frontend.StreamGoldensSpec` (Haskell-side roundtrip) and `frontend/src/types/__tests__/stream.test.ts` (TS-side parse).
- **`withPingThread` for WS keepalive**: Warp's `setTimeout` does NOT apply to hijacked WS sockets. WS connections use `Network.WebSockets.withPingThread` with 25 s interval + 10 s pong timeout. See `Frontend.Stream.runConnection`.
