# Tabs-as-View — Execution-Binding Design Spike (WU8 core)

**Status:** Design spike for the cutover core (fills the gap the plan under-specified)
**Date:** 2026-06-09
**Parent:** GitHub #79; spec `docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md`
**Decides:** how a provider-session tab and a harness tab actually *execute* once the legacy per-tab loops (`Tab.{Ai,Harness,Backend}`) are removed.

## 1. The problem

The legacy modules being deleted aren't just routing — each tab is a forked `TabRunner` (via `_env_fork`) running an **infinite input-queue loop** that drives a provider turn or pumps harness/backend I/O, emitting to `_env_channelOutQ` behind a **global** `_env_focus` gate. The new model says "a tab is a pure binding" — so something else must drive execution. This spike defines that.

## 2. Key finding: primitives are reusable; only the loop wrapper is coupled

Reusable as-is (verified in the code map):
- **Provider turn:** `runProviderTurn` / `handleCompletion` (CompletionRequest → `completeStream` → `StreamText|StreamDone|StreamWarning`) + tool-call cycling (`executeCall`).
- **Harness I/O:** `_hh_send` / `_hh_receive` + `sanitizeHarnessOutput`; JSONL `splitLines` / `convertLine`; `Reconcile`.
- **Backend I/O:** `_bh_send` / `_bh_recv`.
- **Output transport:** the `_env_channelOutQ` + `ChannelOut` producer/consumer split, event mapping (`ChunkOf`/`FullMsg`/`StreamStart`/`StreamEnd`/`BannerLine`), and the breadcrumb-dedup state machine.

Coupled (to be replaced): the per-tab `_ats_inputQ`/`loopBody`, the harness/backend `drainerLoop`/`writerLoop`, the per-tab `TabRunner` fork bookkeeping (`_env_runners`), and the **global-focus** gate in `ChannelOut`.

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

- **Input flow:** dispatcher resolves `tab slot → TabRef`, calls `_ex_send ref text`. Provider → enqueue to `_rt_inputQ`; the worker serializes turns (preserving the single-writer Context invariant), runs `runProviderTurn` + tool cycling, appends to the session transcript. Harness → `_hh_send` (via the writer queue).
- **Why per-ref workers, not inline:** an LLM turn is slow; running it on the dispatcher thread would stall all routing. The worker is the *only* writer of its session Context (preserves E5). Two messages to the same session serialize through its queue.

## 4. Output flow: runtimes → relay → per-conversation sinks (reuse ChannelOut, swap the gate)

Keep the queue transport; **replace the global-focus gate with the per-conversation relay**:

- Runtimes enqueue `(TabRef, ChannelEvent)` onto the existing output queue (rename intent: it's now ref-tagged, not `SrcTab idx`).
- A single **relay writer thread** (replaces `runChannelOutThread`) drains the queue and, per event, applies `Tabs.Relay` semantics against a snapshot of `CursorState` + the global default `RelayMode`, fanning out to a **conversation→sink registry**:

```haskell
-- conversation output sinks, registered by each channel as it becomes active
_exec_sinks :: IORef (Map ConversationKey ChannelHandle)
```
  - **Focused** conversations (cursor == ref) receive the event as a stream (`_ch_sendChunk`/`_ch_send`) — full fidelity, streaming preserved.
  - **Background** conversations get the `ActivityDigest` name-first ping (once per burst — the relay's pinged-set replaces `ChannelOut`'s `BreadcrumbState`), or nothing under `FocusedOnly`, or full content under `Firehose`.
  - `SrcDispatcher`-class events (banners, switch acks, command replies) are emitted directly to the originating conversation's sink (not gated).

The breadcrumb-dedup machinery and event→channel mapping in `ChannelOut` port directly onto this writer; `Tabs.Relay.relayOutput` supplies the per-conversation decision that the old `shouldEmit` made globally.

## 5. Conversation → sink registry

Each channel registers `ConversationKey → ChannelHandle` when a conversation becomes active (the dispatcher already receives every inbound message tagged with its `ConversationKey` after WU4). CLI registers one entry; the web frontend registers one per client; Telegram/Signal per chat. The relay writer sends a conversation's output to its registered sink. A missing sink (conversation went away) is a safe drop.

## 6. Lifecycle

- **Tab close / detach:** dispatcher removes the binding → `_ex_release ref`. Provider: drain + stop worker, flush transcript (reuse the AI graceful-close steps), keep the SessionHandle in the pool only if still referenced. Harness: stop the drainer/writer threads **but do NOT stop the harness** (it keeps running in tmux) — re-attachable.
- **Harness death (WU9):** the reconcile `_rd_evict` seam enqueues a lifecycle event; the dispatcher applies the two-phase tombstone removal and calls `_ex_release` for that harness ref.
- **Boot:** persisted tabs (WU3) are restored; `_ex_ensure` starts a runtime for each (provider session reopened from transcript; harness re-attached if live).

## 7. What gets deleted vs kept

- **Deleted:** the per-tab loop wrappers (`Tab.{Ai,Harness,Backend}` factories + loops), `Routing.{AutoSpawn,Registry,Dashboard,LegacyDispatch}`, the `ChannelOut` *gate* (its mapping/dedup logic moves into the relay writer), `_env_focus`/`_env_tabs`/`_env_runners`/`_env_session` globals.
- **Kept & reused:** `runProviderTurn`/`handleCompletion`/tool cycling, `_hh_*`/`_bh_*`, JSONL converters, `sanitizeHarnessOutput`, `Reconcile`, the `ChannelEvent` types + event→channel mapping, `_env_fork` (the runtimes still fork worker threads — forking didn't go away, it moved from per-tab to per-ref).

## 8. Revised WU8 sub-staging (keeps the additive-then-flip property)

- **8b — `PureClaw.Tabs.Exec` (additive, TDD).** Build the runtime registry + provider/harness runtimes + the relay writer, parameterized over injected seams (a fake "turn" fn, fake `_hh_*`, a recording sink) so it reaches ≥95% with no real LLM/tmux. Not wired into the live app yet. Also build **`PureClaw.Routing.TabDispatch`** (the per-conversation `handleInbound` + flat commands + wizard interception), parameterized over `ExecHandle` + the tab/cursor handles, fully TDD'd against fakes. The app still runs the old dispatcher.
- **8c — flip + delete.** Add the new state to `AgentEnv`; point `runDispatcherWith`/the main loop at `TabDispatch` + the relay writer; migrate `Agent/Loop` off `LegacyDispatch`; delete the legacy modules + slim `Handles.Tab` + remove the legacy `AgentEnv` fields. Build green (warnings tolerated).
- **8d — integration + cleanup.** Rewrite `Routing/ParseSpec` off legacy types; `CLISpec` end-to-end (`/new`, `/nt`, `/tab`, `/close`, `/N`, `/relay`); adversarial review of the whole cutover.
- (WU9 harness-death, WU10 config+WARN+docs, WU11 restore `-Werror` + final gate — unchanged.)

## 9. Open risks (call out, not blockers)
- **Streaming through the relay:** chunk-level fan-out means the focused conversation streams while background gets one ping — confirmed expressible with the relay's pinged-set; framing (`StreamStart`/`End`) rides the existing `ChannelEvent` mapping.
- **Context seeding on reopen:** a reopened provider session must rebuild `Context` from its transcript — reuse the existing transcript→context path the CLI already uses at startup.
- **Test surface:** 8b is large but additive + injected-seam testable, exactly like WU1–WU7. 8c is the irreducible flip (small, mechanical once 8b exists). This is the same shape that has worked for 7 WUs.
