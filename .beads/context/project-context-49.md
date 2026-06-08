# Project Context (Sessions and Agents Execution)

## Tooling
- **Build system**: Nix flake + Cabal — ALL commands prefixed with `nix develop . --command`
- **Compiler**: GHC 9.12.1, GHC2021, `-Wall -Werror`, `-Wmissing-export-lists`, `-Wincomplete-record-updates`
- **Test framework**: Hspec (via `cabal test`)
- **Coverage**: 100% lines/branches/functions/statements required (`.coverage-thresholds.json`)
- **Coverage command**: `nix develop . --command cabal test --enable-coverage`
- **Build command**: `nix develop . --command cabal build`
- **Test command**: `nix develop . --command cabal test`
- **Lint**: hlint (should be clean)

## Project Structure
- `src/PureClaw/` — library modules
- `test/` — Hspec specs; `test/Integration/CLISpec.hs` spawns the real binary
- `pureclaw.cabal` — cabal file, must have new modules in `exposed-modules` and test specs in test suite `other-modules`

## Key Conventions
- **Handle pattern**: Every capability is a record of IO actions. No global state.
- **Smart constructors**: `SafePath`, `AuthorizedCommand`, `ApiKey` use non-exported constructors. `AgentName`, `SessionPrefix`, `SessionId` follow the same pattern.
- **Import style**: `qualified as` throughout; no explicit import lists except canonical cases (`import Data.Set (Set)`).
- **Mutable state**: Prefer `IORef`. `TVar`/`MVar` only when concurrency requires.
- **Explicit export lists**: All new modules MUST have explicit export lists.

## Active AgentEnv Construction Sites
1. `src/PureClaw/CLI/Commands.hs:startWithChannel` — production
2. `test/Agent/SlashCommandsSpec.hs` — test helper
3. `test/Agent/LoopSpec.hs` — test helper

Any change to `AgentEnv` record fields must touch all three sites atomically (enforced by `-Werror`).

