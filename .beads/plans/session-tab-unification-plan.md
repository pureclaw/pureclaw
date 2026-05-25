---
status: complete
completed: WU-0, WU-1, WU-2, WU-3, WU-4, WU-5, WU-6, WU-7, WU-8, WU-9, WU-10, WU-11, WU-12, WU-13, WU-14
design_doc: docs/session-tab-unification.md
design_review: passed (round 2, all 5 agents APPROVED)
branch: fill-out-frontend
epic: pureclaw-9sp
---

# Session / Tab Unification — Implementation Plan

## Overview

Implements the approved design from `docs/session-tab-unification.md`. Three PRs, 15 work units total. Each WU follows the 4-phase loop: IMPLEMENT → VALIDATE → ADVERSARIAL REVIEW → COMMIT.

## Pre-flight Results

- **PF-A**: `cabal build` clean on HEAD (verified: pre-push hook passed at c330dde)
- **PF-B**: Frontend has NO test runner. **WU-0 adds vitest.**
- **PF-C**: `Frontend/Server.hs:46` uses `Warp.run port` (binds 0.0.0.0). **WU-1 fixes to 127.0.0.1.**
- **PF-D**: `_sm_runtime`/`RuntimeType` blast radius — 5 files, ~46 references:
  - `Session/Types.hs` (definition, 14 lines)
  - `Session/Handle.hs` (6 refs: re-export, construction, validateRuntime)
  - `Frontend/API.hs` (4 refs: runtimeToText, construction)
  - `Agent/SlashCommands.hs` (8 refs: createSession, session info display)
  - `CLI/Commands.hs` (3 refs: construction, resume validation)
- **TabKind blast radius**: 13 files, 132 references

## PR 1 — Type Layer + Migration + Pre-flights (WU-0 through WU-6)

**Goal**: New `Session.Kind` module, `SessionMeta._sm_kind` replaces `_sm_runtime`, `TabKind` refactored, all existing tests green.

**PR split note:** WU-0 (vitest) and WU-1 (Warp binding) are pre-flight fixes placed in PR 1 even though the design's PR 1 scope is "T/P/M/G/S1-S2". Rationale: WU-1 (S11: 127.0.0.1 binding) MUST land before any new endpoints (WU-7) per security review — it's a pre-condition, not a feature. WU-0 (vitest) is infrastructure that unblocks PR 3 testing — placing it early avoids blocking the critical path.

### WU-0: Frontend test infrastructure

**Scope**: `frontend/package.json`, `frontend/vitest.config.ts`, `frontend/tsconfig.json`
**DoD**: PF-B
**Deps**: None
**Effort**: Small

- Add vitest + @testing-library/react as dev dependencies
- Add `"test"` script to `package.json`
- Create minimal vitest config
- Verify `npm test` runs (even with 0 tests)

### WU-1: Warp 127.0.0.1 binding + CORS

**Scope**: `src/PureClaw/Frontend/Server.hs`
**DoD**: S11, PF-C
**Deps**: None
**Effort**: Small

- Switch `Warp.run port` to `Warp.runSettings` with `setHost "127.0.0.1"` and `setPort`
- Add CORS middleware restricting `Origin` — prefer `wai-extra` middleware (already a dependency) over adding new `wai-cors` package
- Test: verify server binds only to localhost (connection from non-localhost refused)
- RED: write test that current server would fail (e.g., test the settings value)
- GREEN: apply fix

### WU-2: Session.Kind leaf module — types + smart constructors

**Scope**: NEW `src/PureClaw/Session/Kind.hs`, `pureclaw.cabal` (exposed-modules)
**DoD**: T1, T2 (partial — types only, no Aeson yet), S1, S2, S3 (type-level: ContainerEngine allowlist IS the type)
**Deps**: None
**Effort**: Medium

