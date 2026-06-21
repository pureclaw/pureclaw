# PureClaw Skills Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Implement a production-grade skills system in PureClaw that matches or exceeds the best practices from Claude Code, Hermes Agent, and the agentskills.io ecosystem standard.

**Architecture:** Skills are filesystem artifacts (SKILL.md + supporting files) stored canonically on the Harness Machine. Every mutation is a transcript entry. Skills are synced to the Execution Machine at session start. Progressive disclosure: metadata at session start → full content on demand → linked files on demand. Trusted tools manage skill state; untrusted tools execute skill scripts.

**Tech Stack:** Haskell (PureClaw), filesystem-backed, YAML frontmatter parsing, agentskills.io compatible.

---

## Research Summary: What the Ecosystem Does

### The agentskills.io Standard

The open standard all major harnesses are converging on:

```
my-skill/
├── SKILL.md          # Required: YAML frontmatter + markdown instructions
├── scripts/          # Optional: executable code
├── references/       # Optional: documentation loaded on demand
├── assets/           # Optional: templates, resources
└── templates/        # Optional: output templates
```

**Progressive disclosure** is the core design pattern:
1. **Tier 1 (startup):** Name + description only. Token cost: ~50 tokens per skill.
2. **Tier 2 (invocation):** Full SKILL.md content loaded into context.
3. **Tier 3 (on demand):** Linked files (references, templates, scripts) loaded only when needed.

**SKILL.md format:**
```yaml
---
name: skill-name              # Required, max 64 chars
description: Brief description # Required, max 1024 chars
# All other fields optional
---
# Instructions here
```

Supported by: Claude Code, OpenAI Codex, Cursor, Junie, Letta, OpenHands, Spring AI, Laravel Boost, pi, Hermes Agent, and others.

### Claude Code (Reference Implementation)

**Key features beyond the standard:**

