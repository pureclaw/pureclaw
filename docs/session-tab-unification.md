# Session / Tab Unification

**Issue:** _(to be assigned)_
**Status:** design — draft (pre-review)
**Branch:** `fill-out-frontend`
**Authors:** Doug Beardsley, Claude
**Builds on:** [Tabbed Chat](tabbed-chat.md) (#51), [Terminal / Backend Abstractions](terminal-backend-abstractions.md) (#49).

## TL;DR

PureClaw has two parallel concepts that the user reasonably perceives as the same thing:

- **Console UI** — uses `Tab` for an open chat slot (`/0`, `/1`, …).
- **Frontend UI** — uses `Session` for a persisted conversation on disk.

Today they're modelled as separate types (`TabHandle` is in-memory; `SessionMeta` is persistent), the frontend's bifurcated sidebar shows "harnesses" (live) and "sessions" (disk) as parallel lists, and the frontend's "New Session" button can only create AI provider sessions — it cannot spawn harnesses, terminal backends, or other session kinds that the console's `/tab new` already supports.

This work establishes one coherent model:

> **A Session is the persistent record of an AI conversation. A Tab is the UI affordance for displaying an open session — a slot in the console, a row in the frontend's Active Tabs section.**

It also generalises the `New Session` UX so it can construct any AI execution scheme: direct provider calls AND external harnesses (Claude Code, Codex, OpenCode, Hermes, PureClaw itself, ad-hoc) running on any terminal backend (local subprocess, tmux pane, ssh remote, container exec).

## Motivation

Concrete user-facing gaps closed by this work:

1. **The frontend can't create non-AI-provider sessions.** `/api/sessions/new` hardcodes `RTProvider` (`src/PureClaw/Frontend/API.hs:450`). To start a harness session, the user has to drop to the console. The frontend's "New Session" button is misleadingly limited.
2. **No first-class support for running AI CLIs outside tmux.** `claude` / `codex` / `aider` running as a local subprocess (without tmux) is not a session kind today. The tmux-wrapped harness path is the only blessed way to drive these CLIs.
3. **No container support.** Running `claude` inside `docker exec` / `podman exec` / `kubectl exec` requires manual shell-tab gymnastics.
4. **"Tab" and "Session" feel like different concepts to users** but they aren't. The sidebar's bifurcation into "harnesses" (live) and "sessions" (disk) is an artifact of this confusion, not a deliberate model.
5. **No three-tier lifecycle in the UI.** The `_sm_archived` field exists on `SessionMeta` but the frontend doesn't surface archived sessions; they're just hidden.

## Glossary (the unified model)

| Term | Meaning |
|---|---|
| **Session** | Persistent entity. The record of an AI conversation. Identified by `_sm_id`; stored as `session.json` + `transcript.jsonl` in a per-session directory on disk. |
| **SessionMeta** | Data shape for a session's persistent metadata. Extended with `_sm_kind :: SessionKind`. |
| **SessionHandle** | Live persistent identity — `SessionMeta` in an `IORef` plus a save action. Unchanged. |
| **SessionKind** | What kind of AI execution this session is. Two top-level variants: `SkProvider` (PureClaw drives an LLM API directly) or `SkHarness` (PureClaw drives an external agentic CLI). Replaces the current `RuntimeType`. |
| **Harness** | An agentic CLI tool that wraps an LLM with side-effect capability (Claude Code, Codex, OpenCode, Hermes, PureClaw itself, …). |
| **TerminalBackend** | Where a subprocess physically runs: `Local` (direct PTY), `Tmux` (in a tmux pane), `Ssh` (on a remote host), `Container` (inside docker/podman/kubectl exec). Aligns with Hermes' "terminal backends" vocabulary and PureClaw's own #49 work. |
| **Tab** | An *open slot* displaying a session. The console arranges tabs as numbered slots (`/0`, `/1`, …); the frontend lists them in the "Active Tabs" section. |
| **TabHandle** | The runtime record of IO actions for an open tab. Unchanged in role from #51. |
| **TabKind** | The set of things that can occupy a tab slot. Two variants: `TkSession SessionKind` (persistent) or `TkRawShell TerminalBackend` (stateless — no harness, no persistence). |

**Naming rule (load-bearing):** "Tab" is never a noun for an entity in user-facing copy. It is the console's word for a slot. "Session" is always the noun for the entity that occupies a slot.

The console UI's per-slot vocabulary ("`/tab new`", "tab 0") is unaffected — those refer to the slot. The frontend UI uses "Active Tabs" as a section label, not as the noun for the things in it.

### Layering of "Backend"-named types

This work introduces `TerminalBackend` (where a subprocess lives). PureClaw also has `Handles.Backend.BackendHandle` (#49) which is the lower-level byte-stream transport with `_bh_send`/`_bh_recv`/`_bh_close`. They're at different layers:

| Layer | Type | Role |
|---|---|---|
| Environment | `TerminalBackend` | Local / Tmux / Ssh / Container — *where* the subprocess runs |
| Transport (existing) | `BackendHandle` | `_bh_*` IO record — *how* we talk to it once spawned |
| Mechanism (existing) | `BackendKind = Pipe \| Pty` | One-shot vs conversational |

A `TerminalBackend` is *constructed into* a `BackendHandle` by an appropriate factory. They share the word "Backend" but at adjacent layers; the doc and module structure call this out explicitly.

## Non-Goals

- **No new console UX.** The console's tab vocabulary, slot model, and prompt UX from #51 are unchanged. Only the `TabKind` ADT gains its two-level shape and the `/session new` command is dropped in favour of `/tab new`.
- **No re-architecture of the agent loop.** The deferred #51 follow-ups (Agent.Loop refactor, H2 sig migration, in-place `_tabHandle_name` mutation) are out of scope.
- **No new persistence for stateless tabs.** `TkRawShell` tabs continue to be in-memory-only.
- **No multi-user / multi-tenant changes.** Single-user model from #51 stands.
- **No automatic archival.** Lifecycle transitions are explicit user actions; there is no time-based or pressure-based auto-archive.
- **No rename of `BackendHandle`.** `TerminalBackend` (new, higher layer) and `BackendHandle` (existing, lower layer) coexist.
- **No Hermes-parity TerminalBackend variants in v1.** Daytona / Modal / Singularity are deferred; the ADT shape admits them as additive constructors.

## Three-Tier Lifecycle

Sessions traverse three tiers, mapping to existing `SessionMeta` state:

| Tier | Predicate | UI surface |
|---|---|---|
| **Running** | Has a live `TabHandle` in `_env_tabs` | Frontend: "Active Tabs" section; Console: numbered tab slot |
| **Recent** | `_sm_archived = False`, no live tab | Frontend: "Recent Sessions" section |
| **Archived** | `_sm_archived = True` | Frontend: "Archived" section (collapsed by default) |

Transitions:

- **Running → Recent** — user closes the tab. `_sh_save` flushes metadata; transcript is closed; tab vanishes from `_env_tabs`.
- **Recent → Running** — user resumes (via `/tab resume <id>` or clicking a Recent Sessions row). Loads `SessionMeta` from disk, opens a new tab at the lowest free slot.
- **Recent → Archived** — user archives. Sets `_sm_archived = True`, persists.
- **Archived → Recent** — user unarchives.

Stateless tabs (`TkRawShell`) participate in Running but never enter Recent or Archived. On close, they exit the system entirely.

## SessionKind ADT

```haskell
-- | What kind of AI execution this session represents.
-- Persisted as the `_sm_kind` field on SessionMeta.
--
-- Two top-level cases by who owns the agent loop:
--   * SkProvider — PureClaw owns the loop, talks to an LLM API directly.
--   * SkHarness  — Some OTHER harness CLI owns the loop; PureClaw drives it as a subprocess.
data SessionKind
  = SkProvider !ProviderSpec
  | SkHarness  !HarnessSpec
  deriving stock (Show, Eq)

data ProviderSpec = ProviderSpec
  { _ps_provider :: !ProviderName     -- e.g. "anthropic", "openai", "ollama", "openrouter"
  , _ps_model    :: !Text             -- e.g. "claude-opus-4-7"
  , _ps_agent    :: !(Maybe AgentName)
  } deriving stock (Show, Eq)

data HarnessSpec = HarnessSpec
  { _h_flavour :: !HarnessFlavour
  , _h_backend :: !TerminalBackend
  , _h_cwd     :: !(Maybe FilePath)
  , _h_args    :: ![Text]
  } deriving stock (Show, Eq)

-- | Well-known harness flavours plus a custom escape hatch.
--
-- Closed enum (with HCustom escape) chosen for: ergonomic pattern matching,
-- picker UI with a clean named list, type-level association of known
-- defaults (capabilities, conventional args), and one-line extension cost.
data HarnessFlavour
  = HClaudeCode    -- Anthropic's Claude Code CLI
  | HCodex         -- OpenAI's Codex CLI
  | HOpenCode      -- OpenCode
  | HHermes        -- Hermes Agent
  | HPureClaw      -- recursive: a PureClaw session driving another PureClaw
  | HCustom !Text  -- user-provided executable name; validated via `authorize`
  deriving stock (Show, Eq)
```

### TerminalBackend

```haskell
-- | Where a subprocess physically runs.
--
-- Vocabulary aligned with Hermes' "terminal backends" (gap-analysis-hermes-agent.md:59).
-- This is the higher layer above #49's `BackendHandle`: a TerminalBackend is a
-- description; a factory constructs it into a BackendHandle.
data TerminalBackend
  = TbLocal                              -- direct PTY subprocess on this host
  | TbTmux      !TmuxHarnessConfig       -- in a tmux pane (persistence + external attach)
  | TbSsh       !SshTarget               -- on a remote host via ssh
  | TbContainer !ContainerSpec           -- inside docker / podman / kubectl exec
  deriving stock (Show, Eq)

data ContainerSpec = ContainerSpec
  { _cs_engine :: !ContainerEngine       -- Docker | Podman | Kubectl
  , _cs_target :: !ContainerTarget       -- validated container ID/name or pod selector
  } deriving stock (Show, Eq)

data ContainerEngine = Docker | Podman | Kubectl
  deriving stock (Show, Eq, Bounded, Enum)
```

`TmuxHarnessConfig` and `SshTarget` already exist in #49 / #51; this work reuses them. `ContainerSpec` and `ContainerEngine` are new.

### The two orthogonal axes, realised at the type level

The earlier conversation framed sessions as having two orthogonal axes: *which harness* × *where it runs*. That framing is now realised directly in the type structure: `HarnessSpec._h_flavour :: HarnessFlavour` and `HarnessSpec._h_backend :: TerminalBackend`. There's no flat product enum; the axes are composable.

`SkProvider` has no `TerminalBackend` because there's no subprocess — PureClaw makes an HTTPS request and that's it.

## SessionMeta Changes

```haskell
data SessionMeta = SessionMeta
  { _sm_id                :: SessionId
  , _sm_kind              :: SessionKind        -- NEW: replaces _sm_runtime
  , _sm_agent             :: Maybe AgentName    -- Kept for backward-compat display fallback
  , _sm_model             :: Text               -- Kept for backward-compat display fallback
  , _sm_channel           :: Text
  , _sm_createdAt         :: UTCTime
  , _sm_lastActive        :: UTCTime
  , _sm_bootstrapConsumed :: Bool
  , _sm_archived          :: Bool               -- Unchanged
  , _sm_description       :: Maybe Text         -- Unchanged
  , _sm_autoSummary       :: Maybe Text         -- Unchanged
  } deriving stock (Show, Eq, Generic)
```

`_sm_runtime :: RuntimeType` is *removed*. Its information is folded into `_sm_kind`:

- `RTProvider` → `SkProvider {_ps_provider, _ps_model, _ps_agent}` (provider derived from model name; agent from `_sm_agent`).
- `RTHarness name` → `SkHarness {_h_flavour = lookupFlavour name, _h_backend = TbTmux (lookupTmuxConfig name), _h_cwd = Nothing, _h_args = []}`.

`_sm_agent` and `_sm_model` are kept for backward compatibility with the existing display fallback chain (`description` → `autoSummary` → snippet → `agent` → `id`). For `SkProvider` they duplicate `ProviderSpec`; for `SkHarness` they're informational.

## TabKind (in-memory only; not persisted)

```haskell
-- | The set of things that can occupy a tab slot.
--
-- Two variants because tabs split cleanly into "has a session" and "doesn't":
--   * TkSession  — backed by a SessionMeta on disk; the four lifecycle tiers apply.
--   * TkRawShell — stateless: a raw shell on a TerminalBackend, no harness.
--                  Lives in Active Tabs while open; vanishes on close.
data TabKind
  = TkSession  !SessionKind
  | TkRawShell !TerminalBackend
  deriving stock (Show, Eq)
```

The existing flat five-variant `TabKind` from #51 (`KindAi`, `KindHarness`, `KindShell`, `KindSsh`, `KindTmux`) is refactored:

- `KindAi` → `TkSession (SkProvider _)`
- `KindHarness` → `TkSession (SkHarness _ {_h_backend = TbTmux _})`
- `KindShell` → `TkRawShell TbLocal`
- `KindSsh` → `TkRawShell (TbSsh _)`
- `KindTmux` → `TkRawShell (TbTmux _)`

Existing call sites updated; the `-Werror` field-completion rule enforces correctness.

## JSON Migration

Existing `session.json` files on disk have shape:

```json
{
  "id": "...",
  "agent": "claude-opus-4-7",
  "runtime": "provider",                   // or "harness:claude-code"
  "model": "claude-opus-4-7",
  "channel": "frontend",
  "created_at": "...", "last_active": "...",
  "bootstrap_consumed": false,
  "archived": false
}
```

New sessions write the `kind` field:

```json
{
  "id": "...",
  "kind": {
    "tag": "provider",
    "provider": "anthropic",
    "model": "claude-opus-4-7",
    "agent": "default"
  },
  "agent": "default",
  "model": "claude-opus-4-7",
  "channel": "frontend",
  "created_at": "...", "last_active": "...",
  "bootstrap_consumed": false,
  "archived": false
}
```

For harness sessions:

```json
{
  "kind": {
    "tag": "harness",
    "flavour": "claude-code",
    "backend": { "tag": "tmux", "session": "pureclaw-cc", "window": "@42" },
    "cwd": "/Users/zoe/code/foo",
    "args": []
  }
}
```

The `FromJSON SessionMeta` decoder:

1. If `kind` field present: parse via `FromJSON SessionKind`.
2. Else if legacy `runtime` field present: map `"provider"` → `SkProvider` (provider inferred from model name; default `"anthropic"`), `"harness:<name>"` → `SkHarness` (flavour from name via registry; backend = `TbTmux` via discoverHarnesses lookup; cwd/args empty).
3. Default missing both → `SkProvider` with model from `_sm_model` (final fallback).

Tests assert: every legacy `session.json` fixture parses to a non-bottom `SessionMeta` with sensible `_sm_kind`.

## Frontend Sidebar

```
┌──────────────────────────────────┐
│ Active Tabs                  [+] │  ← header + new-tab affordance
│   0  ●  claude-code     (cwd=/r) │  ← session row: status dot + name + hint
│   1  ○  codex@docker  (claudvm)  │
│   2  ●  ssh prod-db       [raw]  │  ← raw shell badge
├──────────────────────────────────┤
│ Recent Sessions                  │
│   yesterday's debug     2h ago   │
│   refactor planning     1d ago   │
├──────────────────────────────────┤
│ Archived                    [▾]  │  ← collapsed by default
│   (8 archived sessions)          │
└──────────────────────────────────┘
```

### Active Tabs section

- Header: `"Active Tabs"` label + `[+]` button. Tooltip on hover: `"New tab"`. Aria-label: `"New tab"`.
- Each row: tab slot index, status indicator (icon — never the literal word "Active"), session/tab display name, optional context hint.
- Status indicator visual vocabulary: `●` (filled, coloured) for live activity; `○` (outline) for idle; `◐` (half) for "working"/streaming; `✕` (red) for crashed.
- User-facing status words (in tooltips / status bar): `Running`, `Working`, `Thinking`, `Idle`, `Crashed`. (Internal `Active`/`Idle`/`Crashed` enum is mapped to these.)
- `TkRawShell` rows show a `[raw]` badge indicating they will not persist on close.

### Recent Sessions section

- Unchanged from current layout (rows + age pill + archive button).
- Filter: `_sm_archived = False` AND session is not currently in `_env_tabs`.
- Clicking a row resumes the session.

### Archived section

- Collapsed by default; header shows count.
- Expanded: list of archived sessions with unarchive button per row.
- Filter: `_sm_archived = True`.

### Removed UI

- Top-bar "New Session" button (`frontend/src/components/TopBar.tsx:27`). The `[+]` in the sidebar is the sole creation affordance.

## Kind Picker Modal

Triggered by `[+]`. Two-step flow.

### Step 1 — Pick top-level kind

```
[ Provider ]    Direct LLM API (PureClaw is the harness)
[ Harness  ]    Drive an external agentic CLI (Claude Code, Codex, ...)
[ Raw shell ]   Just a terminal (won't be saved as a session)
```

### Step 2 — Kind-specific form

**Provider:**
- Provider dropdown (Anthropic / OpenAI / Ollama / OpenRouter)
- Model dropdown (populated from provider catalog)
- Agent picker (optional, populated from discoverAgents)

**Harness:**
- Flavour radio group (Claude Code / Codex / OpenCode / Hermes / PureClaw / Custom…) — sourced from the closed `HarnessFlavour` enum. "Custom" reveals an executable-name text field.
- Backend radio group (Local / Tmux / SSH / Container) with kind-specific sub-fields:
  - **Local**: optional cwd, additional args.
  - **Tmux**: tmux config — either pick a registered harness (from `discoverHarnesses`) or specify session/window manually.
  - **SSH**: `user@host`, identity key picker (from Vault), optional remote cwd.
  - **Container**: engine dropdown (Docker / Podman / Kubectl), container target text field (engine-specific placeholder), optional inner cwd.

**Raw shell:**
- Backend radio group (Local / Tmux / SSH) with the same sub-fields as Harness, minus Container (containers without a harness are out of scope for v1).

### Submit behaviour

- Validates form server-side via `POST /api/tabs/new`.
- On success: server returns the new tab's index and (if persistent) session ID. Modal closes; the new row appears in Active Tabs.
- On validation failure: inline error message; modal stays open.

## Backend API

### `POST /api/tabs/new` (unified)

One endpoint creates a tab; the server decides whether a session is persisted based on the tab kind.

**Request body:**
```json
{
  "kind": {
    "tag": "session",
    "session_kind": { "tag": "provider", "provider": "anthropic", "model": "claude-opus-4-7" }
  },
  "channel": "frontend",
  "description": "optional"
}
```

For a harness tab:
```json
{
  "kind": {
    "tag": "session",
    "session_kind": {
      "tag": "harness",
      "flavour": "claude-code",
      "backend": { "tag": "local", "cwd": "/Users/zoe/code/foo" },
      "args": []
    }
  }
}
```

For a stateless raw shell tab:
```json
{
  "kind": {
    "tag": "raw_shell",
    "backend": { "tag": "local", "cwd": "/Users/zoe/code/foo" }
  }
}
```

**Response (persistent kinds):**
```json
{
  "tab_index": 0,
  "session_id": "anthropic-20260522-103214-001",
  "kind": { ... }
}
```

**Response (stateless kinds):**
```json
{
  "tab_index": 1,
  "session_id": null,
  "kind": { ... }
}
```

The `session_id: Maybe SessionId` field in the response is the single discriminant between "session was created" and "tab is stateless." The frontend uses `null` as the cue to omit a Recent Sessions transition.

### `GET /api/tabs`

Returns the current state of the in-process tab registry: ordered list of `{ index, kind, name, status, session_id? }`. Polled by the frontend to populate Active Tabs. Status field is the user-facing word (`Running`/`Working`/`Thinking`/`Idle`/`Crashed`).

### `GET /api/sessions/recent`

Existing endpoint. Behaviour change: filter results to exclude session IDs currently in `_env_tabs`.

### `GET /api/sessions/archived`

NEW. Returns archived sessions (`_sm_archived = True`), sorted by `_sm_lastActive` desc.

### `POST /api/sessions/{id}/archive` and `/unarchive`

Existing flip-the-flag endpoints; ensure they're idempotent.

### Removed

- `POST /api/sessions/new` — the per-session endpoint is replaced by the unified `POST /api/tabs/new`. Existing clients calling the old route receive a 410 Gone with a header pointing at the new route for one release.

## Console Parity

- `/tab new harness <flavour> <backend> [backend-args…] [-- harness-args…]` — generalised. Examples:
  - `/tab new harness claude-code local`
  - `/tab new harness codex container docker my-dev-box`
  - `/tab new harness pureclaw ssh user@dev.box`
- `/tab new provider <provider> <model> [agent]` — direct-API session.
- `/tab new shell [backend] [backend-args…]` — raw shell (stateless).
- `/session new [agent]` — DROPPED. Emits a deprecation notice and is internally aliased to `/tab new provider <default-provider> <default-model> [agent]` for one release.
- `/tab list` and `/tabs` — show the kind for each tab. AI sessions render as `provider:anthropic claude-opus-4-7`; harness as `harness:claude-code/tmux`; raw as `shell:local`.

## Security Considerations

The new session kinds expand the attack surface. Smart constructors enforce:

- **HCustom flavour**: the executable name passes through `authorize` (same path as raw shell commands today).
- **ContainerTarget**: rejects shell metacharacters in container IDs; admits only `[a-zA-Z0-9_\-]+` for `docker`/`podman` and `pod/name:container` shapes for `kubectl`.
- **Container engine**: fixed allowlist (Docker / Podman / Kubectl); no plugin engines.
- **SSH identity**: taken from Vault slot `_rc_sshIdentityKey` only; no inline-credential acceptance.
- **Harness subprocess stdout**: NOT trusted as slash-command input (existing #51 discipline applies — `parseSlashCommand` runs on user input only).
- **Rate limits**: all new kinds respect `_rc_maxTabs` and the S7 spawn rate limit from #51.

## Definition of Done

Series-organised; each DoD is independently verifiable. The plan decomposes these into work units.

### G-series — Glossary / Documentation

- **G1**: `docs/session-tab-unification.md` (this doc) lands on the branch.
- **G2**: `docs/tabbed-chat.md` gets a post-merge note pointing at the new SessionKind/TabKind shape.
- **G3**: `docs/terminal-backend-abstractions.md` gets a note about the higher-layer `TerminalBackend` type that wraps `BackendHandle` factories.
- **G4**: `CLAUDE.md` "Key Decisions" section references the unified model.

### T-series — Type layer

- **T1**: `SessionKind` ADT (two-variant) defined in `PureClaw.Session.Types`.
- **T2**: `ProviderSpec`, `HarnessSpec`, `HarnessFlavour`, `TerminalBackend`, `ContainerSpec`, `ContainerEngine`, `ContainerTarget` defined with smart constructors where appropriate.
- **T3**: `SessionMeta._sm_kind :: SessionKind` field added; `_sm_runtime` removed.
- **T4**: `TabKind` refactored to two-level (`TkSession SessionKind | TkRawShell TerminalBackend`).
- **T5**: All construction sites updated (`-Werror` field-completion rule).
- **T6**: Module-level haddock on `TerminalBackend` calls out the layering relationship to `BackendHandle`.

### P-series — Persistence / Migration

- **P1**: `ToJSON SessionMeta` writes the new shape with `kind` field.
- **P2**: `FromJSON SessionMeta` accepts both new (`kind`) and legacy (`runtime`) shapes. Property: every fixture in `test/fixtures/legacy-session-json/` decodes to a non-bottom `SessionMeta`.
- **P3**: Round-trip: `toJSON . fromJSON $ legacyJson` produces the new shape; subsequent parse is stable.
- **P4**: `_sm_agent` and `_sm_model` fields preserve backward-compat display fallback for sessions without `kind`.

### F-series — Tab factories

- **F1**: `mkTabFromSessionKind :: AgentEnv -> TabIndex -> SessionKind -> IO (Either TabError TabHandle)` — top-level factory.
- **F2**: `mkProviderTab` (refactored from `mkTabAi`) takes `ProviderSpec`.
- **F3**: `mkHarnessTab` (NEW unified factory) takes `HarnessSpec`, dispatches on `_h_backend`. Subsumes #51's tmux-only `mkTabHarness` as the `TbTmux` arm.
- **F4**: `mkRawShellTab :: AgentEnv -> TabIndex -> TerminalBackend -> IO (Either TabError TabHandle)` — refactored from #51's `mkTabBackend`; no `SessionHandle` created.
- **F5**: All factories preserve #51 invariants: bracket-style status transitions, AsyncCancelled discipline, `sanitizeTabName`, `_env_fork` (not `forkIO`).
- **F6**: `mkHarnessTab` arms by backend: `TbLocal` spawns subprocess via `Backend.Local`'s Pty; `TbTmux` reuses existing #51 tmux harness path; `TbSsh` reuses #49 SSH PTY mechanism; `TbContainer` runs `<engine> exec -it <target> <flavour-binary> [args…]` via local PTY.

### A-series — Backend API

- **A1**: `POST /api/tabs/new` accepts the unified request body and creates a tab + optional session.
- **A2**: Response includes `session_id: Maybe SessionId` discriminating persistent vs stateless.
- **A3**: `GET /api/tabs` returns the live tab state with user-facing status words.
- **A4**: `GET /api/sessions/recent` excludes sessions currently in tabs.
- **A5**: `GET /api/sessions/archived` returns archived sessions.
- **A6**: `POST /api/sessions/{id}/archive` and `/unarchive` are idempotent.
- **A7**: `POST /api/sessions/new` (legacy) returns 410 Gone with a `Location` header for one release.
- **A8**: All write endpoints enforce `_rc_maxTabs` and S7 rate limit.

### U-series — Frontend UI

- **U1**: Sidebar.tsx adds an "Active Tabs" section above "Recent Sessions" with `[+]` affordance.
- **U2**: Status indicators use icons (●/○/◐/✕), not the literal word "Active".
- **U3**: Kind picker modal with two-step flow (top-level kind → kind-specific form).
- **U4**: Per-kind form fields wired to `POST /api/tabs/new`.
- **U5**: Top-bar "New Session" button removed.
- **U6**: Active Tabs rows show display name, status, optional context hint.
- **U7**: Clicking an Active Tab row focuses that tab.
- **U8**: Clicking a Recent Sessions row resumes the session into a new tab.
- **U9**: Archived section: collapsed by default, expandable, shows count.
- **U10**: `TkRawShell` rows show a `[raw]` badge.
- **U11**: Polling: `/api/tabs` polled at the same cadence as `/api/sessions/recent`.

### C-series — Console parity

- **C1**: `/tab new provider <provider> <model> [agent]` works.
- **C2**: `/tab new harness <flavour> <backend> [backend-args…] [-- harness-args…]` works for all four `TerminalBackend` constructors.
- **C3**: `/tab new shell <backend> [backend-args…]` works for raw shell tabs.
- **C4**: `/session new` emits deprecation notice and aliases to `/tab new provider`.
- **C5**: `/tab list` and `/tabs` show kind information per tab.

### L-series — Lifecycle

- **L1**: Closing a session-backed tab calls `_sh_save` and `_th_close` before removing it from `_env_tabs`.
- **L2**: Closing a `TkRawShell` tab destroys the backend handle and removes the tab; no `SessionMeta` written.
- **L3**: Resuming an archived session implicitly unarchives it (sets `_sm_archived = False`).
- **L4**: Archiving a Running session closes the tab first, then sets `_sm_archived = True`.
- **L5**: Unarchive moves session from Archived to Recent.

### S-series — Security

- **S1**: `ContainerTarget` smart constructor rejects shell metacharacters.
- **S2**: `HCustom` executables pass through `authorize`.
- **S3**: Container engine is fixed allowlist (Docker/Podman/Kubectl).
- **S4**: Harness subprocess stdout is NOT trusted as slash-command input.
- **S5**: All new kinds respect `_rc_maxTabs` and S7 rate limit.
- **S6**: SSH identity sourced from Vault only.

### M-series — Migration

- **M1**: Test fixtures of legacy `session.json` files (provider, harness:claude-code, no-agent, missing-runtime) added to `test/fixtures/legacy-session-json/`.
- **M2**: All fixtures decode to non-bottom `SessionMeta` with sensible `_sm_kind`.
- **M3**: Round-trip re-write of any legacy fixture produces the new shape; new shape re-parses identically.
- **M4**: Existing on-disk sessions in `~/.pureclaw/sessions/` load without manual migration.

## Open Questions

- **OQ-L1**: Resume-archived flow — resolved: implicit unarchive on resume (L3). If you're resuming it, you want to see it.
- **OQ-L2**: Archive-while-running — resolved: single click archives and closes (L4).
- **OQ-API**: Endpoint count — resolved: one unified `POST /api/tabs/new`. `session_id: Maybe SessionId` in response discriminates.
- **OQ-Picker**: Kind picker layout — resolved: modal with two-step flow.
- **OQ-CLI-detect**: For `HarnessFlavour`, do we want first-class detection of "is the CLI installed on this machine" with a friendlier error than "subprocess failed to spawn"? *Recommended: yes — `command -v <binary>` check before spawn, surfaced as a setup-help error. Defer to a follow-up if WU scope creeps.*
- **OQ-Container-pod**: For Kubectl, support label selectors in v1 or only direct `pod/name:container` strings? *Recommended: direct strings only in v1.*
- **OQ-Status-detail**: User-facing status word `Working` vs `Thinking` — is the distinction worth making, or collapse to `Working`? *Recommended: keep both — `Thinking` for "model is generating, no stream yet"; `Working` for "tool call running."*

## Out of Scope (v1.5+)

- **Clone / fork session** — "start a new session with the same setup as this old one." Trivial follow-up once `SessionKind` is in place.
- **Session templates** — saved kind+args bundles invocable by name.
- **Process adoption** — "take over a shell I started outside PureClaw." Tmux attach covers the realistic case today.
- **Archive import** — bring in sessions from a zip/tar exported elsewhere.
- **Hermes-parity terminal backends** — Daytona, Modal, Singularity. Type admits them as additive `TerminalBackend` constructors.
- **TmuxRpc backend** — non-PTY tmux control (stubbed in `Backend.hs:18`).
- **Cross-host session migration** — open a Recent session on a different PureClaw instance.

## Decision Log

- **Why "Session" as the entity, "Tab" as the slot?** Both words are correct from their respective UI contexts. The browser analogy ("a tab is the slot in the bar; the page is the entity") generalises cleanly.
- **Why two top-level SessionKinds (`Provider` and `Harness`) instead of more?** The fundamental split is "who owns the agent loop": PureClaw or someone else. Everything else (which CLI, where it runs) is a sub-axis.
- **Why `HarnessFlavour × TerminalBackend` as two axes inside `HarnessSpec` instead of a flat product enum?** The two axes are genuinely orthogonal; flattening creates O(N×M) constructors. The compositional form makes each new flavour or backend a one-line change.
- **Why "TerminalBackend" rather than "ExecHost" or "Host" or "Locus"?** Aligns with Hermes' established vocabulary ("terminal backends") and with PureClaw's own #49 work. Coexists with the lower-level `BackendHandle` because they're at adjacent layers, not the same layer.
- **Why keep `BackendHandle` un-renamed?** The rename has aesthetic value but real cost (touch points across factories, error types, prefix usage). The layering (`TerminalBackend` *constructs into* `BackendHandle`) is clean enough with both words present.
- **Why `TkSession | TkRawShell` instead of one flat enum?** Stateless tabs have no session; forcing them into `SessionKind` would either require a "non-persistent session" oxymoron variant or split lifecycle logic at every persistence call site.
- **Why drop `/session new` in favour of `/tab new provider`?** Console UX consistency. `/tab new <kind>` is the general path; `/session new` was a redundant prefix.
- **Why a single `[+]` affordance and not separate buttons per kind?** Discoverability scales poorly past 3 buttons; a picker keeps the kind set growable without UI churn. Matches Claude.ai's "New chat" pattern.
- **Why icons rather than the word "Active" for status?** Collides with the existing `Active` runtime status enum, which is one tier finer than the user-facing status.
- **Why one unified `POST /api/tabs/new` endpoint instead of two?** The thing being created is always a tab; whether a session is persisted is downstream from the kind. One endpoint, one client code path, response shape discriminates with `session_id: Maybe SessionId`.
- **Why `HarnessFlavour` as closed enum with `HCustom Text` escape hatch?** Known flavours get ergonomic pattern matching, picker UX gets a named list, type-level defaults are possible (default args, default backend), and `HCustom` covers the long tail. Adding a new well-known harness is a one-line change.