Define all types in `PureClaw.Session.Kind`:
- `SessionKind = SkProvider !ProviderSpec | SkHarness !HarnessSpec`
- `ProviderSpec { _ps_provider :: !ProviderId, _ps_model :: !Text, _ps_agent :: !(Maybe AgentName) }`
- `HarnessSpec { _h_flavour :: !HarnessFlavour, _h_backend :: !TerminalBackend, _h_cwd :: !(Maybe Text), _h_args :: ![Text] }`
- `HarnessFlavour = HClaudeCode | HCodex | HOpenCode | HHermes | HPureClaw | HCustom !Text`
- `TerminalBackend = TbLocal | TbTmux !TmuxConfig | TbSsh !SshConfig | TbContainer !ContainerSpec`
- `TmuxConfig { _tc_session, _tc_window :: !Text, _tc_pane :: !(Maybe Text) }`
- `SshConfig { _sc_user, _sc_host :: !Text, _sc_port :: !(Maybe Int) }`
- `ContainerSpec { _cs_engine :: !ContainerEngine, _cs_target :: !ContainerTarget }`
- `ContainerEngine = Docker | Podman | Kubectl` (derive Ord too)
- `ContainerTarget` (newtype, smart constructor `mkContainerTarget`)
- `mkHCustom :: Text -> Either HCustomError HarnessFlavour` (reject path separators)
- `inferProviderId :: Text -> ProviderId` (fixed model-prefix → provider mapping)
- `fixedFlavourLookup :: Text -> HarnessFlavour` (fixed harness-name → flavour mapping)

Smart constructor tests (RED first):
- `mkContainerTarget` accepts `[a-zA-Z0-9_-]+`, rejects shell metacharacters
- `mkContainerTarget` accepts `pod/name:container` for Kubectl shape
- `mkHCustom` accepts bare names like `"claude"`, rejects `"/tmp/evil/claude"`, rejects `"foo\\bar"`
- `inferProviderId "claude-opus-4-7"` = anthropic, `"gpt-4o"` = openai, `"unknown"` = anthropic (fallback)
- `fixedFlavourLookup "claude-code"` = HClaudeCode, `"unknown"` = HCustom "unknown"

Imports: only `Core.Types` (for `ProviderId`, `SessionId`) and `Agent.AgentDef` (for `AgentName`).

### WU-3: Session.Kind Aeson instances

**Scope**: `src/PureClaw/Session/Kind.hs`
**DoD**: T2 (complete — Aeson instances), S12 (FromJSON HarnessFlavour validates HCustom at deserialization)
**Deps**: WU-2
**Effort**: Medium

Hand-written `ToJSON`/`FromJSON` for all types:
- `SessionKind`: tag-discriminated (`"provider"` / `"harness"`)
- `ProviderSpec`: `{ "provider": "anthropic", "model": "...", "agent": "..." }`
- `HarnessSpec`: `{ "flavour": "claude-code", "backend": {...}, "cwd": "...", "args": [...] }`
- `HarnessFlavour`: string for known (`"claude-code"`, `"codex"`, etc.), `"custom:name"` for HCustom
- `TerminalBackend`: tag-discriminated (`"local"`, `"tmux"`, `"ssh"`, `"container"`)
- `TmuxConfig`, `SshConfig`, `ContainerSpec`: flat objects with snake_case keys
- `ContainerEngine`: lowercase string (`"docker"`, `"podman"`, `"kubectl"`)
- `ContainerTarget`: `FromJSON` routes through `mkContainerTarget`
- `HarnessFlavour FromJSON`: routes `HCustom` through `mkHCustom` (S12 — validate at deserialization)

Tests (RED first):
- Round-trip: `decode . encode == identity` for each type
- `FromJSON HarnessFlavour` rejects `"custom:/tmp/evil"` (S12)
- `FromJSON ContainerTarget` rejects `"foo;rm -rf /"` (S1)
- Tag discrimination: `{"tag":"provider",...}` parses as `SkProvider`, `{"tag":"harness",...}` as `SkHarness`

### WU-4: SessionMeta migration — _sm_kind replaces _sm_runtime

**Scope**: `src/PureClaw/Session/Types.hs`, `src/PureClaw/Session/Handle.hs`, `src/PureClaw/CLI/Commands.hs`, NEW `test/fixtures/legacy-session-json/`
**DoD**: T3, T5 (Session.Types + Handle + CLI/Commands sites), P1, P2, P3, P4, M1, M2, M3, M4
**Deps**: WU-3
**Effort**: Large

Changes to `Session/Types.hs`:
- Add `import PureClaw.Session.Kind`
- Replace `_sm_runtime :: RuntimeType` with `_sm_kind :: SessionKind`
- Remove `RuntimeType` ADT and its instances (move `defaultTarget` to use `SessionKind`)
- Update `defaultTarget :: SessionKind -> MessageTarget`
- `ToJSON SessionMeta`: write `"kind"` field via `ToJSON SessionKind`
- `FromJSON SessionMeta`: accept `"kind"` (new) OR `"runtime"` (legacy). Use `inferProviderId` and `fixedFlavourLookup` for legacy path. Pure — no IO.
- Keep `_sm_agent`, `_sm_model` fields with backward-compat defaults

