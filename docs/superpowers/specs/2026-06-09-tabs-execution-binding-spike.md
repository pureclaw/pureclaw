# Tabs-as-View — Execution-Binding Design Spike (WU8 core)

**Status:** Design spike for the cutover core (fills the gap the plan under-specified)
**Date:** 2026-06-09
**Parent:** GitHub #79; spec `docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md`
**Decides:** how a provider-session tab and a harness tab actually *execute* once the legacy per-tab loops (`Tab.{Ai,Harness,Backend}`) are removed.

## 1. The problem

The legacy modules being deleted aren't just routing — each tab is a forked `TabRunner` (via `_env_fork`) running an **infinite input-queue loop** that drives a provider turn or pumps harness/backend I/O, emitting to `_env_channelOutQ` behind a **global** `_env_focus` gate. The new model says "a tab is a pure binding" — so something else must drive execution. This spike defines that.

## 2. Reuse, corrected (design-review found two overstatements)

**Cleanly reusable (verified):**
- **Raw provider stream:** `runProviderTurn` (Tab/Ai.hs:554) — CompletionRequest → `completeStream` → `StreamText|StreamDone|StreamWarning`. Reusable for the streaming call itself.
- **Harness I/O:** `_hh_send` / `_hh_receive` + `sanitizeHarnessOutput`; JSONL `splitLines` / `convertLine`; `Reconcile`.
- **Backend I/O:** `_bh_send` / `_bh_recv`.
- **Context seeding on reopen:** `loadRecentMessages :: TranscriptHandle -> Int -> Int -> IO [Message]` (Session/Handle.hs:750) + `replaceMessages` (Agent/Context.hs:124) — per-session, not singleton; the exact seam the CLI resume path uses (CLI/Commands.hs:639). A ProviderRuntime calls these against the pooled `SessionHandle`.
- **Channel event types + per-event channel mapping** (`ChunkOf`/`FullMsg`/`StreamStart`/`StreamEnd`/`BannerLine` → `_ch_sendChunk`/`_ch_send`).

**NOT reusable as-is — must be (re)built in 8b (this is real work, not a port):**
- ⚠️ **`handleCompletion` is coupled, not reusable** (Loop.hs:201): it's an unexported `where`-closure that writes `_env_channel` directly, fires `_env_onFirstStreamDone`, and tail-recurses into the singleton `go` loop; `runProviderTurn` does the streaming but **no tool cycling** and its transcript append is a no-op (Tab/Ai.hs:623). **8b extracts a new env-light** `runTurnWithTools :: TurnDeps -> Context -> IO (Context, [ChannelEvent])` that does the tool-call cycle (the logic at Loop.hs:260-268), emits to an **injected sink** (not `_env_channel`), and appends to the per-ref transcript via `mkTranscriptProvider`. `TurnDeps` injects the provider/turn fn, the tool-exec fn, and the transcript handle — so it unit-tests to ≥95% with no live LLM.
- ⚠️ **The relay must be widened** (see §4) from a `Text` sink to a `ChannelEvent` sink with `StreamId` framing — the existing `Tabs.Relay` decides once per whole `Text` and cannot express chunk-streaming or per-stream breadcrumb dedup.

**Coupled / replaced:** the per-tab `_ats_inputQ`/`loopBody`, harness/backend `drainerLoop`/`writerLoop`, the per-tab `TabRunner` fork bookkeeping (`_env_runners`), and the **global-focus** gate in `ChannelOut`.

## 3. New execution model: per-ground-truth *runtimes*, refcounted by tab binding

The execution unit moves from **per-tab** to **per-ground-truth-ref**. Because a session/harness lives in ≤1 tab (I2), this is ~1:1 with tabs today, but keying by the *stable ref* is what makes "detach a tab, harness keeps running" and "reopen a session" fall out naturally.

A new leaf module **`PureClaw.Tabs.Exec`** owns a registry of live runtimes, keyed by `TabRef`, started when a tab first binds a ref and stopped when the last binding goes (the same refcount discipline as `SessionPool`, which it composes with):

```haskell
data Runtime
  = ProviderRuntime
      { _rt_inputQ :: TBQueue Text          -- user messages for this session
      , _rt_worker :: TabRunner             -- serializes turns; single-writer Context
      , _rt_ctx    :: IORef Context }       -- conversation context (seeded from the session transcript)
  | HarnessRuntime
      { _rt_drain  :: TabRunner             -- reads _hh_receive / JSONL tail -> emits output
      , _rt_writer :: TabRunner }           -- forwards input -> _hh_send

data ExecHandle = ExecHandle
  { _ex_ensure :: TabRef -> IO ()                 -- start a runtime if absent (++refcount)
  , _ex_release :: TabRef -> IO ()                 -- --refcount; stop on last
  , _ex_send   :: TabRef -> Text -> IO (Either TabError ())  -- route input to the runtime
  , _ex_stopAll :: IO () }
```

