# Sessions and Agents — Implementation Plan (Revision 2)

**Status**: in-progress
**Branch**: sessions-and-agents
**Design**: `.beads/plans/sessions-and-agents.md` (revision 3)
**Priority**: P1

## Overview

Implement Sessions and Agents per the approved design. Two sequential work units with a clean seam — WU1 (Agents) has no dependency on sessions and is independently shippable.

**Revision 2 changes** (addressing Plan Review Gate feedback):
- `pureclaw.cabal` module registration added to both work units
- `AgentEnv` construction site enumeration (production + test helpers) added
- `/transcript` slash command update added to WU2
- Exhaustive TDD sequences covering every DoD bullet
- Custom `FromJSON` for smart-constructor types to prevent bypass
- Injectable bootstrap-consumed callback for testability
- TOML frontmatter fence extraction step called out
- Prefix-matching semantics pinned

## AgentEnv Construction Sites

Enumerated to avoid hidden file scope explosion. All sites must be updated when adding new `AgentEnv` fields (`-Werror` enforced):

1. `src/PureClaw/CLI/Commands.hs:startWithChannel` — primary production construction
2. `test/Agent/SlashCommandsSpec.hs` — test helper (likely `mkTestEnv` or similar)
3. `test/Agent/LoopSpec.hs` — test helper

**Strategy to minimize churn**: Both `_env_agentDef :: Maybe AgentDef` AND `_env_session :: SessionHandle` are added in WU1. In WU1, `_env_session` is initialized to `mkNoOpSessionHandle`. WU2 replaces the no-op with real session handling. This touches each construction site once instead of twice.

---

## Work Unit 1: Agents

**Goal**: Named collections of `.md` bootstrap files in `~/.pureclaw/agents/<name>/` can be discovered, loaded, validated, and composed into a system prompt. Selectable via `--agent` flag and `/agent` slash commands.

### DoD

- [ ] `AgentName` smart constructor rejects path traversal, validates `[a-zA-Z0-9_-]`, max 64 chars, non-exported constructor
- [ ] `AgentName` has custom `FromJSON` that calls `mkAgentName` (prevents bypass via corrupted JSON)
- [ ] `AgentDef`, `AgentConfig` types implemented with TOML frontmatter parsing
- [ ] TOML frontmatter fence extraction (splits `---\n...\n---\nbody`) before handing inner block to `tomland`
- [ ] `discoverAgents` enumerates `~/.pureclaw/agents/` and skips invalid directory names with log warning
- [ ] `loadAgent :: FilePath -> AgentName -> IO (Maybe AgentDef)` works for existing dirs
- [ ] `composeAgentPrompt` reads bootstrap files in order, skips empty/missing, truncates at 8000 chars (configurable), rejects files >1MB at read time
- [ ] Truncation marker string is exactly `\n[...truncated at 8000 chars...]`
- [ ] Section markers are exactly `--- SOUL ---`, `--- USER ---`, `--- AGENTS ---`, `--- MEMORY ---`, `--- IDENTITY ---`, `--- TOOLS ---`, `--- BOOTSTRAP ---`
- [ ] `composeAgentPromptWithBootstrap` skips `BOOTSTRAP.md` when `bootstrapConsumed=True`
- [ ] Empty agent dir (no .md files) is valid — returns empty system prompt with log info
- [ ] Workspace validation: tilde-expand, absolute required, must exist, canonicalize, denylist check covering `/`, `/etc`, `/usr`, `/bin`, `/sbin`, `/var`, `/sys`, `/proc`, `/dev`, `$HOME/.ssh`, `$HOME/.gnupg`, `$HOME/.aws`, `$HOME/.config`, `$HOME/.pureclaw`
- [ ] Default workspace `~/.pureclaw/agents/<name>/workspace/` is created on first use with `0o700` permissions
- [ ] Custom workspace (from frontmatter) must exist — not auto-created
- [ ] Override priority enforced: CLI flag > agent frontmatter > config file > default
- [ ] `--agent <name>` CLI flag works; invalid name → error with hint; missing agent → error lists available agents
- [ ] `default_agent` config field loads agent when `--agent` omitted
- [ ] `/agent list` shows agents, or helpful message when none
- [ ] `/agent info [<name>]` shows files, frontmatter, workspace; no-agent-selected message; missing agent error
- [ ] `/agent start <name>` switches agent (placeholder in WU1 — full behavior lands in WU2 when sessions exist)
- [ ] Tab completion for agent names in `/agent info` and `/agent start`
- [ ] No-agent backward-compat path (existing `loadIdentity` + `--system`) still works and is tested
- [ ] `AgentEnv` gains `_env_agentDef :: Maybe AgentDef` and `_env_session :: SessionHandle` (no-op in WU1)
- [ ] `mkNoOpSessionHandle` stub exists in `src/PureClaw/Session/Handle.hs` (minimal skeleton for WU1, full implementation in WU2)
- [ ] `pureclaw.cabal` updated with new modules in `exposed-modules` and test spec in test suite `other-modules`
- [ ] 100% test coverage (lines, branches, functions, statements)
- [ ] `-Wall -Werror` clean, hlint clean, `-Wmissing-export-lists` honored (explicit export lists on all new modules)