## Completed Work Units / Sessions
| Session | Title | Status | Key Files |
|---------|-------|--------|-----------|
| WU1-A | AgentName + TOML frontmatter parser | COMMITTED | AgentDef.hs (119 LOC), AgentDefSpec.hs (90 LOC), pureclaw.cabal, test/Main.hs |
| WU1-B | Prompt composition + agent discovery | COMMITTED | AgentDef.hs (+170 LOC), AgentDefSpec.hs (+200 LOC), test/fixtures/agents/{zoe,empty,needs-truncation}/ |
| WU1-C | Workspace validation + default workspace + override priority | COMMITTED | AgentDef.hs (+113 LOC), AgentDefSpec.hs (+154 LOC) |
| WU1-D | /agent slash commands + tab completion helper | COMMITTED | SlashCommands.hs (+197 LOC), SlashCommandsSpec.hs (+216 LOC) |
| WU1-E | AgentEnv wiring + --agent flag + integration + cabal | COMMITTED | Env.hs (+9), CLI/Commands.hs (+64), CLI/Config.hs (+5), Session/Handle.hs (new 32 LOC stub), Completion.hs (+12), CLISpec.hs (+85), test helpers updated, pureclaw.cabal (+2) |
| **WU1 Total** | **Agents — feature complete** | **APPROVED + MERGED (PR #33)** | **1081 tests passing, 0 failures, 2 pending. Coverage: AgentDef 86%, Env 80%, Config 82%, Session.Handle 14% (stub).** |
| WU2-A | SessionId + SessionPrefix + RuntimeType + SessionMeta (pure types) | COMMITTED | Core/Types.hs (+SessionId), Session/Types.hs (NEW ~170 LOC), TypesSpec.hs (NEW ~160 LOC), 33 new tests, 1114 total |
| WU2-B | SessionHandle full implementation + cycle break refactor | COMMITTED | MessageTarget moved to Core.Types (re-exported from Agent.Env for compat), Session/Handle.hs (full rewrite ~330 LOC), HandleSpec.hs (NEW 19 examples), 1133 total |
| WU2-C | /session slash commands + aliases + tab completion | COMMITTED | SlashCommands.hs (+SessionSubCommand ADT, executeSessionCommand, /last alias), Completion.hs (+session resume completion), SlashCommandsSpec.hs (+32 tests), 1165 total |
| WU2-D | AgentEnv migration + envTranscript + /transcript + atomic field changes | COMMITTED | _env_session is now IORef SessionHandle, envTranscript accessor, _env_transcript removed, all 4 construction sites updated, /session new and /session resume actually swap, production transcripts at sessions/<id>/transcript.jsonl, 1169 total. **1 retry** (initial review FAILed for missing swap meaningfulness tests; fix-up added 4 IORef-state-verification tests + integration test for production path; re-review PASSed.) |
| WU2-E | CLI flags + bootstrap callback + reload budget + runtime validation + cabal | COMMITTED | markBootstrapConsumed, loadRecentMessages, _env_onFirstStreamDone one-shot callback, --session/--prefix flags + mutual exclusion, _fc_sessionPrefix, resolveResumedTarget, runAgentLoopWith threads reloaded messages into Context. 1190 total. **1 retry** (initial review FAILed: Blocker 1 reloaded messages discarded via `_reloadedMessages`, Blocker 2 validateRuntime dead code; fix-up added runAgentLoopWith + resolveResumedTarget + 5 meaningful tests; re-review PASSed.) |
| **WU2 Total** | **Sessions — feature complete** | **APPROVED (final WU2 review PASS)** | **1190 tests passing, 0 failures, 2 pending. +109 tests over WU1's 1081 baseline. 17 files changed, +2486/-223 lines.** |

## Session D (WU2) State Changes
- `AgentEnv._env_session :: IORef SessionHandle` (was `SessionHandle`)
- `AgentEnv._env_transcript` REMOVED — use `envTranscript :: AgentEnv -> IO TranscriptHandle` accessor (reads `_sh_transcript` from current session)
- Production startup: `startWithChannel` constructs a real `SessionHandle` via `mkSessionHandle logger sessionsDir initialMeta`, where `sessionsDir = ~/.pureclaw/sessions` and `initialMeta` is built from current model/agent/channel
- Production transcripts now write to `~/.pureclaw/sessions/<sessionId>/transcript.jsonl` — old `~/.pureclaw/transcripts/` path is no longer used
- `/session new` and `/session resume` and `/session last` actually swap the active session via `writeIORef (_env_session env) newHandle`
- Test helpers in `SlashCommandsSpec.hs`, `LoopSpec.hs`, `SignalFlowSpec.hs` use `newIORef =<< mkNoOpSessionHandle`
- Test helpers that need to inject a custom transcript do `SessionHandle { _sh_transcript = th, ... }` and wrap in IORef

## Session C (WU2) Notes (for downstream sessions)
- `SessionSubCommand(..)` added with `SessionNew | SessionList (Maybe Text) | SessionResume Text | SessionLast | SessionInfo | SessionReset | SessionCompact`
- `CmdSession SessionSubCommand` is the top-level wrapper
- Legacy `/new`, `/reset`, `/status`, `/compact` STILL parse to `CmdNew | CmdReset | CmdStatus | CmdCompact` (NOT routed through `CmdSession`) — preserved to keep existing tests passing without `withTempHome` changes
- `/last` parses directly to `CmdSession SessionLast`
- **Session D MUST**: convert `_env_session` to `IORef SessionHandle` (or similar) so `/session new` and `/session resume` can actually swap the active session. Currently they create/validate but discard. Update `/session info` to still read from the IORef.
- `/session reset` and `/session compact` delegate to existing `CmdReset`/`CmdCompact` handlers via `executeSlashCommand env CmdReset ctx` — no shared logic extraction needed.
- Pure helper `sessionIdMatches :: [Text] -> Text -> [Text]` exported from `SlashCommands.hs` for tab completion
- Tab completion in `Completion.hs` detects `/session resume ` prefix and calls `Session.listSessions` + `sessionIdMatches`

## Session A (WU2) Exports
From `PureClaw.Core.Types`: `SessionId(..)`, `unSessionId`, `parseSessionId`, `ToJSON/FromJSON SessionId`
From `PureClaw.Session.Types`:
- `SessionPrefix` (type only, constructor non-exported)
- `unSessionPrefix`, `mkSessionPrefix :: Text -> Either SessionPrefixError SessionPrefix`
- `SessionPrefixError(..)` — `PrefixEmpty | PrefixTooLong | PrefixInvalidChars Text | PrefixLeadingDot | PrefixReserved Text`
- `RuntimeType(..)` — `RTProvider | RTHarness Text` with custom JSON `"provider"` / `"harness:<name>"`
- `SessionMeta(..)` — `_sm_id`, `_sm_agent :: Maybe AgentName`, `_sm_runtime`, `_sm_model`, `_sm_channel`, `_sm_createdAt`, `_sm_lastActive`, `_sm_bootstrapConsumed`
- `newSessionId :: Maybe SessionPrefix -> UTCTime -> SessionId` (PURE)
- `defaultTarget :: RuntimeType -> MessageTarget` (lives here today; **Session B may need to relocate** to break a cycle when SessionHandle uses SessionMeta)

**Session B WARNING**: ~~Session.Types currently imports Agent.Env for MessageTarget.~~ **RESOLVED** by Session B: `MessageTarget` relocated to `PureClaw.Core.Types`, re-exported from `PureClaw.Agent.Env` for backward compat. `defaultTarget` stays in `Session.Types`.

## Session B (WU2) Exports
From `PureClaw.Session.Handle` (full rewrite — replaces WU1 stub):
- `SessionHandle(..)` — `_sh_meta :: IORef SessionMeta`, `_sh_transcript :: TranscriptHandle`, `_sh_dir :: FilePath`, `_sh_save :: IO ()`
- `mkSessionHandle :: LogHandle -> FilePath -> SessionMeta -> IO SessionHandle` — creates dir 0o700, session.json 0o600, transcript.jsonl 0o600
- `mkNoOpSessionHandle :: IO SessionHandle`
- `noOpSessionHandle :: SessionHandle` (pure top-level CAF — uses `unsafePerformIO` + NOINLINE for shared sentinel meta IORef; safe because tests only read)
- `resumeSession :: LogHandle -> FilePath -> SessionId -> IO (Either ResumeError SessionHandle)` — reopens transcript for append
- `ResumeError(..)` — `ResumeMissingMetadata FilePath | ResumeCorruptedMetadata FilePath String`
- `listSessions :: FilePath -> Maybe AgentName -> Int -> IO [SessionMeta]` — sorted by lastActive desc, capped at limit, silently skips corrupted entries
- `resolveSessionRef :: FilePath -> Text -> IO (Either ResolveError SessionId)` — exact > unique prefix > Ambiguous/NotFound
- `ResolveError(..)` — `NotFound | Ambiguous [SessionId]`
- `validateRuntime :: Map Text HarnessHandle -> RuntimeType -> ResolvedRuntime` (PURE)
- `ResolvedRuntime(..)` — `RuntimeOk MessageTarget | RuntimeFallback MessageTarget Text`

`MessageTarget` now lives in `PureClaw.Core.Types` (re-exported from `PureClaw.Agent.Env`)

Atomic save: `_sh_save` writes `session.json.tmp` → `setFileMode 0o600` → `renameFile`. Crash-safe on POSIX.

## Session A Exports (available to downstream sessions)
From `PureClaw.Agent.AgentDef`:
- `AgentName` (type only, constructor not exported)
- `unAgentName :: AgentName -> Text`
- `mkAgentName :: Text -> Either AgentNameError AgentName`
- `AgentNameError(..)` — `AgentNameEmpty | AgentNameTooLong | AgentNameInvalidChars Text | AgentNameLeadingDot`
- `FromJSON AgentName` (routes through `mkAgentName`)
- `extractFrontmatter :: Text -> (Maybe Text, Text)`
- `AgentConfig(..)` with `_ac_model`, `_ac_toolProfile`, `_ac_workspace :: Maybe Text`
- `defaultAgentConfig :: AgentConfig`
- `parseAgentsMd :: Text -> Either AgentsMdParseError (AgentConfig, Text)`
- `AgentsMdParseError(..)` — newtype around `AgentsMdTomlError Text` (may widen to data in later sessions)

## Session B Exports (available to downstream sessions)
Added to `PureClaw.Agent.AgentDef`:
- `AgentDef(..)` — record `{ _ad_name :: AgentName, _ad_dir :: FilePath, _ad_config :: AgentConfig }`
- `composeAgentPrompt :: LogHandle -> AgentDef -> Int -> IO Text` (Int = truncation limit in chars)
- `composeAgentPromptWithBootstrap :: LogHandle -> AgentDef -> Int -> Bool -> IO Text` (Bool = bootstrap consumed)
- `discoverAgents :: LogHandle -> FilePath -> IO [AgentDef]`
- `loadAgent :: FilePath -> AgentName -> IO (Maybe AgentDef)`

Injection order (top-to-bottom): SOUL, USER, AGENTS, MEMORY, IDENTITY, TOOLS, BOOTSTRAP
Section marker format: `--- NAME ---` exactly
Truncation marker: `\n[...truncated at <N> chars...]` where N is the configured limit
File size limit: >1MB rejected with log warning
AGENTS.md body-only injection: frontmatter stripped, only body appears in `--- AGENTS ---` section

## Session D Exports (available to downstream sessions)
Added to `PureClaw.Agent.SlashCommands`:
- `AgentSubCommand(..)` — `AgentList | AgentInfo (Maybe Text) | AgentStart Text | AgentUnknown Text`
- `agentNameMatches :: [Text] -> Text -> [Text]` — pure case-insensitive prefix filter for tab completion
- `/agent list|info|start` registered in `allCommandSpecs` under a new `GroupAgent` category
- Handlers read from disk via `getPureclawDir </> "agents"` (honors `$HOME`)
- `/agent start <name>` returns a placeholder message (full session-aware behavior in WU2)
- Tab completion wiring into `buildCompleter` DEFERRED to Session E (the helper `agentNameMatches` is the pure core)

## Session C Exports (available to downstream sessions)
Added to `PureClaw.Agent.AgentDef`:
- `WorkspaceError(..)` — `WorkspaceNotAbsolute Text | WorkspaceDoesNotExist FilePath | WorkspaceDenied FilePath Text`
- `validateWorkspace :: FilePath -> Text -> IO (Either WorkspaceError FilePath)` — args: homeDir, rawInputPath
- `ensureDefaultWorkspace :: FilePath -> AgentName -> IO FilePath` — creates `<pureclawDir>/agents/<name>/workspace/` with 0o700, idempotent
- `resolveOverride :: Maybe a -> Maybe a -> Maybe a -> Maybe a -> Maybe a` — precedence resolver (CLI > frontmatter > config > default)

Denylist (absolute): `/`, `/etc`, `/usr`, `/bin`, `/sbin`, `/var`, `/sys`, `/proc`, `/dev`
Denylist (home-relative): `.ssh`, `.gnupg`, `.aws`, `.config`, `.pureclaw`
Denylist entries are canonicalized before comparison (macOS `/etc` → `/private/etc`).
`isUnderPath "/"` special-cased to match only the literal root.

## Established Patterns
- Handle pattern for capabilities (see `src/PureClaw/Handles/*.hs`)
- Smart constructors with non-exported data constructors (see `src/PureClaw/Security/Path.hs`)
- `AgentEnv` as the central DI record passed to `runAgentLoop`
- JSONL transcript format via POSIX fd writes (see `src/PureClaw/Handles/Transcript.hs`)
- TOML config parsing via `tomland` (see `src/PureClaw/CLI/Config.hs`)

## Security Invariants
- No file path traversal: smart constructors reject `..`, `/`, null bytes
- File permissions: `0o700` for dirs, `0o600` for sensitive files
- No secrets in logs or transcripts (headers redacted via `redactHeaders`)
- `SafePath` containment for all file tool operations