Changes to `Session/Handle.hs`:
- Update re-exports (remove `RuntimeType(..)`, add `SessionKind(..)` etc.)
- Update `validateRuntime` → `validateSessionKind` (or remove if no longer needed — check callers)
- Update all `SessionMeta` construction sites

Legacy test fixtures (in `test/fixtures/legacy-session-json/`):
- `provider-basic.json` — minimal RTProvider session
- `harness-claude-code.json` — RTHarness "claude-code"
- `no-agent.json` — session without agent field
- `missing-runtime.json` — very old session with no runtime field at all

Tests (RED first):
- Each fixture decodes to non-bottom `SessionMeta` with correct `_sm_kind`
- `provider-basic.json` → `SkProvider (ProviderSpec "anthropic" "claude-opus-4-7" ...)`
- `harness-claude-code.json` → `SkHarness (HarnessSpec HClaudeCode (TbTmux ...) ...)`
- Round-trip: `encode . decode $ legacyJson` produces new shape; re-decode is identical
- `_sm_agent` and `_sm_model` preserved through round-trip

**Blast radius**: All ~46 `RuntimeType`/`_sm_runtime` references across 5 files must be updated. `CLI/Commands.hs` has 3 references (RTProvider construction at line 562, RTHarness validation at lines 595/603). `-Werror` catches any missed sites.

Additional test fixture for new-format `kind` field:
- `new-format-provider.json` — session written with new `kind` field (tests branch 1 of the decoder)

### WU-5: TabKind refactor

**Scope**: `src/PureClaw/Handles/Tab.hs`, `src/PureClaw/Tab/Backend.hs`, `src/PureClaw/Routing/Types.hs` (`_rc_defaultKind` field type), `src/PureClaw/Routing/Config.hs` (TOML codec + `PartialRoutingConfig`), + all 13 files referencing TabKind constructors
**DoD**: T4, T5 (Tab sites), T6, F4 (mkRawShellTab refactored from mkTabBackend — takes TerminalBackend, no SessionHandle)
**Deps**: WU-2 (needs Session.Kind types), WU-4 (must commit before WU-5 since WU-4 removes RuntimeType which TabKind consumers reference)
**Effort**: Large

Note: `Routing/Config.hs` TOML codec for `TabKind` needs redesign — new `TabKind` carries structured payload, can't be a simple keyword. Strategy: `_rc_defaultKind` becomes `_rc_defaultKind :: !TabKind` using the new two-level ADT; TOML representation uses a structured sub-table or a compact string key (e.g. `"provider"` → `TkSession (SkProvider defaultProviderSpec)`) with `-Werror` exhaustiveness enforcement. `_prc_defaultKind`, `overlayRoutingConfig`, and `tabKindCodec` all update accordingly. The `.hs-boot` file for `Routing/Types.hs` exports `RoutingConfig` abstractly — unaffected.

- `Handles/Tab.hs`: Replace `TabKind = KindAi | KindHarness | KindShell | KindSsh | KindTmux` with `TabKind = TkSession !SessionKind | TkRawShell !TerminalBackend`
- Add `import PureClaw.Session.Kind`
- Add module-level haddock on the spec-vs-runtime layering (T6)
- Update `TabHandle._tabHandle_kind :: !TabKind`
- Update `mkTabBackend` signature

All 13 files referencing old constructors must be updated:
- `Agent/SlashCommands.hs` — `TabKindArg` and `parseTabKindArg` updated
- `Routing/Dispatcher.hs` — factory dispatch
- `Routing/Dashboard.hs` — `renderKind`
- `Routing/AutoSpawn.hs`, `Config.hs`, `Parse.hs`, `PromptRenderer.hs`, `Types.hs`, `LegacyDispatch.hs`
- `Tab/Ai.hs`, `Tab/Harness.hs`, `Tab/Backend.hs`

Translation table:
- `KindAi` → `TkSession (SkProvider _)` — pattern match on outer `TkSession` then `SkProvider`
- `KindHarness` → `TkSession (SkHarness _)`
- `KindShell` → `TkRawShell TbLocal`
- `KindSsh` → `TkRawShell (TbSsh _)`
- `KindTmux` → `TkRawShell (TbTmux _)`

