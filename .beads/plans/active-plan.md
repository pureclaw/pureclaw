# MVP OpenClaw Feature Parity

**Status**: draft
**Branch**: TBD (per-epic branches off main)
**Priority**: P1

## Overview

Bring PureClaw to MVP feature parity with OpenClaw across three areas: messaging channels (Signal + Telegram), unrestricted shell execution, and OpenClaw config import (channels + agent definitions).

---

## Epic 1: Unrestricted Shell Execution

**Goal**: Power users on dedicated hardware can run with zero command restrictions.

### Current State

- `SecurityPolicy` has `AllowList CommandName` + `AutonomyLevel`
- `AllowList` already has an `AllowAll` constructor
- `authorize` checks both allow-list and autonomy level
- Shell tool has basic foreground execution only

### Design

**No new security types needed.** `SecurityPolicy { _sp_allowedCommands = AllowAll, _sp_autonomy = Full }` already represents unrestricted execution — `authorize` succeeds for any command. We just need to:

1. Wire up config: `autonomy = "full"` in TOML. When `full` + no explicit `allow` list → `AllowAll`
2. Add CLI flag: `--autonomy full|supervised|deny`
3. Print startup warning when autonomy is `full`
4. Enhance the shell tool with:
   - **Background execution**: `background :: Bool` param → returns process ID, delivers results async
   - **Timeout**: `exec_timeout_sec` config (default 300s), kill after timeout
   - **Working directory**: `cwd` param on shell tool
   - **Environment variables**: `env` param (Map Text Text)
   - **Streaming output**: forward stdout/stderr chunks via `_ch_sendChunk`

**Key insight**: Type safety is preserved — `AuthorizedCommand` is still required to call `ShellHandle`. Unrestricted mode just means `authorize` always succeeds.

### Config

```toml
autonomy = "full"    # full | supervised | deny (default: supervised)

[exec]
timeout_sec = 300
background_ms = 10000
```

### File Scope

- `src/PureClaw/Security/Policy.hs` — verify AllowAll path
- `src/PureClaw/Security/Command.hs` — verify authorize handles AllowAll
- `src/PureClaw/Tools/Shell.hs` — background exec, timeout, cwd, env params
- `src/PureClaw/Handles/Shell.hs` — extend for background + streaming
- `src/PureClaw/Handles/Process.hs` — process tracking for background jobs
- `src/PureClaw/CLI/Config.hs` — autonomy + exec config fields, TOML codec
- `src/PureClaw/CLI/Commands.hs` — `--autonomy` flag, startup warning
- `src/PureClaw/Core/Types.hs` — exec config types
- `test/Security/PolicySpec.hs` — unrestricted policy tests
- `test/Security/CommandSpec.hs` — AllowAll authorize tests
- `test/Tools/ShellSpec.hs` — background exec, timeout tests

---

## Epic 2: Signal Channel (Full Integration)

**Goal**: Signal as a first-class chat interface via signal-cli JSON-RPC.

### Current State

Skeleton in `PureClaw.Channels.Signal` — parses `SignalEnvelope` from JSON, has `TQueue`-based inbox, but `sendSignalMessage` only logs. No signal-cli process management.

### Design

**Transport**: Spawn `signal-cli --output=json jsonRpc` as a child process (stdio JSON-RPC). Same approach as OpenClaw. Process stays running for session lifetime.

**SignalHandle** (new):
```haskell
data SignalHandle = SignalHandle
  { _sh_process :: Process Handle Handle ()  -- signal-cli child
  , _sh_inbox   :: TQueue SignalEnvelope
  , _sh_account :: Text                      -- E.164 phone number
  }
```

**Receive loop**: Background thread reads stdout line-by-line, parses JSON envelopes, filters for `dataMessage`, pushes to inbox queue.

**Send**: JSON-RPC `send` method written to stdin. Chunking at 6000 chars on paragraph boundaries.

**DM policy**: Reuse `AllowList UserId`. Map E.164 numbers and UUIDs to `UserId`.

**Group support**: Parse `groupInfo` from envelopes. Mention-gating via bot's phone number in message text.

**Lifecycle**: `withSignalChannel :: SignalConfig -> (ChannelHandle -> IO a) -> IO a` — starts signal-cli, spawns reader thread, cleans up on exit.

**ChannelHandle mapping**: `_ch_readSecret`/`_ch_promptSecret` throw IOError (same as current). `_ch_prompt` sends message, waits for next from same sender.

### Config

```toml
channel = "signal"

[signal]
account = "+15555550123"
dm_policy = "allowlist"
allow_from = ["+15551234567"]
text_chunk_limit = 6000
```

### File Scope

