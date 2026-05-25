# Live Transcript Streaming Over WebSocket

**Issue:** TBD (filed after design-review-gate approval)
**Status:** design — DRAFT round 4 (pending design-review gate)
**Branch:** TBD
**Authors:** Doug Beardsley, Claude
**Related:**
- Builds on existing HTTP API in [`src/PureClaw/Frontend/API.hs`](../src/PureClaw/Frontend/API.hs).
- Adjacent to (does not overlap with) the *Session/Tab Unification* epic (`pureclaw-9sp`, GH #56), which is about session/tab creation — this doc is about live updates to already-open sessions.

**Revision note (round 1 → 2)** — round 1 of the design-review gate flagged five categories of blocker: instrumentation site (the round-1 design only wrapped the HTTP `/send` path; UC-1 "watch a CLI-driven agent from the web" therefore could not work), broker lifetime (Open Q5 was load-bearing — `FrontendEnv` is constructed in `src/PureClaw/CLI/Commands.hs` around line 653, and `runFrontend` is launched via `forkIO` with no shutdown handshake, so the round-1 doc's `Async.withAsync` reference had no real scope), wire-protocol ambiguity (`since` was triply specified; activity event taxonomy failed MECE; hook shape inconsistent), security parity (WS-over-HTTP without Origin allowlist is *strictly worse* than the HTTP API, not parity; subscriber DoS + existing Warp config gap in `Server.hs`), and DoD quality (mechanism-level rather than behavioral; D14 hedged on frontend test infra). Round 2 addressed all five categories.

**Revision note (round 3 → 4)** — All 5 round-3 reviewers approved the architecture but converged on documentation staleness introduced by round 3's edits. Round 4 sweeps the references: (a) D8 now matches the round-3 `hello` schema (`type`, `protocolVersion`, `serverStartedAt` — three fields, no `focusedSessionId`, no `lastReplayedEntryId`); (b) D16 rewords the spinner DoD to describe the probe-loop path with a 2.5 s budget (instead of the removed synchronous-emission path); (c) WU4 description no longer mentions sync emission; (d) Resolved Open Q #2 and #5 updated to match round-3 architecture; (e) Risks rows updated to credit `withPingThread` and to drop sync-emission credit; (f) `_streamBroker_currentCounter` reference removed from §Replay-on-reconnect (the UUID dedup against `fileSlice` is sufficient — the counter was dead in the algorithm); (g) D33 added for the `internal` error code (specifies emission site); (h) D34 added for `_th_record` disk-failure logging discipline; (i) broadcasting decorator now takes a `LogHandle` so disk/broker divergence is `_lh_logWarn`'d; (j) §Broker now explicitly documents that `EntryRecorded`/`ActivityChanged` pair is NOT atomic across the pair and why this is fine; (k) §Origin matching gains a `StreamGuard` key normalization paragraph + Unicode/IDN rule 7. No architectural changes; editorial cleanup only.

**Revision note (round 2 → 3)** — PM approved round 2; the other four reviewers found load-bearing specifics that round-2's broader strokes hid. Round 3 fixes: (a) broker construction ordering — round 2 placed it at `CLI/Commands.hs:653` but `mkSessionHandle`/`resumeSession` are called at lines 544/569 of the same function; broker now constructed at the top of `startWithChannel` and threaded through `AgentEnv._env_broker`; (b) instrumentation coverage table missed `Agent/SlashCommands.hs:2287` (a write site) and `Tools/SessionSearch.hs:80` (a read-only site that breaks the D6 grep test); both are now enumerated and D6 is rewritten as an explicit allowlist; (c) synchronous activity emission from `handleSend` (round-2 addition) created a wire-protocol double-emit racing the probe loop; removed for v1 (2 s lag is documented as acceptable, see Risks); (d) replay-on-reconnect dedup race when publishes arrive during file read — replaced with a snapshot-based approach; (e) replay terminator was double-specified (`hello` after replay AND `replay-end` event); `replay-end` is now the sole post-replay terminator; (f) `ActivityEvent` TS type was referenced but undeclared — explicit TS discriminated union now in §Frontend changes; (g) `Warp.setTimeout` does not apply to hijacked WS sockets (verified from `wai-websockets` docs) — `Network.WebSockets.withPingThread` is now the per-WS keepalive mechanism with a documented disconnect policy; (h) per-origin subscriber-cap data structure and bracket discipline are now spec'd as `StreamGuard`; (i) `_fc_allowedOrigins` matching semantics are now exact-match with documented case rules; (j) D25 had a wrong call chain — corrected to `handleSend → doCompletion → mkBroadcastingFileTranscriptHandle → mkTranscriptProvider`. Five new DoDs added for the security blockers (D27–D31) and one for WS pings (D32).

## Scope of v1 (explicit)

This work targets the **web frontend** as the user surface. Chat-channel users (Signal/Telegram, per `SPRINT-PLAN.md`) are not affected: their UX is push-message-based, not request/poll-based, so live streaming over WS doesn't apply. Tabbed Chat (`docs/tabbed-chat.md`) ships; its per-tab routing operates inside a single chat thread independent of this feature.

## TL;DR — What does this look like to a user?

A user opens the PureClaw web frontend and clicks a session in the sidebar. The transcript view loads existing history via the current HTTP GET endpoint. From that moment on, **anything new written to that session's transcript appears in the UI within ~500 ms p95 on localhost** (concrete budget; verified by integration test, see D14/D15), with no page refresh. The sidebar also updates live: when an agent in another session transitions idle → thinking, that session's row shows a spinner **within ~2 s** (the activity probe loop interval — see Risks); when a new transcript entry is recorded in a non-focused session, that row gets a "new" indicator within the same ~500 ms budget as focused entries; when a session is created, the list reflects it without refresh.

Under the hood, the frontend keeps one WebSocket connection open per client (per browser tab). The client tells the server which session it is currently viewing; the server streams full transcript entries for that one session, plus lightweight activity events for *all* sessions so the sidebar can stay live. The endpoint inherits the current HTTP API's no-auth posture **with one strict addition**: the WS upgrade is rejected unless the `Origin` header resolves to localhost (or the `*` HTTP CORS policy is configured for the API).

## Motivation

The frontend currently fetches a session's transcript once via `GET /api/sessions/{sid}/transcript`. When the user sends a message via `POST /api/sessions/{sid}/send`, they see the assistant's response because the POST returns it; but any *other* activity (a CLI tab writing to the same session, a harness emitting output later, a parallel agent loop streaming through `mkTranscriptProvider`) is invisible until manual refresh. The sidebar's harness-activity indicators are point-in-time — they don't reflect a state change that happens five seconds after page load.

The result: the frontend feels static in a runtime that is otherwise event-driven. Users on a CLI/web split workflow ("CLI to drive, web to browse") have to refresh manually.

### Why WebSocket over HTTP polling

Polling was considered. For the sidebar activity case alone, a 2-second poll of a small `/api/activity` endpoint would deliver ≥ 90% of the perceived value at a fraction of the implementation complexity. We reject polling for v1 because:

1. **UC-1 needs sub-second freshness for transcript appends.** Polling at < 1 s adds noticeable battery / CPU drain on the client and amplifies server file-read load. WS scales naturally because the server pushes only when there is something to push.
2. **A unified primitive is cheaper than two.** With polling we'd need *two* mechanisms: poll for activity, separate cursor-based polling for transcript appends. WS handles both over one channel; the integration cost is paid once.
3. **WS is forward-compatible with mid-completion token streaming.** When token-level streaming lands (v1.5; see Risks & Future Work), it slots into the same WS channel without protocol churn. Polling would need a different mechanism entirely.

The cost is justified: a single WS endpoint, a single broker module, a focused frontend hook. This work does not exceed the polling-cost ceiling because the broker is in-process (no Redis/queue) and the connection lifecycle is simple (one socket per browser tab).

## Use Cases

> Each UC names a target persona. Items marked `[assumption-to-validate post-v1]` lack user research; the validation gate is below.

**UC-1 — Watch a live agent run** (Persona: developer running a long-form agent task in CLI, monitoring in the web UI). User starts a long-running PureClaw session in the CLI (e.g., a coding agent doing a multi-file refactor), opens the web UI in a browser, and clicks that session. New transcript entries appear in the UI as they're written, in order, without page refresh. *Critical implementation note:* CLI session writes go through `mkSessionHandle`'s `TranscriptHandle` (and through `mkTranscriptProvider`'s wrapper); the broadcasting decorator must therefore be applied at session-handle construction time, not at the HTTP send site (see §Instrumentation Coverage). *[assumption-to-validate post-v1]*

**UC-2 — Sidebar live status** (Persona: power user with multiple concurrent harness sessions). User has the web UI open with the sidebar showing 4 sessions. A different process (or the same process, different tab) sends a message to session #2, which causes its harness to go thinking. The sidebar row for session #2 shows a spinner without the user clicking anything; when the harness goes idle, the spinner clears. *[assumption-to-validate post-v1]*

**UC-3 — Multi-window same session** (Persona: developer with two browser windows showing the same session). User has session #1 open in window A and window B. They send a message from window A; the assistant's response appears in *both* windows in matching order (each window observes entries in `_te_timestamp` order; the relative order of any pair of entries agrees between windows because the broker enqueues atomically per publish). *[assumption-to-validate post-v1]*

**UC-4 — Tabbed chat composition** (Persona: power user with multiple tabs in one session — Tabbed Chat already shipped). User has session #1 with two tabs (`/0` AI, `/1` shell). Both tabs write to the **same** `transcript.jsonl` (per shipped tabbed-chat behavior). The web UI shows entries from both tabs interleaved in the session's transcript view, in `_te_timestamp` order — there is **no per-tab UI filtering in v1**. The activity events (`harness-activity-changed`) refer to the **session's** harness state (not per-tab); per-tab activity is a v1.5 concern. *[assumption-to-validate post-v1]*

**UC-5 — Connection blip from user's POV** (Persona: any web frontend user, intermittent network). User has the UI open; the WS drops for 5 s (laptop sleep, wifi blip). The UI shows a small bottom-bar pill saying "reconnecting…" — the transcript stays visible. On reconnect, missed entries fade in at the bottom. The user does not lose state, does not see entries appear out of order, and does not need to refresh.

### Validation gate (post-v1)

Post-merge, qualitative feedback from ≥ 3 power users in the target personas. Each UC is confirmed or de-prioritized for v2 planning. Leading indicators (in the first week post-merge): manual-refresh frequency in browser logs (instrumented via simple counter on the GET endpoint), web-server error rate (must not regress), p95 transcript-append-to-WS-frame latency on the integration test fixture (must remain ≤ 500 ms — see D14).

## Non-Goals

- **Mid-completion token streaming is out of scope for v1.** Only finalized `TranscriptEntry` records (those written via `_th_record`) are published. A 60-second completion still appears as a single entry at the end. This is acknowledged: v1 satisfies UC-1 well for sessions with many short entries (typical interactive use) and only partially for sessions with long single completions. v1.5 adds intra-completion token streaming; see Risks & Future Work for the planned protocol extension.
- **No authentication or per-user authorization.** The WS endpoint matches the current HTTP API's no-auth posture. Adding auth is a separable change that affects HTTP and WS together. **Strict additional check** beyond HTTP: WS upgrade rejects non-localhost Origin (see Security).
- **No cross-process file-watch in v1.** v1 assumes the pureclaw process serving HTTP/WS is the only writer to a given `transcript.jsonl`. The broker interface is designed so a future `mkFileWatchBroker` can be plugged in without changing the wire protocol (see Risks & Future Work).
- **No durable subscription state.** If the server restarts, all connections drop. Clients reconnect with `since=<lastEntryId>` to recover missed entries; activity events are not replayed across restarts (best-effort, not the source of truth).
- **No frontend changes outside the session-view + sidebar live-indicator components.** Other UI is unaffected.
- **No streaming completions HTTP API.** `POST /api/sessions/{sid}/send` keeps its current synchronous semantics. The response body still contains the final assistant text.
- **No chat-channel (Signal/Telegram) impact.** Live streaming is a frontend concept; chat channels are push-message-based.
- **No per-tab transcript filtering in the web UI.** With tabbed chat shipped, tabs share a `transcript.jsonl`; the UI shows them interleaved. Per-tab filtering is a v1.5 concern.

## Instrumentation Coverage

**This section directly addresses round-1 blocker #1.** It enumerates every site that writes to a `transcript.jsonl` today and specifies whether it is instrumented in v1 and how.

Sites where `mkFileTranscriptHandle` is called or `_th_record` is invoked:

### Write sites — must wrap

| Site | File:line | v1 instrumentation |
|---|---|---|
| `mkSessionHandle` constructs a session-level handle | `src/PureClaw/Session/Handle.hs:143` | **WRAP** with broadcasting decorator (covers UC-1, UC-3, UC-4) |
| `resumeSession` reopens a session-level handle | `src/PureClaw/Session/Handle.hs:250` | **WRAP** (same code path) |
| `handleSend → doCompletion` opens a per-request handle | `src/PureClaw/Frontend/API.hs:413` | **WRAP** (covers the web-POST sub-case; broker comes from `FrontendEnv._fe_broker`) |
| `handleNewSession` constructs a fresh session via `mkSessionHandle` | `src/PureClaw/Frontend/API.hs:323` | **TRANSITIVE** via `mkSessionHandle` (no separate change at this call site once `mkSessionHandle` itself wraps) |
| Slash-command session creation via `mkSessionHandle` | `src/PureClaw/Agent/SlashCommands.hs:2287` | **TRANSITIVE** via `mkSessionHandle`. The slash-command handler obtains the broker from `AgentEnv._env_broker` and passes it through. **AgentEnv gains `_env_broker :: Maybe StreamBroker`** as part of this work (see §Module Layout). |
| `mkTranscriptProvider` wraps a provider's call with transcript recording | `src/PureClaw/Transcript/Provider.hs` (lines 46, 65, 86, 112) | **TRANSITIVE** — `mkTranscriptProvider` writes to the `TranscriptHandle` it is given by the caller; as long as the caller's handle is broadcasting, the provider's `_th_record` calls broadcast. |

### Read-only sites — do not wrap

| Site | File:line | Rationale |
|---|---|---|
| `mkFileTranscriptHandle` opened for `_th_query` only | `src/PureClaw/Tools/SessionSearch.hs:80` | Read-only consumer; opens a handle, queries via `_th_query`, never records. No publish needed. **Explicitly excluded from the D6 allowlist test below.** |
| `mkNoOpTranscriptHandle` | `src/PureClaw/Handles/Transcript.hs:143` | Test-only no-op; not used in production paths. |

### Wrapping helper and policy

A single helper `mkBroadcastingFileTranscriptHandle :: Maybe StreamBroker -> SessionId -> LogHandle -> FilePath -> IO TranscriptHandle` does the file-handle construction *and* the wrap in one call. When the broker argument is `Nothing` (e.g., one-off scripts that load sessions without a frontend, or `mkNoOpSessionHandle`), the helper returns a plain file handle (no decorator).

All write-site callers switch to this helper. `mkSessionHandle` and `resumeSession` gain a `Maybe StreamBroker` parameter (existing call sites updated; the `Nothing` case preserves the legacy behavior for scripts and tests).

Sites where `_th_record` is invoked via the recorded `_th_record` field need no instrumentation — they go through the wrapped handle the SessionHandle was constructed with. These include:

- `src/PureClaw/Agent/SlashCommands.hs:~1130` (slash-command transcript writes)
- `src/PureClaw/Harness/ClaudeCode.hs:~143, ~176, ~308` (harness writes)
- `src/PureClaw/Transcript/Combinator.hs:49,71,86` (via `safeRecord`, which wraps `_th_record` in `try`)

## Architecture

### Components

```
                ┌─────────────────────────────────────────────────────────────┐
                │                    pureclaw process                          │
                │                                                              │
   HTTP POST    │  handleSend ──► mkBroadcastingFileTranscriptHandle ─┐        │
   /send        │                  (broker, sid)                      │        │
                │                                                     │        │
   CLI session  │  mkSessionHandle ──► mkBroadcastingFileTranscriptHandle──┐   │
   (mainline)   │  resumeSession   ──► …                                  │   │
                │                                                         │   │
                │                                  ┌──────────────────┐   │   │
                │                                  │  transcript.jsonl│   │   │
                │                                  │  (disk)          │   │   │
                │                                  └──────────────────┘   │   │
                │                                                         ▼   │
                │                                          ┌─────────────────────┐
                │                                          │   StreamBroker      │
                │   Activity probe loop ────publish───────►│ (in-process pub/sub │
                │   (forked via withAsync)                 │  bounded queues)    │
                │                                          └─────────┬───────────┘
                │                                                    │           │
                │  WS /api/stream ◄─── streamApp ◄── per-client subscriber       │
                │                       │                  (focus IORef,         │
                │                       │                   overflow TVar)       │
                │                                                                │
                └─────────────────────────────────────────────────────────────┘
                                        │
                                        │ WebSocket (one per browser tab)
                                        ▼
                                ┌─────────────────────────────────┐
                                │  Frontend (TS/React)            │
                                │                                 │
                                │  useTranscriptStream(sid)       │
                                │  useSessionActivityStream()     │
                                │  Shared WS client; auto-reconn. │
                                └─────────────────────────────────┘
```

### Broker (`PureClaw.Frontend.StreamBroker`, new module)

```haskell
module PureClaw.Frontend.StreamBroker
  ( StreamBroker (..)
  , BrokerEvent (..)
  , SessionActivity (..)
  , Subscription (..)
  , BrokerStats (..)
  , BrokerConfig (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  ) where

import Control.Concurrent.STM (TBQueue, TVar)
import Data.IORef (IORef)
import PureClaw.Session.Types (SessionId, SessionMeta)
import PureClaw.Transcript.Types (TranscriptEntry)
import PureClaw.Frontend.API (HarnessActivity)
  -- ^ HarnessActivity already defined in API.hs; promote to a shared location
  --   (Frontend.Activity.Types) when introducing this — see §Module Layout.

-- | Tagged event published by writers; consumed by subscribers (WS handlers).
data BrokerEvent
  = EntryRecorded   !SessionId !TranscriptEntry
  | ActivityChanged !SessionId !SessionActivity
  deriving stock (Show, Eq)

-- | Per-session signals for sidebar/tab live indicators.
data SessionActivity
  = SaEntryAt        !UTCTime                  -- ^ Cheap "ping": new entry at this timestamp; carries no payload.
  | SaHarnessStatus  !HarnessActivity          -- ^ "thinking" | "idle" | "stopped" — same union as Frontend.API.
  | SaSessionCreated !SessionMeta              -- ^ A new session appeared (carries the meta).
  deriving stock (Show, Eq)

-- | Subscription handle returned by `_streamBroker_subscribe`.
data Subscription = Subscription
  { _sub_queue    :: !(TBQueue BrokerEvent)
  , _sub_overflow :: !(TVar Bool)
  , _sub_cancel   :: !(IO ())
  }

data StreamBroker = StreamBroker
  { _streamBroker_publish    :: BrokerEvent -> IO ()
    -- ^ Non-blocking. STM-atomic: enqueue or (on full queue) pop oldest + enqueue + set overflow flag.
  , _streamBroker_subscribe  :: IO Subscription
    -- ^ Returns queue + overflow TVar + cleanup. The handler reads from the queue
    --   and from the overflow TVar (STM orElse); on overflow the handler sends
    --   `{type:"overflow"}` to its peer and disconnects.
  , _streamBroker_introspect :: IO BrokerStats
  , _streamBroker_config     :: BrokerConfig
    -- ^ Read-only accessor exposing the config to consumers (e.g.
    --   BroadcastingTranscriptHandle's capPayload needs _bc_maxEventBytes).
  }

data BrokerStats = BrokerStats
  { _bs_subscriberCount :: !Int
  , _bs_queueDepths     :: ![Int]
  }
  deriving stock (Show, Eq)

data BrokerConfig = BrokerConfig
  { _bc_queueDepth          :: !Int   -- ^ Per-subscriber TBQueue depth. Default 256.
  , _bc_maxSubscribers      :: !Int   -- ^ Per-process subscriber cap. Default 32.
  , _bc_maxSubsPerOrigin    :: !Int   -- ^ Per-origin subscriber cap (loosely "per IP"). Default 8.
  , _bc_maxEventBytes       :: !Int   -- ^ Per-event payload size cap. Larger entries are truncated with
                                       --   _te_metadata["truncated":true] and a console warn. Default 256 KB.
  }
defaultBrokerConfig :: BrokerConfig
defaultBrokerConfig = BrokerConfig 256 32 8 (256 * 1024)
```

**Why STM (not IORef).** Publish must atomically enqueue to N subscriber queues — doing so with IORef requires a global lock around the map *and* per-queue locks (or a CAS loop), which is strictly worse than STM transactions. The codebase preference for IORef applies to single-writer cells; multi-writer pub/sub is the canonical case where STM is the right primitive. We document this exception explicitly to forestall future "shouldn't this be IORef?" PRs.

**Overflow protocol — STM atomicity, explicit.**

```haskell
publish :: SubscriberMap -> BrokerEvent -> STM ()
publish subs ev =
  forM_ subs $ \Subscription{_sub_queue=q, _sub_overflow=ovTv} -> do
    full <- isFullTBQueue q
    when full $ do
      _ <- readTBQueue q              -- drop oldest
      writeTVar ovTv True
    writeTBQueue q ev                 -- write new
```

This is a single `atomically` block per publish (across all subscribers); the dequeue, write, and flag set are linearizable. The subscriber's handler reads from `(_sub_queue, _sub_overflow)` via `orElse`:

```haskell
nextSignal :: Subscription -> STM (Either OverflowSignal BrokerEvent)
nextSignal Subscription{_sub_queue=q, _sub_overflow=ovTv} =
  (Left . OverflowSignal <$> (readTVar ovTv >>= check)) `orElse`
  (Right <$> readTBQueue q)
  where check b = unless b retry
```

On the `Left OverflowSignal` path, the WS handler sends `{type:"overflow"}`, runs cleanup, and closes.

**Why the publish-to-every-subscriber + filter-at-subscriber policy.** Correct for v1's single-user-per-process posture. A future change with per-session subscriber lists is a routing optimization, not a correctness or interface change.

**Pair-publish atomicity.** When `BroadcastingTranscriptHandle` records an entry, it issues two publishes: `EntryRecorded` then `ActivityChanged (SaEntryAt _)`. These are **NOT atomic across the pair** — each publish is its own STM transaction. Under concurrent writers for different sessions, a subscriber may observe an interleaving like `EntryRecorded(A) → EntryRecorded(B) → ActivityChanged(A) → ActivityChanged(B)`. This is acceptable because subscribers match events by `sessionId` (the frontend hook `useTranscriptStream` keys by `entry.sessionId`; `useSessionActivityStream` keys by `activity.sessionId`); the pair carries the same `sessionId` and the activity is a derived signal. No per-session ordering invariant requires the pair to be atomic, and forcing it would complicate the broker contract without observable benefit.

**v1 implementation** (`mkInProcessBroker config`): a `TVar (Map SubscriberId Subscription)` keyed by a newtype `SubscriberId = SubscriberId Int` (monotonic counter, allocated under STM). `subscribe` enforces `_bc_maxSubscribers`; rejects with `BrokerError SubscriberCapReached` (the WS handler maps this to a 503 on the upgrade). Per-origin cap is enforced at the WS handler level using the upgrade request's `Origin` header (not the broker — the broker is origin-agnostic).

### Broadcasting transcript wrapper

```haskell
module PureClaw.Frontend.BroadcastingTranscript
  ( mkBroadcastingFileTranscriptHandle
  , mkBroadcastingTranscriptHandle
  ) where

import Control.Exception (SomeException, throwIO, try, fromException)
import Control.Exception (AsyncException, asyncExceptionFromException)
-- 'AsyncCancelled' is in Control.Concurrent.Async / GHC.Conc; import per project pattern.

-- | Open a new file-backed transcript handle that ALSO publishes to the broker.
-- The standard helper. All write-path call sites (mkSessionHandle, resumeSession,
-- handleSend) use this — never `mkFileTranscriptHandle` directly.
mkBroadcastingFileTranscriptHandle
  :: Maybe StreamBroker -> SessionId -> LogHandle -> FilePath -> IO TranscriptHandle
mkBroadcastingFileTranscriptHandle Nothing       _sid logger path = mkFileTranscriptHandle logger path
mkBroadcastingFileTranscriptHandle (Just broker) sid  logger path = do
  inner <- mkFileTranscriptHandle logger path
  pure (mkBroadcastingTranscriptHandle broker sid logger inner)

-- | Wrap an existing TranscriptHandle to publish broker events on record.
-- AsyncCancelled discipline (project memory): on AsyncCancelled, re-raise so
-- bracket-style cleanup runs; on other exceptions in `_th_record`, swallow and
-- log (matching `safeRecord` semantics from Transcript.Combinator) AND publish
-- so subscribers see the entry (documented divergence — see §Failure Modes; D34).
mkBroadcastingTranscriptHandle
  :: StreamBroker -> SessionId -> LogHandle -> TranscriptHandle -> TranscriptHandle
mkBroadcastingTranscriptHandle broker sid logger inner = inner
  { _th_record = \entry -> do
      let truncatedEntry = capPayload (_bc_maxEventBytes (_streamBroker_config broker)) entry
      r <- try @SomeException (_th_record inner entry)
      case r of
        Right ()
          -> publishSafely truncatedEntry
        Left e
          | Just (_ :: AsyncCancelled) <- fromException e -> throwIO e
          | otherwise -> do
              _lh_logWarn logger $ "transcript disk-write failed; in-memory broker still notified "
                                 <> "(entry=" <> _te_id entry <> ", session=" <> unSessionId sid <> "): "
                                 <> T.pack (show e)
              publishSafely truncatedEntry
  }
  where
    publishSafely e = do
      r <- try @SomeException $ do
        _streamBroker_publish broker (EntryRecorded   sid e)
        _streamBroker_publish broker (ActivityChanged sid (SaEntryAt (_te_timestamp e)))
      case r of
        Right () -> pure ()
        Left ex
          | Just (_ :: AsyncCancelled) <- fromException ex -> throwIO ex
          | otherwise -> _lh_logWarn logger ("broker publish failed: " <> T.pack (show ex))
```

`capPayload`: if `_te_payload`'s UTF-8 byte length exceeds the cap, truncate to the cap and add `_te_metadata.truncated = true` so the frontend can render a "[truncated]" badge. Per-event size cap is part of the broker's contract (the broker config is the source of truth); the wrapper enforces it before publish.

### WS endpoint (`PureClaw.Frontend.Stream`, new module)

Routing change in `apiApp`/`combinedApp`: `Network.Wai.Handler.WebSockets.websocketsOr` composes `streamApp` with `apiApp` so the WS endpoint (`GET /api/stream`) coexists with JSON routes.

**Connection guard.** `StreamGuard` is a module-local data structure (lives in `FrontendEnv._fe_streamGuard :: Maybe StreamGuard`, constructed alongside the broker at the top of `startWithChannel`) that enforces per-origin subscriber caps:

```haskell
data StreamGuard = StreamGuard
  { _streamGuard_perOrigin   :: !(TVar (Map Text Int))  -- live count per Origin
  , _streamGuard_maxPerOrigin :: !Int                   -- _bc_maxSubsPerOrigin
  }

-- Atomic try-claim: returns True if under cap (and increments), False otherwise.
tryClaim :: StreamGuard -> Text -> STM Bool
release  :: StreamGuard -> Text -> STM ()
```

`tryClaim` is called inside the upgrade handshake; `release` is invoked in the bracket cleanup. The per-origin counter is separate from the broker's subscriber map (which is origin-agnostic) but lives at the same lifetime (created and destroyed together).

Per-connection lifecycle:

1. **Upgrade handshake.**
   1. Read `Origin` header. If absent → reject with `403`.
   2. Match `Origin` against `_fc_allowedOrigins` (exact match semantics; see §Security). If no match → reject with `403`.
   3. `tryClaim` against `StreamGuard` for this `Origin`. If full → reject with `503`.
   4. Subscribe to broker. If global cap reached → release the claim, reject with `503`.
   5. Start a `Network.WebSockets.withPingThread` with **25 s interval and 10 s timeout** (sends a ping every 25 s; the lib disconnects if no pong within 10 s). This is the v1 keepalive — Warp's `setTimeout 30` does not apply to hijacked WS sockets per `wai-websockets` semantics (verified during round 3 against `wai-websockets` upstream).
2. **Hello.** Immediately send `{type:"hello", protocolVersion:"v1", serverStartedAt:"<UTC ISO8601>"}` before any other event. The `serverStartedAt` lets clients detect restarts; on a restart, the client must drop its cached `lastEntryId` and refetch via HTTP GET.
3. **Reader/writer race.** STM `orElse` between:
   - Inbound wire frames. Each frame is parsed via `try @SomeException (Aeson.eitherDecode bytes)`. Decode exceptions or malformed JSON → send `{type:"error", code:"invalid-frame"}`; connection stays open. Frames exceeding 4 KB → `{type:"error", code:"frame-too-large"}` and close.
   - Outbound broker events from the subscription queue (with overflow TVar).
4. **Focus state.** `IORef (Maybe SessionId)` per connection. Updated on `focus` op. The writer's filter for `EntryRecorded` events reads this IORef inside the writer thread immediately before sending — minimizing the focus-flip TOCTOU window (focus-flip drops any pending entries for the previous session still in the queue).
5. **Bracket cleanup.** On any disconnect (clean or abnormal): `_sub_cancel` is invoked, then `release` is called on the `StreamGuard` for this connection's `Origin`, then the ping thread is killed (via `withPingThread`'s scoped semantics — automatic on bracket exit). The subscriber is removed from the broker map; in-flight publishes that captured the queue ref before removal write to an orphan queue and are garbage-collected.

### Replay-on-reconnect

`{op:"focus", sessionId, since: <entryId>}` is the **single** mechanism for triggering replay. (No URL query-string `?since=`; no first-message-with-since separate from focus. The `since` parameter is optional but never `null` — omitting it means "no replay, live tail only".)

`{type:"replay-end", sessionId, lastReplayedEntryId}` is the **single** terminator that signals "live mode resumed for this session." (Round-2 had both a second `hello` and a `replay-end`; round 3 keeps only `replay-end`. The `hello` event is sent exactly once per WS connection, on connect.)

The replay algorithm is **snapshot-based** to eliminate the round-2 race between in-flight publishes and the file read:

1. Validate `sessionId` (path-traversal check via the shared `isValidSessionId` helper; see Security).
2. Validate `since`'s length (max 64 chars; UUID-ish bound). On invalid length, send `{type:"error", code:"invalid-frame"}`.
3. **Atomically (under STM)**: set a connection-local "replay-mode" flag (`TVar Bool` per `Subscription`, returned by `_streamBroker_subscribe`). While replay-mode is set, the WS writer thread inspects each incoming `EntryRecorded sid e` event for the focused `sessionId`: instead of forwarding to the client, it appends to a per-connection `bufferRef :: IORef [TranscriptEntry]`. Events for other sessions, and all `ActivityChanged` events, continue to flow through normally during replay.
4. Read `transcript.jsonl` via `readFileRaw`, wrapped in `try @SomeException`. On I/O error, send `{type:"error", code:"replay-failed"}`, clear the buffer + flag, and continue in live mode (the client falls back to HTTP GET).
5. Decode JSONL entries; drop entries whose `_te_id` is `since` or earlier in the file (file order = write order; see Id Allocation Invariant below). The remaining entries are the "missed-since-since" set, called `fileSlice`.
6. For each `e ∈ fileSlice`: send `{type:"entry", sessionId, entry: e}`.
7. **Atomically**: read `bufferRef`; for each buffered entry, if its `_te_id` is in `fileSlice` (the dedup set), skip; otherwise send. Then clear the buffer and the replay-mode flag in one transaction (any publish arriving *after* this point goes through the normal forwarding path).
8. Send `{type:"replay-end", sessionId, lastReplayedEntryId: <last forwarded entry id or null>}`.
9. Resume normal reader/writer race.

This eliminates the round-2 race: any publish that happened between the file read and "now" is in the buffer; the dedup set is built from the file slice. There is no window where an entry can be in neither the file nor the buffer.

If the client sends a *new* `focus` op while a replay is in progress (mid-stream switch), the server (a) discards the in-flight buffer, (b) does NOT emit a `replay-end` for the old session, (c) sends `{type:"error", code:"replay-aborted"}` if `_lh_logInfo` debug is enabled (advisory; otherwise silent), and (d) begins a new replay for the new focus. The client's bottom-bar pill should reflect "Catching up…" → "Catching up…" with the new sessionId.

**Id Allocation Invariant** (required for safe dedup): every `_te_id` is a unique UUID, generated *before* `_th_record` is called. This is already true in `Transcript.Combinator.withTranscript` (lines 33, 56) and in `Frontend.API.handleSend`'s provider call chain. The broadcasting decorator preserves this — it doesn't generate ids itself.

### Activity event source

`ActivityChanged` events come from two sources in v1:

1. **`BroadcastingTranscriptHandle`** emits `SaEntryAt (_te_timestamp entry)` after each `_th_record`. The frontend uses this single event to update both the unread badge and the "X seconds ago" label.
2. **Activity probe loop** (`PureClaw.Frontend.ActivityProbe`, new module): forked once at server startup via `Async.withAsync` (see §Lifecycle and Shutdown). Every 2 s, walks `_fe_harnesses`, calls `probeHarness` (already implemented in `Frontend/API.hs:155`), and emits `ActivityChanged sid (SaHarnessStatus ...)` for any harness whose status changed since the last probe. **First-tick semantics:** the first probe establishes the baseline; no events are emitted on the first tick. From the second tick onward, only transitions emit events. The probe loop is the **single source of truth** for harness-status events; there is no synchronous emission from `handleSend` (round-2 proposed this, but it raced the probe loop and produced wire-protocol double-emits — see Risks for the accepted 2 s latency).

`SaSessionCreated meta` is emitted from `handleNewSession`. No `session-deleted` in v1 (deletion is out of scope).

### Lifecycle and Shutdown

The broker and probe loop must be lifecycle-bounded against the WAI server, and the broker must exist **before** any call to `mkSessionHandle`/`resumeSession` (which happen at `CLI/Commands.hs:544` and `:569`, inside `startWithChannel` at line 504, well before `FrontendEnv` construction at line 653 in the current code).

Construction site: **top of `startWithChannel`** (before line 544's `resumeSession` call). Round-2 placed the broker at line 653, but that was after both `mkSessionHandle`/`resumeSession` had already constructed their TranscriptHandles. Round 3 moves construction earlier.

```haskell
-- BEFORE (current):
let startWithChannel :: ChannelHandle -> IO ()
    startWithChannel channel = do
      -- ... (lines 504-543) ...
      sh <- case resumeArg of
        Just sid -> ... resumeSession logger sessionsDir ...  -- line 544
        Nothing  -> ... mkSessionHandle logger sessionsDir initialMeta  -- line 569
      -- ... (lines 570-652) ...
      let env = AgentEnv { ... }
      let frontendEnv = FrontendEnv { ... }                         -- line 653
      void $ forkIO $ runFrontend defaultFrontendConfig (Just frontendEnv) logger  -- line 664
      runAgentLoopWith env reloadedMessages                          -- line 665

-- AFTER:
let startWithChannel :: ChannelHandle -> IO ()
    startWithChannel channel = do
      broker <- mkInProcessBroker defaultBrokerConfig    -- NEW: at top of body
      Async.withAsync (runActivityProbeLoop broker harnessRef logger) $ \_probeAsync -> do
        -- ... (lines 504-543) ...
        sh <- case resumeArg of
          Just sid -> ... resumeSession logger sessionsDir (Just broker) ...     -- threaded
          Nothing  -> ... mkSessionHandle logger sessionsDir initialMeta (Just broker)
        -- ... (lines 570-652) ...
        let env = AgentEnv { ..., _env_broker = Just broker }  -- carries broker
        let frontendEnv = FrontendEnv { ..., _fe_broker = Just broker }
        Async.withAsync (runFrontend defaultFrontendConfig (Just frontendEnv) logger) $ \_serverAsync ->
          runAgentLoopWith env reloadedMessages
```

`withAsync`'s linked semantics cancel both children when `runAgentLoopWith` returns or throws. The bare `forkIO $ runFrontend …` is replaced with `withAsync` so the WAI server has a parent scope; this also fixes a latent shutdown bug (the current code never joins).

**INVARIANT** (called out explicitly): exactly one `StreamBroker` is constructed in the binary's main process and shared across all WS connections, the activity probe loop, and every `mkSessionHandle`/`resumeSession` call. The broker is *not* per-request, per-session, or per-connection. Both `AgentEnv._env_broker` and `FrontendEnv._fe_broker` carry the same handle.

Both fields are wrapped in `Maybe StreamBroker` to preserve no-broker code paths (one-off scripts, `mkNoOpSessionHandle`, the legacy `runFrontend cfg Nothing logger` API). When the broker is `Nothing`, the WS endpoint returns 503; HTTP routes still work; non-broadcasting TranscriptHandles are used.

**Activity-probe loop bracket.**

```haskell
runActivityProbeLoop :: StreamBroker -> IORef (Map Text HarnessHandle) -> LogHandle -> IO ()
runActivityProbeLoop broker harnessesRef logger = do
  lastStatesRef <- newIORef Map.empty
  -- First tick: establish baseline, emit nothing.
  initial <- probeAll harnessesRef
  writeIORef lastStatesRef initial
  forever $ do
    threadDelay 2_000_000
    next <- probeAll harnessesRef
    prev <- readIORef lastStatesRef
    let transitions = Map.differenceWith
          (\new old -> if new == old then Nothing else Just new) next prev
    forM_ (Map.toList transitions) $ \(sid, status) ->
      _streamBroker_publish broker
        (ActivityChanged sid (SaHarnessStatus status))
    writeIORef lastStatesRef next
  `catch` \(e :: SomeException) -> case fromException e of
    Just (_ :: AsyncCancelled) -> throwIO e   -- cooperate with withAsync cancel
    Nothing -> _lh_logError logger ("activity-probe crashed: " <> T.pack (show e))
```

`AsyncCancelled` is re-raised per project memory. Other exceptions are logged but the loop is NOT restarted — a crashed probe loop should be visible at next session start. (Alternative: respawn with backoff. Either is defensible; preferring "loud failure" for v1.)

### Frontend changes

**Two hooks** (single shared WS client at module scope):

```ts
// frontend/src/types/stream.ts (new) — wire-protocol TS types, hand-mirrored from Haskell

export interface HelloEvent {
  type: 'hello';
  protocolVersion: 'v1';
  serverStartedAt: string; // ISO 8601
}
export interface EntryEvent {
  type: 'entry';
  sessionId: string;
  entry: TranscriptEntryInfo; // existing type from useApi.ts
}
export type ActivityEvent =
  | { kind: 'entry-at'; timestamp: string /* ISO 8601 */ }
  | { kind: 'harness-status'; status: 'thinking' | 'idle' | 'stopped' }
  | { kind: 'session-created'; session: SessionInfo /* existing */ };
export interface ActivityEnvelope {
  type: 'activity';
  sessionId: string;
  activity: ActivityEvent;
}
export interface ReplayEndEvent {
  type: 'replay-end';
  sessionId: string;
  lastReplayedEntryId: string | null;
}
export interface OverflowEvent { type: 'overflow'; }
export interface ErrorEvent {
  type: 'error';
  code: 'invalid-op' | 'invalid-frame' | 'session-not-found' | 'frame-too-large'
      | 'replay-failed' | 'replay-aborted' | 'internal';
  message: string;
}
export type ServerEvent =
  | HelloEvent | EntryEvent | ActivityEnvelope | ReplayEndEvent
  | OverflowEvent | ErrorEvent;

// Client → server ops.
export type ClientOp =
  | { op: 'focus'; sessionId: string | null }
  | { op: 'focus'; sessionId: string; since: string };

// frontend/src/lib/streamClient.ts (new) — singleton WS client + reconnect logic
export type StreamStatus = 'connecting' | 'live' | 'reconnecting' | 'replaying' | 'closed';
export interface StreamClient {
  /** Current connection status. */
  status: StreamStatus;
  /** Send a focus op. `since` triggers replay; omit for live-tail only. */
  focus(sessionId: string | null, since?: string): void;
  /** Subscribe to entries (focused session only). */
  onEntry(cb: (e: TranscriptEntryInfo) => void): () => void;
  /** Subscribe to activity events (ALL sessions). */
  onActivity(cb: (sid: string, a: ActivityEvent) => void): () => void;
  /** Subscribe to status changes. */
  onStatusChange(cb: (s: StreamStatus) => void): () => void;
  /** Last error message, or null. Distinguishes hard errors (e.g. 403/503) from clean closes. */
  lastError(): string | null;
}

// frontend/src/hooks/useTranscriptStream.ts (new)
export interface UseTranscriptStream {
  /** Entries for the focused session: initial HTTP GET seed + WS-delivered tail, deduped by id, in _te_timestamp order. */
  entries: TranscriptEntryInfo[];
  status: StreamStatus;
  /** Non-null when status === 'closed' and the close was due to an error (e.g. 403 Origin reject). */
  lastError: string | null;
}
export function useTranscriptStream(sessionId: string | null): UseTranscriptStream { ... }

// frontend/src/hooks/useSessionActivityStream.ts (new)
export interface SessionActivityState {
  harness: 'thinking' | 'idle' | 'stopped' | null;
  unread: number;        // count of entries since last focus or since mount
  lastEntryAt: string | null; // ISO timestamp, drives "X seconds ago"
}
export interface UseSessionActivityStream {
  sessions: Record<string, SessionActivityState>;
  status: StreamStatus;
  lastError: string | null;
}
export function useSessionActivityStream(): UseSessionActivityStream { ... }
```

**Status union → UX mapping.** The five statuses map to the bottom-bar pill:
- `connecting` (initial connect in progress): "Connecting…"
- `live` (no pill rendered — happy path)
- `replaying` (catching up after `focus` with `since`): "Catching up…"
- `reconnecting` (WS dropped; auto-retry in progress): "Reconnecting… (n)"
- `closed` (terminal): rendered with `lastError` if non-null ("Disconnected: <reason>. Click to retry.") or as a clean close ("Disconnected. Click to retry."). Examples of non-null `lastError`: `403 Forbidden — Origin not allowed`, `503 Service Unavailable — connection cap reached`. Auto-retry stops after 5 attempts; manual click re-tries.

**Reconciliation contract** (resolves Designer blocker on `useTranscriptStream` shape ambiguity). The hook owns:
- An initial HTTP GET on mount (existing endpoint).
- A focus op to the WS client with `since` = the largest `_te_id` from the initial GET (if any).
- A merge of the GET seed with subsequent WS `entry` events.
- Dedup by `_te_id` (Set lookup).
- Sort by `_te_timestamp` ascending (entries arrive in this order normally; sort is defense against out-of-order delivery during reconnect-replay edge cases).

**TypeScript types provenance**: hand-mirrored from Haskell ADTs in `frontend/src/types/stream.ts`. A round-trip test in the integration suite verifies a canonical sample event roundtrips correctly between Haskell-encoded JSON and the TS type definitions (via a golden-file comparison). When `aeson-typescript` or similar codegen is adopted later, this test becomes the regression seam.

**Connection UX**: a small bottom-bar pill rendered when `status !== 'live'`:
- `connecting`: "Connecting…"
- `reconnecting`: "Reconnecting… (n attempt)"
- `replaying`: "Catching up…"
- `closed`: "Disconnected. Click to retry." (no auto-retry past 5 attempts)

## Wire Protocol

WebSocket text frames. Each message is one JSON object. Discriminant: `type` for server→client; `op` for client→server. (The asymmetry is intentional: keeping them distinct prevents server-side bugs that accidentally process a client→server `op` as if it were a server→client `type`, and vice versa, during refactors. The TS types use two disjoint discriminated unions; tooling cost is minor.)

### Client → Server

```jsonc
// Focus a session (optionally requesting replay from `since`):
{ "op": "focus", "sessionId": "session-abc-123" }
{ "op": "focus", "sessionId": "session-abc-123", "since": "te-uuid-42" }
// Unfocus (stop receiving entries; activity still streamed):
{ "op": "focus", "sessionId": null }
```

No `{op:"ping"}` (WS protocol-level pings are handled by the library; an app-level ping has no concrete consumer in v1).

### Server → Client

```jsonc
// Greeting; sent EXACTLY ONCE per WS connection, on connect (before any other server→client event).
// Never resent after replays — replay completion is signalled by `replay-end` (see below).
{ "type": "hello",
  "protocolVersion": "v1",
  "serverStartedAt": "2026-05-22T18:00:00Z" }

// A finalized transcript entry, only for the currently focused session.
{ "type": "entry",
  "sessionId": "session-abc-123",
  "entry": { /* TranscriptEntryInfo, same shape as the HTTP GET response (camelCase). */ } }

// Activity (for any session, regardless of focus). Discriminant on activity.kind.
{ "type": "activity", "sessionId": "session-abc-123", "activity": { "kind": "entry-at", "timestamp": "2026-05-22T18:00:01.234Z" } }
{ "type": "activity", "sessionId": "session-abc-123", "activity": { "kind": "harness-status", "status": "thinking" } }
{ "type": "activity", "sessionId": "session-abc-123", "activity": { "kind": "session-created", "session": { /* SessionInfo */ } } }

// Replay terminator: emitted after a replay sequence completes; signals "live mode resumed for this session".
// `lastReplayedEntryId` is the id of the last `entry` event in the replay sequence, or null if replay sent zero entries.
{ "type": "replay-end", "sessionId": "session-abc-123", "lastReplayedEntryId": "te-uuid-42" | null }

// Overflow signal: the server's outbound queue for this client overflowed. Client should reconnect with `since`.
{ "type": "overflow" }

// Error events.
{ "type": "error",
  "code": "invalid-op" | "invalid-frame" | "session-not-found" | "frame-too-large" | "replay-failed" | "replay-aborted" | "internal",
  "message": "<human-readable>" }
```

Note: the round-2 `hello.focusedSessionId` and `hello.lastReplayedEntryId` fields are removed (focus is established by the first `focus` op; replay completion is signalled by `replay-end`).

### Forward-compatibility

- Unknown `op` from client → server sends `{type:"error", code:"invalid-op"}`. Connection stays open.
- Unknown `type` or `activity.kind` from server → client → TS code logs at debug level and discards. This is a *behavioral DoD* (D-fwd-compat) verified by an integration test that injects a synthetic unknown event.

### Frame size limit

Inbound WS frames are bounded at **4 KB** (largest legitimate frame is `{op:"focus", sessionId, since}` ≈ 200 B; 4 KB is generous). Frames exceeding the limit are rejected with `{type:"error", code:"frame-too-large"}` and the connection is closed. Outbound entry frames are limited by `_bc_maxEventBytes` (256 KB by default; entries larger than this are truncated with `_te_metadata.truncated = true`).

## Reconnect, Resume, Backpressure, Failure Modes

| Scenario | Behavior |
|---|---|
| WS dropped (network blip) | Client reconnects with exponential backoff (250 ms → 5 s, jittered, max 5 attempts). On reconnect, the client sends `{op:"focus", sessionId, since: <lastEntryId>}` once the WS opens. The server replays missed entries; activity events from the dropped period are lost (best-effort). |
| Server restart | Client sees a new `serverStartedAt` in `hello` (vs. the previously stored one). On detection, the client drops its cached `lastEntryId` and **refetches via HTTP GET**, then resumes with `since` = new max id. This prevents trusting `since` against a possibly different `transcript.jsonl` state. |
| Slow client | Per-subscriber bounded queue (256). On overflow: STM-atomic pop oldest + write new + set overflow TVar. The handler reads the TVar via `orElse`, sends `{type:"overflow"}`, runs cleanup, closes. The client reconnects with `since`. |
| Malformed inbound frame (bad JSON) | Server catches the decode exception with `try @SomeException`, sends `{type:"error", code:"invalid-frame"}`, keeps the connection open. |
| Malformed inbound op (parsed but unknown) | `{type:"error", code:"invalid-op"}`; connection stays open. |
| Frame over 4 KB inbound | `{type:"error", code:"frame-too-large"}`; connection closes. |
| Focus → unknown sessionId | `{type:"error", code:"session-not-found"}`; focus state remains whatever it was. |
| Focus → invalid sessionId (path traversal) | Same as session-not-found (deliberately conflated; no info leak). |
| Replay file read fails | `{type:"error", code:"replay-failed"}`; client falls back to HTTP GET. The error is `_lh_logError`'d. |
| Frontend tab in background | The browser may suspend the WS. The client's heartbeat detection (no message received for 60 s) triggers reconnect. (Note: WS-level pings still keep the socket warm in most browsers; this is a defensive fallback.) |
| Multiple WS connections from one client | Allowed (e.g., two browser windows). Each gets its own subscription. Same machinery. Subject to the per-origin subscriber cap. |
| Subscriber cap reached | Upgrade is rejected with 503; client surfaces an error message. |
| Broker subscribe leak | Bracket pattern in the WS handler guarantees `_sub_cancel` on disconnect. `_streamBroker_introspect` is exposed (callable from a future `/api/debug` endpoint). |
| `_th_record` throws (synchronous) | The decorator catches with `try @SomeException`. AsyncCancelled is re-raised. Other exceptions: the wrapper still publishes to the broker (deliberate — the entry's existence in memory is announced; disk-write failure is logged but doesn't suppress the broadcast). **Known divergence:** an entry can exist in the broker stream but not on disk; on reconnect with `since`, that entry is invisible to the file-replay path. Acknowledged tradeoff; v1.5 may add a `durable` flag in the broker event so the WS handler can surface "this entry is not durable" hints to the client. |
| Broker `publish` throws | The decorator catches; AsyncCancelled re-raised; other exceptions swallowed (broker failures must not poison recording). |
| Probe loop crashes | Logged; loop terminates (no auto-restart in v1). Server keeps running. AsyncCancelled re-raised so `withAsync` shutdown is clean. |

## Security

This work matches the existing HTTP API posture with **one strict addition** (Origin allowlist for WS) and **one hardening fix** (Warp connection limits previously missing per `SECURITY_PRACTICES.md §9.1`).

### Threat model

| Risk | Vector | Mitigation |
|---|---|---|
| **High** — drive-by malicious local page reads transcripts via WS | A localhost page (different port, attacker-controlled) opens `ws://localhost:8080/api/stream` — browser SOP/CORS do not apply to WS the same way they do to XHR | **Origin allowlist on upgrade** (see Origin matching semantics below) with exact-string matching. D7 + D31 verify. |
| **High** — resource exhaustion via unbounded WS connections | Slow-loris / connection flood holds many WS open; current `Server.hs:46` doesn't set `setMaxTotalConnections` or `setTimeout` | **Four layers**: (a) Warp settings: `setMaxTotalConnections 1024` + `setTimeout 30` (idle) — Warp's timeout does NOT apply to hijacked WS sockets, so it only protects the non-WS HTTP routes; (b) **WS ping discipline**: `Network.WebSockets.withPingThread` 25 s interval, 10 s pong timeout — silent peers are forcibly disconnected (D32); (c) global broker cap `_bc_maxSubscribers 32`; (d) per-origin cap `_bc_maxSubsPerOrigin 8` enforced via `StreamGuard` at WS upgrade (D30). |
| **Medium** — replay amplification | Repeated reconnects with bad `since` force full-file re-reads | (a) Bound `since` to 64 chars + DoD verifies rejection (D27); (b) reconnect rate limit is client-side only in v1 — documented gap for v1.5; (c) `since` validation rejects malformed shapes cheaply. |
| **Medium** — activity events leak existence of all sessions | All `ActivityChanged` events go to every subscriber regardless of focus; an attacker who connects learns of every session on the machine | **Documented as new exposure** (was not reachable via HTTP without an explicit GET). Origin allowlist + local-dev posture make this acceptable for v1. Future auth retrofit must scope activity events to authorized session set. |
| **Medium** — provider error text exfiltration | If `mkTranscriptProvider` records raw provider errors that include partial credentials, those reach the broker and WS | **Pre-existing requirement**: `mkTranscriptProvider` must record `PublicError`-stripped payloads (per `SECURITY_PRACTICES.md §6.1`). v1 of this work *verifies* (test seam) that error payloads recorded by `mkTranscriptProvider` are PublicError-stripped before they reach `_th_record`. If they are not, a separate hardening issue is filed; this work does not introduce the gap. |
| **Low** — aeson decode exception teardown | A malformed inbound frame triggers an unhandled decode exception, killing the reader | **`try @SomeException` around `Aeson.eitherDecode`**; emit `{type:"error", code:"invalid-frame"}`. D29 verifies. |
| **Low** — sessionId path traversal | `focus.sessionId` containing `..` or `/` allows file-system traversal during replay | Shared helper: `isValidSessionId :: Text -> Bool`. Used by `handleTranscript`, `handleSetPrompt`, `handleSend`, **AND** the new `focus` op. D26 verifies. |
| **Low** — in-memory entry never reaches disk | Round-2 chose to publish to the broker even when `_th_record` throws a non-async exception. A WS client could see an entry that isn't in `transcript.jsonl`. On reconnect with `since`, the entry is invisible. | Documented as known divergence (see §Reconnect/Failure Modes table). Disk-write failures are rare (filesystem error / out-of-space); the alternative (skip publish on disk failure) creates a worse user experience for the common case. v1.5 may introduce per-entry "durable" flag in the broker event. |

### Origin matching semantics

`_fc_allowedOrigins :: [Text]` is matched against the request's `Origin` header with the following rules:

1. If `Origin` header is **absent**, reject with `403` (no `Origin` is never a match).
2. If `_fc_allowedOrigins` is the **empty list**, reject with `403` (no origin is admitted — this is the deny-all configuration).
3. Match is **exact-string** against the full `Origin` value (`scheme://host:port`). Substring / prefix / suffix matching is NOT supported.
4. Match is **case-insensitive on scheme and host** (per RFC 6454), **case-sensitive nowhere else**. The comparator normalizes both sides to lowercase before comparing the scheme and host components; port is compared as-is.
5. **No wildcard support** in v1. Configure each origin explicitly. (The HTTP API's `Access-Control-Allow-Origin: *` posture is documentation-only — this work does not add a wildcard escape hatch to the WS path.)
6. Default value: `["http://localhost:<port>", "http://127.0.0.1:<port>"]` where `<port>` is the configured frontend port. Override by setting `_fc_allowedOrigins` in `FrontendConfig`.
7. No Unicode normalization. Host names are compared byte-for-byte after lowercasing the scheme and host components. Punycode-encoded IDN hostnames (`xn--*`) are compared as-presented — homoglyph attacks via Unicode lookalikes are foreclosed because such hosts arrive as either the byte-encoded form (which won't match `localhost`) or as raw Unicode that fails lowercase-ASCII matching.

**StreamGuard key normalization.** The `_streamGuard_perOrigin :: TVar (Map Text Int)` counter is keyed by the **normalized** Origin string (after applying rule 4's lowercase-on-scheme-and-host). Without normalization, a peer alternating `http://LOCALHOST:8080` and `http://localhost:8080` would get two slots in the map. The normalization function `normalizeOrigin :: Text -> Text` is applied both before matching against `_fc_allowedOrigins` and before keying into `_streamGuard_perOrigin`.

D31 verifies that `Origin: http://localhost.evil.com:8080` (a host that *contains* `localhost` as a substring) is rejected with `403`.

### OWASP-relevant checks

- **A01 Broken Access Control** — N/A (no auth by design; new Origin check is documented as the only access primitive).
- **A03 Injection** — JSON parse exceptions caught (D29); `sessionId` validated (D26); `since` length-bounded (D27).
- **A04 Insecure Design** — addressed by the explicit threat model above; the deliberate WS-firehose-with-Origin-allowlist trade-off is documented.
- **A05 Security Misconfiguration** — Warp settings explicitly set (D20); WS ping discipline added (D32); resolves pre-existing `SECURITY_PRACTICES.md §9.1` gap.
- **A06 Vulnerable & Outdated Components** — new dependency `wai-websockets` pinned via `cabal.project.freeze`. The cabal freeze file is updated in WU3; reviewers verify no known CVEs at the chosen version before merge.
- **A07 Auth Failures** — N/A.
- **A09 Security Logging Failures** — replay-read errors logged via `_lh_logError`. Origin reject + cap-reached events logged (`_lh_logWarn`) with the Origin string and remote address (from `Wai.Request.remoteHost`).

## Test Seams

| Seam | Coverage target |
|---|---|
| `StreamBroker` unit tests | publish-then-subscribe (no replay buffer); subscribe-then-publish; multi-subscriber fanout in order; per-subscriber TBQueue isolation; overflow protocol (drop oldest + flag set); cleanup removes from map; subscriber cap reached returns error; `_streamBroker_introspect` reflects current state. |
| `BroadcastingTranscriptHandle` unit tests | Wraps a mock TranscriptHandle (capturing IORef); publishes `EntryRecorded` and `ActivityChanged (SaEntryAt _)` on record; AsyncCancelled in `_th_record` is re-raised; non-async exceptions in `_th_record` still publish; broker publish failures don't propagate; payload over `_bc_maxEventBytes` truncated. |
| `ActivityProbe` unit tests | No event emitted on first tick (baseline); transitions emit; non-transitions don't; AsyncCancelled re-raised on shutdown. |
| `Frontend.Stream` integration tests | Use `Warp.testWithApplication` + `openFreePort` (new test helper in `test/Frontend/StreamHarness.hs`). Cover: hello on connect; focus + entry; unfocus + no entries; replay from `since`; dedup against in-queue duplicates; overflow → reconnect → replay; invalid-op; invalid-frame; frame-too-large; session-not-found; Origin reject (403 on bad Origin). Server-restart simulation: stop+start; client detects new `serverStartedAt`. |
| `BroadcastingFileTranscriptHandle` end-to-end test | Write through `mkSessionHandle` (CLI path) — verify the entry reaches a connected WS client. This is the regression test for round-1 blocker #1. |
| Wire-protocol golden test | JSON sample of every event variant; roundtrip through Haskell encode/decode; byte-equal to fixtures in `test/Frontend/fixtures/stream-events/*.json`. The TS type tests (frontend) import the same fixtures. |
| Forward-compat test | Inject a synthetic `{type:"future-event"}` into the WS stream from a mocked publisher; TS hook ignores; no crash. |
| Frontend hook tests (Vitest) | `useTranscriptStream`: HTTP GET seed + WS append; dedup by id; sort by timestamp; status union transitions on connect/disconnect/reconnect. `useSessionActivityStream`: harness state updates; unread badge increments and clears on focus; entry-at updates lastEntryAt. Setup: ~30 LoC `vite.config.ts` + `vitest.config.ts` added to `frontend/`; CI step added to run `pnpm test` after build. |
| Frontend hook contract test | Run the integration server, connect via real WS from a Node-based test, verify the hook contract (entries arrive, dedup works) against a real backend. (Lower priority; could be follow-up.) |

## Definition of Done

Behavioral DoDs (verifiable by running the app or by automated test). Each DoD has one verification method named.

| DoD | Wording | Verification |
|---|---|---|
| **D1** | `mkInProcessBroker` returns a handle on which publish→subscribe round-trips a known event in order, and a subsequent `_sub_cancel` removes the subscriber from `_streamBroker_introspect` results. | Broker unit test. |
| **D2** | With 3 subscribers and 10 published events, each subscriber receives all 10 in publish order. | Broker unit test. |
| **D3** | A subscriber whose queue is full causes `_streamBroker_publish` to drop the oldest event, write the new one, and set the subscriber's `_sub_overflow` TVar — all in one STM transaction (no observable intermediate state). The WS handler reading via `orElse` sends `{type:"overflow"}` and closes. | Broker unit test + Stream integration test. |
| **D4** | A `mkBroadcastingTranscriptHandle` wrapping a mock inner handle: when `_th_record` is called, the inner record runs once, then one `EntryRecorded sid entry` and one `ActivityChanged sid (SaEntryAt entry.timestamp)` are published, in that order. | Broadcasting unit test. |
| **D5** | A CLI agent loop writes a transcript entry via `mkSessionHandle`'s handle. A separate WS client connected to `/api/stream` with `focus: sid` receives an `{type:"entry", sessionId:sid, entry}` event whose `entry._te_id` matches. (End-to-end regression test for round-1 blocker #1.) | E2E test with two threads + WS client. |
| **D6** | `src/` contains `mkFileTranscriptHandle` only at the following allowed sites: (a) the definition in `Handles/Transcript.hs`; (b) the wrapping helper in `Frontend/BroadcastingTranscript.hs`; (c) the read-only consumer in `Tools/SessionSearch.hs` (which uses only `_th_query`, never `_th_record`). Any other occurrence in `src/` fails the test. (Tests in `test/` are exempt and may call `mkFileTranscriptHandle` directly to exercise the file backend.) | CI script (`scripts/lint-transcript-handles.sh`) greps `src/` for `mkFileTranscriptHandle`, computes the call-site set, and diffs against the allowlist literal `{Handles/Transcript.hs, Frontend/BroadcastingTranscript.hs, Tools/SessionSearch.hs}`. Non-empty diff fails the build. |
| **D7** | `GET /api/stream` upgrades to WebSocket when `Origin` matches the allowlist, returns 403 otherwise, and returns 503 when the subscriber cap is exceeded. | Stream integration test. |
| **D8** | On connect, the client receives `{type:"hello", protocolVersion:"v1", serverStartedAt:<ISO>}` before any other event. The hello payload has exactly these three fields — no `focusedSessionId`, no `lastReplayedEntryId`. | Stream integration test. |
| **D9** | After `{op:"focus", sessionId}`, the client receives subsequent `entry` events for that session and ONLY that session; switching focus stops the previous stream within 50 ms. | Stream integration test. |
| **D10** | `activity` events for ALL sessions are received regardless of focus. | Stream integration test. |
| **D11** | A reconnecting client that sends `{op:"focus", sessionId, since:<id>}` receives a replay of entries written after `since` (filtered against in-queue duplicates), followed by a `{type:"replay-end"}` event, followed by live entries. No duplicates. | Stream integration test. |
| **D12** | `focus` with a sessionId containing `..` or `/` returns `{type:"error", code:"session-not-found"}` (no info leak). Focus state unchanged. | Stream integration test. |
| **D13** | Inbound frames > 4 KB are rejected with `{type:"error", code:"frame-too-large"}` and the connection closes. | Stream integration test. |
| **D14** | The frontend test suite (Vitest) is configured and runs in CI; `useTranscriptStream`'s reconciliation logic is unit-tested with at least: HTTP-seed-only, WS-tail-only, seed-then-tail with dedup, out-of-order timestamps. | `pnpm test` in CI; CI fails on hook regression. |
| **D15** | End-to-end latency from `_th_record`'s return to `entry` arriving at the WS client on localhost is ≤ 50 ms p50 and ≤ 500 ms p95 over a 100-entry burst. (p50 catches regressions that hide under a loose p95.) | Stream integration test with explicit timing assertion. |
| **D16** | The sidebar UI shows a spinner on a session row within ≤ 2.5 s of its harness transitioning to thinking, and clears the spinner within ≤ 2.5 s of an idle/stopped transition. Both directions are driven by the 2 s activity probe loop (the sole source of `SaHarnessStatus` events in v1; no synchronous emission). The 2.5 s budget = 2 s probe interval + 0.5 s slack. | Manual visual test against the running app; documented in `docs/BEHAVIORAL_TEST_PLAN.md`. |
| **D17** | Activity probe loop emits one `ActivityChanged` per state transition (not per probe tick), and emits zero events on the first tick. | Probe unit test. |
| **D18** | `handleNewSession` publishes `ActivityChanged sid (SaSessionCreated meta)`. | Stream integration test: POST `/sessions/new`, observe activity event. |
| **D19** | The TS client logs and ignores unknown `type` or `activity.kind` values (forward compatibility). | Frontend unit test with a synthetic unknown event. |
| **D20** | Warp settings: `setMaxTotalConnections 1024` and `setTimeout 30` are applied to the frontend server (fixes pre-existing `SECURITY_PRACTICES.md §9.1` gap). | `test/Gateway/ServerSpec.hs`-style test that inspects the Warp settings builder OR an integration test that asserts connection-limit behavior. |
| **D21** | Coverage gate: ≥ 95% per `.coverage-thresholds.json` on all new Haskell modules (StreamBroker, BroadcastingTranscript, Stream, ActivityProbe). | `cabal test --enable-coverage`; orchestrator validates. |
| **D22** | `pureclaw.cabal` declares the new modules and adds `wai-websockets` dependency. Build clean with `-Wall -Werror`. | Build step in CI. |
| **D23** | Existing endpoints (`GET /api/sessions/{sid}/transcript`, `POST /api/sessions/{sid}/send`, `POST /api/sessions/new`, `GET /api/harnesses`, `PUT /api/sessions/{sid}/prompt`, `GET /api/agents`) behave identically before and after. | New regression tests in `test/Frontend/APISpec.hs` (currently no Frontend tests exist; this is part of the work). |
| **D24** | Lifecycle: when the binary's `runAgentLoopWith` exits, the WAI server and the activity probe loop are cancelled within 1 s. | Manual smoke test + a unit test on the bracket structure. |
| **D25** | `mkTranscriptProvider`-recorded entries pass through the broadcasting decorator. The actual call chain instrumented in v1: in `handleSend → doCompletion` (at `Frontend/API.hs:413`), the file handle is opened via `mkBroadcastingFileTranscriptHandle broker sid logger transcriptPath`; this broadcasting handle is then passed to `mkTranscriptProvider`. The provider's recorded Request and Response entries therefore reach the broker. | E2E test: a WS client subscribes with `focus: sid`; HTTP POST to `/api/sessions/{sid}/send` runs a fake provider through `mkTranscriptProvider`; client sees both Request and Response `entry` events. |
| **D26** | `isValidSessionId :: Text -> Bool` (shared helper) is called by `handleTranscript`, `handleSetPrompt`, `handleSend`, AND the `focus` op handler. | grep test in CI: each handler must have `isValidSessionId` in its source path. |
| **D27** | A `focus` op with `since` longer than 64 characters is rejected with `{type:"error", code:"invalid-frame"}` and the focus state is unchanged. | Stream integration test. |
| **D28** | An I/O error during replay file read produces `{type:"error", code:"replay-failed"}`; the connection stays open; `_lh_logError` recorded the error. | Stream integration test (uses a test seam that toggles `readFileRaw` to throw). |
| **D29** | A malformed JSON inbound frame produces `{type:"error", code:"invalid-frame"}`; the connection stays open; `_lh_logWarn` recorded the frame. | Stream integration test (sends raw garbage). |
| **D30** | The 9th simultaneous WS upgrade attempt from the same `Origin` is rejected with `503` (per-origin cap `_bc_maxSubsPerOrigin = 8`). On disconnect of any of the 8 existing connections, the next attempt from that Origin succeeds. | Stream integration test that opens 9 connections from the same Origin and asserts 8 succeed + 9th gets 503. |
| **D31** | A WS upgrade with `Origin: http://localhost.evil.com:8080` is rejected with `403` even though `localhost` appears as a substring (verifies exact-match Origin semantics). Likewise an upgrade with no `Origin` header is rejected with `403`. | Stream integration test. |
| **D32** | The WS handler uses `Network.WebSockets.withPingThread` with a 25 s interval. A peer that stops responding to pings is forcibly disconnected within ≤ 35 s of going silent. Forcible disconnect is logged via `_lh_logWarn` with the Origin and remote address. | Stream integration test (a silent peer simulator that ignores pings; assert disconnect within budget; assert log line emitted). |
| **D33** | The `internal` error code is emitted **only** from the WS writer thread when an exception escapes the per-message handling logic (i.e., never expected under normal operation). The handler logs via `_lh_logError` with the exception text, sends `{type:"error", code:"internal"}`, and closes the connection. | Stream integration test: inject an exception into a publish-handling code path via a test seam and assert the wire event + log line. |
| **D34** | When `_th_record` throws a non-`AsyncCancelled` exception (broadcasting decorator's documented disk-error path), the wrapper publishes to the broker AND emits `_lh_logWarn` with the entry id, session id, and exception text. This makes the in-memory-vs-disk divergence auditable per `SECURITY_PRACTICES.md §9`. | Unit test on the wrapper with a mock inner that throws. |
| **D5b** | E2E: a CLI agent loop writes a transcript entry through `mkSessionHandle`'s broadcasting handle; a WS client connected to `/api/stream` with `focus: sid` receives `{type:"entry", sessionId:sid, entry}` whose `entry._te_id` matches the on-disk entry. (D5 verifies the broker-level path in WU2; D5b verifies the full wire-level E2E in WU3.) | E2E test with two threads + a real WS client. |
| **D35** | Across distinct origins (all on the allowlist), the 33rd simultaneous WS upgrade attempt is rejected with `503` (global `_bc_maxSubscribers = 32`). On disconnect, a 33rd subsequent attempt succeeds. | Stream integration test that opens 32 connections from 32 distinct allowed origins, asserts 32 succeed, then asserts the 33rd gets 503. |
| **D36** | An unknown client `op` (e.g., `{op:"future-op"}`) produces `{type:"error", code:"invalid-op"}`; the connection stays open. | Stream integration test. |
| **D37** | A WS client that stores a `serverStartedAt` from one connection, observes a different `serverStartedAt` on reconnect (after a simulated server restart), drops its cached `lastEntryId`, and refetches the transcript via HTTP GET before requesting WS `focus`. | Frontend Vitest test that mocks the hello event sequence and asserts the HTTP GET is issued; integration test asserts the WS client behavior end-to-end. |
| **D38** | Provider errors recorded via `mkTranscriptProvider` are PublicError-stripped before reaching `_th_record` (and hence the broker / WS subscribers). A test injects a fake provider that returns an error containing partial credentials; the broker subscriber observes a PublicError-stripped payload. If verification fails, a separate hardening issue is filed; this work does not enlarge the existing exposure. | Test in `test/Frontend/BroadcastingTranscriptSpec.hs` with a fake provider via `mkTranscriptProvider`. |
| **D39** | UC-3: two WS clients (simulating two browser windows) connected to `/api/stream` with `focus: sid` on the same session observe entries in matching order (each client sees entries in `_te_timestamp` order; relative order of any pair of entries agrees between clients). | Stream integration test with two parallel WS client subscriptions. |
| **D40** | A `focus` op that switches sessionId during an in-flight replay aborts the current replay (the in-flight buffer is discarded, no `replay-end` is emitted for the old session, an `{type:"error", code:"replay-aborted"}` event is emitted under debug logging) and starts a new replay for the new sessionId. | Stream integration test that simulates a focus switch mid-replay. |

## Workflow / Work Units

Decomposing this design into work units that respect dependencies and stack cleanly. Each WU is independent enough to be reviewable and merge-ready on its own; later WUs depend on earlier ones.

1. **WU1 — StreamBroker module + tests** (D1, D2, D3). Pure new module; no integration. ~250 LoC + tests. ~95% coverage.
2. **WU2 — Broadcasting decorator + standard helper** (D4, D5, D6, D25, D34). Adds `BroadcastingTranscript.hs` + helper (`mkBroadcastingFileTranscriptHandle`, `mkBroadcastingTranscriptHandle` taking a `LogHandle`). Adds `scripts/lint-transcript-handles.sh` for D6. Updates `mkSessionHandle`/`resumeSession` (new `Maybe StreamBroker` parameter), `handleSend → doCompletion`, `handleNewSession`'s call site, and `SlashCommands.hs:2287`. Adds `_fe_broker :: Maybe StreamBroker` to `FrontendEnv` and `_env_broker :: Maybe StreamBroker` to `AgentEnv` (and updates every AgentEnv construction site under `-Werror`). ~250 LoC (revised up from round-2's 150 estimate).
3. **WU3 — WS endpoint + wire protocol + Origin/cap enforcement + test harness** (D7–D13, D19, D20, D22, D26, D27, D28, D29, D30, D31, D32, D33). Adds `Stream.hs`, `StreamHarness.hs` (test helper using `Warp.testWithApplication` + `openFreePort`). Wires `websocketsOr` into `combinedApp`. Adds `wai-websockets` dep + cabal.project.freeze pin (D22). Adds `_fc_allowedOrigins` to `FrontendConfig` and `_fe_streamGuard :: Maybe StreamGuard` to `FrontendEnv`. Implements `StreamGuard` (per-origin cap), `normalizeOrigin`, `withPingThread` (D32), the `internal` error code emission discipline (D33), the shared `isValidSessionId` helper (D26), and the replay snapshot algorithm. Adds Warp `setMaxTotalConnections 1024` + `setTimeout 30` to `Server.hs` (D20). ~450 LoC + extensive integration tests (revised up from round-2's 350 estimate to reflect Origin/cap/ping logic).
4. **WU4 — Activity probe + lifecycle** (D17, D18, D24). Adds `ActivityProbe.hs`. Wires `Async.withAsync` in `CLI/Commands.hs` for both the probe loop and the WAI server at the top of `startWithChannel`, replacing the bare `forkIO`. Threads broker into `AgentEnv` and `FrontendEnv`. ~100 LoC.
5. **WU5 — Frontend stream client + hooks + Vitest config** (D14, D15, D16). Adds `streamClient.ts`, `useTranscriptStream.ts`, `useSessionActivityStream.ts`, `types/stream.ts`, fixtures, Vitest config, CI step. Wires hooks into session-view and sidebar components. ~400 LoC TS + tests.
6. **WU6 — Regression tests for unchanged endpoints + coverage gate** (D21, D23). Adds `test/Frontend/APISpec.hs`. Ensures coverage threshold is enforced for new modules. ~200 LoC.
7. **WU7 — Documentation & polish**. Update `SERVICE-INVENTORY.md`. Update `docs/ARCHITECTURE.md` to reference the streaming layer. Behavioral test plan entries for D16. ~50 LoC docs.

Sequencing: WU1 → WU2 → (WU3 || WU4) → WU5 → WU6 → WU7. WU3 and WU4 can be parallelized once WU2 is merged. WU5 depends on WU3's wire protocol being stable.

## Module Layout

New Haskell modules:
- `src/PureClaw/Frontend/StreamBroker.hs`
- `src/PureClaw/Frontend/BroadcastingTranscript.hs`
- `src/PureClaw/Frontend/Stream.hs`
- `src/PureClaw/Frontend/ActivityProbe.hs`
- `src/PureClaw/Frontend/Activity/Types.hs` *(holds `HarnessActivity`, moved from `Frontend.API` to break a potential cycle and make the broker independent of the API layer; `Frontend.API` re-exports for compatibility)*

Modified Haskell modules:
- `src/PureClaw/Frontend/API.hs` — `FrontendEnv` gains `_fe_broker :: Maybe StreamBroker` and `_fe_streamGuard :: Maybe StreamGuard`; `FrontendConfig` gains `_fc_allowedOrigins :: [Text]`. `handleSend → doCompletion` uses `mkBroadcastingFileTranscriptHandle`. `handleNewSession` publishes `SaSessionCreated`. `isValidSessionId` extracted as a shared helper.
- `src/PureClaw/Frontend/Server.hs` — `combinedApp` composes `streamApp` via `websocketsOr`. `runFrontend` accepts the broker and guard. Warp settings: `setMaxTotalConnections 1024` + `setTimeout 30` (note: applies only to non-hijacked HTTP routes; WS uses `withPingThread`).
- `src/PureClaw/Session/Handle.hs` — `mkSessionHandle` and `resumeSession` accept `Maybe StreamBroker` and route through `mkBroadcastingFileTranscriptHandle`. `mkNoOpSessionHandle` passes `Nothing`.
- `src/PureClaw/CLI/Commands.hs` — broker + `StreamGuard` construction at the TOP of `startWithChannel` (before line 544's `resumeSession`); `Async.withAsync` nesting for probe loop + Warp server, scoped under `runAgentLoopWith`; bare `forkIO` removed. Broker is threaded into `AgentEnv` and `FrontendEnv`.
- `src/PureClaw/Agent/Env.hs` — `AgentEnv` gains `_env_broker :: Maybe StreamBroker`. All construction sites updated.
- `src/PureClaw/Agent/SlashCommands.hs` — the `mkSessionHandle` call at line 2287 passes `_env_broker envS` as the broker argument.
- `src/PureClaw/Transcript/Provider.hs` — no source change needed (recording semantics unchanged); the verification test in D25 confirms the call chain works correctly.
- `pureclaw.cabal` — `wai-websockets` added; new modules declared.

New TS files:
- `frontend/src/lib/streamClient.ts`
- `frontend/src/hooks/useTranscriptStream.ts`
- `frontend/src/hooks/useSessionActivityStream.ts`
- `frontend/src/types/stream.ts`
- `frontend/vitest.config.ts` (new, ~10 LoC)
- `frontend/src/lib/__tests__/streamClient.test.ts`
- `frontend/src/hooks/__tests__/useTranscriptStream.test.ts`
- `frontend/src/hooks/__tests__/useSessionActivityStream.test.ts`

Modified TS files: session-view component, sidebar component (both wire up the new hooks). Number of touched files is small (the hooks encapsulate the change).

New test files:
- `test/Frontend/StreamSpec.hs` (Stream integration tests)
- `test/Frontend/StreamHarness.hs` (test helper for ephemeral Warp + WS client)
- `test/Frontend/BroadcastingTranscriptSpec.hs`
- `test/Frontend/StreamBrokerSpec.hs`
- `test/Frontend/ActivityProbeSpec.hs`
- `test/Frontend/APISpec.hs` (regression tests for unchanged endpoints — currently NONE exist)
- `test/Frontend/fixtures/stream-events/*.json` (wire-protocol goldens)

Cycle check (verified during the WU1 implementation): `StreamBroker` depends only on `Transcript.Types`, `Session.Types`, `Frontend.Activity.Types`, and stdlib STM. `BroadcastingTranscript` depends on `Handles.Transcript` + `StreamBroker`. `Stream` depends on `StreamBroker` + `Frontend.API` (for `FrontendEnv` + helpers) + `wai-websockets`. No new `.hs-boot` files needed (the cycle that exists today between `Handles.Tab` ↔ `Routing.Types` ↔ `Agent.SlashCommands` is separate; we add no new triangles).

## Resolved Open Questions

The round-1 draft listed 5 open questions. All are now resolved:

1. **Replay before focus?** — Resolved: replay is *only* triggered by `{op:"focus", sessionId, since}`. There is no URL `?since=` parameter and no separate first-message replay mechanism. This is the *single* mechanism. See §Replay-on-reconnect.
2. **Activity-event coalescing?** — Resolved: NO coalescing in v1. The probe loop emits each transition. (Round 2 considered a synchronous emission from `handleSend` to shorten spinner latency, but that approach raced the probe loop and produced wire-protocol double-emits; removed in round 3. The 2 s lag is the documented v1 tradeoff — see Risks.) If event volume becomes a problem (unlikely with one user), coalescing is a v1.5 addition.
3. **Frontend test infrastructure?** — Resolved: YES, Vitest is added in this PR (WU5). D14 is automated.
4. **WS protocol versioning?** — Resolved: YES. `protocolVersion: "v1"` is part of every `hello` event. Future incompatible changes can advertise `v2` and clients can detect the mismatch.
5. **Broker ownership / lifetime?** — Resolved: constructed at the **top of `startWithChannel`** in `src/PureClaw/CLI/Commands.hs` (line ~504, before line 544's `resumeSession` call), scoped under `Async.withAsync` paired with the WAI server and probe loop, all bounded by `runAgentLoopWith`. INVARIANT documented: exactly one broker per process. See §Lifecycle and Shutdown for the before/after.

## Risks & Future Work

| Risk | Likelihood | Mitigation |
|---|---|---|
| Broker becomes hot lock at high subscriber count | Low (v1 = single user) | Per-subscriber TChan + per-subscriber forked thread is the swap if it shows up; interface unchanged. |
| File-watch implementation (v1.5) breaks ordering with broker-published entries | Medium | Fingerprint mechanism: process-local `IORef (Set EntryId)` of recently-published ids, garbage-collected after a TTL. File-watch publishes only entries whose id is NOT in the set. Designed but not implemented in v1. |
| Subscriber count grows under future multi-user auth | Medium | When auth lands, broker's "publish to every subscriber, filter at WS" policy needs a routing optimization (subscriber-keyed by allowed sessions). Interface accommodates this. |
| Wire protocol can't carry mid-completion tokens | Low (forward-compat by design) | Add `{type:"token-chunk", sessionId, completionId, chunk}` event; clients ignore unknown types. No breaking change. Add a new `op` for the client to indicate "I want token-level chunks" (default off for backward-compatible behavior). |
| `_fc_allowedOrigins` misconfiguration locks out legitimate users | Low | Default config is sane (`localhost`, `127.0.0.1`); error message on 403 includes the allowed-origin list to aid debugging. |
| 30s idle timeout (Warp) closes idle web tabs prematurely | Low | Warp's `setTimeout 30` does not apply to hijacked WS sockets (per `wai-websockets` semantics); WS connections are kept alive by `Network.WebSockets.withPingThread` (25 s interval, 10 s pong timeout) per D32. Only ordinary HTTP routes are subject to the 30 s idle timeout — and HTTP requests in this app are short-lived. |
| Behavior under tabbed chat composition not fully tested | Medium | D5 (CLI write → WS receive) covers the path; D4 covers the wrapper. Per-tab UX in the web frontend is explicitly out of scope (Non-Goals); a follow-up issue will address it. |
| Activity probe loop's 2 s interval is too long for the sidebar UX | Medium | Documented v1 tradeoff: harness-status events have up to 2 s lag (regardless of whether the trigger is web-driven or CLI-driven). The round-2 synchronous emission from `handleSend` was removed in round 3 because it raced the probe loop. If users complain, v1.5 moves to an event-driven trigger from the harness layer itself, eliminating both the lag and the race. |

### Future work (out of scope for v1)

- Mid-completion token streaming (planned protocol addition).
- File-watch broker implementation for external writers.
- Per-tab transcript filtering in the web UI (works with tabbed-chat composition).
- Auth + per-user session scoping (requires re-evaluating activity-event leak surface).
- Rate limiting at the WS layer (per-peer reconnect rate, per-peer message rate).
- Persistent subscription state across restarts (currently each restart drops all subs).
- Token-chunk wire event (`{type:"token-chunk"}`).
- Session deletion + `SaSessionDeleted` event (paired with a v1.5 delete endpoint).
- `SaHarnessSpawned`, `SaSessionRenamed` activity events.