Tests:
- All existing tests still pass (no behavior change, only type restructuring)
- `cabal build` clean under `-Werror`

### WU-6: Documentation updates

**Scope**: `docs/tabbed-chat.md`, `docs/terminal-backend-abstractions.md`, `CLAUDE.md`
**DoD**: G1 (already done), G2, G3, G4
**Deps**: WU-5
**Effort**: Small

- `docs/tabbed-chat.md`: Add post-merge note at top pointing at the new SessionKind/TabKind shape
- `docs/terminal-backend-abstractions.md`: Add note about TerminalBackend type
- `CLAUDE.md`: Add "Session/Tab unification" to Key Decisions

## PR 2 — Backend API + Security + Factories + Console (WU-7 through WU-11)

**Goal**: New endpoints, security hardening, tab factories for new backends, console parity commands.

**PR split note:** WU-11 (C-series console parity) is placed in PR 2 rather than PR 3 (where the design places C-series). Rationale: WU-11 depends on WU-10 (factories) and WU-7 (API), both in PR 2. Console commands are backend Haskell code, not frontend TypeScript — they naturally belong with the backend work. PR 3 becomes purely frontend.

### WU-7: POST /api/tabs/new unified endpoint

**Scope**: `src/PureClaw/Frontend/API.hs`, `src/PureClaw/Frontend/Server.hs`, `src/PureClaw/Tab/Ai.hs`, `frontend/src/` (update existing "New Session" call site to POST /api/tabs/new)
**DoD**: A1, A2, A7, A8, F1 (mkTabFromSessionKind top-level factory), F2 (mkProviderTab refactored from mkTabAi to take ProviderSpec)
**Deps**: WU-4 (SessionMeta with _sm_kind), WU-5 (TabKind refactored)
**Effort**: Large

- `mkTabFromSessionKind :: AgentEnv -> TabIndex -> SessionKind -> IO (Either TabError TabHandle)` — top-level factory dispatching to mkProviderTab / mkHarnessTab (F1)
- `mkProviderTab` refactored from `mkTabAi` to take `ProviderSpec` (F2)
- New handler `handleNewTab` accepting unified request body (snake_case JSON)
- Dispatches on `TabKind` to appropriate factory (mkTabFromSessionKind for TkSession, mkRawShellTab for TkRawShell)
- Returns `{ tab_index, session_id, kind }` (session_id = null for stateless)
- Enforces `_rc_maxTabs` and spawn rate limit
- Remove `handleNewSession` — replace with 410 Gone stub (A7): `Location: /api/tabs/new` header + `{"error":"deprecated","use":"/api/tabs/new"}` body
- **Frontend call-site update**: Existing "New Session" button still exists until PR 3 (WU-12 removes it), so update the frontend fetch call from `POST /api/sessions/new` to `POST /api/tabs/new` with a provider-kind payload. This prevents frontend breakage between PR 2 and PR 3.

Tests (RED first):
- POST with `{"kind":{"tag":"session","session_kind":{"tag":"provider",...}}}` creates provider tab
- POST with stateless kind → response has `session_id: null`
- POST when at maxTabs → 429 or appropriate error
- POST to `/api/sessions/new` → 410 Gone with Location header and JSON body

### WU-8: GET /api/tabs + GET /api/sessions/archived

**Scope**: `src/PureClaw/Frontend/API.hs`
**DoD**: A3, A4, A5, A6
**Deps**: WU-7
**Effort**: Medium

- `GET /api/tabs`: Read `_env_tabs` registry, return `[{ index, kind, name, status, session_id }]` with status mapped to Running/Idle/Crashed
- `GET /api/sessions/recent`: Filter excludes session IDs currently in tabs
- `GET /api/sessions/archived`: New endpoint, `_sm_archived = True`, sorted by lastActive desc
- `POST /api/sessions/{id}/archive` and `/unarchive`: Ensure idempotent

Tests:
- GET /api/tabs returns correct status words
- GET /api/sessions/recent excludes active tab sessions
- GET /api/sessions/archived returns only archived sessions
- Archive + unarchive is idempotent

### WU-9: HPureClaw depth limit + vault non-propagation