- `src/PureClaw/Channels/Signal.hs` — complete rewrite (signal-cli JSON-RPC)
- `src/PureClaw/Channels/Class.hs` — Signal in SomeChannel
- `src/PureClaw/CLI/Config.hs` — signal config fields + TOML codec
- `src/PureClaw/CLI/Commands.hs` — `--channel` flag, signal startup path
- `src/PureClaw/Core/Types.hs` — ChannelType enum, signal types
- `test/Channels/SignalSpec.hs` — new module
- `test/CLI/ConfigSpec.hs` — signal config parsing tests

---

## Epic 3: Telegram Channel (Complete Integration)

**Goal**: Telegram as a fully working chat interface via Bot API long polling.

### Current State

Skeleton in `PureClaw.Channels.Telegram` — parses `TelegramUpdate`, has `TQueue`, sends via `sendMessage` Bot API. Missing: polling loop, lifecycle management.

### Design

**Transport**: Long polling via `getUpdates` (simpler than webhooks, no TLS/domain needed for MVP). Configurable timeout (default 30s).

**TelegramHandle** (extend existing):
```haskell
data TelegramHandle = TelegramHandle
  { _th_config  :: TelegramConfig
  , _th_inbox   :: TQueue TelegramUpdate
  , _th_network :: NetworkHandle
  , _th_lastId  :: IORef Int     -- last update_id for offset
  , _th_chatId  :: IORef (Maybe Int)
  }
```

**Receive loop**: Background thread polls `getUpdates?offset=N&timeout=30`, parses updates, pushes text messages to inbox.

**Send**: Existing `sendMessage`. Add chunking at 4096 chars. Add `parse_mode=Markdown`.

**DM policy**: `AllowList UserId` with `tg:123456789` format.

**Group support**: Parse `chat.type`. Mention-gating via `@botusername` or reply-to-bot.

**Bot commands**: Register via `setMyCommands` API at startup (`/help`, `/status`, `/new`).

**Lifecycle**: `withTelegramChannel :: TelegramConfig -> NetworkHandle -> (ChannelHandle -> IO a) -> IO a`

### Config

```toml
channel = "telegram"

[telegram]
bot_token = "123456:ABC-DEF..."
dm_policy = "pairing"
allow_from = ["tg:123456789"]
require_mention = true
text_chunk_limit = 4096
```

### File Scope

- `src/PureClaw/Channels/Telegram.hs` — complete implementation
- `src/PureClaw/CLI/Config.hs` — telegram config fields + TOML codec
- `src/PureClaw/CLI/Commands.hs` — telegram startup path
- `test/Channels/TelegramSpec.hs` — new module
- `test/CLI/ConfigSpec.hs` — telegram config parsing tests

---

## Epic 4: OpenClaw Config Import (Channels + Agents)

**Goal**: `pureclaw import <path>` reads an OpenClaw config and generates PureClaw config, covering channels and agent definitions.

### Current State

Provider import (API key, model) already works. No channel or agent definition import.

### Design

**CLI subcommand**: `pureclaw import <path>` (runs before agent loop, not a slash command).

**JSON5 parsing**: Lightweight preprocessor to strip `//` comments and trailing commas, then parse with `aeson`. OpenClaw configs rarely use advanced JSON5 features (no hex literals, multiline strings, etc.).

**Import scope (MVP)**:

| OpenClaw field | PureClaw equivalent |
|---|---|
| `channels.signal.account` | `[signal] account` |
| `channels.signal.dmPolicy` | `[signal] dm_policy` |
| `channels.signal.allowFrom` | `[signal] allow_from` |
| `channels.telegram.botToken` | `[telegram] bot_token` |
| `channels.telegram.dmPolicy` | `[telegram] dm_policy` |
| `channels.telegram.allowFrom` | `[telegram] allow_from` |
| `channels.telegram.groups` | `[telegram] groups` (simplified) |
| `agents.defaults.model` | `model` (already working) |
| `agents.defaults.workspace` | `workspace` (new field) |
| `agents.list[].name` | `[[agents]] name` |
| `agents.list[].systemPrompt` | `[[agents]] system` |
| `agents.list[].model` | `[[agents]] model` |
| `agents.list[].tools.profile` | `[[agents]] tool_profile` |
| API keys in config | Prompt to store in vault |

**Agent definitions as files on disk**:

OpenClaw's `agents.list[]` entries become individual files under `~/.pureclaw/agents/`:
```
~/.pureclaw/agents/coder.toml
~/.pureclaw/agents/research.toml
```

Each agent file:
```toml
name = "coder"
system = "You are a coding assistant..."
model = "anthropic/claude-sonnet-4-6"
tool_profile = "coding"    # minimal | coding | full
workspace = "~/Projects"
```