| Feature | Detail |
|---------|--------|
| **Invocation control** | `disable-model-invocation: true` — only user can invoke. `user-invocable: false` — only model can invoke. |
| **Dynamic context injection** | `!`cmd`` and ```! blocks — shell commands run at load time, output replaces placeholder. |
| **String substitutions** | `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N`, `$name`, `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}`, `${CLAUDE_SKILL_DIR}` |
| **Subagent execution** | `context: fork` + `agent: Explore` — skill runs in isolated subagent. |
| **Tool pre-approval** | `allowed-tools` / `disallowed-tools` — grant/restrict tools while skill is active. |
| **Path-scoped activation** | `paths` glob patterns — skill only activates when working with matching files. |
| **Live change detection** | Watches skill directories; edits take effect mid-session. |
| **Skill hierarchy** | Enterprise > Personal > Project > Plugin > Bundled. |
| **Nested skills** | Monorepo support: `apps/web/.claude/skills/deploy/` → `/apps/web:deploy`. |
| **Content lifecycle** | Skill stays in context across turns. Auto-compaction carries forward (first 5K tokens, 25K combined budget). |
| **Bundled skills** | `/code-review`, `/batch`, `/debug`, `/loop`, `/run`, `/verify`, `/run-skill-generator`. |
| **Slash commands** | `/skill-name` invokes directly. Skills merged with old `.claude/commands/` system. |

**Frontmatter fields (all optional except description recommended):**
`name`, `description`, `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`, `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`

### Hermes Agent (Most Mature Open-Source Implementation)

**Tool surface (3 tools, 7 actions):**

| Tool | Purpose |
|------|---------|
| `skills_list` | Tier 1: name + description + category. Optional category filter. |
| `skill_view` | Tier 2-3: full SKILL.md content + linked_files dict. `file_path` param for tier 3. |
| `skill_manage` | CRUD: create, edit, patch, delete, write_file, remove_file. |

**Key features beyond Claude Code:**

| Feature | Detail |
|---------|--------|
| **Category organization** | `skills/mlops/axolotl/SKILL.md` → category = "mlops". DESCRIPTION.md per category. |
| **Readiness status** | `available`, `setup_needed`, `unsupported` — skill declares requirements, harness checks. |
| **Environment variable management** | `required_environment_variables` in frontmatter. Interactive secret capture. Passthrough to sandboxed execution. |
| **Credential file mounting** | `required_credential_files` — mounted into remote sandboxes (Docker, Modal). |
| **Platform filtering** | `platforms: [macos, linux, windows]` — skill only loads on compatible OS. |
| **Per-platform disable** | `skills.platform_disabled.telegram: [skill-a]` in config.yaml. |
| **Bundled skill sync** | Manifest-based: tracks origin hash, detects user modifications, skips customized skills. |
| **Skill hub** | Search/install from skills.sh, GitHub, ClawHub, Claude Marketplace, LobeHub. |
| **Plugin skills** | `plugin:skill` namespace. Bundle context banner shows sibling skills. |
| **Slash commands** | Auto-generated `/skill-name` commands. Normalized to hyphens. |
| **Preloading** | `--preload skill1,skill2` at CLI session start. |
| **Skill config injection** | `metadata.hermes.config` entries resolved from config.yaml, injected as `[Skill config: ...]` block. |
| **Security** | Prompt injection detection, path traversal prevention, security scanning on create/edit. |
| **Template vars** | `${HERMES_SKILL_DIR}`, `${HERMES_SESSION_ID}`. |
| **Inline shell** | `!`cmd`` — configurable, off by default. |
| **Fuzzy patching** | `skill_manage(action='patch')` uses 9-strategy fuzzy matching. |
| **Atomic writes** | temp file + `os.replace()` for all skill mutations. |
| **Size limits** | 100K chars per SKILL.md, 1 MiB per supporting file. |

**Frontmatter fields:**
`name`, `description`, `version`, `license`, `platforms`, `prerequisites` (env_vars, commands), `compatibility`, `metadata.hermes` (tags, related_skills, config), `required_environment_variables`, `required_credential_files`, `setup`

### OpenCode

OpenCode follows the agentskills.io standard. Skills live in `.opencode/skills/`. Less feature-rich than Claude Code or Hermes — primarily file-based with no CRUD tools exposed to the agent. Skills are user-managed, not agent-managed.

---

## Design Decisions for PureClaw

### What to Adopt (from all three)

1. **agentskills.io compatibility** — Non-negotiable. SKILL.md format, directory structure, progressive disclosure. This is the ecosystem standard.

2. **Progressive disclosure** — Tier 1 (list: name + description), Tier 2 (view: full SKILL.md), Tier 3 (view file: linked files). This is the single most important design pattern. Token efficiency is a first-class concern.

3. **Agent-managed CRUD** — `skill_create`, `skill_update`, `skill_delete`, `skill_file_write`, `skill_file_remove`. The agent should be able to capture successful approaches as skills. This is Hermes's killer feature.

4. **Fuzzy patching** — `skill_update` with `old_string`/`new_string` semantics. Targeted edits are far more token-efficient than full rewrites. Hermes's 9-strategy fuzzy matching is the gold standard.

5. **Category organization** — `skills/category/name/SKILL.md`. Flat directories don't scale past ~30 skills.

6. **Readiness status** — `available`, `setup_needed`, `unsupported`. Skills declare what they need; harness checks.

7. **Environment variable requirements** — Skills declare required env vars. Harness checks, captures interactively, passes through to execution.

8. **Platform filtering** — `platforms: [macos, linux]`. Not all skills work everywhere.

9. **Slash command integration** — `/skill-name` invokes skills. This is table stakes.

10. **Preloading** — Skills can be preloaded at session start for session-wide guidance.

11. **Invocation control** — `disable-model-invocation` and `user-invocable` from Claude Code. Critical for dangerous skills (deploy, commit).

12. **Dynamic context injection** — `!`cmd`` from Claude Code. Run shell at load time, inline output. Too powerful to skip.

13. **String substitutions** — `$ARGUMENTS`, `${PURECLAW_SESSION_ID}`, `${PURECLAW_SKILL_DIR}`. Essential for parameterized skills.

14. **Tool pre-approval** — `allowed-tools` / `disallowed-tools`. Critical for autonomous skills that need specific tool access.

15. **Atomic writes** — All skill mutations use temp file + atomic replace. Never corrupt.

16. **Size limits** — Cap SKILL.md and supporting files. Prevent context flooding.

17. **Security scanning** — Prompt injection detection on skill load. Path traversal prevention on file access.

### What to Defer (phase 2+)

1. **Skill hub / marketplace** — Search/install from external sources. Complex, needs auth, rate limiting, trust decisions. Phase 2.

2. **Bundled skill sync** — Manifest-based update tracking. Only matters when PureClaw ships bundled skills. Phase 2.

3. **Subagent execution** — `context: fork`. Requires subagent infrastructure. Phase 2.

4. **Live change detection** — File watchers. Nice-to-have, not launch-critical. Phase 2.

5. **Nested skills / monorepo** — Directory-qualified names. Phase 2.

6. **Plugin skills** — Namespaced skills from plugins. Requires plugin system. Phase 2.

7. **Skill config injection** — `metadata.hermes.config` pattern. Requires config system maturity. Phase 2.

8. **Credential file mounting** — For remote sandboxes. Requires sandbox infrastructure. Phase 2.

9. **Skill hooks** — `hooks` frontmatter. Requires hook system. Phase 3.

10. **Path-scoped activation** — `paths` glob patterns. Nice-to-have. Phase 3.

### What to Skip

1. **`model` / `effort` overrides** — Claude Code feature. PureClaw's model selection is harness-level, not skill-level. YAGNI.

2. **`shell` override** — Claude Code's PowerShell support. PureClaw targets Unix. YAGNI.

3. **`when_to_use`** — Claude Code's extended description field. Redundant with `description`. Use `description` well instead.

4. **`argument-hint`** — Claude Code's autocomplete hint. Requires CLI autocomplete infrastructure. Phase 3.

---

## Tool Design: 7 Tools (Trusted — Harness Machine)

All skill tools are **Trusted** — they operate on the Harness Machine's skill store. Every mutation is a transcript entry. Skills are synced to the Execution Machine at session start (NFS ro mount or tool-call sync).

### 1. `skill_list` — Tier 1: Metadata Only

```
skill_list { category?: String } → {
  skills: [{ name, description, category, readiness_status }],
  categories: [String],
  count: Int
}
```

- Returns name + description + category + readiness_status only.
- Optional category filter.
- Sorted by category then name.
- Disabled skills excluded.
- Platform-incompatible skills excluded.
- **Token cost:** ~50 tokens per skill.

### 2. `skill_view` — Tier 2-3: Full Content + Linked Files

```
skill_view { name: String, file_path?: String } → {
  name, description, content, path, skill_dir,
  linked_files?: { references: [...], templates: [...], scripts: [...], assets: [...] },
  readiness_status, setup_needed, missing_env_vars, ...
}
```

- First call (no `file_path`): returns full SKILL.md content + `linked_files` dict.
- Second call (with `file_path`): returns specific file content.
- Applies template substitutions (`${PURECLAW_SKILL_DIR}`, `${PURECLAW_SESSION_ID}`).
- Applies dynamic context injection (`!`cmd``) if enabled.
- Security: prompt injection detection, path traversal prevention.
- Returns readiness info: missing env vars, setup needed.

### 3. `skill_create` — Create New Skill

```
skill_create { name: String, content: String, category?: String } → {
  success: Bool, path: String, transcript_offset: Int
}
```

- Validates name (lowercase, hyphens/underscores, max 64 chars).
- Validates frontmatter (must have `---` delimiters, `name` and `description` fields).
- Validates content size (max 100K chars).
- Checks for name collisions.
- Atomic write (temp file + rename).
- **Transcript entry:** `SkillCreate { name, category, content_hash, offset }`.

### 4. `skill_update` — Targeted Patch or Full Edit

```
skill_update { name: String, old_string: String, new_string: String,
               file_path?: String, replace_all?: Bool } → {
  success: Bool, match_count: Int, transcript_offset: Int
}
```

- Fuzzy matching (multiple strategies — whitespace normalization, indentation tolerance, block-anchor matching).
- Defaults to SKILL.md; `file_path` for supporting files.
- Requires unique match unless `replace_all: true`.
- Validates frontmatter intact after patch (if patching SKILL.md).
- Validates size limits on result.
- Atomic write with rollback on failure.
- **Transcript entry:** `SkillUpdate { name, file_path, old_hash, new_hash, offset }`.

### 5. `skill_delete` — Delete Skill

```
skill_delete { name: String } → {
  success: Bool, transcript_offset: Int
}
```

- Tombstone delete — not erased from transcript, only removed from active store.
- Cleans up empty category directories.
- **Transcript entry:** `SkillDelete { name, offset }`.

### 6. `skill_file_write` — Add/Overwrite Supporting File

```
skill_file_write { name: String, file_path: String, file_content: String } → {
  success: Bool, path: String, transcript_offset: Int
}
```

- `file_path` must be under `references/`, `templates/`, `scripts/`, or `assets/`.
- Path traversal prevention.
- Size limit: 1 MiB per file.
- Atomic write.
- **Transcript entry:** `SkillFileWrite { name, file_path, content_hash, offset }`.

### 7. `skill_file_remove` — Remove Supporting File

```
skill_file_remove { name: String, file_path: String } → {
  success: Bool, transcript_offset: Int
}
```

- Same path restrictions as `skill_file_write`.
- Cleans up empty subdirectories.
- **Transcript entry:** `SkillFileRemove { name, file_path, offset }`.

---

## SKILL.md Format (agentskills.io Compatible + PureClaw Extensions)

```yaml
---
name: my-skill                    # Required, max 64 chars, lowercase/hyphens
description: What and when        # Required, max 1024 chars
version: 1.0.0                    # Optional
license: MIT                      # Optional
platforms: [macos, linux]         # Optional — restrict OS compatibility
disable-model-invocation: true    # Optional — only user can invoke
user-invocable: false             # Optional — only model can invoke
allowed-tools: [Bash, Read]       # Optional — pre-approve tools
disallowed-tools: [AskUser]       # Optional — restrict tools
arguments: [issue, branch]        # Optional — named positional args
required_environment_variables:   # Optional — declare needed env vars
  - name: GITHUB_TOKEN
    prompt: Enter your GitHub token
    help: https://github.com/settings/tokens