**Scope**: `src/PureClaw/Routing/Types.hs` (RoutingConfig: `_rc_maxPureClawDepth`, `_rc_pureClawDepth`), `src/PureClaw/Routing/Config.hs` (`defaultRoutingConfig`, `PartialRoutingConfig`, `overlayRoutingConfig`, TOML codec), CLI flag parsing (optparse-applicative `--depth` flag)
**DoD**: S7, S8
**Deps**: WU-2
**Effort**: Medium

- Add `_rc_maxPureClawDepth :: !Int` to `RoutingConfig` (default 2)
- Add `_rc_pureClawDepth :: !Int` (current depth, default 0) — incremented from `--depth` CLI flag
- Add `--depth` CLI flag to optparse-applicative parser
- Factory check: when spawning HPureClaw, if `_rc_pureClawDepth >= _rc_maxPureClawDepth`, return `Left MaxPureClawDepthExceeded`
- Document: child spawned with `--depth <current+1>`
- Vault: HPureClaw factory arm sets `_env_vault = Nothing` on child's AgentEnv

Tests:
- Depth 0, max 2 → spawn succeeds
- Depth 2, max 2 → spawn returns Left MaxPureClawDepthExceeded
- Verify child command line includes `--depth` flag
- Verify child AgentEnv has `_env_vault = Nothing`

### WU-10: Container + Local harness factory arms

**Scope**: `src/PureClaw/Tab/Harness.hs` (extend mkHarnessTab), possibly new `src/PureClaw/Tab/Container.hs`
**DoD**: F3 (TbLocal + TbContainer arms), F5 (factory invariants), F6, S4 (harness stdout not trusted — verify existing discipline preserved), S5 (maxTabs/rate limit for factory path), S6 (SSH identity from Vault only), S9, S10
**Deps**: WU-5 (TabKind refactored), WU-9 (for HPureClaw arm)
**Effort**: Large

- `mkHarnessTab` gains dispatch on `_h_backend`:
  - `TbLocal`: spawn via `Backend.Local` PTY (direct subprocess)
  - `TbTmux`: existing #51 tmux harness path (refactored)
  - `TbSsh`: reuse #49 SSH PTY mechanism (resolve `SshConfig` → `SshTarget` at spawn)
  - `TbContainer`: build argv `[engine, "exec", "-it", target, "--", binary] ++ args`, spawn via local PTY
- Container args denylist validation (S9)
- `_h_cwd` validation via `mkSafePath` at spawn time (S10)
- All factories preserve #51 invariants (F5): bracket status transitions, AsyncCancelled discipline, sanitizeTabName, _env_fork

Tests:
- Container args denylist rejects `--privileged`, `--cap-add`, etc.
- Container argv structure: verify `--` separator present
- `_h_cwd` with `../../etc` → validation failure
- TbLocal spawns a process (integration test with `/bin/echo`)

### WU-11: Console parity commands

**Scope**: `src/PureClaw/Agent/SlashCommands.hs`
**DoD**: C1, C2, C3, C4, C5, S5 (maxTabs enforcement for console /tab new path)
**Deps**: WU-10 (factories), WU-7 (for parity)
**Effort**: Medium

- `/tab new provider <provider> <model> [agent]`
- `/tab new harness <flavour> <backend> [backend-args…] [-- harness-args…]`
- `/tab new shell <backend> [backend-args…]`
- `/session new` → deprecation notice + alias to `/tab new provider`
- `/tab list` / `/tabs` → show kind info (provider:anthropic, harness:claude-code/tmux, shell:local)
- Update `TabKindArg` and `parseTabKindArg` for new syntax

Tests:
- Parse `/tab new provider anthropic claude-opus-4-7` → correct TabNewCmd
- Parse `/tab new harness claude-code local` → correct TabNewCmd
- Parse `/session new` → deprecation + alias
- `/tabs` output includes kind info

## PR 3 — Frontend UI (WU-12 through WU-14)

**Goal**: Three-tier sidebar, kind picker modal, status indicators.

### WU-12: Sidebar restructure — Active Tabs + Recent + Archived

**Scope**: `frontend/src/components/Sidebar.tsx`, new `frontend/src/components/ActiveTabs.tsx`, `frontend/src/components/ArchivedSessions.tsx`
**DoD**: U1, U2, U5, U6, U7, U8, U9, U10, U11
**Deps**: WU-8 (GET /api/tabs, GET /api/sessions/archived)
**Effort**: Large

