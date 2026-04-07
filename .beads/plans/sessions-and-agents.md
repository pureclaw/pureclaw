# Sessions and Agents

**Status**: draft (revision 3 — chroot extracted to follow-up epic)
**Branch**: sessions-and-agents
**Priority**: P1

## Overview

Introduce two core concepts to PureClaw:

1. **Agents** — named collections of `.md` bootstrap files (`AGENTS.md`, `SOUL.md`, `USER.md`, `MEMORY.md`, etc.) stored in `~/.pureclaw/agents/<agent-name>/`. On session start, their contents are injected into the system prompt context.

2. **Sessions** — the unit of conversation. A session binds together a runtime (harness or provider), an optional agent, a unique ID, and a transcript. Sessions are created, used, and eventually stop being used — they are never deleted.

### Work Unit Decomposition

This feature splits into two sequential work units with a clean seam:

- **Work Unit 1: Agents** — `AgentName` type, discovery, loading, prompt composition, `--agent` CLI flag, `/agent` slash commands. No dependency on sessions. Can be shipped independently.
- **Work Unit 2: Sessions** — `SessionId` type, `SessionHandle`, session metadata persistence, `/session` slash commands, transcript migration, session resume. Builds on agents.

---

## Security: Input Validation

All user-controlled text that enters file path construction is validated through smart constructors with non-exported constructors, consistent with PureClaw's security-by-construction philosophy (`SafePath`, `AuthorizedCommand`, `ApiKey`).

### AgentName

```haskell
newtype AgentName = AgentName { unAgentName :: Text }
  deriving newtype (Show, Eq, Ord, ToJSON, FromJSON)

data AgentNameError = AgentNameEmpty | AgentNameInvalidChars Text
  deriving stock (Show, Eq)

-- | Smart constructor. Accepts only [a-zA-Z0-9_-], non-empty, max 64 chars.
-- Rejects: /, \, .., null bytes, leading dots, spaces.
mkAgentName :: Text -> Either AgentNameError AgentName
```

### SessionPrefix

```haskell
newtype SessionPrefix = SessionPrefix { unSessionPrefix :: Text }
  deriving newtype (Show, Eq, Ord, ToJSON, FromJSON)

data SessionPrefixError = PrefixEmpty | PrefixInvalidChars Text | PrefixReserved Text
  deriving stock (Show, Eq)

-- | Smart constructor. Same character restrictions as AgentName.
-- Additionally rejects the reserved word "new" (used as --session keyword).
mkSessionPrefix :: Text -> Either SessionPrefixError SessionPrefix
```