### Files Affected

**New**:
- `src/PureClaw/Agent/AgentDef.hs` — `AgentName` (smart constructor, custom `FromJSON`), `AgentConfig`, `AgentDef`, `discoverAgents`, `loadAgent`, `composeAgentPrompt`, `composeAgentPromptWithBootstrap`, workspace validation, TOML fence extraction
- `src/PureClaw/Session/Handle.hs` — `SessionHandle` type, `mkNoOpSessionHandle` ONLY (full implementation in WU2)
- `test/Agent/AgentDefSpec.hs` — unit tests
- `test/fixtures/agents/` — fixture agent directories used across tests

**Modified**:
- `pureclaw.cabal` — add `PureClaw.Agent.AgentDef` and `PureClaw.Session.Handle` to `exposed-modules`; add `Agent.AgentDefSpec` to test suite `other-modules`
- `src/PureClaw/Agent/Env.hs` — add `_env_agentDef :: Maybe AgentDef` and `_env_session :: SessionHandle`; add `envTranscript` accessor (reads from session's no-op transcript in WU1)
- `src/PureClaw/Agent/SlashCommands.hs` — add `/agent list|info|start` commands + tab completion over agent names
- `src/PureClaw/CLI/Commands.hs:startWithChannel` — add `--agent` flag, discover agents, load selected agent, compose system prompt, initialize `_env_session` with `mkNoOpSessionHandle`, update `AgentEnv` construction
- `src/PureClaw/CLI/Config.hs` — add `_fc_defaultAgent`, `_fc_agentTruncateLimit` fields + TOML codec
- `test/Agent/SlashCommandsSpec.hs` — update test helper to include `_env_agentDef` and `_env_session`
- `test/Agent/LoopSpec.hs` — update test helper similarly
- `test/Integration/CLISpec.hs` — add `--agent` integration tests (confirmed to exist)

### TDD Sequence

**Each step = separate commits: (1) failing test, (2) minimum implementation, (3) optional refactor.**

1. **AgentName smart constructor**
   - Red: tests for `mkAgentName ""`, `mkAgentName "../evil"`, `mkAgentName "foo/bar"`, `mkAgentName "a\0b"`, `mkAgentName ".hidden"`, `mkAgentName (T.replicate 65 "a")`, `mkAgentName "valid-name_1"`
   - Green: implement with `[a-zA-Z0-9_-]` regex, max 64, reject empty
   - Exhaustive: every rejection branch has a dedicated test (coverage requirement)

2. **AgentName custom FromJSON**
   - Red: `decode "\"../evil\"" :: Maybe AgentName` returns `Nothing`; `decode "\"zoe\""` returns `Just (AgentName "zoe")`
   - Green: custom `FromJSON` calls `mkAgentName`, fails with `parseFail` on error
   - Ensures smart constructor cannot be bypassed via corrupted JSON files

3. **TOML frontmatter fence extraction**
   - Red: `extractFrontmatter "---\nmodel = \"foo\"\n---\nbody"` returns `(Just "model = \"foo\"", "body")`; no fence returns `(Nothing, whole)`; malformed fence returns `(Nothing, whole)` with warning
   - Green: implement fence splitter (plain Text parsing, no library)

4. **AgentConfig TOML parser**
   - Red: full pipeline `parseAgentsMd` on fixture files → expected `(AgentConfig, body)` pairs
   - Green: wire `extractFrontmatter` → `Toml.decode` → `AgentConfig`
   - Tests: no frontmatter, empty frontmatter, all fields set, unknown fields ignored, parse error returns `defaultAgentConfig` + log warning

5. **composeAgentPrompt — file reading basics**
   - Red: fixture agent dir with SOUL.md + AGENTS.md → exact expected output with section markers
   - Green: implement file reading with section concatenation
   - Tests cover each file type in the injection order table

6. **composeAgentPrompt — skip empty, truncate large, reject >1MB**
   - Red: fixture with empty SOUL.md (skipped), 10000-char AGENTS.md (truncated at 8000 + marker), 2MB MEMORY.md (rejected with log warning)
   - Green: implement skip/truncate/reject logic
   - Tests cover: zero bytes, whitespace-only, exactly-at-limit, just-over-limit, >1MB

7. **composeAgentPromptWithBootstrap**
   - Red: fixture with BOOTSTRAP.md → when `consumed=False`, BOOTSTRAP included; when `consumed=True`, BOOTSTRAP skipped
   - Green: add bootstrap flag branch
   - Tests cover both paths

8. **composeAgentPrompt — empty agent dir**
   - Red: fixture dir with no .md files → returns empty Text, logs info
   - Green: handle empty-result case

9. **discoverAgents**
   - Red: fixture parent with `zoe/` (valid), `../escape/` (not possible since it's a real dir name test), `bad name/` (contains space → invalid), `valid_1/` (valid) → returns `[zoe, valid_1]`, logs warning for bad name
   - Green: implement with `listDirectory` + `mkAgentName` filter
   - Tests: missing parent dir, empty parent, invalid names skipped

10. **Workspace validation — exhaustive denylist**
    - Red: for EACH entry in the denylist table (`/etc`, `/usr`, ..., `$HOME/.ssh`, `$HOME/.pureclaw`), create a test asserting `validateWorkspace` rejects it
    - Red: valid temp dir accepted; relative path rejected; nonexistent dir rejected
    - Red: symlink pointing to denylisted dir rejected (via `canonicalizePath` resolution) — requires `createSymbolicLink` from `unix`
    - Green: implement validation pipeline
    - Coverage: every denylist entry hit (branch coverage requirement)

11. **Default workspace auto-creation**
    - Red: session starts with no custom workspace → `~/.pureclaw/agents/<name>/workspace/` is created with mode `0o700` (verified via `getFileStatus`)
    - Green: add auto-creation in `loadAgent` or session setup
    - Tests: creation is idempotent (second start doesn't fail); custom workspace does NOT auto-create

12. **Override priority resolution**
    - Red: with CLI `--model X`, frontmatter `model = "Y"`, config `model = "Z"` → effective model is `X`. Drop CLI → `Y`. Drop frontmatter → `Z`. Drop all → default.
    - Green: implement priority resolution in `runChat`
    - Tests: test table for model, tool_profile, workspace

13. **`/agent list`**
    - Red: parser test; handler test with fixture agent dir; empty-dir case produces "No agents found. Create one at ~/.pureclaw/agents/<name>/"
    - Green: implement command and handler

14. **`/agent info`**
    - Red: `/agent info zoe` shows files + frontmatter + effective workspace; `/agent info nonexistent` → "Agent \"nonexistent\" not found. Available agents: ..."; `/agent info` with no agent selected shows "No agent selected. Use --agent <name>."
    - Green: implement
    - Tests: all three branches

15. **`/agent start` (WU1 skeleton)**
    - Red: parser test; handler test stubs for future expansion
    - Green: implement parser + placeholder handler (full behavior in WU2)

16. **Tab completion for agent names**
    - Red: completer returns discovered agent names when completing `/agent info ` prefix; returns empty when no agents
    - Green: wire discovered agent names into `buildCompleter`
    - Tests: with/without agents

17. **`--agent` CLI flag integration (happy path)**
    - Red: `test/Integration/CLISpec.hs` — spawn `pureclaw` with `HOME=$tmp` and fixture agent `$tmp/.pureclaw/agents/zoe/`, verify startup log contains `Agent: zoe` and system prompt is used
    - Green: wire up in `runChat`

18. **`--agent` CLI flag error states**
    - Red: `--agent ../evil` → stderr contains "invalid agent name"; `--agent nonexistent` → stderr contains "Available agents:"
    - Green: validate via `mkAgentName`, list agents on miss

19. **`default_agent` config field**
    - Red: config with `default_agent = "zoe"`, no `--agent` flag, fixture agent present → agent is loaded
    - Red: `--agent` overrides `default_agent` in config
    - Green: wire config field through `FileConfig` → `runChat`

20. **Backward-compat: no-agent path**
    - Red: integration test with no agents dir, no `--agent`, no `default_agent`, with SOUL.md in cwd → existing `loadIdentity` path runs, system prompt contains identity; no SOUL.md → no system prompt
    - Red: integration test with `--system "custom"` and no agent → custom system prompt
    - Green: preserve existing code path (no change should be required if fall-through is correct)

21. **AgentEnv construction site updates**
    - Red: any test that constructs `AgentEnv` fails to compile (this happens as soon as fields are added)
    - Green: update `test/Agent/SlashCommandsSpec.hs` and `test/Agent/LoopSpec.hs` helpers to include `_env_agentDef = Nothing` and `_env_session = mkNoOpSessionHandle`
    - This step runs concurrently with step 17 because `-Werror` forces it

22. **pureclaw.cabal updates**
    - Add `PureClaw.Agent.AgentDef` and `PureClaw.Session.Handle` to `exposed-modules`
    - Add `Agent.AgentDefSpec` to test suite `other-modules`
    - Verify `cabal build` succeeds (no `-Wmissing-home-modules` warnings)

### Work Unit 1 Estimate
~20-22 commits (TDD red/green pairs), 1 PR

---

## Work Unit 2: Sessions

**Goal**: Conversations are organized into sessions with unique IDs, persistent metadata, and per-session transcript directories. Sessions are created implicitly on startup, resumable via `/session resume`, and listed via `/session list`.

### DoD

- [ ] `SessionId` newtype in `PureClaw.Core.Types` with custom `FromJSON` that validates format
- [ ] `SessionPrefix` smart constructor: same character restrictions as `AgentName` + rejects reserved word "new"; non-exported constructor; custom `FromJSON`
- [ ] `newSessionId :: Maybe SessionPrefix -> UTCTime -> SessionId` (pure, deterministic for fixed time)
- [ ] `SessionMeta` type with JSON round-trip
- [ ] `RuntimeType` with custom JSON encoding (`"provider"`, `"harness:claude-code"`)
- [ ] `defaultTarget :: RuntimeType -> MessageTarget`
- [ ] `SessionHandle` full implementation with `_sh_save`, `_sh_transcript`, `_sh_dir`, `_sh_meta`
- [ ] `mkSessionHandle` creates session dir with `0o700`, writes `session.json` with `0o600`, opens transcript
- [ ] `resumeSession` reads metadata, reopens transcript for append, validates runtime
- [ ] `mkNoOpSessionHandle` (promoted from WU1 skeleton to full implementation)
- [ ] Runtime validation on resume: if `RTHarness name` and harness not in `_env_harnesses`, log warning, set `_env_target` to `TargetProvider`, retain `RTHarness` in metadata
- [ ] Session resume recomposes system prompt from current agent files (picks up edits)
- [ ] Resume context reload: load last 50 messages or 100K estimated tokens (whichever is smaller) from transcript
- [ ] Bootstrap consumption callback: after first `StreamDone`, update `session.json` with `bootstrap_consumed: true`
- [ ] Bootstrap callback is injectable (testable in isolation without driving full agent loop)
- [ ] `--session <id>` CLI flag resumes by exact match
- [ ] `--prefix <prefix>` CLI flag for new sessions, validated via `mkSessionPrefix`
- [ ] `--session` and `--prefix` are mutually exclusive (post-parse validation in `runChat`)
- [ ] `/session list [<agent>]` shows up to 20 recent sessions, sorted by `last_active` desc
- [ ] `/session resume <id-or-prefix>` with `isPrefixOf`-over-full-ID matching; ambiguous matches list candidates
- [ ] `/session last` and `/last` resume most recent
- [ ] `/session new|reset|info|compact` all work
- [ ] `/new`, `/reset`, `/status`, `/compact` become aliases
- [ ] `/session info` shows session ID, agent, runtime, message count, token usage (subsumes `/status`)
- [ ] Tab completion for session IDs in `/session resume`
- [ ] `_env_transcript` deprecated; `envTranscript` accessor reads from `_env_session._sh_transcript`
- [ ] All existing `_env_transcript` call sites migrated to `envTranscript`
- [ ] Transcripts write to `~/.pureclaw/sessions/<id>/transcript.jsonl`
- [ ] `/transcript` slash command handler updated to read from current session transcript via `envTranscript`
- [ ] Default workspace `~/.pureclaw/agents/<name>/workspace/` is initialized via session setup
- [ ] `pureclaw.cabal` updated with new modules and test specs
- [ ] 100% test coverage
- [ ] `-Wall -Werror` clean, hlint clean, export lists explicit

### Files Affected

**New**:
- `src/PureClaw/Session/Types.hs` — `SessionPrefix`, `SessionMeta`, `RuntimeType`, `defaultTarget`
- `test/Session/TypesSpec.hs`
- `test/Session/HandleSpec.hs`

**Modified**:
- `pureclaw.cabal` — add `PureClaw.Session.Types` to `exposed-modules`; add `Session.TypesSpec`, `Session.HandleSpec` to test suite `other-modules`
- `src/PureClaw/Core/Types.hs` — add `SessionId` newtype (with custom `FromJSON`)
- `src/PureClaw/Session/Handle.hs` — promote `mkNoOpSessionHandle` skeleton to full implementation; add `mkSessionHandle`, `resumeSession`, listing, prefix matching
- `src/PureClaw/Agent/Env.hs` — deprecate `_env_transcript`, add `envTranscript` accessor reading from session
- `src/PureClaw/Agent/SlashCommands.hs` — add `/session list|new|resume|last|info|reset|compact`, register aliases for `/new`, `/reset`, `/status`, `/compact`, `/last`; update `/transcript` handler to use `envTranscript`; tab completion for session IDs
- `src/PureClaw/CLI/Commands.hs` — add `--session`, `--prefix` flags with mutual exclusion; update startup flow (create or resume session); replace `mkNoOpSessionHandle` with real handle in `AgentEnv` construction
- `src/PureClaw/CLI/Config.hs` — add `_fc_sessionPrefix` field
- `src/PureClaw/Agent/Loop.hs` — bootstrap consumed callback after first `StreamDone`; use `envTranscript` instead of `_env_transcript`
- Any other modules referencing `_env_transcript` — migrated to `envTranscript`
- `test/Integration/CLISpec.hs` — integration tests for `--session`, `--prefix`, transcript migration

### TDD Sequence

1. **SessionId in Core.Types**
   - Red: round-trip `parseSessionId` / `unSessionId`; JSON encode/decode
   - Red: `FromJSON` with corrupted `SessionId` value — define intended behavior (opaque string, so always succeeds)
   - Green: implement newtype + instances

2. **SessionPrefix smart constructor**
   - Red: `mkSessionPrefix "new"` → `Left PrefixReserved`; same character rejection tests as `AgentName`
   - Red: custom `FromJSON` prevents bypass
   - Green: implement with character validation + reserved word check

3. **newSessionId pure function**
   - Red: `newSessionId (Just zoe) fixedTime` produces exactly `SessionId "zoe-<mjd>-<picos>"` for a known time; `Nothing` prefix omits the prefix hyphen
   - Green: implement using `diffTimeToPicoseconds` + `toModifiedJulianDay`

4. **RuntimeType custom JSON**
   - Red: `encode RTProvider == "\"provider\""`; `encode (RTHarness "cc") == "\"harness:cc\""`; both round-trip; invalid string → parse failure
   - Green: custom `ToJSON`/`FromJSON`

5. **SessionMeta JSON round-trip**
   - Red: sample JSON decodes; encode matches canonical form; missing optional field handled
   - Green: implement instances

6. **defaultTarget**
   - Red: `defaultTarget RTProvider == TargetProvider`; `defaultTarget (RTHarness "x") == TargetHarness "x"`
   - Green: trivial implementation
   - Red: integration test — session created with `RTProvider` initializes `_env_target` to `TargetProvider` via `defaultTarget`

7. **mkSessionHandle — create path**
   - Red: `mkSessionHandle` in temp dir creates dir with mode `0o700` (verified via `getFileStatus`); `session.json` exists with mode `0o600`; transcript file exists with mode `0o600`
   - Green: implement using `createDirectory`, `setFileMode`, `mkFileTranscriptHandle`

8. **mkSessionHandle — metadata persistence**
   - Red: after `_sh_save`, reading `session.json` from disk yields the same `SessionMeta`; `last_active` updates on subsequent saves
   - Green: implement IORef + save action

9. **resumeSession**
   - Red: create session, write transcript entries, close, resume — metadata matches, transcript appendable
   - Red: resume missing `session.json` → `Left MissingMetadata`
   - Red: resume corrupted `session.json` → `Left (CorruptedMetadata path err)` with recovery hint
   - Green: implement resume path

10. **mkNoOpSessionHandle (full)**
    - Red: no-op save is safe; transcript is `mkNoOpTranscriptHandle`; meta is a static default
    - Green: promote WU1 skeleton to full implementation

11. **Runtime validation on resume**
    - Red: resume session with `RTHarness "dead"` where `_env_harnesses` is empty → `_env_target` ends up as `TargetProvider`, warning logged; `session.json` still has `"runtime": "harness:dead"`
    - Red: resume with `RTHarness "cc"` where cc IS in `_env_harnesses` → `_env_target` is `TargetHarness "cc"`
    - Green: implement validation in resume path

12. **Session listing and prefix matching**
    - Red: sessions `zoe-60759-111`, `zoe-60759-222`, `ops-60759-333` on disk
    - Red: `listSessions Nothing 20` returns all 3 sorted by `last_active` desc
    - Red: `listSessions (Just "zoe") 20` returns only zoe sessions
    - Red: `resolveSessionRef "zoe-60759-222"` → exact match returned
    - Red: `resolveSessionRef "zoe-607"` → ambiguous (both match by `isPrefixOf`); returns `Left [zoe-60759-111, zoe-60759-222]`
    - Red: `resolveSessionRef "ops"` → unambiguous match
    - Red: `resolveSessionRef "nothing"` → `Left []` (not found)
    - Red: default list count is 20 (create 25 sessions, assert 20 returned)
    - Green: implement

13. **Bootstrap consumption callback**
    - Red: test callback directly — `markBootstrapConsumed session` updates `session.json`'s `bootstrap_consumed` field to `true`; idempotent on re-call
    - Red: unit test that `runAgentLoop` invokes the callback exactly once on first `StreamDone` (use injectable `OnFirstStreamDone :: IO ()` callback in `AgentEnv`, or a mock provider that stubs the stream)
    - Green: implement callback and inject
    - Red: resume test — session with `bootstrap_consumed: true` preserves the flag after resume + save

14. **Slash command aliases**
    - Red: parser tests — `/new` parses to same `SlashCommand` as `/session new`; same for `/reset`→`/session reset`, `/status`→`/session info`, `/compact`→`/session compact`, `/last`→`/session last`
    - Green: add aliases to `allCommandSpecs`

15. **`/session new`**
    - Red: handler test — creates new session, resets context, returns confirmation
    - Green: implement

16. **`/session list`**
    - Red: handler test with fixture sessions dir; `/session list zoe` filters
    - Green: implement using `listSessions`

17. **`/session resume`**
    - Red: unambiguous prefix resumes; ambiguous prefix lists candidates; missing → error
    - Green: implement using `resolveSessionRef` + `resumeSession`

18. **`/session last` and `/last`**
    - Red: handler test resumes most recent by `last_active`
    - Green: implement

19. **`/session info`**
    - Red: handler test — output contains session ID, agent name, runtime string, message count from context, token usage from context
    - Green: implement
    - Verifies `/status` subsumption is behaviorally complete

20. **`/session reset` and `/session compact`**
    - Red: handler tests assert same behavior as existing `/reset` and `/compact`
    - Green: route through existing logic or extract shared handler

21. **Tab completion for session IDs**
    - Red: completer returns session IDs from sessions dir when completing `/session resume ` prefix; sorted by `last_active` desc
    - Green: extend `buildCompleter` to enumerate sessions

22. **`_env_transcript` deprecation migration**
    - Red: every call site of `_env_transcript` in `src/` has been replaced with `envTranscript`; `-Wall -Werror` passes; test helpers updated
    - Green: grep + replace; run build

23. **`/transcript` slash command update**
    - Red: integration test — `/transcript` reads from the current session's transcript file, not old flat dir
    - Green: update handler to use `envTranscript`

24. **`--session` CLI flag**
    - Red: integration test — create session, restart pureclaw with `--session <id>`, verify session is resumed (metadata matches, transcript reopened)
    - Red: `--session nonexistent` → clear error
    - Green: wire up in `runChat`

25. **`--prefix` CLI flag**
    - Red: integration test — `pureclaw tui --prefix myrun` creates session dir matching `myrun-*` under `$tmp/.pureclaw/sessions/`
    - Red: `--prefix "../evil"` rejected
    - Red: `--prefix` defaults to agent name when `--agent` is set
    - Green: wire up via `mkSessionPrefix`

26. **`--session` and `--prefix` mutual exclusion**
    - Red: passing both flags → post-parse validation error
    - Green: add validation in `runChat` (optparse `<|>` is insufficient — explicit check needed)

27. **Resume context reload budget**
    - Red: session with 100 transcript messages on disk → resume loads only last 50 messages into context
    - Red: session with 10 messages totaling >100K tokens → resume loads only messages fitting in 100K budget
    - Red: session with <50 messages → all loaded
    - Green: implement reload logic with budget

28. **Transcript migration end-to-end**
    - Red: integration test — new `pureclaw tui` creates `~/.pureclaw/sessions/<id>/transcript.jsonl`, NOT `~/.pureclaw/transcripts/*.jsonl`
    - Red: old transcripts (if any) in the old dir are untouched
    - Green: update `startWithChannel` to use `_sh_transcript` from real session handle

29. **AgentEnv construction migration**
    - Red: `startWithChannel` constructs real `SessionHandle` (no longer `mkNoOpSessionHandle`); test helpers still use `mkNoOpSessionHandle`; compiles clean
    - Green: update production construction site

30. **pureclaw.cabal updates**
    - Add `PureClaw.Session.Types` to `exposed-modules`
    - Add `Session.TypesSpec`, `Session.HandleSpec` to test suite `other-modules`
    - Verify build clean

### Work Unit 2 Estimate
~28-32 commits, 1 PR (can split into 2 if review load is high: types/handle vs CLI integration)

---

## Execution Order

1. **WU1: Agents** — branch `sessions-and-agents`, TDD red/green pairs, PR when DoD complete
2. **Review + merge WU1**
3. **WU2: Sessions** — continue on same branch, same TDD discipline
4. **Review + merge WU2**

## Pre-PR Checklist (both WUs)

- [ ] All tests pass: `nix develop . --command cabal test`
- [ ] Coverage meets thresholds: `nix develop . --command cabal test --enable-coverage` satisfies `.coverage-thresholds.json`
- [ ] `-Wall -Werror` clean: `nix develop . --command cabal build`
- [ ] hlint clean: `nix develop . --command hlint src test`
- [ ] `pureclaw.cabal` modules registered (no `-Wmissing-home-modules` warnings)
- [ ] `/self-reflect` run to capture learnings before PR creation
- [ ] Knowledge base updates committed atomically with code

## Rollback Strategy

Each WU is a self-contained PR. If WU2 has issues post-merge, WU1 remains valuable (agents without sessions still improve over the current single-SOUL.md model). If WU1 has issues, revert and re-plan.

## Risks

| Risk | Mitigation |
|---|---|
| TOML frontmatter parsing edge cases | Explicit fence extraction step; `tomland` handles TOML body; thorough parser tests |
| `AgentEnv` construction site churn | Both fields added in WU1 (with `mkNoOpSessionHandle` for `_env_session`); construction sites enumerated upfront |
| `/transcript` handler breakage during transcript migration | Explicit TDD step (WU2 step 23) covers this |
| Session resume context reload hits token limit | 100K token budget enforced with oldest-first truncation |
| Backward compat with existing `loadIdentity` | Explicit no-agent test (WU1 step 20) |
| Smart constructor bypass via corrupted JSON | Custom `FromJSON` for `AgentName`, `SessionPrefix`, `SessionId` that calls smart constructor |
| Bootstrap callback hard to test in agent loop | Injectable callback as `IO ()` action + direct unit test of `markBootstrapConsumed` |
| Denylist branch coverage | Exhaustive test table hitting every denylist entry |
| symlink TOCTOU in workspace validation | `canonicalizePath` before denylist check (documented limitation; not a full fix but matches v1 security model) |