- Remove TopBar "New Session" button (U5)
- Sidebar: three sections — Active Tabs (with [+]), Recent Sessions, Archived (collapsed)
- Active Tabs: poll GET /api/tabs, render rows with status icons (● ○ ✕), display name, [raw] badge
- Click Active Tab → focus that tab (U7)
- Click Recent Session → resume (U8)
- Archived: collapsed by default, shows count, expand to see list with unarchive button (U9)
- Polling: GET /api/tabs at same cadence as /api/sessions/recent (U11)

Tests (vitest + testing-library):
- ActiveTabs component renders tab rows from mock API data
- Status icon mapping: Active → ●, Idle → ○, Crashed → ✕
- [raw] badge shown for TkRawShell tabs
- Archived section collapsed by default, expandable

### WU-13: Kind picker modal

**Scope**: NEW `frontend/src/components/KindPickerModal.tsx`, wire to [+] button
**DoD**: U3, U4
**Deps**: WU-12 (sidebar with [+] button), WU-7 (POST /api/tabs/new)
**Effort**: Large

- Two-step modal: Step 1 (Provider / Harness / Raw shell), Step 2 (kind-specific form)
- Provider form: provider dropdown, model dropdown, agent picker
- Harness form: flavour radio, backend radio, backend-specific sub-fields
- Raw shell form: backend radio (Local/Tmux/SSH)
- Submit → POST /api/tabs/new
- Validation errors shown inline
- SSH form: user@host, port (no key picker — sourced from config)

Tests:
- Modal opens on [+] click
- Step 1 → Step 2 navigation
- Form submission produces correct JSON body
- Validation error display

### WU-14: Lifecycle transitions

**Scope**: Frontend event handlers, backend lifecycle endpoints
**DoD**: L1, L2, L3, L4, L5
**Deps**: WU-12, WU-8
**Effort**: Medium

- Close session-backed tab → _sh_save + _th_close (L1)
- Close raw shell tab → destroy backend, remove from registry (L2)
- Resume archived session → implicit unarchive (_sm_archived = False) (L3)
- Archive running session → close tab first, then set archived (L4)
- Unarchive → move from Archived to Recent (L5)

Tests:
- Archive a Recent session → appears in Archived
- Unarchive → appears in Recent
- Resume an archived session → appears in Active Tabs, _sm_archived = False

## Dependency Graph

```
WU-0 (vitest)    WU-1 (Warp binding)    WU-2 (Session.Kind types)
                                               |
                                         WU-3 (Aeson instances)
                                               |
                                         WU-4 (SessionMeta migration)
                                               |
                                         WU-5 (TabKind refactor + F4)
                                          / |
                                         /  |          WU-9 (depth limit)
                                        /   |               |
                                  WU-6 |  WU-7 (API + F1/F2)  |
                                  (docs)|    |          WU-10 (factories)
                                        |  WU-8 (GET)     |
                                        |    |        WU-11 (console)
                                        |    |
                                        | WU-12 (sidebar)
                                        |    |
                                        | WU-13 (picker)
                                        |
                                       WU-14 (lifecycle)
```

**Dependency edges:**
- WU-3 → WU-2; WU-4 → WU-3; WU-5 → WU-2, WU-4 (ordering)
- WU-7 → WU-4, WU-5; WU-8 → WU-7; WU-9 → WU-2; WU-10 → WU-5, WU-9
- WU-11 → WU-7, WU-10; WU-12 → WU-8; WU-13 → WU-12, WU-7; WU-14 → WU-12, WU-8

## Risk Register

| Risk | Mitigation | Owner |
|---|---|---|
| TabKind refactor breaks 132 references across 13 files | `-Werror` field-completion catches all; do in a single atomic commit | WU-5 |
| Legacy session.json files fail to parse after migration | Fixture-based regression tests (M-series); fallback to SkProvider | WU-4 |
| .hs-boot cycle regression | Session.Kind is a leaf; verified import graph in design review | WU-2 |
| Container exec injection | Explicit argv + denylist + `--` separator; tested | WU-10 |
| HPureClaw fork bomb | Depth limit enforced at factory; tested | WU-9 |
| Frontend test infrastructure blocks UI work | WU-0 is independent, runs first | WU-0 |

## Human Checkpoints

1. **After PR 1 (WU-6 complete)**: Review type layer and migration before API work begins
2. **After WU-10 (factories)**: Review security-sensitive factory code before console/frontend wiring
3. **After PR 3 (WU-14 complete)**: Full manual walkthrough of frontend before merge
