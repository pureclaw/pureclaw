# Tool Comparison: PureClaw vs Hermes Agent

## Tools PureClaw Has

| PureClaw Tool | Hermes Equivalent | Parity Notes |
|---|---|---|
| `file_read` | `read_file` | Hermes adds offset/limit pagination, ~100K char guard |
| `file_write` | `write_file` | Hermes adds auto syntax checks (.py/.json/.yaml/.toml) |
| `edit` | `patch` | **Big gap.** Hermes has 9 fuzzy-match strategies + V4A multi-file patch mode. PureClaw requires exact unique string match |
| `shell` | `terminal` | **Big gap.** Hermes has 7 backends (local/Docker/SSH/Modal/Singularity/Daytona/Vercel), background mode, PTY, watch patterns. PureClaw is local-only with allowlist |
| `git` | _(via terminal)_ | PureClaw has a dedicated git tool; Hermes just uses terminal. PureClaw advantage here (structured subcommands) |
| `http_request` | `web_extract` | Hermes is smarter -- markdown conversion, PDF support, LLM summarization for large pages. PureClaw is raw GET with domain allowlist |
| `web_search` | `web_search` | Roughly equivalent. Hermes supports DuckDuckGo/Firecrawl/Exa backends and advanced operators |
| `memory_store` / `memory_recall` | `memory` | Different model. PureClaw: vector/FTS search with similarity scores. Hermes: curated markdown (MEMORY.md/USER.md) injected into system prompt, 2200 char cap |
| `process` | `process` | Similar (spawn/list/poll/kill/write_stdin). Hermes adds log pagination, wait, submit, close stdin |
| `message` | `send_message` | **Big gap.** Hermes sends to 17 platforms with media attachments. PureClaw sends text to the active channel only |
| `cron` | `cronjob` | Hermes adds repeat limits, custom model overrides, skill-aware, pause/resume/trigger. PureClaw is basic add/remove/list |
| `image` | `vision_analyze` | Different scope. PureClaw reads local image files. Hermes analyzes URLs via vision LLM with custom prompts |

## Tools Hermes Has That PureClaw Lacks Entirely

| Hermes Tool | What It Does | Impact |
|---|---|---|
| **`patch`** (V4A mode) | Multi-file patches in a single tool call | High -- dramatically reduces round-trips for refactoring |
| **`search_files`** | Ripgrep-backed regex search with glob filters, pagination, context lines | **High** -- PureClaw has no file content search tool at all |
| **`browser_*`** (12 tools) | Full browser automation -- navigate, click, type, scroll, screenshot, JS console, CDP | High -- entire capability missing |
| **`delegate_task`** | Spawn isolated subagents with restricted toolsets | High -- enables parallel task decomposition |
| **`execute_code`** | Run Python that calls tools programmatically (collapses multi-step pipelines) | Medium-high -- reduces inference round-trips |
| **`clarify`** | Ask user structured questions (multiple choice or open-ended) | **High** -- PureClaw agent can't ask clarifying questions |
| **`todo`** | In-memory task list for decomposing complex work | Medium -- lightweight planning aid |
| **`session_search`** | FTS5 search across past session transcripts with LLM summarization | Medium -- cross-session recall |
| **`image_generate`** | Text-to-image via FAL.ai (FLUX, GPT-Image, etc.) | Low-medium -- niche but impressive |
| **`text_to_speech`** | TTS via 5+ providers | Low -- niche |
| **`mixture_of_agents`** | Multi-model reasoning synthesis | Low -- advanced reasoning aid |
| **`skill_*`** (3 tools) | Browse, view, create/edit skills | Medium -- enables self-improvement loop |
| **`kanban_*`** (7 tools) | Multi-agent task coordination board | Low -- only relevant for multi-agent |
| **`ha_*`** (4 tools) | Home Assistant smart home control | Low -- domain-specific |

## Hermes Tool Details (for implementation reference)

### search_files

- **Parameters:** pattern (regex), target ("content" or "files"), path (default "."), file_glob, limit (default 50), offset, output_mode ("content"/"files_only"/"count"), context (lines, default 0)
- **Backend:** Ripgrep
- **Modes:** Content search (regex match with line numbers) or file search (glob match)
- **Output:** Matches with line numbers, file paths only, or match counts