Both types reject path separators (`/`, `\`), parent traversal (`..`), null bytes, leading dots, and restrict to `[a-zA-Z0-9_-]`. This prevents path traversal when these values are used as directory names.

### File Permissions

All session directories and files are created with restrictive permissions, matching the existing `TranscriptHandle` security posture:

- Session directories: `0o700` (owner read/write/execute only)
- `session.json`: `0o600` (owner read/write only)
- `transcript.jsonl`: `0o600` (owner read/write only — already enforced by `mkFileTranscriptHandle`)

### Agent File Size Limit

Agent bootstrap files are subject to two limits:
- **Read limit**: Refuse to read files larger than 1MB at the IO level (prevents excessive memory allocation)
- **Truncation limit**: Configurable (default 8000 chars), applied after reading

---

## Agent Design

### Discovery

Agents are discovered by enumerating subdirectories of `~/.pureclaw/agents/`. Each subdirectory name is the agent's name (e.g., `zoe`, `haskell`, `ops`). No registration step — presence on disk is sufficient.

Directory names are validated through `mkAgentName` on discovery — directories with invalid names (containing path separators, dots, etc.) are skipped with a log warning.

### Bootstrap Files

Each agent directory may contain these files (all optional):

| File | Purpose | Injection Order |
|---|---|---|
| `SOUL.md` | Persona, boundaries, communication tone | 1st |
| `USER.md` | User profile and preferred address/contact info | 2nd |
| `AGENTS.md` | Operating instructions, session rituals, core rules | 3rd |
| `MEMORY.md` | Agent-specific persistent memory | 4th |
| `IDENTITY.md` | Agent name, vibe, emoji identifier | 5th |
| `TOOLS.md` | Tool usage conventions | 6th |
| `BOOTSTRAP.md` | One-time initialization (see Bootstrap Lifecycle below) | 7th (if present) |

### Injection Mechanism

On the first turn of a new session with an agent:

1. Read each file in injection order
2. **Skip** files that are missing or empty (zero bytes or whitespace-only)
3. **Reject** files larger than 1MB (log warning, skip)
4. **Truncate** files exceeding the configurable limit (default: 8000 chars) with a marker: `\n[...truncated at 8000 chars...]`
5. Compose into a single system prompt by concatenating with section markers:

```
--- SOUL ---
<contents of SOUL.md>

--- USER ---
<contents of USER.md>

--- AGENTS ---
<contents of AGENTS.md>

...
```

On **session resume**, agent bootstrap files are re-read from disk (not cached). This ensures edits to SOUL.md, AGENTS.md, etc. between sessions take effect immediately.

### Bootstrap Lifecycle (BOOTSTRAP.md)

`BOOTSTRAP.md` is a one-time initialization file. Rather than deleting it from the shared agent directory (which would race if two sessions start simultaneously), bootstrap consumption is tracked per-session:

1. On session creation, if `BOOTSTRAP.md` exists and is non-empty, inject it into the system prompt
2. After the first successful `StreamDone` response in the agent loop, record `"bootstrap_consumed": true` in `session.json`
3. On subsequent turns in the same session, and on resume of a session where `bootstrap_consumed` is true, `BOOTSTRAP.md` is NOT re-injected
4. The file itself is **never deleted or mutated** — the agent directory remains read-only from PureClaw's perspective

This avoids the race condition of two sessions sharing an agent, avoids data loss, and makes the behavior recoverable (delete the session to "re-bootstrap").

### AGENTS.md Frontmatter

`AGENTS.md` may contain **TOML** frontmatter (not YAML — the project already depends on `tomland`, avoiding a new dependency) with agent-level configuration overrides. PureClaw never modifies agent files — frontmatter is read-only from PureClaw's perspective.

```toml
---
model = "anthropic/claude-sonnet-4-6"
tool_profile = "coding"
workspace = "~/Projects"
---
```

These override the global config for sessions using this agent. The frontmatter is parsed but NOT included in the system prompt injection — only the body (after the closing `---`) is injected.

**Override priority**: CLI flag > agent frontmatter > config file > default.

#### Agent Workspace

Each agent has an associated **workspace directory** where its file tools operate. By default, this is `~/.pureclaw/agents/<agent-name>/workspace/` (created on first use with `0o700` permissions). The frontmatter `workspace` field overrides this default; custom workspaces must already exist (not created implicitly).

**Security model (v1)**: Workspace containment is enforced by `SafePath` — the existing security primitive that validates all file tool paths against the workspace root. There is no kernel-level sandbox in v1.

A separate follow-up epic, **Agent Sandboxing**, will design and implement OS-level isolation (likely `sandbox-exec` on macOS and Landlock + user namespaces on Linux). Classic `chroot` was considered and rejected because it requires root (unavailable on the primary dev platform), has known escape vectors, and conflicts with the Nix-built binary's runtime dependencies. Sandboxing is intentionally out of scope for this work to keep the Sessions+Agents change shippable.

#### Workspace Validation

The `workspace` field is security-sensitive — it determines where file tools operate. Since agent files may be imported from OpenClaw or shared between machines, the value cannot be trusted blindly. PureClaw validates the workspace at session start:

1. **Tilde expansion**: `~` is expanded to `$HOME`
2. **Absolute path required**: Relative paths are rejected with an error
3. **Must exist**: The directory must exist (no implicit creation)
4. **Canonicalization**: Symlinks are resolved via `canonicalizePath` to detect escape attempts
5. **Denylist check**: The canonicalized path must not be:
   - `/`, `/etc`, `/usr`, `/bin`, `/sbin`, `/var`, `/sys`, `/proc`, `/dev`
   - `$HOME/.ssh`, `$HOME/.gnupg`, `$HOME/.aws`, `$HOME/.config`
   - `$HOME/.pureclaw` or any subdirectory thereof (prevents agents from writing to their own definition)
6. **Visibility**: The effective workspace is logged at session start: `Workspace: /Users/zoe/Projects (from agent "zoe" frontmatter)`

If validation fails, the session refuses to start with a clear error message:

```
Error: agent "evil" specifies workspace "/etc" which is in the denylist.
Edit ~/.pureclaw/agents/evil/AGENTS.md to fix the workspace field.
```

This validation runs once at session start, before any tool calls. It is a check, not a sandbox — file tools still enforce `SafePath` containment relative to the validated workspace at every operation.

### AgentDef Type

```haskell
data AgentDef = AgentDef
  { _ad_name        :: AgentName       -- ^ Validated agent name
  , _ad_config      :: AgentConfig     -- ^ Parsed frontmatter overrides
  }

adDir :: AgentDef -> FilePath
adDir ad = dotPureClawPath </> "agents" </> _ad_name ad

-- | Agent-level configuration overrides from AGENTS.md frontmatter.
-- Extensible record — new frontmatter fields can be added here without
-- changing AgentDef.
data AgentConfig = AgentConfig
  { _ac_model       :: Maybe Text     -- ^ Model override
  , _ac_toolProfile :: Maybe Text     -- ^ Tool profile override
  , _ac_workspace   :: Maybe Text     -- ^ Workspace override (validated at session start)
  }
  deriving stock (Show, Eq)

-- | Empty config (no overrides).
defaultAgentConfig :: AgentConfig
defaultAgentConfig = AgentConfig Nothing Nothing Nothing
```

Agent definitions are loaded eagerly at startup (they're small — just metadata from frontmatter). The actual `.md` file contents are read lazily when a session starts.

### Loading Functions

```haskell
-- | Discover all agents in the agents directory.
-- Skips directories with invalid names (logs warning).
discoverAgents :: LogHandle -> FilePath -> IO [AgentDef]

-- | Load a specific agent by name. Returns Nothing if not found.
loadAgent :: FilePath -> AgentName -> IO (Maybe AgentDef)

-- | Compose the system prompt from an agent's bootstrap files.
-- Reads files, skips empty/missing ones, enforces size limits, concatenates
-- with section markers. The Int parameter is the truncation limit.
composeAgentPrompt :: AgentDef -> Int -> IO Text

-- | Like composeAgentPrompt but also checks bootstrap status.
-- If bootstrapConsumed is True, BOOTSTRAP.md is skipped.
composeAgentPromptWithBootstrap :: AgentDef -> Int -> Bool -> IO Text
```

### Compatibility with Existing Identity System

The current `loadIdentity` / `AgentIdentity` / `identitySystemPrompt` system parses `SOUL.md` into structured fields (`Name`, `Description`, `Instructions`, `Constraints`). The new agent system replaces this:

- When an agent is selected: `composeAgentPrompt` produces the system prompt (SOUL.md is injected as raw text, not parsed into AgentIdentity fields)
- When no agent is selected: existing behavior is preserved (SOUL.md parsed via `loadIdentity`, or `--system` flag, or nothing)
- `AgentIdentity` is not removed — it remains for the no-agent path

### Error States

| Scenario | Error Message |
|---|---|
| `--agent nonexistent` | `Error: agent "nonexistent" not found. Available agents: zoe, haskell, ops` |
| `--agent ../evil` | `Error: invalid agent name "../evil" — names may only contain [a-zA-Z0-9_-]` |
| Agent dir exists but no .md files | Valid — agent is loaded with empty system prompt (log info) |
| `~/.pureclaw/agents/` doesn't exist | No agents discovered (log info). `/agent list` shows: `No agents found. Create one at ~/.pureclaw/agents/<name>/` |
| AGENTS.md frontmatter parse error | Log warning, use `defaultAgentConfig`, continue with body injection |

---

## Session Design

### Session ID Format

```
[<prefix>-]<modified-julian-day>-<picoseconds>
```

Examples:
- `60759-48372000000000` (no prefix — auto-generated)
- `code-review-60759-48372000000000` (user-provided prefix)
- `zoe-60759-48372000000000` (agent name as prefix)

The timestamp portion uses the same format as existing transcript IDs (`generateId`), ensuring backward compatibility. The prefix is optional and user-specified at session creation time.

If no prefix is provided and an agent is selected, the agent name is used as the default prefix.

### SessionId Type

`SessionId` lives in `PureClaw.Core.Types` alongside other core ID newtypes (`ModelId`, `ToolCallId`) to avoid circular imports.

```haskell
newtype SessionId = SessionId { unSessionId :: Text }
  deriving newtype (Show, Eq, Ord, ToJSON, FromJSON)

-- | Generate a new session ID with an optional prefix. Pure function —
-- takes UTCTime as parameter for testability.
newSessionId :: Maybe SessionPrefix -> UTCTime -> SessionId

-- | Parse a session ID from text. Always succeeds (opaque string).
parseSessionId :: Text -> SessionId
```

### Session Metadata

Each session is persisted as a small JSON metadata file:

```json
{
  "id": "zoe-60759-48372000000000",
  "agent": "zoe",
  "runtime": "provider",
  "model": "claude-sonnet-4-20250514",
  "channel": "cli",
  "created_at": "2026-04-06T12:00:00Z",
  "last_active": "2026-04-06T14:30:00Z",
  "bootstrap_consumed": false
}
```

Note: `transcript_path` is not stored — it is derived from the session directory (`<session-dir>/transcript.jsonl`).

### Storage Layout

```
~/.pureclaw/sessions/
├── zoe-60759-48372000000000/
│   ├── session.json          # Session metadata (0o600)
│   └── transcript.jsonl      # Conversation transcript (0o600)
├── code-review-60759-99999/
│   ├── session.json
│   └── transcript.jsonl
└── 60759-11111/              # No-agent session
    ├── session.json
    └── transcript.jsonl
```

Session directories are created with `0o700` permissions. This replaces the current flat `~/.pureclaw/transcripts/` directory.

### RuntimeType

```haskell
data RuntimeType = RTProvider | RTHarness Text
  deriving stock (Show, Eq, Generic)
```

Custom JSON encoding for human-readable on-disk format:
- `RTProvider` → `"provider"`
- `RTHarness "claude-code"` → `"harness:claude-code"`

### Session Types

```haskell
data SessionMeta = SessionMeta
  { _sm_id                :: SessionId
  , _sm_agent             :: Maybe AgentName  -- ^ Agent (Nothing = no agent)
  , _sm_runtime           :: RuntimeType      -- ^ Provider or Harness
  , _sm_model             :: Text             -- ^ Model ID at creation time
  , _sm_channel           :: Text             -- ^ Channel type (cli, signal, etc.)
  , _sm_createdAt         :: UTCTime
  , _sm_lastActive        :: UTCTime
  , _sm_bootstrapConsumed :: Bool             -- ^ Whether BOOTSTRAP.md was consumed
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON SessionMeta
instance FromJSON SessionMeta
```

### Session Handle

```haskell
data SessionHandle = SessionHandle
  { _sh_meta       :: IORef SessionMeta    -- ^ Mutable metadata (lastActive updates)
  , _sh_transcript :: TranscriptHandle     -- ^ Transcript for this session
  , _sh_dir        :: FilePath             -- ^ Session directory path
  , _sh_save       :: IO ()               -- ^ Persist metadata to disk
  }

-- | No-op session handle for tests and code paths that don't need sessions.
mkNoOpSessionHandle :: IO SessionHandle
```

### Transcript Ownership

`AgentEnv._env_transcript` is **deprecated** in favor of `_env_session._sh_transcript`. The agent loop and transcript provider wrapper read the transcript handle from the session. A convenience accessor provides backward-compatible access:

```haskell
-- | Get the transcript handle from the current session.
envTranscript :: AgentEnv -> TranscriptHandle
envTranscript = _sh_transcript . _env_session
```

### Session Lifecycle

**Creation** (one of):
1. Implicit — starting `pureclaw tui` or `pureclaw gateway run` with no `--session` flag creates a new session
2. Explicit — `/session new [<prefix>]` slash command
3. CLI flag — `--prefix <prefix>` (always creates a new session)

**Resume**:
1. `/session resume <id-or-prefix>` — prefix matching: if `<id-or-prefix>` uniquely matches one session, resume it. If ambiguous, list matches and ask user to be more specific.
2. `--session <id>` CLI flag — exact match resume on startup
3. `/session last` (aliased as `/last`) — resume the most recent session

**Resume validation**:
- If `RuntimeType` is `RTHarness name` and the harness is not currently running:
  - Log warning: `Harness "claude-code" is not running. Falling back to provider.`
  - Set `_env_target` to `TargetProvider`
  - The session metadata retains `RTHarness` (the harness can be started later via `/harness start`)
- Agent bootstrap files are re-read from disk on resume (picks up edits)
- `bootstrap_consumed` flag is preserved — BOOTSTRAP.md is not re-injected

**Resume context loading**: On resume, reload the most recent messages from the transcript up to a configurable limit (default: 50 messages or 100K estimated tokens, whichever is smaller). The system prompt is recomposed from the agent's current bootstrap files. This balances context restoration with token budget management.

**Listing**:
1. `/session list [<agent-name>]` — show recent sessions (ID, agent, last active, runtime)
2. Default: show 20 most recent sessions, sorted by last_active descending

**No deletion** — sessions are never removed.

### Integration with AgentEnv

`AgentEnv` gains two new fields:

```haskell
data AgentEnv = AgentEnv
  { _env_provider       :: IORef (Maybe SomeProvider)
  , _env_model          :: IORef ModelId
  , _env_channel        :: ChannelHandle
  , _env_logger         :: LogHandle
  , _env_systemPrompt   :: Maybe Text
  , _env_registry       :: ToolRegistry
  , _env_vault          :: IORef (Maybe VaultHandle)
  , _env_pluginHandle   :: PluginHandle
  , _env_transcript     :: IORef (Maybe TranscriptHandle)  -- DEPRECATED: use _env_session
  , _env_policy         :: SecurityPolicy
  , _env_harnesses      :: IORef (Map Text HarnessHandle)
  , _env_target         :: IORef MessageTarget
  , _env_nextWindowIdx  :: IORef Int
  , _env_session        :: SessionHandle       -- ^ Current session (NEW)
  , _env_agentDef       :: Maybe AgentDef      -- ^ Loaded agent definition (NEW)
  }
```

**Construction sites** that must be updated:
1. `CLI/Commands.hs:startWithChannel` — primary construction site
2. Any test helpers that construct `AgentEnv` — use `mkNoOpSessionHandle`

The deprecated `_env_transcript` field is kept for one release cycle to avoid breaking existing code paths that reference it. New code should use `envTranscript`.

### Runtime Selection

The runtime for a session is determined at creation time:

1. **Default**: `RTProvider` (direct LLM provider call)
2. **CLI flag**: `--runtime harness:<name>` selects a specific harness

The existing `MessageTarget` / `/target` mechanism continues to work for ad-hoc routing within a session. The session's `RuntimeType` provides the *default* target; `/target` can override it temporarily.

**Relationship between `RuntimeType` and `MessageTarget`**:

```haskell
-- | Convert a session's runtime type to the default message target.
defaultTarget :: RuntimeType -> MessageTarget
defaultTarget RTProvider       = TargetProvider
defaultTarget (RTHarness name) = TargetHarness name
```

---

## Slash Command Changes

### Unified Session Namespace

The existing `/new`, `/reset`, `/status`, and `/compact` commands are **consolidated** under `/session`, with the bare forms kept as aliases for backward compatibility:

| Old Command | New Command | Alias Kept? |
|---|---|---|
| `/new` | `/session new` | Yes — `/new` = `/session new` |
| `/reset` | `/session reset` | Yes — `/reset` = `/session reset` |
| `/status` | `/session info` | Yes — `/status` = `/session info` |
| `/compact` | `/session compact` | Yes — `/compact` = `/session compact` |
| (new) | `/session list [<agent>]` | — |
| (new) | `/session resume <id>` | — |
| (new) | `/session last` | `/last` |

This resolves the `/new` vs `/session new` conflict — they are the same command. `/session new` creates a new session (new ID, new transcript, resets context). `/session info` subsumes `/status` (showing session ID, agent, runtime, message count, token usage).

### New `/agent` Commands

```
/agent list                        List available agents
/agent info [<name>]               Show agent details (files, frontmatter config)
/agent start <name>                Start new session with new agent
```

### Tab Completion

The existing tab completion system (via `buildCompleter` and `envRef`) is extended:

- `/session resume` triggers tab completion over session IDs from the sessions directory
- `/agent` subcommands trigger tab completion over discovered agent names
- `/session list` after a space triggers tab completion over agent names (for filtering)

### Error States

| Scenario | Error Message |
|---|---|
| `/session resume nonexistent` | `No session matching "nonexistent" found.` |
| `/session resume zoe` (ambiguous) | `Multiple sessions match "zoe": zoe-60759-111, zoe-60759-222. Be more specific.` |
| `/session resume <id>` with corrupted JSON | `Error reading session metadata: <parse error>. The transcript file may still be readable at <path>.` |
| `/agent switch nonexistent` | `Agent "nonexistent" not found. Available agents: zoe, haskell, ops` |
| `/agent info` (no agent selected) | Shows: `No agent selected. Use --agent <name> or /agent switch <name>.` |

---

## CLI Changes

### New Flags

```
pureclaw tui [--agent <name>] [--session <id>] [--prefix <prefix>]
pureclaw gateway run [--agent <name>] [--session <id>] [--prefix <prefix>]
```

- `--agent <name>`: Select an agent by name (validated via `mkAgentName`). Agent must exist in `~/.pureclaw/agents/<name>/`.
- `--session <id>`: Resume an existing session by exact ID match. Mutually exclusive with `--prefix`.
- `--prefix <prefix>`: Set the session ID prefix for new sessions (validated via `mkSessionPrefix`). Defaults to agent name if agent is selected.

The `--session new` keyword is removed — omitting `--session` always creates a new session (the default). This avoids the ambiguity of "new" as both a keyword and a potential session ID.

### Startup Flow Changes

Current flow:
1. Load config → resolve provider → load SOUL.md → build AgentEnv → run loop

New flow:
1. Load config
2. Resolve provider
3. **Discover agents** (enumerate `~/.pureclaw/agents/`, validate names)
4. **Load selected agent** (from `--agent` flag or config `default_agent` field)
5. **Create or resume session** (from `--session` flag or create new)
6. **Compose system prompt** (from agent bootstrap files, or existing SOUL.md path)
7. Build AgentEnv (now includes SessionHandle and AgentDef)
8. Run loop

---

## Transcript Migration

Current: `~/.pureclaw/transcripts/<YYYYMMDD-HHMMSS>-<channel>.jsonl`
New: `~/.pureclaw/sessions/<session-id>/transcript.jsonl`

Existing transcripts are not migrated — they remain in the old directory. New sessions write to the new path. The `/transcript` slash command is updated to read from the current session's transcript (via `envTranscript`).

---

## Config Changes

New fields in `config.toml`:

```toml
# Default agent to use when --agent is not specified
# If omitted, no agent is loaded (existing behavior preserved)
default_agent = "zoe"

# Default session ID prefix (overridden by --prefix flag)
# If omitted, defaults to agent name when an agent is selected
session_prefix = ""

# Agent bootstrap file truncation limit (chars)
agent_truncate_limit = 8000
```

New fields in `FileConfig`:

```haskell
data FileConfig = FileConfig
  { ...existing fields...
  , _fc_defaultAgent        :: Maybe Text
  , _fc_sessionPrefix       :: Maybe Text
  , _fc_agentTruncateLimit  :: Maybe Int
  }
```

---

## File Scope

### New Modules
- `src/PureClaw/Agent/AgentDef.hs` — `AgentName`, `AgentConfig`, `AgentDef` types, discovery, loading, prompt composition
- `src/PureClaw/Session/Types.hs` — `SessionPrefix`, `SessionMeta`, `RuntimeType`
- `src/PureClaw/Session/Handle.hs` — `SessionHandle`, `mkNoOpSessionHandle`, create/resume/save operations
- `src/PureClaw/Core/Types.hs` — `SessionId` newtype (added to existing module)
- `test/Agent/AgentDefSpec.hs` — agent name validation, discovery, loading, prompt composition tests
- `test/Session/TypesSpec.hs` — session prefix validation, session ID generation, RuntimeType JSON tests
- `test/Session/HandleSpec.hs` — session creation, resume, persistence, file permission tests

### Modified Modules
- `src/PureClaw/Agent/Env.hs` — add `_env_session`, `_env_agentDef` fields; deprecate `_env_transcript`
- `src/PureClaw/Agent/SlashCommands.hs` — add `/session` and `/agent` commands; alias `/new`→`/session new`, `/status`→`/session info`
- `src/PureClaw/CLI/Commands.hs` — add `--agent`, `--session`, `--prefix` flags; update startup flow; update AgentEnv construction
- `src/PureClaw/CLI/Config.hs` — add `default_agent`, `session_prefix`, `agent_truncate_limit`
- `src/PureClaw/Agent/Loop.hs` — update context initialization; bootstrap consumed callback
- `test/Integration/CLISpec.hs` — add integration tests for `--agent` and `--session` flags

### Unchanged
- `src/PureClaw/Agent/Identity.hs` — kept for no-agent path (backward compat)
- `src/PureClaw/Transcript/Types.hs` — transcript entry format unchanged
- `src/PureClaw/Handles/Transcript.hs` — transcript handle unchanged (just different path)

---

## Design Decisions

1. **Agents are not types** — An agent is a directory of files, not a Haskell type with structured fields. `AgentDef` captures only the metadata (name, dir, frontmatter overrides). The actual content is read and composed at session start time.

2. **Sessions own transcripts** — Moving transcripts from a flat directory into per-session directories is a clean break. No migration needed — old transcripts stay where they are.

3. **Session metadata is JSON** — Small, simple, easy to read/write. No need for a database.

4. **Agent prompt is raw text** — Unlike the current `AgentIdentity` which parses SOUL.md into structured fields, agent prompt composition injects files as raw text with section markers. This preserves the full richness of files like AGENTS.md (which have their own internal structure that shouldn't be re-parsed).

5. **RuntimeType is session-level** — The runtime (provider vs harness) is a property of the session, not the agent. This allows the same agent to be used with different runtimes.

6. **No session GC** — Sessions are tiny (a few KB of JSON metadata + transcript). No cleanup needed for MVP.

7. **Bootstrap tracking, not deletion** — `BOOTSTRAP.md` consumption is tracked in `session.json` as a boolean flag. The file itself is never mutated or deleted. This avoids race conditions between concurrent sessions, avoids data loss, and keeps the agent directory read-only from PureClaw's perspective.

8. **TOML frontmatter, not YAML** — The project already depends on `tomland` for config parsing. Using TOML for AGENTS.md frontmatter avoids adding a YAML dependency (`yaml`/`HsYAML` + `libyaml` C FFI).

9. **Workspace override is parsed but validated** — `workspace` in agent frontmatter is read (since OpenClaw imports may include it) but validated at session start: must be absolute, must exist, canonicalized via symlink resolution, and checked against a denylist of sensitive directories. PureClaw never modifies agent files.

13. **OS-level sandboxing deferred** — v1 uses `SafePath` + workspace validation as the security boundary. Kernel sandboxing (`sandbox-exec`/Landlock/user namespaces) is a separate follow-up epic. This keeps Sessions+Agents shippable and gives sandboxing the design attention it needs.

10. **Slash command consolidation** — `/new`, `/reset`, `/status`, `/compact` become aliases for `/session new`, `/session reset`, `/session info`, `/session compact`. One namespace, no ambiguity.

11. **Session resume recomposes agent prompt** — On resume, bootstrap files are re-read from disk (not cached from the original session). This ensures edits to SOUL.md between sessions take effect.

12. **`newSessionId` is pure** — Takes `UTCTime` as parameter instead of performing IO, making it trivially testable.

---

## Resolved Questions (formerly Open)

1. **Session resume context**: Reload the most recent messages from the transcript up to a configurable limit (default: 50 messages or 100K estimated tokens, whichever is smaller). System prompt is recomposed from current agent files.

2. **Agent-level model override priority**: CLI flag > agent frontmatter > config file > default. This matches the existing precedence pattern used for other config values.

3. **Multi-agent sessions**: `/agent switch` creates a new session. The old session is preserved and can be resumed. A session always has a fixed agent (or no agent).

---

## Explicitly Out of Scope (v1)

- Session garbage collection / pruning (`/session prune --older-than 30d`)
- `runtime` field in agent frontmatter
- Multi-channel sessions (one session serving both Signal and Telegram)
- Session forking (branching a session into two)
- BOOTSTRAP.md file deletion (only tracking)
- Modifying any file in agent directories (PureClaw treats them as read-only)
- OS-level sandboxing of agents (chroot, sandbox-exec, Landlock, user namespaces) — deferred to a separate "Agent Sandboxing" epic
- Automatic session resume on startup (always creates new unless `--session` flag)

---

## Design Review Gate — Results

**Date**: 2026-04-06
**Revision**: 3 (chroot extracted to follow-up epic per unanimous reviewer recommendation)

### Revision 2 Outcome

Revision 2 attempted to add chroot-based sandboxing to the design. All 5 reviewers re-reviewed:
- PM and Designer: PASS — confirmed all v1 blockers resolved
- Architect, Security, CTO: NEEDS_REVISION — **all blockers exclusively about chroot**

Key reviewer findings on chroot:
- **Security**: chroot doesn't work on macOS (primary dev platform), has known escape vectors, would create a false sense of security
- **CTO**: process model rewrite, breaks Nix-built binary at `/nix/store/...`, untestable under TDD + 100% coverage
- **Architect**: no architectural home, conflicts with `SafePath`/`FileHandle`/`ShellHandle`, untestable

All three independently recommended extracting sandboxing to a separate epic. Revision 3 does exactly that — Sessions+Agents ship with `SafePath` + workspace validation as the documented security boundary, and a follow-up "Agent Sandboxing" epic will design OS-level isolation properly.

### Reviewers

| Reviewer | Verdict (v1) | Blockers Addressed |
|----------|-------------|-------------------|
| PM | PASS | N/A |
| Architect | PASS | N/A |
| Designer | NEEDS_REVISION | B1: /new conflict → unified namespace. B2: /status overlap → /session info alias. B3: session ID usability → prefix matching + tab completion. B4: error states → error table added. |
| Security | NEEDS_REVISION | B1: path traversal → AgentName/SessionPrefix smart constructors. B2: workspace override → removed from frontmatter. B3: file permissions → specified 0o700/0o600. |
| CTO | NEEDS_REVISION | B1: BOOTSTRAP.md → tracked in session.json, not deleted. B2: AgentEnv construction → sites enumerated, mkNoOpSessionHandle added. B3: session resume runtime → fallback to provider with warning. B4: YAML dep → TOML frontmatter instead. |

### Incorporated Suggestions
- Split into two work units: Agents first, then Sessions (CTO S1)
- Deprecate `_env_transcript` in favor of session handle (Architect S2)
- `SessionId` in `PureClaw.Core.Types` (Architect S6)
- `newSessionId` is pure (CTO S4)
- `AgentConfig` extensible record for frontmatter (Architect S7)
- Custom JSON encoding for `RuntimeType` (CTO S3)
- Resolve all open questions before implementation (PM S3)
- Out-of-scope section added (PM S8)
- `/last` alias for `/session last` (Designer S2)
- Agent file size limit at read time (Security S4)
- `defaultTarget :: RuntimeType -> MessageTarget` function (Architect S5)