required_credential_files:        # Optional — declare needed cred files
  - ~/.ssh/id_rsa
metadata:                         # Optional — arbitrary key-value
  pureclaw:
    tags: [deployment, git]
    related_skills: [commit, code-review]
---

# Skill Title

Instructions here. Use $ARGUMENTS, $0, $1, $issue, $branch for arguments.
Use ${PURECLAW_SKILL_DIR} for the skill's directory.
Use ${PURECLAW_SESSION_ID} for the current session.

## Dynamic context
!`git diff HEAD`

## Supporting files
- See [reference.md](references/api.md) for details
```

---

## Directory Structure

```
~/.pureclaw/skills/              # Personal skills (all projects)
├── devops/
│   ├── deploy/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   └── deploy.sh
│   │   └── references/
│   │       └── environments.md
│   └── DESCRIPTION.md           # Category description
├── coding/
│   └── code-review/
│       └── SKILL.md
└── my-skill/
    ├── SKILL.md
    └── templates/
        └── output.md

./.pureclaw/skills/              # Project skills (this project only)
└── project-deploy/
    └── SKILL.md
```

**Skill resolution order:** Project > Personal. (No enterprise tier in PureClaw v1.)

---

## Implementation Phases

### Phase 1: Core Skill Infrastructure (Tasks 1-12)

Foundation: file format, parsing, discovery, progressive disclosure.

### Phase 2: Agent-Managed CRUD (Tasks 13-20)

Create, update, delete — the agent captures successful approaches.

### Phase 3: Advanced Features (Tasks 21-28)

Dynamic context injection, invocation control, tool pre-approval, slash commands, preloading.

### Phase 4: Polish & Security (Tasks 29-35)

Readiness status, env var management, security scanning, size limits, atomic writes.

---

## Phase 1: Core Skill Infrastructure

### Task 1: Define SKILL.md parser types

**Objective:** Create Haskell types for parsed SKILL.md frontmatter and skill metadata.

**Files:**
- Create: `src/PureClaw/Skill/Types.hs`

**Types to define:**

```haskell
-- Core skill metadata from frontmatter
data SkillMeta = SkillMeta
  { smName        :: Text           -- max 64 chars
  , smDescription :: Text           -- max 1024 chars
  , smVersion     :: Maybe Text
  , smLicense     :: Maybe Text
  , smPlatforms   :: Maybe [Text]   -- ["macos", "linux", "windows"]
  , smDisableModelInvocation :: Bool
  , smUserInvocable :: Bool         -- default True
  , smAllowedTools :: Maybe [Text]
  , smDisallowedTools :: Maybe [Text]
  , smArguments   :: Maybe [Text]   -- named positional args
  , smRequiredEnvVars :: [EnvVarRequirement]
  , smRequiredCredFiles :: [FilePath]
  , smTags        :: [Text]
  , smRelatedSkills :: [Text]
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

data EnvVarRequirement = EnvVarRequirement
  { evrName     :: Text
  , evrPrompt   :: Maybe Text
  , evrHelp     :: Maybe Text
  , evrOptional :: Bool
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- Readiness status
data SkillReadiness
  = SkillAvailable
  | SkillSetupNeeded { missing :: [Text] }
  | SkillUnsupported { reason :: Text }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- Full skill view result
data SkillView = SkillView
  { svName         :: Text
  , svDescription  :: Text
  , svContent      :: Text           -- rendered SKILL.md
  , svPath         :: FilePath       -- relative to skills dir
  , svSkillDir     :: FilePath       -- absolute
  , svLinkedFiles  :: Maybe (Map Text [FilePath])
  , svReadiness    :: SkillReadiness
  , svTags         :: [Text]
  , svRelatedSkills :: [Text]
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- Skill listing entry (tier 1 — minimal)
data SkillEntry = SkillEntry
  { seName        :: Text
  , seDescription :: Text
  , seCategory    :: Maybe Text
  , seReadiness   :: SkillReadiness
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)
```

**Verification:** Types compile. `FromJSON` instances round-trip with sample YAML.

---

### Task 2: Implement YAML frontmatter parser

**Objective:** Parse SKILL.md files, extracting frontmatter and body.

**Files:**
- Create: `src/PureClaw/Skill/Parser.hs`

**Implementation:**

```haskell
parseSkillMd :: Text -> Either ParseError (SkillMeta, Text)
parseSkillMd content = do
  (frontmatter, body) <- extractFrontmatter content
  meta <- parseFrontmatter frontmatter
  pure (meta, body)

extractFrontmatter :: Text -> Either ParseError (Text, Text)
-- Split on --- delimiters. First line must be ---.
-- Everything between first and second --- is YAML.
-- Everything after second --- is body.

parseFrontmatter :: Text -> Either ParseError SkillMeta
-- Parse YAML with defaults for all optional fields.
-- Validate: name ≤ 64 chars, description ≤ 1024 chars.
-- Validate: platforms values are valid OS identifiers.
```

**Verification:** Parse the example SKILL.md from the format spec above. Round-trip test: parse → encode → parse produces identical result.

---

### Task 3: Implement skill discovery

**Objective:** Recursively find all SKILL.md files in skills directories.

**Files:**
- Create: `src/PureClaw/Skill/Discovery.hs`

**Implementation:**

```haskell
discoverSkills :: [FilePath] -> IO [SkillEntry]
-- Walk each skills directory recursively.
-- Find all SKILL.md files.
-- Parse frontmatter only (first 4KB of file).
-- Filter: platform-compatible, not disabled.
-- Extract: name, description, category, readiness.
-- Sort by category then name.
-- Deduplicate by name (first match wins — personal > project).

getCategory :: FilePath -> FilePath -> Maybe Text
-- Given skills root and skill path, extract category.
-- e.g., skills/devops/deploy/SKILL.md → "devops"
-- e.g., skills/my-skill/SKILL.md → Nothing
```

**Verification:** Create test directory with 3 skills in 2 categories. `discoverSkills` returns 3 entries with correct categories.

---

### Task 4: Implement skill file reading with security

**Objective:** Read SKILL.md and supporting files with path traversal prevention.

**Files:**
- Create: `src/PureClaw/Skill/FileAccess.hs`

**Implementation:**

```haskell
readSkillFile :: FilePath -> FilePath -> IO (Either SkillError Text)
-- skillDir: absolute path to skill directory
-- filePath: relative path within skill (e.g., "references/api.md")
-- Security: resolve, verify within skillDir, reject if escapes.
-- Read file, return content.

readSkillMd :: FilePath -> IO (Either SkillError Text)
-- Read SKILL.md from skill directory.

listSupportingFiles :: FilePath -> IO (Map Text [FilePath])
-- Scan references/, templates/, scripts/, assets/.
-- Return map of category → relative file paths.
```

**Verification:** Attempt path traversal (`../../etc/passwd`) → rejected. Normal file read → succeeds.

---

### Task 5: Implement `skill_list` tool

**Objective:** Tier 1 progressive disclosure — list all skills with minimal metadata.

**Files:**
- Create: `src/PureClaw/Tool/SkillList.hs`

**Implementation:**

```haskell
skillList :: Maybe Text -> Harness SkillListResult
-- Optional category filter.
-- Discover skills from personal + project directories.
-- Filter by category if specified.
-- Return: skills array, categories array, count, hint.
-- Token-efficient: only name + description + category + readiness.
```

**Tool schema (JSON):**
```json
{
  "name": "skill_list",
  "description": "List available skills (name + description). Use skill_view(name) to load full content.",
  "parameters": {
    "type": "object",
    "properties": {
      "category": { "type": "string", "description": "Optional category filter" }
    }
  }
}
```

**Verification:** Call with no args → returns all skills. Call with `category: "devops"` → returns only devops skills.

---

### Task 6: Implement `skill_view` tool (tier 2 — full content)

**Objective:** Load full SKILL.md content with linked files discovery.

**Files:**
- Create: `src/PureClaw/Tool/SkillView.hs`

**Implementation:**

```haskell
skillView :: Text -> Maybe Text -> Harness SkillViewResult
-- name: skill name or path (e.g., "deploy" or "devops/deploy")
-- filePath: optional linked file path
-- If filePath: read and return that file.
-- Otherwise: read SKILL.md, parse frontmatter, list supporting files.
-- Apply template substitutions (${PURECLAW_SKILL_DIR}, ${PURECLAW_SESSION_ID}).
-- Apply dynamic context injection (!`cmd`) if enabled.
-- Return: full SkillView with linked_files dict.
-- Security: prompt injection detection (log warning, still serve).
```

**Tool schema:**
```json
{
  "name": "skill_view",
  "description": "Load a skill's full content or access its linked files. First call returns SKILL.md content plus a 'linked_files' dict. To access linked files, call again with file_path parameter.",
  "parameters": {
    "type": "object",
    "properties": {
      "name": { "type": "string", "description": "The skill name" },
      "file_path": { "type": "string", "description": "Optional: path to linked file (e.g., 'references/api.md')" }
    },
    "required": ["name"]
  }
}
```

**Verification:** `skill_view("deploy")` → returns full SKILL.md + linked_files. `skill_view("deploy", "scripts/deploy.sh")` → returns script content.

---

### Task 7: Implement template variable substitution

**Objective:** Replace `${PURECLAW_SKILL_DIR}` and `${PURECLAW_SESSION_ID}` in skill content.

**Files:**
- Modify: `src/PureClaw/Skill/Parser.hs` (add substitution module)

**Implementation:**

```haskell
substituteVars :: Text -> FilePath -> Text -> Text
-- Replace ${PURECLAW_SKILL_DIR} with actual skill directory path.
-- Replace ${PURECLAW_SESSION_ID} with current session ID.
-- Unresolved tokens left as-is.

substituteArgs :: Text -> [Text] -> SkillMeta -> Text
-- Replace $ARGUMENTS with all args joined.
-- Replace $0, $1, etc. with positional args.
-- Replace $name with named args from frontmatter.
-- Shell-style quoting: "multi word" treated as single arg.
```

**Verification:** Skill with `${PURECLAW_SKILL_DIR}/scripts/foo.sh` → substituted with actual path.

---

### Task 8: Implement dynamic context injection

**Objective:** Run `!`cmd`` and ```! blocks at skill load time, inline output.

**Files:**
- Modify: `src/PureClaw/Skill/Parser.hs` (add injection module)

**Implementation:**

```haskell
expandInlineShell :: Text -> FilePath -> IO Text
-- Find !`cmd` patterns (only at line start or after whitespace).
-- Run each command with skill dir as CWD.
-- Replace placeholder with stdout.
-- Timeout per command: 10s default.
-- Cap output: 4000 chars per command.
-- Errors: replace with [inline-shell error: ...] marker.

expandFencedShell :: Text -> FilePath -> IO Text
-- Find ```! blocks.
-- Run block content as script.
-- Replace block with stdout.
```

**Verification:** Skill with `!`git diff HEAD`` → command runs, output inlined.

---

### Task 9: Implement platform filtering

**Objective:** Skip skills not compatible with current OS.

**Files:**
- Modify: `src/PureClaw/Skill/Discovery.hs`

**Implementation:**

```haskell
skillMatchesPlatform :: SkillMeta -> Bool
-- If platforms is Nothing: compatible with all.
-- If platforms is set: check current OS against list.
-- Map: "macos" → darwin, "linux" → linux, "windows" → win32.

currentPlatform :: Text
-- Return current OS identifier.
```

**Verification:** Skill with `platforms: [linux]` on macOS → filtered out.

---

### Task 10: Implement disabled skill filtering

**Objective:** Respect user's disabled skills configuration.

**Files:**
- Create: `src/PureClaw/Skill/Config.hs`

**Implementation:**

```haskell
getDisabledSkills :: Harness (Set Text)
-- Read from config: skills.disabled and skills.platform_disabled.<platform>.

isSkillDisabled :: Text -> Harness Bool
-- Check if skill name is in disabled set for current platform.
```

**Verification:** Add skill to disabled list → `skill_list` excludes it. `skill_view` returns error.

---

### Task 11: Implement readiness status calculation

**Objective:** Determine if a skill is available, needs setup, or is unsupported.

**Files:**
- Modify: `src/PureClaw/Skill/Discovery.hs`

**Implementation:**

```haskell
calcReadiness :: SkillMeta -> IO SkillReadiness
-- Check platform compatibility → Unsupported if mismatch.
-- Check required env vars → SetupNeeded if any missing.
-- Check required credential files → SetupNeeded if any missing.
-- Otherwise → Available.

checkEnvVars :: [EnvVarRequirement] -> IO [Text]
-- Return list of missing required (non-optional) env var names.

checkCredFiles :: [FilePath] -> IO [Text]
-- Return list of missing credential file paths.
```

**Verification:** Skill requiring `GITHUB_TOKEN` when not set → `SetupNeeded { missing: ["env GITHUB_TOKEN"] }`.

---

### Task 12: Wire tools into harness tool registry

**Objective:** Register `skill_list` and `skill_view` as Trusted tools.

**Files:**
- Modify: `src/PureClaw/Harness/ToolRegistry.hs`

**Implementation:**
- Add `skill_list` and `skill_view` to Trusted tool set.
- Both are Trusted (operate on Harness Machine state).
- Both are read-only → no ACK required.
- Transcript entries: `SkillListView { name?, category? }` and `SkillViewView { name, file_path? }`.

**Verification:** Tools appear in tool list. Agent can call them. Results return correctly.

---

## Phase 2: Agent-Managed CRUD

### Task 13: Implement name and content validation

**Objective:** Validate skill names and SKILL.md content before creation/update.

**Files:**
- Create: `src/PureClaw/Skill/Validation.hs`

**Implementation:**

```haskell
validateName :: Text -> Either SkillError ()
-- Lowercase, hyphens/underscores/dots, max 64 chars.
-- Must start with letter or digit.
-- Regex: ^[a-z0-9][a-z0-9._-]*$

validateCategory :: Maybe Text -> Either SkillError ()
-- Same rules as name, plus no path separators.

validateFrontmatter :: Text -> Either SkillError ()
-- Must start with ---.
-- Must have closing ---.
-- YAML must parse.
-- Must have 'name' and 'description' fields.
-- Description ≤ 1024 chars.
-- Body must be non-empty after frontmatter.

validateContentSize :: Text -> Either SkillError ()
-- Max 100K chars for SKILL.md.
-- Max 1 MiB for supporting files.

validateFilePath :: Text -> Either SkillError ()
-- Must be under references/, templates/, scripts/, or assets/.
-- No path traversal (..).
-- Must have filename (not just directory).
```

**Verification:** Invalid name "My Skill!" → rejected. Valid name "my-skill" → accepted.

---

### Task 14: Implement atomic file write

**Objective:** Write files atomically — never corrupt, never partial.

**Files:**
- Create: `src/PureClaw/Skill/AtomicWrite.hs`

**Implementation:**

```haskell
atomicWriteText :: FilePath -> Text -> IO ()
-- Write to temp file in same directory.
-- fsync temp file.
-- os.replace temp → target.
-- On exception: clean up temp file.

atomicWriteBytes :: FilePath -> ByteString -> IO ()
-- Same pattern for binary files.
```

**Verification:** Kill process mid-write → target file unchanged. Normal write → target file updated.

---

### Task 15: Implement `skill_create` tool

**Objective:** Agent creates new skills from successful approaches.

**Files:**
- Create: `src/PureClaw/Tool/SkillCreate.hs`

**Implementation:**

```haskell
skillCreate :: Text -> Text -> Maybe Text -> Harness SkillCreateResult
-- Validate name, category, content.
-- Check for name collisions.
-- Create skill directory (skills/category/name/ or skills/name/).
-- Atomic write SKILL.md.
-- Return success + path + transcript offset.
-- Transcript entry: SkillCreate { name, category, content_hash, offset }.
```

**Tool schema:**
```json
{
  "name": "skill_create",
  "description": "Create a new skill from a successful approach. Provide full SKILL.md content (YAML frontmatter + markdown body).",
  "parameters": {
    "type": "object",
    "properties": {
      "name": { "type": "string", "description": "Skill name (lowercase, hyphens, max 64 chars)" },
      "content": { "type": "string", "description": "Full SKILL.md content" },
      "category": { "type": "string", "description": "Optional category for organization" }
    },
    "required": ["name", "content"]
  }
}
```

**Verification:** Create a skill → appears in `skill_list`. Create duplicate name → error.

---

### Task 16: Implement fuzzy matching for patches

**Objective:** Multi-strategy fuzzy matching so the agent doesn't need exact whitespace/indentation matches.

**Files:**
- Create: `src/PureClaw/Skill/FuzzyMatch.hs`

**Implementation:**

```haskell
fuzzyFindAndReplace :: Text -> Text -> Text -> Bool
                    -> Either MatchError (Text, Int, MatchStrategy)
-- 9 strategies tried in order:
--   1. Exact match
--   2. Normalize whitespace (collapse spaces, trim lines)
--   3. Normalize indentation (strip leading whitespace)
--   4. Normalize blank lines
--   5. Escape sequences (handle \n, \t differences)
--   6. Block-anchor (match first+last lines, fuzzy middle)
--   7. Line-by-line (match individual lines)
--   8. Strip all whitespace
--   9. Substring (last resort)
-- replace_all: replace all occurrences instead of requiring unique match.
-- Return: new content, match count, strategy used.

data MatchStrategy = Exact | Whitespace | Indent | BlankLines | ...
```

**Verification:** Agent patches with slightly different indentation → fuzzy match succeeds. No match → error with file preview.

---

### Task 17: Implement `skill_update` tool

**Objective:** Targeted find-and-replace within SKILL.md or supporting files.

**Files:**
- Create: `src/PureClaw/Tool/SkillUpdate.hs`

**Implementation:**

```haskell
skillUpdate :: Text -> Text -> Text -> Maybe Text -> Bool
            -> Harness SkillUpdateResult
-- name: skill to update.
-- old_string: text to find.
-- new_string: replacement (empty = delete).
-- file_path: defaults to SKILL.md, or supporting file.
-- replace_all: replace all occurrences.
-- Validate: skill exists, file exists.
-- Fuzzy find and replace.
-- If patching SKILL.md: validate frontmatter intact after patch.
-- Validate size limits on result.
-- Atomic write with rollback on failure.
-- Transcript entry: SkillUpdate { name, file_path, old_hash, new_hash, offset }.
```

**Tool schema:**
```json
{
  "name": "skill_update",
  "description": "Update a skill by targeted find-and-replace. Uses fuzzy matching — minor whitespace/indentation differences won't break it.",
  "parameters": {
    "type": "object",
    "properties": {
      "name": { "type": "string" },
      "old_string": { "type": "string", "description": "Text to find" },
      "new_string": { "type": "string", "description": "Replacement text (empty to delete)" },
      "file_path": { "type": "string", "description": "Optional: defaults to SKILL.md" },
      "replace_all": { "type": "boolean", "description": "Replace all occurrences (default: false)" }
    },
    "required": ["name", "old_string", "new_string"]
  }
}
```

**Verification:** Patch a skill → content updated. Patch with broken frontmatter → rejected. Patch non-existent skill → error.

---

### Task 18: Implement `skill_delete` tool

**Objective:** Delete a skill (tombstone — not erased from transcript).

**Files:**
- Create: `src/PureClaw/Tool/SkillDelete.hs`

**Implementation:**

```haskell
skillDelete :: Text -> Harness SkillDeleteResult
-- Validate: skill exists, is local (not external).
-- Remove skill directory.
-- Clean up empty category directory.
-- Transcript entry: SkillDelete { name, offset }.
-- Note: transcript retains all prior versions. Only active store changes.
```

**Tool schema:**
```json
{
  "name": "skill_delete",
  "description": "Delete a skill. The skill is removed from the active store but all prior versions remain in the transcript.",
  "parameters": {
    "type": "object",
    "properties": {
      "name": { "type": "string" }
    },
    "required": ["name"]
  }
}
```

**Verification:** Delete skill → removed from `skill_list`. Transcript still has all prior entries.

---

### Task 19: Implement `skill_file_write` tool

**Objective:** Add or overwrite supporting files within a skill.

**Files:**
- Create: `src/PureClaw/Tool/SkillFileWrite.hs`

**Implementation:**

```haskell
skillFileWrite :: Text -> Text -> Text -> Harness SkillFileWriteResult
-- name: skill to add file to.
-- file_path: relative path under references/templates/scripts/assets.
-- file_content: content to write.
-- Validate: skill exists, file_path valid, size ≤ 1 MiB.
-- Atomic write.
-- Transcript entry: SkillFileWrite { name, file_path, content_hash, offset }.
```

**Verification:** Write `references/api.md` → file appears. Write `../../escape.md` → rejected.

---

### Task 20: Implement `skill_file_remove` tool

**Objective:** Remove a supporting file from a skill.

**Files:**
- Create: `src/PureClaw/Tool/SkillFileRemove.hs`

**Implementation:**

```haskell
skillFileRemove :: Text -> Text -> Harness SkillFileRemoveResult
-- Same validation as skill_file_write.
-- Remove file.
-- Clean up empty subdirectory.
-- Transcript entry: SkillFileRemove { name, file_path, offset }.
```

**Verification:** Remove file → gone. Remove non-existent → error with available files list.

---

## Phase 3: Advanced Features

### Task 21: Implement invocation control

**Objective:** Respect `disable-model-invocation` and `user-invocable` frontmatter fields.

**Files:**
- Modify: `src/PureClaw/Skill/Discovery.hs`

**Implementation:**

```haskell
-- In skill_list: only include skills where user-invocable is true
-- (or omit entirely if user-invocable: false — model-only skills).

-- In skill_view: check disable-model-invocation.
-- If true and invoked by model (not user slash command): reject.
-- If user-invocable: false and invoked by user: reject.

-- Skill descriptions for model-invocable skills are always in context.
-- Skill descriptions for disable-model-invocation skills are NOT in context
-- (model shouldn't know about them to invoke them).
```

**Verification:** Skill with `disable-model-invocation: true` → model can't invoke. User can via slash command.

---

### Task 22: Implement tool pre-approval

**Objective:** `allowed-tools` and `disallowed-tools` modify tool availability while skill is active.

**Files:**
- Modify: `src/PureClaw/Harness/ToolRegistry.hs`

**Implementation:**

```haskell
-- When skill is loaded into context, apply its tool modifiers:
-- allowed-tools: these tools don't require ACK while skill is active.
-- disallowed-tools: these tools are removed from available pool.
-- Modifiers clear when skill is unloaded (next user message or session end).

applySkillToolModifiers :: SkillMeta -> ToolRegistry -> ToolRegistry
clearSkillToolModifiers :: ToolRegistry -> ToolRegistry
```

**Verification:** Skill with `allowed-tools: [Bash(git *)]` → git commands run without ACK. Other Bash commands still require ACK.

---

### Task 23: Implement slash command generation

**Objective:** Auto-generate `/skill-name` commands from installed skills.

**Files:**
- Create: `src/PureClaw/CLI/SlashCommands.hs`

**Implementation:**

```haskell
scanSkillCommands :: IO (Map Text SkillCommand)
-- Scan all skill directories.
-- Generate /skill-name for each user-invocable skill.
-- Normalize names: lowercase, spaces→hyphens, underscores→hyphens.
-- Strip non-alphanumeric chars.
-- Deduplicate: first skill wins.

data SkillCommand = SkillCommand
  { scName        :: Text  -- "/deploy"
  , scDescription :: Text
  , scSkillPath   :: FilePath
  }
```

**Verification:** Skills directory with "My Skill" → `/my-skill` command generated.

---

### Task 24: Implement skill invocation via slash command

**Objective:** When user types `/skill-name`, load skill content into context.

**Files:**
- Modify: `src/PureClaw/CLI/SlashCommands.hs`

**Implementation:**

```haskell
invokeSkill :: Text -> Text -> Harness Message
-- command: "/deploy"
-- userInstruction: text after command (arguments)
-- Load skill, apply substitutions, inject into conversation as user message.
-- Format: "[SYSTEM: The user has invoked the 'deploy' skill...]\n\n<skill content>"
-- Append user instruction if provided.
-- Append supporting files list with load instructions.
```

**Verification:** `/deploy production` → skill loads with `$ARGUMENTS` = "production".

---

### Task 25: Implement skill preloading

**Objective:** Skills can be preloaded at session start for session-wide guidance.

**Files:**
- Modify: `src/PureClaw/CLI/SessionStart.hs`

**Implementation:**

```haskell
preloadSkills :: [Text] -> Harness [Message]
-- Load each skill, format as system message.
-- Activation note: "[SYSTEM: This session was launched with the 'X' skill preloaded...]"
-- Return list of messages to prepend to conversation.
```

**Verification:** Start session with `--preload code-review` → skill content in system prompt.

---

### Task 26: Implement argument parsing for skills

**Objective:** Parse `$ARGUMENTS`, `$0`, `$1`, `$name` in skill content.

**Files:**
- Modify: `src/PureClaw/Skill/Parser.hs`

**Implementation:**

```haskell
parseSkillArgs :: Text -> SkillMeta -> Either SkillError (Map Text Text)
-- Parse argument string with shell-style quoting.
-- "hello world" second → two args: "hello world", "second".
-- Map positional indices: $0 = "hello world", $1 = "second".
-- Map named args from frontmatter: $issue = first arg, $branch = second arg.
-- $ARGUMENTS = full string as typed.

substituteArgs :: Text -> Map Text Text -> Text
-- Replace all argument placeholders in skill content.
-- $0, $1, $ARGUMENTS, $name for each named arg.
-- Literal $ escaped with backslash: \$1.00 stays literal.
```

**Verification:** `/fix-issue 123` with `arguments: [issue]` → `$issue` = "123", `$ARGUMENTS` = "123".

---

### Task 27: Implement prompt injection detection

**Objective:** Detect common prompt injection patterns in skill content.

**Files:**
- Create: `src/PureClaw/Skill/Security.hs`

**Implementation:**

```haskell
detectInjection :: Text -> [InjectionWarning]
-- Check for known patterns:
--   "ignore previous instructions"
--   "ignore all previous"
--   "you are now"
--   "disregard your"
--   "forget your instructions"
--   "new instructions:"
--   "system prompt:"
--   "<system>"
--   "]]>"
-- Log warning but still serve content (matches Hermes behavior).
-- For agent-created skills: block if injection detected.

data InjectionWarning = InjectionWarning
  { iwPattern :: Text
  , iwLocation :: Int  -- char offset
  }
```

**Verification:** Skill with "ignore previous instructions" → warning logged. Agent-created skill with injection → blocked.

---

### Task 28: Implement path traversal prevention

**Objective:** Prevent `../../` escapes when accessing skill files.

**Files:**
- Modify: `src/PureClaw/Skill/FileAccess.hs`

**Implementation:**

```haskell
validateWithinDir :: FilePath -> FilePath -> Either SkillError ()
-- Resolve target path.
-- Verify it's within skill directory.
-- Reject if escapes.

hasTraversalComponent :: Text -> Bool
-- Check for ".." path components.
```

**Verification:** `skill_view("deploy", "../../etc/passwd")` → rejected.

---

## Phase 4: Polish & Security

### Task 29: Implement env var requirement checking

**Objective:** Check required environment variables, capture interactively.

**Files:**
- Create: `src/PureClaw/Skill/EnvCheck.hs`

**Implementation:**

```haskell
checkRequiredEnvVars :: [EnvVarRequirement] -> IO [Text]
-- For each required (non-optional) env var:
--   Check if set in environment or .env file.
--   Return list of missing names.

captureMissingEnvVars :: [EnvVarRequirement] -> Harness (Map Text Text)
-- Interactive capture: prompt user for each missing var.
-- Store in session environment (not persisted to .env by default).
-- Gateway mode: skip capture, return setup hint.
```

**Verification:** Skill requires `GITHUB_TOKEN` → if missing, user prompted. If set, passes.

---

### Task 30: Implement credential file checking

**Objective:** Check required credential files exist.

**Files:**
- Modify: `src/PureClaw/Skill/EnvCheck.hs`

**Implementation:**

```haskell
checkRequiredCredFiles :: [FilePath] -> IO [Text]
-- For each path: check if file exists and is readable.
-- Return list of missing paths.
```

**Verification:** Skill requires `~/.ssh/id_rsa` → if missing, flagged in readiness.

---

### Task 31: Implement size limits and content caps

**Objective:** Prevent oversized skills from flooding context.

**Files:**
- Modify: `src/PureClaw/Skill/Validation.hs`

**Implementation:**

```haskell
maxSkillContentChars :: Int  -- 100,000 (~36K tokens)
maxSkillFileBytes :: Int     -- 1,048,576 (1 MiB)

-- Enforced in:
--   skill_create: reject oversized SKILL.md
--   skill_update: reject if result exceeds limit
--   skill_file_write: reject if file exceeds 1 MiB
--   skill_view: truncate linked file content at limit with warning
```

**Verification:** Create skill with 200K chars → rejected with clear error message.

---

### Task 32: Implement atomic write with rollback

**Objective:** All skill mutations use atomic write. Failed operations roll back.

**Files:**
- Modify: `src/PureClaw/Skill/AtomicWrite.hs`

**Implementation:**

```haskell
atomicWriteWithRollback :: FilePath -> Text -> IO (Either SkillError ())
-- 1. Read original content (if exists).
-- 2. Write new content to temp file.
-- 3. fsync temp file.
-- 4. os.replace temp → target.
-- 5. If step 4 fails: clean up temp, return error.
-- 6. If post-write validation fails: restore original from backup.

-- Used by: skill_create, skill_update, skill_file_write.
```

**Verification:** Disk full during write → original file intact. Validation failure after write → restored.

---

### Task 33: Implement skill directory initialization

**Objective:** Create skills directories on first use.

**Files:**
- Modify: `src/PureClaw/Skill/Discovery.hs`

**Implementation:**

```haskell
ensureSkillsDirs :: Harness ()
-- Create ~/.pureclaw/skills/ if not exists.
-- Create ./.pureclaw/skills/ if not exists (project skills).
-- Called at harness startup.
```

**Verification:** Fresh install → `skill_list` returns empty list, not error.

---

### Task 34: Implement transcript integration

**Objective:** Every skill mutation is a transcript entry.

**Files:**
- Modify: `src/PureClaw/Harness/Transcript.hs`

**Implementation:**

```haskell
data TranscriptEntry
  = -- ... existing entries ...
  | SkillCreateEntry { sceName :: Text, sceCategory :: Maybe Text, sceHash :: Text, sceOffset :: Int }
  | SkillUpdateEntry { sueName :: Text, sueFilePath :: Maybe Text, sueOldHash :: Text, sueNewHash :: Text, sueOffset :: Int }
  | SkillDeleteEntry { sdeName :: Text, sdeOffset :: Int }
  | SkillFileWriteEntry { sfweName :: Text, sfwePath :: Text, sfweHash :: Text, sfweOffset :: Int }
  | SkillFileRemoveEntry { sfreName :: Text, sfrePath :: Text, sfreOffset :: Int }
  | SkillListViewEntry { slveCategory :: Maybe Text }
  | SkillViewEntry { sveName :: Text, sveFilePath :: Maybe Text }
```

**Verification:** Create skill → transcript has SkillCreateEntry. Update → SkillUpdateEntry. Delete → SkillDeleteEntry.

---

### Task 35: Integration test — full skill lifecycle

**Objective:** End-to-end test of the entire skill system.

**Files:**
- Create: `test/PureClaw/Skill/IntegrationSpec.hs`

**Test scenario:**
1. `skill_list` → empty.
2. `skill_create` "deploy" with full SKILL.md → success.
3. `skill_list` → shows "deploy".
4. `skill_view` "deploy" → returns full content + linked_files.
5. `skill_file_write` "deploy" "scripts/deploy.sh" → success.
6. `skill_view` "deploy" "scripts/deploy.sh" → returns script.
7. `skill_update` "deploy" patch → success.
8. `skill_view` "deploy" → shows updated content.
9. `skill_delete` "deploy" → success.
10. `skill_list` → empty again.
11. Transcript contains all 6 mutation entries.

**Verification:** All steps pass. Transcript is complete and hash-chained.

---

## Summary: Tool Surface

| # | Tool | Tier | Trust | Mutation | ACK Required |
|---|------|------|-------|----------|--------------|
| 1 | `skill_list` | Trusted | Read | No | No |
| 2 | `skill_view` | Trusted | Read | No | No |
| 3 | `skill_create` | Trusted | Write | Yes | Yes |
| 4 | `skill_update` | Trusted | Write | Yes | Yes |
| 5 | `skill_delete` | Trusted | Write | Yes | Yes |
| 6 | `skill_file_write` | Trusted | Write | Yes | Yes |
| 7 | `skill_file_remove` | Trusted | Write | Yes | Yes |

All 7 are Trusted (Harness Machine). Read ops need no ACK. Write ops need ACK-before-execute. Every mutation is a transcript entry.

---

## What We're NOT Building (Phase 1)

| Feature | Reason |
|---------|--------|
| Skill hub / marketplace | Complex external integration. Phase 2. |
| Bundled skill sync | Only matters when we ship bundled skills. Phase 2. |
| Subagent execution (`context: fork`) | Requires subagent infrastructure. Phase 2. |
| Live change detection | File watchers. Nice-to-have. Phase 2. |
| Nested skills / monorepo | Directory-qualified names. Phase 2. |
| Plugin skills | Requires plugin system. Phase 2. |
| Skill config injection | Requires config system maturity. Phase 2. |
| Credential file mounting | Requires sandbox infrastructure. Phase 2. |
| Skill hooks | Requires hook system. Phase 3. |
| Path-scoped activation (`paths` glob) | Nice-to-have. Phase 3. |
| `model` / `effort` overrides | Harness-level concern, not skill-level. YAGNI. |
| `shell` override (PowerShell) | PureClaw targets Unix. YAGNI. |
| `when_to_use` field | Redundant with `description`. Skip. |
| `argument-hint` field | Requires CLI autocomplete. Phase 3. |

---

## Design Principles Applied

1. **Progressive disclosure is the backbone.** Tier 1 (list) costs ~50 tokens/skill. Tier 2 (view) loads full content only when needed. Tier 3 (file) loads linked files only on demand.

2. **agentskills.io compatibility is non-negotiable.** Skills written for Claude Code or Codex should work in PureClaw with minimal changes.

3. **Every mutation is a transcript entry.** Nothing erased, only superseded. The transcript IS the audit log.

4. **Trusted vs Untrusted is the only privilege distinction.** All skill tools are Trusted (Harness Machine). Skill scripts execute on the Execution Machine.

5. **Token efficiency is a first-class design concern.** Fuzzy patching over full rewrites. Metadata-only listing. Linked files on demand.

6. **Composability over feature count.** 7 tools, not 20. Each tool is a primitive. Advanced features (slash commands, preloading) compose from these primitives.

7. **Orthogonality.** `skill_list` / `skill_view` for reading. `skill_create` / `skill_update` / `skill_delete` for lifecycle. `skill_file_write` / `skill_file_remove` for supporting files. No overlap.

---

## Reference Documents

- Claude Code Skills docs: https://code.claude.com/docs/en/skills
- agentskills.io specification: https://agentskills.io/specification
- Hermes Agent skills_tool.py: `~/code/hermes-agent/tools/skills_tool.py` (1492 lines)
- Hermes Agent skill_manager_tool.py: `~/code/hermes-agent/tools/skill_manager_tool.py` (817 lines)
- Hermes Agent skill_preprocessing.py: `~/code/hermes-agent/agent/skill_preprocessing.py` (131 lines)
- Hermes Agent skill_commands.py: `~/code/hermes-agent/agent/skill_commands.py` (385 lines)
- Hermes Agent skills_sync.py: `~/code/hermes-agent/tools/skills_sync.py` (430 lines)
- PureClaw audit architecture: `pureclaw-audit-architecture` skill
- PureClaw tool inventory: `pureclaw-tool-inventory` skill
- ISA design methodology: `isa-design-methodology` skill
