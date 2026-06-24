# Frontend CRUD for Agents (and a routed page shell) — Design

- **Issue:** [#61 Create frontend UX CRUD for agents and skills](https://github.com/pureclaw/pureclaw/issues/61)
- **Date:** 2026-06-18
- **Status:** Design — approved in brainstorming; pending design-review gate. **No implementation yet.**
- **Scope decision:** Agents only in this iteration. The page shell and patterns are built so **Skills** (and other resource types) slot in later with no rework.

## Problem

PureClaw's web frontend is a single screen: a left sidebar of sessions/tabs/harnesses
and a central chat area. "Agents" exist as first-class backend entities
(`~/.pureclaw/agents/<name>/` directories with bootstrap markdown + TOML config) but are
**read-only** from the UI — only `GET /api/agents` exists. There is no way to create,
edit, or delete agents, or to manage the files inside an agent, from the web UI.

Issue #61 asks for a "frontend UX CRUD for agents and skills" surfaced under a **new
higher-level menu** (not the left session bar — at the top of the page). PureClaw has **no
"skill" concept anywhere in its codebase** (confirmed: zero references in `src/`), so this
iteration delivers **agents only** while establishing a repeatable, routed page structure
that Skills can reuse.

## Goals

- A top-level navigation menu with **Sessions** and **Agents** entries (Skills later).
- The entire existing UI becomes the **Sessions** page (a pure refactor — no behavior change).
- An **Agents** page that supports full CRUD:
  - Create / delete agents.
  - Edit the agent's TOML config (`model`, `tool_profile`, `workspace`), preserving the
    `AGENTS.md` body.
  - Create / read / update / delete **arbitrary flat text files** inside an agent's directory.
  - Set which agent is the **default**, persisted across restarts.
- Deep-linkable agent URLs (`/agents/:name`).
- Repeatable structure so adding "Skills" later is additive.

## Non-Goals (v1)

- The "Skills" feature itself (separate follow-up issue once agents land).
- Nested subdirectories inside an agent (flat files only in v1).
- Binary file uploads (text/UTF-8 only).
- Optimistic-concurrency tokens / multi-editor conflict resolution (last-write-wins).
- Live propagation of edits into already-running sessions (agents are read at session
  start; edits apply on next use).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| What are "skills"? | Out of scope now; design so a peer "Skills" page slots in later. |
| Agent edit scope | Config **plus** create/update/delete of **arbitrary** files in the agent dir. |
| Management UX shape | **Dedicated client-side routes/pages.** Current UI → `/sessions`; Agents → `/agents`. |
| Router | **`react-router-dom` v6** (frontend is expected to grow). |
| URL style | **`BrowserRouter`** (clean paths). Backend SPA fallback already serves `index.html`. |
| Set default from UI | **Yes** — requires runtime-mutable default + persistence. |
| File scope | **Flat text files** directly in the agent dir; no subdirs; reuse 1 MB cap. |

## Architecture

### Section 1 — App shell & routing (frontend)

Introduce `react-router-dom` v6 and restructure the SPA around a persistent shell.

- **`<AppShell>`** renders **`<TopNav>`** above a routed `<Outlet>`.
- **`<TopNav>`** extends today's static `TopBar` (logo + version) with top-level nav links —
  **Sessions** and **Agents** — with active-route highlighting. New resource types (Skills,
  …) are added here.
- **Routes:**
  - `/` → redirect to `/sessions`
  - `/sessions` → **`<SessionsPage>`** = today's entire UI (Sidebar + ChatArea/HarnessControls
    + BottomBar), lifted out of `App.tsx` **verbatim**. All session/tab/harness state and the
    WebSocket stream live inside this page → behavior unchanged.
  - `/agents` → **`<AgentsPage>`** (list view)
  - `/agents/:name` → **`<AgentsPage>`** with that agent selected (detail view)
  - `*` → NotFound → redirect to `/sessions`
- **`App.tsx`** shrinks to `<BrowserRouter>` + the route table.

> **Refactor invariant:** moving the current UI into `SessionsPage` is a pure move. All
> existing session/tab tests must stay green; the Agents feature is purely additive.

`BrowserRouter` deep-links (e.g. `/agents/foo`) work without backend changes: `staticApp`
(`src/PureClaw/Frontend/Server.hs:238`) already falls back to `index.html` for unknown paths
and rejects `..`/`.` traversal segments.

### Section 2 — Backend API & security