- **Input flow:** dispatcher resolves `tab slot → TabRef`, calls `_ex_send ref text`. Provider → enqueue to `_rt_inputQ`; the worker serializes turns (preserving the single-writer Context invariant), runs the extracted `runTurnWithTools` (§2), appends to the session transcript. Harness → `_hh_send` (via the writer queue).
- **Worker identity = `TabRef`, strictly.** Runtimes are keyed by `TabRef`, never by conversation — so two conversations sharing one session (parent §6.5) share ONE worker + ONE Context writer (no race). The runtime registry refcounts on the **same `TabRef` identity as `SessionPool`** (compose them: `_ex_ensure`/`_ex_release` drive `acquire`/`release`) so handle-open/close and runtime-start/stop cannot drift.
- **Why per-ref workers, not inline:** an LLM turn is slow; running it on the dispatcher thread would stall all routing. The worker is the *only* writer of its session Context (preserves E5). Two messages to the same session serialize through its queue.

## 4. Output flow: runtimes → relay → per-conversation sinks (reuse ChannelOut, swap the gate)

Keep the queue transport; **replace the global-focus gate with the per-conversation relay**. **The relay must be widened first** (design-review blocker): `Tabs.Relay.relayOutput` today takes a `ConversationKey -> Text -> IO ()` sink and makes one decision per whole message — it has no chunk/`StreamId` awareness, so it cannot stream or dedup breadcrumbs per stream. 8b reworks the relay sink to a **`ChannelEvent`** sink (`ConversationKey -> ChannelEvent -> IO ()`) and makes the per-event decision:
- **Burst = one logical message**, delimited by `StreamStart sid … StreamEnd sid`. A focused conversation receives every `ChunkOf`/`StreamStart`/`StreamEnd` (full streaming). A background conversation under `ActivityDigest` gets **at most one** ping per `StreamId` (the relay's pinged-set keys on `(ConversationKey, StreamId)`, exactly mapping the old per-`StreamId` `BreadcrumbState`), so a 100-chunk stream is one ping, not 100. `FocusedOnly` background = nothing; `Firehose` background = full stream.
- This is a real change to the built `Tabs.Relay` (widen the sink type, thread `StreamId`, re-key the pinged-set) — budgeted as the first task of 8b, re-tested to ≥95%.

Then:
- Runtimes enqueue `(TabRef, ChannelEvent)` onto the existing output queue (ref-tagged, not `SrcTab idx`).
- A single **relay writer thread** (replaces `runChannelOutThread`) drains the queue and, per event, applies the widened `Tabs.Relay` decision against a snapshot of `CursorState` + the global default `RelayMode`, fanning out to a **conversation→sink registry**:

```haskell
-- conversation output sinks, registered by each channel as it becomes active
_exec_sinks :: IORef (Map ConversationKey ChannelHandle)
```
  - **Focused** conversations (cursor == ref) receive the event as a stream (`_ch_sendChunk`/`_ch_send`) — full fidelity, streaming preserved.
  - **Background** conversations get the `ActivityDigest` name-first ping (once per burst — the relay's pinged-set replaces `ChannelOut`'s `BreadcrumbState`), or nothing under `FocusedOnly`, or full content under `Firehose`.
  - `SrcDispatcher`-class events (banners, switch acks, command replies) are emitted directly to the originating conversation's sink (not gated).

The breadcrumb-dedup machinery and event→channel mapping in `ChannelOut` port directly onto this writer; `Tabs.Relay.relayOutput` supplies the per-conversation decision that the old `shouldEmit` made globally.

## 5. Conversation → sink registry

Each channel registers `ConversationKey → ChannelHandle` when a conversation becomes active (the dispatcher already receives every inbound message tagged with its `ConversationKey` after WU4). The relay writer sends a conversation's output to its registered sink; a missing sink is a safe drop.

**Scope guard (confirmed by review):** for #79, only the **CLI** sink is wired (one entry). The web frontend's per-client sink registration is **deferred to the frontend-parity sibling issue** (no `Frontend/*` module references `ChannelOut`/the relay today, so this introduces no frontend work in #79). Telegram/Signal each register one sink per chat using the `ConversationId` already plumbed in WU4.

## 6. Lifecycle

- **Tab close / detach:** dispatcher removes the binding → `_ex_release ref`. Provider: drain + stop worker, flush transcript (reuse the AI graceful-close steps), keep the SessionHandle in the pool only if still referenced. Harness: stop the drainer/writer threads **but do NOT stop the harness** (it keeps running in tmux) — re-attachable.
- **Harness death (WU9):** the reconcile `_rd_evict` seam enqueues a lifecycle event; the dispatcher applies the two-phase tombstone removal and calls `_ex_release` for that harness ref.
- **Boot:** persisted tabs (WU3) are restored; `_ex_ensure` starts a runtime for each (provider session reopened from transcript; harness re-attached if live).

## 7. What gets deleted vs kept

- **Deleted:** the per-tab loop wrappers (`Tab.{Ai,Harness,Backend}` factories + loops), `Routing.{AutoSpawn,Registry,Dashboard,LegacyDispatch}`, the `ChannelOut` *gate* (its mapping/dedup logic moves into the relay writer), `_env_focus`/`_env_tabs`/`_env_runners`/`_env_session` globals.
- **Kept & reused:** `runProviderTurn` (raw stream), the tool-cycle *logic* (re-homed into the extracted `runTurnWithTools`), `_hh_*`/`_bh_*`, JSONL converters, `sanitizeHarnessOutput`, `Reconcile`, `loadRecentMessages`/`replaceMessages`, the `ChannelEvent` types + event→channel mapping, `_env_fork` (runtimes still fork worker threads — forking moved from per-tab to per-ref). **Note:** `handleCompletion` itself is NOT reused (coupled); its tool-cycle logic is extracted (§2).

## 8. Revised WU8 sub-staging (keeps the additive-then-flip property)

- **8b — additive, TDD, in four parts (all behind injected seams; app still on the old dispatcher):**
  1. **Widen `Tabs.Relay`** to a `ChannelEvent` sink with `StreamId` framing + `(ConversationKey, StreamId)` pinged-set (§4). Re-test to ≥95%.
  2. **Extract `runTurnWithTools`** (§2) — env-light provider turn + tool-call cycle + transcript append, over `TurnDeps` (injected provider/turn fn, **injected tool-exec fn**, transcript handle). Unit-test the full tool→result→re-complete→done cycle with a fake registry to ≥95%.
  3. **`PureClaw.Tabs.Exec`** — the per-`TabRef` runtime registry (provider runtimes using #2; harness runtimes using `_hh_*`), refcount-composed with `SessionPool`, emitting `(TabRef, ChannelEvent)`; the relay writer drains to the sink registry. Injected seams: fake turn fn, fake `_hh_*`, recording `ChannelEvent` sink. ≥95%, no real LLM/tmux.
  4. **`PureClaw.Routing.TabDispatch`** — per-conversation `handleInbound` + flat commands (`/new`,`/nt`,`/close`,`/tabs`,`/rename`,`/relay`) + wizard interception, over `ExecHandle` + tab/cursor handles. Fully TDD'd against fakes, asserting the §14 copy.
- **8c — flip + delete.** Add the new state to `AgentEnv`; point `runDispatcherWith`/the main loop at `TabDispatch` + the relay writer; migrate `Agent/Loop` off `LegacyDispatch`; delete the legacy modules + slim `Handles.Tab` + remove the legacy `AgentEnv` fields. Build green (warnings tolerated).
- **8d — integration + cleanup.** Rewrite `Routing/ParseSpec` off legacy types; `CLISpec` end-to-end (`/new`, `/nt`, `/tab`, `/close`, `/N`, `/relay`); adversarial review of the whole cutover.
- (WU9 harness-death, WU10 config+WARN+docs, WU11 restore `-Werror` + final gate — unchanged.)

## 9. Resolved review findings
- **Streaming through the relay** (was "open risk"; review reclassified as real work): now an explicit 8b task — widen the relay sink to `ChannelEvent`, thread `StreamId`, key the pinged-set on `(ConversationKey, StreamId)` so a burst = one `StreamStart…StreamEnd` and a multi-chunk stream emits one background ping (§4).
- **Provider-turn reuse** (review blocker): `handleCompletion` is coupled (channel/loop globals), `runProviderTurn` lacks tool cycling + transcript append — so 8b **extracts** `runTurnWithTools` over injected `TurnDeps` rather than "reusing as-is" (§2). Adds an injected tool-exec seam to the 8b inventory.
- **Context seeding on reopen** (confirmed sound): reuse `loadRecentMessages` (Session/Handle.hs:750) + `replaceMessages` (Agent/Context.hs:124) against the pooled `SessionHandle` — per-session, not singleton.
- **No frontend bleed** (confirmed): the sink registry needs only the CLI sink for #79; web-per-client is the deferred sibling (§5).
- **Per-ref single-writer** (confirmed): worker keyed strictly by `TabRef`, refcount-shared with `SessionPool` (§3).
- **Additive staging** (confirmed): `ChannelOut`/`startChannelOut` aren't wired into the live `runAgentLoop` (Loop.hs:307-309), so 8b builds entirely behind injected seams; the live flip is 8c.

**Test surface:** 8b is larger than first scoped (4 parts) but each is additive + injected-seam testable, exactly like WU1–WU7. 8c remains the irreducible flip. Same shape that has worked for 7 WUs.