**AgentDef type** (new):
```haskell
data AgentDef = AgentDef
  { _ad_name        :: Text
  , _ad_system      :: Maybe Text
  , _ad_model       :: Maybe Text
  , _ad_toolProfile :: Maybe Text
  , _ad_workspace   :: Maybe Text
  }
```

The importer writes one `.toml` file per OpenClaw agent definition into `~/.pureclaw/agents/`.

**Output**: Write config to `~/.pureclaw/` (prompt before overwrite). Print summary of imported vs. skipped fields.

**$include handling**: Follow `$include` directives (single file or array) up to 3 levels deep, resolve relative paths from including file's directory.

### File Scope

- `src/PureClaw/CLI/Import.hs` — new module: JSON5 preprocessor, field mapping, $include resolution
- `src/PureClaw/CLI/Commands.hs` — `import` subcommand
- `src/PureClaw/CLI/Config.hs` — AgentDef type, extended FileConfig with agents
- `test/CLI/ImportSpec.hs` — new module with fixture OpenClaw configs
- `test/fixtures/openclaw/` — sample openclaw.json files for testing

---

## Directory Structure: Config vs. State

**Principle**: All user-editable configuration lives under `~/.pureclaw/` (version-controllable with git). All mutable runtime state lives under a separate directory (not version-controlled).

### Config directory (`~/.pureclaw/`) — git-friendly

```
~/.pureclaw/
├── config.toml              # main config (provider, model, channel, autonomy, etc.)
├── agents/                  # agent definitions (one .toml per agent)
│   ├── coder.toml
│   └── research.toml
└── system.md                # default system prompt (optional)
```

Everything here is user-authored or imported. Plain text, deterministic, suitable for `git init && git add .`.

### State directory (`~/.pureclaw/state/` or XDG `~/.local/share/pureclaw/`) — mutable

```
~/.local/share/pureclaw/     # or ~/.pureclaw/state/
├── vault/                   # encrypted secrets (vault.age, identity files)
│   ├── vault.age
│   └── age-plugin-yubikey-identity.txt
├── memory/                  # memory backend data (sqlite, markdown files)
├── sessions/                # conversation history / session state
├── pairing/                 # pairing codes and paired device state
└── logs/                    # runtime logs
```

Everything here is written by PureClaw at runtime. Excluded from version control.

**Migration**: Existing `~/.pureclaw/vault/` paths continue to work. We add a config field `state_dir` with a sensible default and migrate gracefully.

**Design decision**: We use `~/.local/share/pureclaw/` (XDG data dir) as the default on Linux/macOS. The config field `state_dir` allows override. The vault path fields in existing configs are respected as-is for backward compatibility.

---

## Channel Selection at Startup

Shared infrastructure for Epics 2 & 3:

- New CLI flag: `--channel <cli|signal|telegram>` (default: `cli`)
- Config field: `channel = "cli"`
- CLI flag overrides config
- Channel-specific config sections only read when that channel is selected
- Future: multi-channel gateway mode (not MVP — single channel per process)

---

## Dependency Graph

```
Epic 1 (Exec)     ─── independent, smallest scope
Epic 2 (Signal)   ─── independent, highest priority
Epic 3 (Telegram) ─── shares patterns with Epic 2
Epic 4 (Import)   ─── depends on channel config schema from 2+3
```

Recommended execution order: **1 → 2 → 3 → 4**

Epics 1 and 2 can be parallelized. Epic 3 reuses channel abstractions from Epic 2. Epic 4 must come last (needs finalized config schema).

## Human Checkpoints

- [ ] After Epic 1: Review security model for unrestricted exec before merging
- [ ] After Epic 2: Test with real signal-cli installation
- [ ] After Epic 3: Test with real Telegram bot
- [ ] After Epic 4: Test with real OpenClaw config file

## Resolved Questions

1. **signal-cli installation**: Require pre-installed. Print helpful error with install instructions if missing. No auto-install for MVP.
2. **Agent definitions**: Stored as individual `.toml` files under `~/.pureclaw/agents/`. Runtime selection (`/agent <name>`) is a fast follow-up, not MVP.
3. **$include depth**: 3 levels for MVP.
4. **Config vs. state separation**: All config under `~/.pureclaw/` (git-friendly), all mutable state under `~/.local/share/pureclaw/` (not version-controlled).

## Open Questions