New REST endpoints under `/api/agents`, dispatched in `src/PureClaw/Frontend/API.hs` and
backed by a **new module `PureClaw.Agent.AgentStore`** (mutation + smart constructors),
keeping `PureClaw.Agent.AgentDef` focused on discovery/read.

| Method & path | Purpose | Notes / errors |
|---|---|---|
| `GET /api/agents` | List agents *(exists)* | unchanged: `[{name, isDefault}]` |
| `GET /api/agents/:name` | Agent detail | `{name, isDefault, config:{model,tool_profile,workspace}, files:[{name,size}]}`; 404 if missing |
| `POST /api/agents` | Create agent | body `{name}`; scaffolds dir + minimal `AGENTS.md`; 409 if exists, 400 invalid name |
| `DELETE /api/agents/:name` | Delete agent | removes dir; 404 if missing; clears default if it was default |
| `PUT /api/agents/:name/config` | Update TOML config | body `{model,tool_profile,workspace}`; rewrites `AGENTS.md` frontmatter, **preserves body** |
| `GET /api/agents/:name/files` | List files (flat) | `[{name,size}]`; top-level files only, subdirs skipped |
| `GET /api/agents/:name/files/:file` | Read file | text; 404 if missing; size-capped |
| `PUT /api/agents/:name/files/:file` | Create/update file | text body; validated filename; 413 if over cap |
| `DELETE /api/agents/:name/files/:file` | Delete file | 404 if missing |
| `PUT /api/agents/default` | Set default agent | body `{name}`; persists choice; 404 if name unknown |

**Security model (arbitrary file writes — the sensitive part):**

- **Agent name** flows through the existing `mkAgentName` smart constructor
  (`src/PureClaw/Agent/AgentDef.hs:76`) — already rejects `.`, `/`, `..`, empty, and >64 chars.
