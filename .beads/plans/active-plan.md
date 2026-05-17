---
issue: 51
pr: pending
design_doc: docs/tabbed-chat.md
status: complete
date_drafted: 2026-05-16
date_approved: 2026-05-16
gate-iterations: 2
plan-review-gate: PASS (Feasibility + Completeness + Scope & Alignment, round 2)
design-review-gate: PASS (PM + Architect + Designer + Security + CTO, round 5)
user-approved: true
branch: feat/terminal-backends-design
---

# Implementation Plan — Tabbed Chat (Mobile-Friendly Multiplexing)

**Issue:** [#51](https://github.com/pureclaw/pureclaw/issues/51)
**Design doc:** `docs/tabbed-chat.md` (APPROVED by all 5 design-review agents over 5 rounds, commit 7562502)
**Sibling design:** `docs/terminal-backend-abstractions.md` (Issue #49, already landed on this branch)

## Strategy

13 work units (WU0–WU12), ordered by dependency. The plan front-loads test seams + type layer (WU0–WU1) so subsequent WUs flip ~120 failing tests green incrementally. Each WU is independently committable with green tests for its declared DoD scope. WU6/WU7/WU8 (Tab.Ai/Harness/Backend factories) are parallelisable once WU3–WU5 land.

**Critical TDD discipline:** WU0 commits all ~120 failing tests (matching the design's DoD enumeration) marked `pending` where the production-code dependency hasn't landed. Subsequent WUs flip them green one by one. No WU is "done" until its declared DoDs in the test suite are green AND coverage thresholds are met for the modules it adds.

**Security distribution:** S-series DoDs (S1–S11) are distributed across WUs (not in a standalone "security WU") because they're cross-cutting concerns. Each WU that touches a security-relevant code path lands the corresponding S-DoD. **S11 is a documented-assumption-only invariant (not a failing test)**: provider connection-pool isolation. It lands as a haddock note + a code-review checklist item, both attached to WU1's `Handles.Tab` module docs. No WU "covers" S11 in the test-flipping sense; verification is by code review.

**Plan persistence (post-approval flow):** This plan file currently lives at `.beads/plans/tabbed-chat-plan.md`. After the plan-review-gate approves AND the user approves, the plan-review-gate skill is responsible for `cp .beads/plans/tabbed-chat-plan.md .beads/plans/active-plan.md` (preserving the source file). The terminal-backends plan currently at `active-plan.md` is moved to `.beads/plans/terminal-backends-plan.md` to retain its history. WU0 starts only after this rename.

## Pre-Flight (Plan Validation)

- [x] Architecture aligned with codebase (Handle pattern, no effect system, ReaderT AppEnv IO).
- [x] Dependency graph acyclic (Handles.Tab → Routing.Types → Agent.Env → Routing.{Parse,Registry,...} → Tab.* → Routing.Dispatcher → Agent.{SlashCommands,Loop}).
- [x] API contracts spelled out in design doc (types, signatures, examples).
- [x] Security review passed (Security agent APPROVED round 4 + post-revision mitigations).
- [x] UI/UX (PM + Designer approved; mobile flow, onboarding, recap window all specified).
- [x] External dependencies identified: none new (containers, stm, async already in pureclaw.cabal).
- [ ] **Pre-flight blockers to clear before WU0**:
  - **PF1**: Verify `Session.resolveSessionRef` is exported and stable (L7 reuses it). The design's L7 relies on this being the canonical safe path. (10-min spike: check `src/PureClaw/Session/Handle.hs:311–341` is exported via the module's export list.)
  - **PF2**: Verify the `Provider` typeclass (`src/PureClaw/Providers/Class.hs`) and `SomeProvider` existential are stable enough for `Test.Fake.Provider` (T1) to live behind. (10-min spike: confirm the typeclass exports + check whether existing test code already fakes it.)
  - **PF3**: Confirm `_sh_save` is sufficient for AI-tab close, or whether a new `_sh_archive` action is needed. (15-min spike: trace `_sh_save` at `src/PureClaw/Session/Handle.hs` and decide whether transcript flushing is implicit or needs separate handling.)
  - **PF4**: Verify the existing `SlashCommand` ADT can absorb `CmdTabNew`, `CmdTabList`, `CmdTabClose`, `CmdTabFocus`, `CmdTabResume`, `CmdTabRename` without breaking exhaustiveness in unrelated handler code (`-Wincomplete-patterns -Werror`). (10-min spike: grep for SlashCommand pattern-matches.)

If any pre-flight fails, fix-or-update the design BEFORE WU0 commits.

## Work Units

### WU0 — TDD red-phase scaffold + test seams

**Purpose:** Enumerate every DoD as a failing top-level test so progress is trackable from day 1. Also lands the test seams (T1–T4) without which downstream WUs can't write deterministic tests.

**Spec:**
- Create `test/Routing/ParseSpec.hs`, `test/Handles/TabSpec.hs`, `test/Routing/{RegistrySpec,DispatcherSpec,ChannelOutSpec,AutoSpawnSpec}.hs`, `test/Tab/{AiSpec,HarnessSpec,BackendSpec}.hs` plus Coexistence, Security, Onboarding spec stubs.
- Write one failing `it` per DoD across all 14 series (P, H, E, C, D, A, L, X, B, S, K, I, O, T). Mark `pending` if production-code dependency hasn't landed yet. The test file structure mirrors the module layout.
- Land test seams T1–T4 inside `test/Test/Fake/`:
  - `Test.Fake.Provider`: `Provider` impl backed by `TVar [CompletionRequest]` plus TMVar-blocking variants.
  - `Test.Fake.ChannelHandle`: `ChannelHandle` impl backed by `TVar [(UTCTime, ChannelEvent)]` plus injected `TQueue` input.
  - `Test.Fake.TabFactory`: pure `mkFakeTabAi`/`mkFakeTabHarness`/`mkFakeTabBackend` for dispatcher/registry tests.
  - Synchronous `_env_fork` variant returning a `TabRunner` whose `_trun_cancel` is observable via `IORef Bool`.

**File scope (write):**
- `test/Routing/ParseSpec.hs` (new)
- `test/Handles/TabSpec.hs` (new)
- `test/Routing/RegistrySpec.hs` (new)
- `test/Routing/DispatcherSpec.hs` (new)
- `test/Routing/ChannelOutSpec.hs` (new)
- `test/Routing/AutoSpawnSpec.hs` (new)
- `test/Tab/AiSpec.hs` (new)
- `test/Tab/HarnessSpec.hs` (new)
- `test/Tab/BackendSpec.hs` (new)
- `test/Coexistence/SlashCmdSpec.hs` (new)
- `test/Security/TabSpec.hs` (new)
- `test/Onboarding/StartSpec.hs` (new)
- `test/Test/Fake/Provider.hs` (new)
- `test/Test/Fake/ChannelHandle.hs` (new)
- `test/Test/Fake/TabFactory.hs` (new)
- `pureclaw.cabal` (test-suite stanza updates + Test.Fake.* exposure)

**DoDs covered:** scaffolding for all ~115 testable DoDs across 14 series P/H/E/C/D/A/L/X/B/S/K/I/O (S11 is documented-only, not scaffolded), plus T1–T4 fully implemented. WU0 commits these as `pending` tests; they go green in the WU that lands the production code.

**Dependencies:** Pre-flight (PF1–PF4) cleared.

**Human checkpoint:** **No.** (Pure test scaffold, no production code.)

---

### WU1 — `PureClaw.Handles.Tab` + `PureClaw.Routing.Types` (type layer)

**Purpose:** Land the foundational types that every subsequent WU depends on.

**Spec:**
- `src/PureClaw/Handles/Tab.hs`: `TabHandle` (record of IO actions, `_tabHandle_*` prefix), `TabIndex` newtype, `mkTabIndex :: Int -> Maybe TabIndex`, `TabKind = KindAi | KindHarness | KindShell | KindSsh | KindTmux` (with `Bounded, Enum`), `TabStatus = Active | Idle UTCTime | Crashed PublicTabError`, `TabError` ADT with manual redacted `Show` instance (H14), `NameError` ADT, `TabRunner = TabRunner { _trun_cancel, _trun_wait }`.
- `src/PureClaw/Routing/Types.hs`: `RoutingConfig`, `RoutingError`, `ParsedInput = Switch !TabIndex | Inject !TabIndex !Text | Default !Text | SlashCmd !SlashCommand`, `InputEvent = UserText !Text | SlashCmd !SlashCommand`, `OutputSource = SrcDispatcher | SrcTab !TabIndex`, `StreamId` newtype (Word64-backed), `ChannelEvent = StreamStart | ChunkOf | StreamEnd | FullMsg | BannerLine`.
- All `TabHandle` factory signatures declared (`mkTabAi`, `mkTabHarness`, `mkTabBackend`) but implementations stubbed with `error "not implemented"` — WU6–WU8 fill them in.
- Hand-written redacted `Show` for `TabError` and (later) `PublicTabError`. Constructors enumerate exactly per H3.
- Module-level haddock includes a short "user-facing primitive: a tab" overview cross-referenced to `docs/tabbed-chat.md`.

**File scope (write):**
- `src/PureClaw/Handles/Tab.hs` (new)
- `src/PureClaw/Routing/Types.hs` (new)
- `pureclaw.cabal` (expose new modules)

**File scope (read-only):**
- `src/PureClaw/Handles/{Backend,Channel,Harness,Transcript}.hs` (Handle-pattern style reference)
- `src/PureClaw/Session/Handle.hs` (SessionHandle reference; note path under `Session/`, not `Handles/`)
- `src/PureClaw/Security/Command.hs`

**DoDs covered:** H1, H2 (signatures only), H3, H5, H12, H13, H14 plus Routing.Types ADT scaffolding.

**Dependencies:** WU0.

**Human checkpoint:** **Yes.** Types are the most-touched surface; pause for sign-off.

---

### WU2 — `PureClaw.Routing.Parse` + `sanitizeTabName`

**Purpose:** Implement the parser and shared input sanitization functions.

**Spec:**
- `src/PureClaw/Routing/Parse.hs`: `parseInput :: RoutingConfig -> Text -> Either ParseError ParsedInput`. Implements grammar at design line 75–93 including: greedy DIGITS, no leading-zero rejection, `/0 0 run` payload preservation, `_rc_maxTabs` bounds check, `@botname` strip, multi-line handling, `parseSlashCommand :: Text -> Maybe SlashCommand` for in-tab-loop re-parse (I2).
- `mkTabIndex :: Int -> Maybe TabIndex` — bounds-checks against `_rc_maxTabs`.
- `mkSessionId :: Text -> Either ParseError SessionId` — rejects `/`, `\`, `..`, NUL, non-`[a-zA-Z0-9_-]` (per S3 + P15a + L7).
- `sanitizeTabName :: Text -> Either NameError Text` — shared by every `_tabHandle_name` construction path (H11) AND `/tab rename` handler (S10): length cap, control-byte rejection, ANSI rejection, hostname/path/ssh-stderr redaction. Property test asserts the four rules on the output of every code path.

**File scope (write):**
- `src/PureClaw/Routing/Parse.hs` (new)
- `pureclaw.cabal` (expose)

**File scope (read-only):**
- `src/PureClaw/Agent/SlashCommands.hs` (existing slash-command grammar for no-regression)
- `src/PureClaw/Core/Types.hs` (SessionId)

**DoDs covered:** P1–P17, P15a (parser-level only; P18's dispatcher-integrated property test lands in WU5 because it needs the dispatcher + fake Provider seam from T1), S3 (parser-side smart constructors), S10's `sanitizeTabName` function (the call sites that USE it land in WU6/WU7/WU8/WU9), H11's property-test machinery (the test definition; the construction-site call sites land in WU6/WU7/WU8).

**Dependencies:** WU1.

**Human checkpoint:** **No.**

---

### WU3 — `AgentEnv` additions + `PureClaw.Routing.Registry`

**Purpose:** Land AgentEnv field additions and the pure tab CRUD registry. After this, AgentEnv compiles with all new fields wired but no live tabs yet.

**Spec:**
- `src/PureClaw/Agent/Env.hs` (modified): add `_env_tabs :: IORef (IntMap TabHandle)`, `_env_focus :: IORef (Maybe TabIndex)`, `_env_activeCount :: TVar Int`, `_env_runners :: IORef (IntMap (IORef (Maybe TabRunner)))`, `_env_channelOutQ :: TBQueue (OutputSource, ChannelEvent)`, `_env_routingConfig :: RoutingConfig`, `_env_fork :: IO () -> IO TabRunner`. All construction sites updated (per `-Werror` field-completion rule).
- `src/PureClaw/Routing/Registry.hs`: pure tab CRUD over `IORef (IntMap TabHandle)` — `lookupTab`, `insertTab`, `removeTab`, `lowestFreeIndex`. No factory dispatch (that's WU5).
- `src/PureClaw/Routing/Config.hs`: `RoutingConfig` parser from `~/.pureclaw/config.toml [routing]`.

**File scope (write):**
- `src/PureClaw/Routing/Registry.hs` (new)
- `src/PureClaw/Routing/Config.hs` (new)
- `src/PureClaw/Agent/Env.hs` (modified — add fields + update constructors)
- `src/PureClaw/CLI/Config.hs` or wherever `RoutingConfig` is loaded (modified)
- All AgentEnv construction sites in production code (modified — record-completion)
- `pureclaw.cabal`

**File scope (read-only):**
- `src/PureClaw/Core/Config.hs` (existing config pattern)

**DoDs covered:** E1, E2 (declaration; reads in subsequent WUs), E4 (the field is there, default `_env_fork` impl in WU5).

**Dependencies:** WU1, WU2.

**Human checkpoint:** **Yes.** AgentEnv changes touch every constructor; pause for sign-off.

---

### WU4 — `PureClaw.Routing.ChannelOut` writer thread + breadcrumb

**Purpose:** Implement the single-writer channel-emission thread with focus-gated drop, breadcrumb logic, and StreamId state tracking.

**Spec:**
- `src/PureClaw/Routing/ChannelOut.hs`: writer thread consumes from `_env_channelOutQ`. For `SrcDispatcher` events: emit unconditionally. For `SrcTab n` events: read `_env_focus`; drop if `/= Just n`. On first drop per `StreamId`, emit one `SrcDispatcher BannerLine "/N has new output — /N to view"` (D5); subsequent drops same `StreamId` silent. Cleanup on `StreamEnd`. Producer-side focus pre-check (D4) helper exposed for tab loops to use.
- Map state: `IORef (Map StreamId BreadcrumbState)` where `BreadcrumbState = Pending | Emitted`.
- Threading: writer runs in its own thread, launched at dispatcher startup via `_env_fork`.

**File scope (write):**
- `src/PureClaw/Routing/ChannelOut.hs` (new)
- `pureclaw.cabal`

**DoDs covered:** D1, D2, D3, D4, D5, D6.

**Dependencies:** WU1, WU3.

**Human checkpoint:** **No.**

---

### WU5 — `PureClaw.Routing.Dispatcher` + `spawnTab` + exception discipline

**Purpose:** Implement the core dispatcher: read from channel, classify input, route. Also lands `spawnTab` indirection (Architect/CTO blocker-fix from rounds 1–2), the bracket+cancelAll pattern, async exception discipline, the placeholder-runner registration, and the LLM-free invariant tests.

**Spec:**
- `src/PureClaw/Routing/Dispatcher.hs`: `runDispatcher :: AgentEnv -> IO ()` wrapped in `bracket (newIORef IntMap.empty) cancelAll dispatcherBody`. Reads `_ch_receive` → `parseInput` → routes `Switch`/`Inject`/`Default`/`SlashCmd`. Per E3: only between message cycles can focus change; handlers run synchronously in dispatcher thread.
- `spawnTab :: AgentEnv -> TabKind -> [Text] -> IO (Either TabError TabIndex)` — under `mask`: register placeholder in `_env_runners` BEFORE `_env_fork`, then fill post-fork. Dispatches to `mkTabAi`/`mkTabHarness`/`mkTabBackend` via case match on `TabKind`.
- Default `_env_fork :: IO () -> IO TabRunner` impl wrapping `Control.Concurrent.Async.async`. `TabRunner._trun_cancel = cancel a; _trun_wait = wait a` for the production variant.
- `closeAllTabs :: AgentEnv -> IO ()` (the `cancelAll`): walks `_env_runners`, derefs each inner `IORef (Maybe TabRunner)`, `traverse_ _trun_cancel`.
- `forkIO` is forbidden in this module (and any tab-related module); discipline test asserts via static-grep code-review checklist.
- Crashed PublicError redaction wiring for the `SrcDispatcher` emit path (S5).
- Spawn rate limit (S7) — token-bucket per chat-user, fail-fast (parallel to S9's pattern).
- User-allowlist invariant (S8) — runtime test asserts dispatcher never sees messages from non-allowlisted users.

**File scope (write):**
- `src/PureClaw/Routing/Dispatcher.hs` (new)
- `pureclaw.cabal`

**File scope (read-only):**
- `src/PureClaw/Channels/Signal.hs`, `Telegram.hs`, `CLI.hs` (user-allowlist gating reference)
- `src/PureClaw/Agent/Loop.hs` (existing main loop — to be refactored in WU10)

**DoDs covered:** C3, C4, C5 (dispatcher-side crash isolation — does not crash when a tab crashes; WU6 owns the AI-loop-side assertion), E3 (focus invariant), S5 (Crashed redaction), S7 (spawn rate limit), S8 (allowlist invariant), P18 (property test for LLM-free invariant integrated here using T1).

**Dependencies:** WU1, WU2, WU3, WU4.

**Human checkpoint:** **Yes.** Dispatcher is the highest-risk WU (refactors the agent loop's structure); pause for sign-off.

---

### WU6 — `PureClaw.Tab.Ai` factory (AI tab loop + single-writer Context)

**Purpose:** Implement the AI tab loop body, the `_ats_context` single-writer model, AsyncCancelled propagation, provider-cancel transcript safety.

**Spec:**
- `src/PureClaw/Tab/Ai.hs`: `mkTabAi :: AgentEnv -> TabIndex -> AiSpawnArgs -> IO (Either TabError TabHandle)`.
- `AiTabState` per-tab (private to factory closure): `_ats_inputQ :: TBQueue InputEvent`, `_ats_provider :: IORef SomeProvider`, `_ats_model :: IORef ModelId`, `_ats_target :: IORef MessageTarget`, `_ats_context :: IORef Context`, `_ats_runner :: TabRunner`.
- Loop body: dequeue `InputEvent`. `UserText t` → if starts with `/` re-parse via `parseSlashCommand` and treat as `SlashCmd` (I2); else feed to provider, run one turn, emit `StreamStart`/`ChunkOf`/`StreamEnd` events, append response to context AND _sh_transcript. `SlashCmd cmd` → run `executeSlashCommand env cmd =<< readIORef _ats_context`, write back.
- `_tabHandle_enqueueSlash`: atomically enqueue `SlashCmd cmd` to `_ats_inputQ` (for AI tabs — returns `Right ()`).
- `_tabHandle_close`: `throwTo` AsyncCancelled to the loop thread (via `_trun_cancel`); bracket cleanup runs `_sh_save` (metadata archive) + `_th_close` on the SessionHandle's `_sh_transcript` (transcript flush — NOT `_sh_close`, which doesn't exist; the transcript is reached via `_sh_transcript :: TranscriptHandle` on `SessionHandle`). Idempotent + never-throws (H6, H7, H8 for KindAi, H10). Pre-flight PF3 should confirm this two-step archive is the right pattern, or whether a new `_sh_archive` helper is warranted.
- `_tabHandle_name` constructed via `sanitizeTabName` (H11).
- AsyncCancelled handling: catches `SomeException` EXCEPT AsyncCancelled (which propagates through bracket per C5).
- Context-mutation atomicity: every loop iteration is `readIORef → process → writeIORef`. Since the loop is single-writer (dispatcher uses `enqueueSlash`, not direct write), there's no race.
- Concurrent provider cancel safety: bracket around provider call ensures transcript is either fully-written-with-cancel-marker or unwritten (C6).
- S9 atomic active-count: status transitions to/from Active happen inside `atomically` together with `modifyTVar' _env_activeCount`. Cap check is fail-fast (per the S9 STM pseudocode).

**File scope (write):**
- `src/PureClaw/Tab/Ai.hs` (new)
- `pureclaw.cabal`

**File scope (read-only):**
- `src/PureClaw/Agent/Loop.hs` (existing AI loop body — port the streaming/tool-call logic)
- `src/PureClaw/Agent/SlashCommands.hs` (executeSlashCommand — used inside loop)

**DoDs covered:** C1 (behavioral concurrent-tabs test — Tab.Ai factory is what makes this go green; the WU5 dispatcher scaffolds it but cannot pass alone), C2, C5 (AI-loop side of crash isolation; WU5 owns the dispatcher-side assertion), C6, H4 (TBQueue bounded `_rc_inputQueueBound` + overflow PublicError + never blocks dispatcher), H6, H7, H8 (KindAi), H9 (KindAi `--force` skips archive), H10, H11 (KindAi name path), I1, I2, I3, I5, S9 (atomic counter wiring for KindAi), E5 (via enqueueSlash for AI tabs).

**Dependencies:** WU1, WU2 (sanitizeTabName), WU3, WU5.

**Human checkpoint:** **Yes.** AI loop refactor is non-trivial; pause for sign-off.

---

### WU7 — `PureClaw.Tab.Harness` factory

**Purpose:** Wrap the existing `HarnessHandle` as a Tabbed Chat tab kind.

**Spec:**
- `src/PureClaw/Tab/Harness.hs`: `mkTabHarness :: AgentEnv -> TabIndex -> HarnessSpawnArgs -> IO (Either TabError TabHandle)`.
- Internal state: a `HarnessHandle` plus a drainer thread reading harness stdout and emitting `FullMsg !TabIndex !Text` per chunk via `_env_channelOutQ`.
- `_tabHandle_send :: Text -> IO ()`: writes to harness stdin via existing API.
- `_tabHandle_enqueueSlash`: returns `Left (TabUnsupportedCommand cmd)` (non-AI tab can't handle slash commands).
- `_tabHandle_close`: calls existing `_hh_stop` (H8 for KindHarness — destructive, no archive).

**File scope (write):**
- `src/PureClaw/Tab/Harness.hs` (new)

**DoDs covered:** H4 (TBQueue bounded for harness `_tabHandle_send`), H8 (KindHarness destructive close), H9 (`--force` no-op on KindHarness), H11 (KindHarness name path via `sanitizeTabName`), I4 (slash-prefix opaque to backend), parts of D5 (FullMsg emission).

**Dependencies:** WU1, WU3.

**Human checkpoint:** **No.**

---

### WU8 — `PureClaw.Tab.Backend` factory (KindShell/KindSsh/KindTmux)

**Purpose:** Wrap `BackendHandle` (from #49) factories as Tabbed Chat tab kinds. All security smart-constructor validation lands here.

**Spec:**
- `src/PureClaw/Tab/Backend.hs`: `mkTabBackend :: AgentEnv -> TabIndex -> TabKind -> [Text] -> IO (Either TabError TabHandle)`. Dispatches to `KindShell`/`KindSsh`/`KindTmux` sub-factories.
- KindShell: parses `[Text]` args → `AuthorizedCommand` (via `authorize` per S1). Calls `mkLocalBackendHandle` from #49.
- KindSsh: parses args → host via `mkSshHost` (S2/S3); identity via Vault slot `_rc_sshIdentityKey` (S4); calls `mkSshBackendHandle`. No inline identity acceptance.
- KindTmux: parses args → tmux target via `mkTmuxSession`/`mkTmuxWindow`/`mkTmuxPane` (S3). Calls `mkTmuxBackendHandle`.
- Internal drainer thread: reads `_bh_recv`, emits `FullMsg !TabIndex !Text` per chunk (per D5 backend rule).
- `_tabHandle_send :: Text -> IO ()`: writes via `_bh_send` (UTF-8 encode).
- `_tabHandle_enqueueSlash`: returns `Left TabUnsupportedCommand`.
- `_tabHandle_close`: calls `_bh_close` (H8 destructive).
- `_tabHandle_name` via `sanitizeTabName` (H11 — strips hostnames per the redaction rule, so an ssh tab against `prod-db.internal` shows as redacted label).

**File scope (write):**
- `src/PureClaw/Tab/Backend.hs` (new)

**File scope (read-only):**
- `src/PureClaw/Backend/{Local,SSH,Tmux}.hs` (#49 factories)
- `src/PureClaw/Security/Command.hs` (`authorize`, `authorizeRemote` — note: in Command.hs, NOT Policy.hs)
- `src/PureClaw/Security/Policy.hs` (SecurityPolicy record + AllowList types)
- `src/PureClaw/Security/Vault.hs` (VaultHandle for SSH identity slot — note path under `Security/`, not `Handles/`)

**DoDs covered:** H4 (TBQueue bounded for backend `_tabHandle_send`), H8 (KindShell/KindSsh/KindTmux destructive close), H9 (`--force` no-op on backend kinds), H11 (backend-tab name redaction), I4, S1, S2, S3, S4, D5 (backend FullMsg path).

**Dependencies:** WU1, WU3.

**Human checkpoint:** **Yes.** Security-relevant; pause for sign-off.

---

### WU9 — Auto-spawn UX + Close + Crashed (A/L/X/B series)

**Purpose:** Implement the user-visible UX for tab creation, close, resume, rename, and crashed-tab handling.

**Spec:**
- Auto-spawn (A-series): `/N` on missing index → if `_rc_defaultKind` set, silent spawn; else prompt for kind. Force-prompt via `/tab new N` (no kind).
- A4/A6 channel-specific prompt rendering: inline-keyboard on Telegram, text reply on Signal/CLI. Specify a `PromptRenderer` typeclass or function passed via `ChannelHandle`.
- Close (L-series): `/tab close N` → kind-dispatch via `_tabHandle_close`. `--force` on KindAi skips archive.
- Resume (L7): `/tab resume <session-id>` → `parser → mkSessionId → resolveSessionRef → Session.resumeSession → new tab at lowest free index`.
- Rename (P16 + S10): `/tab rename N <name>` → `sanitizeTabName` → on success update `_tabHandle_name`, emit confirmation (with redaction-was-applied suffix); on failure emit PublicError.
- Crashed UX (X-series): `/N` on crashed tab → `SrcDispatcher` PublicError + retry/close prompt. Retry semantics differ for AI (continuation) vs non-AI (fresh).
- Dashboard (B-series): `/tabs` (alias for `/tab list`) → render registry. ≥8 tabs use bullets. Empty registry shows helper text.
- Empty-focus L6 + K3: `Default` text input with `_env_focus = Nothing` auto-spawns `_rc_defaultKind` at index 0.
- Max-tab cap (A11, S6) and spawn rate limit (S7 already in WU5).

**File scope (write):**
- `src/PureClaw/Routing/AutoSpawn.hs` (new)
- `src/PureClaw/Routing/Dashboard.hs` (new — `/tabs` rendering)
- `src/PureClaw/Routing/PromptRenderer.hs` (new — channel-dispatch for spawn prompt UX)

**File scope (modified):**
- `src/PureClaw/Routing/Dispatcher.hs` (wire the new commands)
- `src/PureClaw/Agent/SlashCommands.hs` (add `CmdTabNew`, `CmdTabList`, `CmdTabClose`, `CmdTabFocus`, `CmdTabResume`, `CmdTabRename` constructors to the existing ADT + dispatch through Routing.Dispatcher)

**DoDs covered:** A1–A12, L1–L7, X1–X3, B1–B3, S6, S10 (rename handler — `sanitizeTabName` already in WU2).

**Dependencies:** WU2, WU3, WU5, WU6, WU7, WU8.

**Human checkpoint:** **Yes.** User-facing UX surface; pause for sign-off.

---

### WU10 — Coexistence with existing slash commands (K-series + I-series wiring)

**Purpose:** Ensure existing slash commands (`/help`, `/session`, `/target`, `/provider`, `/model`, `/vault`, `/harness`, `/mcp`, `/channel`, `/transcript`, `/agent`, `/new`, `/last`, `/compact`) continue to work under the new tabbed model. Wire the dispatcher's `_tabHandle_enqueueSlash` for Context-mutating commands.

**Spec:**
- Parser no-regression (P17): asserts each existing slash command routes to its existing `SlashCommand` constructor.
- K1, K2, K3: `/session new` interaction with tabs (attaches to focused AI tab; empty-registry implicit-spawn; error on non-AI focused tab).
- K4, K5: `/target` operates on focused KindAi tab; errors on non-AI.
- K6.1–K6.8: existing commands operate on focused tab via focused-tab projection (E2) for simple-value mutations (provider, model, agent) and via E5/I5 queue for Context-mutating commands (`/new`, `/compact`, `/last`).
- K7: `/session resume` while focused on AI tab — replaces the focused tab's session (decided in design).
- K8: `/session last` routes through K6.7.
- The existing main loop in `src/PureClaw/Agent/Loop.hs` is refactored: the body becomes the AI-tab loop (now in `Tab.Ai`); `Agent.Loop.runAgentLoop` becomes a thin wrapper that calls `runDispatcher`.

**File scope (write):**
- (none new — all modifications)

**File scope (modified):**
- `src/PureClaw/Agent/Loop.hs` (significant refactor — body moves to Tab.Ai; this becomes a wrapper)
- `src/PureClaw/Agent/SlashCommands.hs` (handlers for /session new, /target, /provider, etc. updated to operate on focused tab via projections or enqueueSlash)

**DoDs covered:** P17 semantic preservation (parser-level routing tested in WU2; WU10 asserts each command still produces correct behavior post-refactor through the dispatcher), I1–I5 (wiring), K1, K2, K3, K4, K5, K6.1–K6.8, K7, K8.

**Dependencies:** WU5, WU6.

**Human checkpoint:** **Yes.** Existing-command preservation is the highest no-regression risk; pause for sign-off.

---

### WU11 — Onboarding (O-series) + final security polish

**Purpose:** Land user-facing onboarding (Telegram `/start`, `/help` rendering, BotFather command registration). Also any remaining S-series items not yet covered.

**Spec:**
- O1: `/start` handler. Telegram channel registers `/start` slash command (or CLI/Signal equivalent — error gracefully if non-Telegram channels invoke it). Response includes value prop + `/0` + `/tab new 0 shell` + `/tabs`.
- O2: `/help` rendering updated to include "Tab commands" subsection enumerating tab vocabulary.
- O3: BotFather command registration list — `/0`–`/9`, `/tab`, `/tabs`, `/start` with golden-file descriptions per O3.
- Security final pass: confirm S8 (allowlist invariant) test passes end-to-end with real channels. Confirm S5 (PublicError redaction) under real backend failures.

**File scope (write):**
- `src/PureClaw/Routing/Onboarding.hs` (new — `/start` handler + `/help` extension hook)

**File scope (modified):**
- `src/PureClaw/Channels/Telegram.hs` (BotFather command registration at startup)
- `src/PureClaw/Agent/SlashCommands.hs` (CmdHelp rendering extension)

**DoDs covered:** O1, O2, O3.

**Dependencies:** WU2, WU5, WU10.

**Human checkpoint:** **No.**

---

### WU12 — Final cross-unit review + coverage gate + knowledge capture

**Purpose:** Cross-cutting review of the entire feature; coverage gate enforcement; pre-PR knowledge capture per CLAUDE.md's "Pre-PR Knowledge Capture" rule.

**Spec:**
- Run full test suite under `nix develop . --command cabal test`; all ~120 DoDs green.
- Run coverage under `nix develop . --command cabal test --enable-coverage`; verify thresholds in `.coverage-thresholds.json` met for new modules.
- Run hlint; clean.
- Run `/self-reflect` to extract knowledge-base learnings.
- Commit knowledge updates so they land in the PR atomically with code.
- Cross-unit check: verify no module imports a `Tab.*` factory except `Routing.Dispatcher` (the cycle-killer invariant from rounds 1–3).
- Smoke-test the design's "Examples" section by hand-running each example through the running binary (Telegram CLI? Local CLI?).

**File scope (write):**
- `.beads/knowledge/*.md` or via `bd remember` (per project convention; CLAUDE.md says use `bd remember` rather than direct files)
- `.beads/plans/active-plan.md` (mark this plan complete via status frontmatter)

**DoDs covered:** none directly (validation phase); ensures every prior WU's DoDs are still green.

**Dependencies:** WU0–WU11.

**Human checkpoint:** **Yes.** Final go/no-go for PR creation.

---

## Dependency Graph

```
                       Pre-flight (PF1–PF4)
                              |
                              ▼
                            WU0 (scaffold + seams)
                              |
                              ▼
                            WU1 (types)
                              |
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
              WU2          WU3           (wait for WU3)
            (parser)    (Env+Reg)
                              |
                              ▼
                            WU4 (ChannelOut)
                              |
                              ▼
                            WU5 (Dispatcher + spawnTab)
                              |
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
              WU6          WU7           WU8
            (Tab.Ai)    (Tab.Harness) (Tab.Backend)
                └─────────────┼─────────────┘
                              ▼
                            WU9 (Auto-spawn UX + L + X + B)
                              |
                              ▼
                            WU10 (Coexistence)
                              |
                              ▼
                            WU11 (Onboarding)
                              |
                              ▼
                            WU12 (Final review + coverage + self-reflect)
```

WU6/WU7/WU8 are parallelisable. Estimated total: ~13 work units, ~3–4 weeks of focused work (cadence-comparable to #49 which had 13 WUs).

## Recovery Protocol

If an agent loses context mid-execution: run `bd prime --work-type recovery`. This reloads:
- This plan (`.beads/plans/tabbed-chat-plan.md`) once renamed to `active-plan.md` post-approval.
- Current work-unit position (from `.beads/context/execution-state.md`).
- Completed-WU log (from `.beads/context/project-context.md`).

Max 3 retries per work unit before escalating with failure history.

## Anti-Patterns to Avoid

Carried forward from #49's plan and design lessons learned in rounds 1–5:

- **No `--no-verify` on commits.** Pre-commit hooks exist for reasons.
- **No `git push --force` without explicit user approval.**
- **No self-certifying.** Adversarial review runs per WU.
- **No scope creep.** If you discover a need that isn't in the design's ~120 DoDs, log it as a v1.5 deferred item, don't sneak it in.
- **No `forkIO` in `Tab.*` or `Routing.*` modules.** Always go through `_env_fork`.
- **No direct `_ch_send` from tab loops.** All output goes through `_env_channelOutQ`.
- **No mutation of `_ats_context` outside the AI tab loop.** Single-writer invariant.
- **No new `Show` deriving on `TabError`-like internal types.** Manual redacted Show only (H14).
- **No bare `Text` for `_tabHandle_name`.** Always via `sanitizeTabName`.
- **No path concatenation of user-supplied session-id.** Always via `mkSessionId` + `Session.resolveSessionRef`.

## Open questions deferred to per-WU resolution

The design doc's 7 remaining open questions (lines 803–816 of `docs/tabbed-chat.md`) are non-blocking. The WUs listed there will revisit them if friction is observed. Specifically:
- OQ-1 (recap on self-switch) — WU9.
- OQ-2 (idle-timeout) — WU6.
- OQ-3 (ssh tab default name) — WU8.
- OQ-4 (recap window size) — WU9.
- OQ-5 (recap output bound vs Telegram 4096-char limit) — WU11 (testable against fake Telegram).
- OQ-6 (retry preservation of spawn args) — WU9 (X2/X3 testing).
- OQ-7 (CLI channel scope for v1) — WU11 (smoke test).