### clarify

- **Parameters:** question (string), choices (array of strings, max 4, optional)
- **Modes:** Multiple choice (up to 4 choices + "Other" option) or open-ended (no choices)
- **Returns:** JSON with question, choices_offered, user_response

### patch (V4A mode)

- **Parameters:** mode ("replace" or "patch"), path, old_string, new_string, replace_all (default false), patch (V4A format)
- **Replace mode:** 9 fuzzy-match strategies for targeted find-and-replace
- **Patch mode:** V4A multi-file diff format in a single tool call

### delegate_task

- **Parameters:** goal, toolset (optional), max_concurrent (default 3), context (optional), role ("worker"/"orchestrator"), max_spawn_depth (default 1)
- **Behavior:** Spawns isolated child agent with restricted toolset and own terminal session. Parent blocks until children complete. Returns summary only.
- **Nesting:** role="orchestrator" allows nested delegation up to max_spawn_depth

### execute_code

- **Parameters:** code (Python), language (default "python"), timeout (default 300)
- **Available tools inside script:** web_search, web_extract, read_file, write_file, search_files, patch, terminal
- **Limits:** 50 tool calls, 50KB stdout, 10KB stderr
- **Backend:** Local (UDS) or remote (file-based RPC)

### todo

- **Parameters:** todos (array of {id, content, status}), merge (default false)
- **Statuses:** pending, in_progress, completed, cancelled
- **Behavior:** Omit todos to read current list; provide todos to write. Returns full list after writing.
- **Scope:** In-memory per session (not persisted)

### browser_* (12 tools)

| Tool | Parameters |
|---|---|
| `browser_navigate` | url |
| `browser_snapshot` | full (bool) |
| `browser_click` | ref (element ID like "@e5") |
| `browser_type` | ref, text |
| `browser_scroll` | direction ("up"/"down") |
| `browser_back` | (none) |
| `browser_press` | key (e.g., "Enter", "Tab") |
| `browser_get_images` | (none) |
| `browser_vision` | question, annotate (bool) |
| `browser_console` | clear (bool), expression (JS) |
| `browser_cdp` | (CDP protocol) |
| `browser_dialog` | (alert/confirm/prompt handling) |

### send_message

- **Parameters:** platform (17 options), target, text, image, video, audio, thread_id
- **Platforms:** telegram, discord, slack, signal, sms, whatsapp, email, mattermost, matrix, dingtalk, feishu, wecom, wechat, qqbot

### cronjob

- **Parameters:** action (create/list/update/pause/resume/remove/trigger), name, schedule (cron format), prompt, skills, repeat ({times, interval, days_of_week}), model ({provider, model})

### session_search

- **Parameters:** query, limit (default 3)
- **Backend:** SQLite FTS5
- **Returns:** LLM-summarized session transcripts matching query

### mixture_of_agents

- **Parameters:** user_prompt, include_reasoning (default false)
- **Behavior:** Queries multiple frontier models in parallel (reference layer), synthesizes with strongest model (aggregator)

## Priority Ranking for Closing the Gap

Ordered by bang-for-buck (impact vs implementation effort):

1. **`search_files`** -- PureClaw has zero file content search. Table stakes. Simple to implement (shell out to grep/rg through ShellHandle).
2. **`clarify`** -- Agent can't ask user questions. One-tool fix, dramatically improves UX for ambiguous requests.
3. **`patch` fuzzy matching** -- PureClaw's `edit` requires exact unique string match, which fails often. Fuzzy matching is the #1 QoL improvement for code editing.
4. **`web_extract`** -- Upgrade `http_request` from raw GET to markdown extraction with size handling.
5. **`delegate_task`** -- Subagent spawning. PureClaw has session infrastructure already; wire it into a tool.
6. **`todo`** -- Simple in-memory task tracking. Tiny implementation, helps agent plan multi-step work.
7. **Browser automation** -- Big effort, big payoff, but MCP can cover this in the interim.