- **Filename**: a new `mkAgentFileName` smart constructor mirroring `mkAgentName` —
  non-empty, length-bounded, rejects path separators (`/`, `\`), `..`, and leading dots;
  permits a single extension dot.
- **Path confinement (defense in depth):** after joining `agentsDir/<name>/<file>`,
  canonicalize and assert the result is still prefixed by `agentsDir/<name>/` (blocks
  traversal and symlink escape even if a validator is bypassed).
- **Size cap:** reuse `maxBootstrapFileBytes` (1 MB, `AgentDef.hs:179`) on every write →
  reject larger with **413**.
- **Text/UTF-8 only; flat** (no subdir creation), per the v1 file-scope decision.

**Default-agent persistence:** `_fe_defaultAgent :: Maybe Text` (`API.hs:204`) is currently
an immutable startup value. Change it to **`IORef (Maybe Text)`** in `FrontendEnv`, seeded at
startup from config **and** a small state file (`~/.pureclaw/state/default-agent`), written
through on `PUT /api/agents/default`, and read back at the next startup. (IORef per the
project's "IORef unless TVar/MVar necessary" convention.)

**Concurrency / agent-in-use:** agents are read once at session start, so editing an agent's
files never disturbs a running session — changes apply on next use. No locking;
last-write-wins. The UI surfaces a small note so this isn't surprising.

### Section 3 — Agents page UX (frontend)

`<AgentsPage>` mirrors the two-pane feel of Sessions for consistency.

- **Left rail:** agent list (name + "default" badge) and a **+ New agent** button. Selecting
  an agent navigates to `/agents/:name`.
- **Right pane (selected agent):**
  - **Header:** agent name; **Make default** (disabled when already default); **Delete**
    (confirm dialog).
  - **Config card:** `model`, `tool_profile`, `workspace` free-text inputs → **Save**
    (`PUT .../config`; body preserved).
  - **Files card:** flat list of files (name + size). **+ New file** (prompts for a name,
    client-validated to mirror `mkAgentFileName`). Clicking a file opens a **textarea editor**
    with Save/Revert and a dirty indicator; per-file **Delete** (confirm).
- **Create flow:** name prompt (client-side validation mirroring `mkAgentName`) →
  `POST /api/agents` → navigate to the new `/agents/:name`.
- **Reused patterns:** optimistic update + rollback exactly like the existing
  archive/description handlers (`frontend/src/App.tsx:414-455`); an **unsaved-changes guard**
  when leaving a dirty file editor.
- **Edge/empty states:** no agents → create prompt; no selection → hint; banner noting edits
  apply to the agent's *next* use, not running sessions.
- **New frontend pieces:** `pages/SessionsPage.tsx`, `pages/AgentsPage.tsx` (+ `AgentList`,
  `AgentDetail`, `AgentConfigForm`, `AgentFileList`, `AgentFileEditor`),
  `components/TopNav.tsx`; new hooks in `hooks/useApi.ts`; new types in `types.ts`.

### Data shapes

Backend JSON (new Aeson types in `API.hs` or a `Frontend.Types` module):

```jsonc
// GET /api/agents/:name
{
  "name": "zoe",
  "isDefault": true,
  "config": { "model": "claude-opus", "tool_profile": null, "workspace": null },
  "files": [ { "name": "AGENTS.md", "size": 47 }, { "name": "SOUL.md", "size": 13 } ]
}
```

Frontend types (`types.ts`): `AgentDetail`, `AgentConfig`, `AgentFileMeta`.
New `useApi.ts` hooks/calls: `useAgentDetail`, `createAgent`, `deleteAgent`,
`updateAgentConfig`, `listAgentFiles`, `readAgentFile`, `writeAgentFile`, `deleteAgentFile`,
`setDefaultAgent`.

## Error Handling

- Backend handlers return precise status codes (400 invalid name/filename, 404 missing,
  409 already exists, 413 too large, 500 IO failure) with `{error}` JSON bodies, matching
  existing `API.hs` conventions.
- Frontend optimistic mutations roll back on non-2xx and surface a retry affordance,
  following the established archive/description rollback pattern.
- Filenames and agent names are validated client-side for instant feedback **and** revalidated
  server-side (the server is the security boundary).

## Testing Strategy

- **Backend (hspec):** new `AgentStore` — create/delete agent; config rewrite preserving body;
  file list/read/write/delete; `mkAgentFileName` validation; **traversal + symlink-escape
  rejection**; **size-cap (413)**; default persistence across reload. Plus `API.hs` handler
  tests for status codes and error paths.
- **Frontend (vitest + RTL):** `AgentsPage` and subcomponents; hooks; `TopNav`; router
  navigation + deep-link; optimistic rollback; client-side validation; unsaved-changes guard.
- **Refactor safety:** all existing session/tab tests stay green after the `SessionsPage` move.
- **Gates:** coverage ≥ **95%** for lines/branches/functions/statements (per
  `.coverage-thresholds.json`); `-Wall -Werror` + hlint clean; frontend typecheck + lint pass.

## Definition of Done

1. `react-router-dom` + `BrowserRouter`; `TopNav` with **Sessions**/**Agents**; the entire
   current UI lives under `/sessions` with existing tests passing.
2. `/agents` list + `/agents/:name` detail, deep-linkable.
3. Create and delete an agent.
4. Edit/save TOML config (`model`/`tool_profile`/`workspace`) preserving the body.
5. Per-agent flat file CRUD with filename validation, path-traversal guard, and 1 MB cap.
6. Set default agent; persists across restart.
7. All new backend endpoints + smart constructors covered by tests, including security
   (traversal/size) cases.
8. All quality gates green (coverage ≥ 95%, `-Wall -Werror`, hlint, frontend lint/typecheck).

## Suggested File Scope

**Backend**
- `src/PureClaw/Agent/AgentStore.hs` *(new)* — mutations, `mkAgentFileName`, default persistence.
- `src/PureClaw/Agent/AgentDef.hs` — export/reuse helpers (frontmatter rewrite).
- `src/PureClaw/Frontend/API.hs` — new handlers, routes, JSON types; `_fe_defaultAgent` → IORef.
- `src/PureClaw/Frontend/Server.hs` / startup wiring — seed default IORef from state file.
- `test/` — `AgentStoreSpec.hs`, API handler tests, fixtures.

**Frontend**
- `frontend/package.json` — add `react-router-dom`.
- `frontend/src/App.tsx` — slim to `<BrowserRouter>` + routes.
- `frontend/src/pages/SessionsPage.tsx` *(new, extracted)*.
- `frontend/src/pages/AgentsPage.tsx` *(new)* + `AgentList`, `AgentDetail`, `AgentConfigForm`,
  `AgentFileList`, `AgentFileEditor`.
- `frontend/src/components/TopNav.tsx` *(new, from `TopBar`)*.
- `frontend/src/hooks/useApi.ts` — new hooks.
- `frontend/src/types.ts` — new types.
- `frontend/src/**` tests alongside.

## Human Checkpoints

1. After the `SessionsPage` refactor — verify no session/tab regression before adding Agents.
2. After backend endpoints + security tests — review the file-write boundary.
3. After the Agents page — full CRUD walkthrough.

## Next Step

Per project workflow, the next gate is the **Design Review Gate** (`/review-design`, 5 agents)
before any planning/implementation. Implementation has **not** started.