1. **State dir default**: `~/.local/share/pureclaw/` (XDG) vs `~/.pureclaw/state/` — XDG is more standard but splits the pureclaw footprint across two locations.
2. **Agent loading at startup**: Should all agent defs be loaded eagerly, or lazily when referenced? (Recommend: eagerly, they're tiny files)

---

## Design Review Gate — Iteration 1 Results

**Date**: 2026-03-15
**Overall**: NEEDS_REVISION (4 of 5 agents flagged blockers)

### Blocker Summary (deduplicated, prioritized)

#### CRITICAL: Security

1. **User allow-list never enforced** (Security B1): `_cfg_allowedUsers` exists in `Config` but the agent loop (`Loop.hs`) never checks `_im_userId` against it. With `autonomy = "full"` + Signal/Telegram, ANY user who messages the bot gets unrestricted shell execution. **Must add userId authorization check in agent loop immediately after `_ch_receive`, before any message processing. Mandatory for all non-CLI channels.**

2. **Shell `env` parameter enables injection** (Security B2): The proposed `env :: Map Text Text` on the shell tool is controlled by the LLM. A prompt injection via Signal/Telegram could set `LD_PRELOAD`, `PATH`, etc., bypassing `safeEnv`. **Must specify: env vars merge UNDER safeEnv (safeEnv wins), or restrict to an allowlist, or limit to `autonomy = "full"` + CLI only.**

3. **Shell `cwd` parameter enables workspace escape** (Security B3): No containment validation. `cwd = "/etc"` would work. **Must validate through `mkSafePath` or equivalent workspace check. Relax only when `autonomy = "full"`.**

#### HIGH: Design Gaps

4. **Bot token in plaintext config** (Designer B2, CTO B5, Security S1): Telegram `bot_token` is a secret but shown in `config.toml`. Must be vault-stored. **Define `bot_token_vault = "telegram_bot_token"` convention that resolves from vault at startup. Import command should prompt to store in vault.**

5. **Agent selection mechanism missing** (Designer B3): Agent def files are written to `~/.pureclaw/agents/` but no config field or CLI flag selects which one to use. **Must add `agent = "coder"` config field and `--agent` CLI flag.**

6. **`dm_policy` enum undefined** (Designer B4): Different values shown for Signal vs Telegram with no type definition. **Must define `DmPolicy = Pairing | AllowList | Open | Disabled` ADT and document it.**

7. **`channel` → `default_channel`** (Designer B1): Current naming is ambiguous. **Rename to `default_channel` to clarify it's a selector, not a channel object.**

#### MEDIUM: Scope & Process

8. **Epic 1 scope creep** (CTO B1): Bundles unrestricted mode (trivial) with 5 shell enhancements (complex). **Split: Epic 1a = wire autonomy config + AllowAll (small). Epic 1b = background exec, timeout, cwd, env, streaming (separate epic or fast follow).**

9. **No TDD breakdown per epic** (CTO B3): File scopes listed but no red/green/refactor sequence. **Add "TDD Sequence" subsection to each epic with first failing test.**

10. **Missing testability seams** (CTO B2): No mock strategy for signal-cli process or Telegram API. **Specify handle boundaries: Signal gets a process abstraction (replaceable with in-memory queues in tests), Telegram uses mock `NetworkHandle`.**

11. **Channel failure modes unspecified** (CTO B4, Architect S3): What happens when signal-cli crashes or Telegram polling drops? **For MVP: propagate exception, let process die with clear error. No reconnection. Must be stated explicitly.**

#### LOW: Product Completeness

12. **No use cases in WHO/WANTS/SO THAT format** (PM B1): Design describes WHAT, not WHO or WHY.

13. **No success metrics** (PM B2): No measurable criteria for "feature parity."

14. **Import error UX missing** (PM B3): Epic 4 doesn't specify what users see when fields can't be mapped.

15. **Migration path vague** (PM B4): Discovery, side-by-side operation, and explicit exclusions absent.

### Non-Blocking Suggestions (consolidated)

- Architect S1: `ShellHandle` becomes multi-field record (not newtype) — state this explicitly
- Architect S2: Keep `SignalChannel` name for internal state, reserve `*Handle` for capability records
- Architect S5: JSON5 preprocessor limitations (comments in strings) — document as known limitation
- Architect S7: `AgentEnv` may need `SecurityPolicy` field for startup warning
- Designer S1: Rename `background_ms` → `background_check_interval_ms`
- Designer S3: `text_chunk_limit` should be platform constants, not user config
- Designer S5: Add `pureclaw import --dry-run`
- CTO S3: JSON5 preprocessor — consider a state machine for outside-string comment stripping
- CTO S4: `$include` cycle detection (visited-set check)
- CTO S5: Telegram `chat_id` should be `Int64` not `Int`
- Security S2: Curate signal-cli child process environment (don't inherit full parent env)
- Security S4: Per-user rate limiting for remote channels
- Security S5: Bound max concurrent background processes
- Security S6: Require explicit flag for `autonomy=full` + remote channel combination
