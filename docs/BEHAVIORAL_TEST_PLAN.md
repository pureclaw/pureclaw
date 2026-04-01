# OpenClaw Behavioral Test Plan

**Goal:** Verify that PureClaw constructs identical (or deliberately-different) LLM requests compared to OpenClaw — covering system prompt, workspace file injection, message history structure, tool definitions, and tool result formatting.

**Core principle:** We do not test LLM *outputs* (stochastic, unreliable). We test LLM *inputs* (deterministic, diffable). If the JSON payloads sent to the provider are equivalent, behavior will be equivalent.

---

## 1. OpenClaw Internals: What Gets Sent to the LLM

Understanding what OpenClaw stores and how it assembles prompts is prerequisite to knowing what to test.

### 1.1 State Layout (`~/.openclaw/`)

```
~/.openclaw/
├── openclaw.json               # Main config: browser, auth profiles, model providers, features
├── identity/
│   ├── device.json             # Ed25519 device keypair + deviceId
│   └── device-auth.json        # Gateway auth token
├── agents/<agent-name>/
│   ├── agent/
│   │   ├── auth-profiles.json  # Per-agent API tokens (Anthropic OAuth token, etc.)
│   │   └── models.json         # Per-agent model provider overrides
│   └── sessions/
│       └── <uuid>.jsonl        # Session transcripts (JSONL, one record per event)
├── memory/
│   └── main.sqlite             # SQLite memory store (for memory_search / memory_get tools)
├── cron/
│   ├── jobs.json               # Cron job definitions
│   └── runs/                   # Per-job run history
├── delivery-queue/
│   └── <uuid>.json             # Pending outbound messages (to Signal, Telegram, etc.)
├── subagents/
│   └── runs.json               # Sub-agent run tracking
└── workspace[-<agent>]/        # Workspace files per agent
    ├── SOUL.md                 # Agent persona / identity
    ├── AGENTS.md               # Session startup rules, team structure
    ├── MEMORY.md               # Long-term memory index
    ├── IDENTITY.md             # Name, emoji, contact info
    ├── USER.md                 # About the human
    ├── HEARTBEAT.md            # Heartbeat behavior config
    └── TOOLS.md                # Local tool notes
```

### 1.2 Session JSONL Structure

Each session is a JSONL file with typed records:

```jsonl
{"type":"session","version":3,"id":"<uuid>","timestamp":"...","cwd":"..."}
{"type":"message","id":"...","parentId":null,"timestamp":"...",
  "message":{"role":"assistant","content":[{"type":"text","text":"..."}],
    "api":"openai-responses","provider":"openclaw","model":"delivery-mirror",
    "usage":{...},"stopReason":"stop","timestamp":...}}
{"type":"thinking_level_change","id":"...","parentId":"...","thinkingLevel":"medium"}
{"type":"tool_call","id":"...","parentId":"...","tool":"exec","input":{...}}
{"type":"tool_result","id":"...","parentId":"...","output":"...","exitCode":0}
```

### 1.3 How OpenClaw Constructs the LLM Request

The request to the Anthropic Messages API is assembled from multiple layers:

**System prompt (assembled in order):**
1. Static base system prompt (runtime description, tool availability policy, safety rules, etc.)
2. Agent persona block (from `SOUL.md` if present)
3. Workspace file injection — each file injected as a labeled section:
   - `AGENTS.md` (session startup rules)
   - `SOUL.md` (persona)
   - `USER.md` (about the human)
   - `MEMORY.md` (long-term memory)
   - `IDENTITY.md`, `HEARTBEAT.md`, `TOOLS.md`
   - Any other `.md` files in workspace root that match injection rules
4. Dynamic runtime block:
   - `## Silent Replies` rules
   - `## Heartbeats` instructions
   - `## Runtime` line (agent ID, host, model, OS, channel, capabilities, thinking mode)
   - `## Current Date & Time`
   - `## Workspace Files (injected)` header
   - Available skills list (from `~/.openclaw/skills/` + workspace `skills/`)
   - Reply tags rules
   - Messaging rules
   - Group chat context (if applicable)
   - `## Inbound Context` (trusted metadata JSON: chat_id, channel, provider, chat_type)

**Messages array:**
- Prior conversation turns from session JSONL
- Tool calls represented as `{"role":"assistant","content":[{"type":"tool_use","id":"...","name":"...","input":{...}}]}`
- Tool results represented as `{"role":"user","content":[{"type":"tool_result","tool_use_id":"...","content":"..."}]}`
- Current user message appended last

**Tool definitions array:**
- One object per available tool
- Schema: `{"name":"...","description":"...","input_schema":{"type":"object","properties":{...},"required":[...]}}`
- Which tools appear depends on: channel (e.g., `message` tool gated on channel having a provider), skill SKILL.md availability, policy filters

---

## 2. Interception Architecture

### 2.1 The Proxy Approach (Recommended)

Run a local HTTP proxy that logs + forwards all requests to Anthropic. Both OpenClaw and PureClaw point to it.

**Setup:**
```bash
# proxy.py — ~30 lines, logs full request body then forwards
python3 proxy.py &  # listens on localhost:9999

# OpenClaw: set in openclaw.json or env
export ANTHROPIC_BASE_URL=http://localhost:9999

# PureClaw: set in config or env
export PURECLAW_ANTHROPIC_BASE_URL=http://localhost:9999
```

**What the proxy logs (per request):**
- Timestamp
- Endpoint path (`/v1/messages`)
- Full request JSON body (system, messages, tools, model, max_tokens, etc.)
- Response (optional, for round-trip verification)

**Log format:** JSONL, one record per request. Each record:
```json
{
  "ts": "2026-03-23T00:10:00Z",
  "system": "<prompt>",
  "messages": [...],
  "tools": [...],
  "model": "claude-sonnet-4-6",
  "max_tokens": 8096
}
```

### 2.2 The Mock Provider Approach (For Deterministic Testing)

Instead of forwarding to Anthropic, the mock returns a canned response (e.g., `{"role":"assistant","content":[{"type":"text","text":"MOCK_RESPONSE"}]}`). This prevents any real API cost during test runs and keeps outputs fully deterministic.

Combine with the proxy: default to mock for development, proxy+forward for live validation.

### 2.3 PureClaw `--dump-request` Flag

Add a flag to PureClaw that writes the request JSON to a file before sending:
```
pureclaw --dump-request /tmp/pureclaw-request.json
```

This gives a second capture path independent of the proxy and is useful for debugging individual sessions.

---

## 3. Test Corpus

A set of standardized scenarios that exercise every prompt-construction code path. Each scenario specifies: workspace state, user input sequence, expected tool calls (if any), and what to verify in the captured request.

### Fixture: Minimal Workspace

A minimal but representative workspace fixture stored at `test/fixtures/workspace-minimal/`:

```
workspace-minimal/
├── SOUL.md      # Short persona (5 lines)
├── AGENTS.md    # Minimal startup rules
├── MEMORY.md    # Short memory (3 entries)
├── USER.md      # User: "TestUser"
└── IDENTITY.md  # Name: TestAgent
```

Used for all scenarios unless otherwise noted. Provides a stable, known baseline.

---

### Scenario 1: Cold Start — Single Message

**Purpose:** Verify base system prompt construction and workspace file injection order.

**Input:**
```
User: Hello, who are you?
```

**Session state:** No prior history.

**What to verify in captured request:**
- `system` field contains all 5 workspace files (SOUL.md, AGENTS.md, MEMORY.md, USER.md, IDENTITY.md)
- Files appear under their expected section headers
- Runtime block present (date/time, model name, channel)
- Inbound context block present with correct `chat_type`
- `messages` array has exactly 1 entry (the user message)
- `tools` array is non-empty and contains expected core tools (exec, read, write, edit, web_search, memory_search, etc.)

**Diff focus:** System prompt content and structure.

---

### Scenario 2: Multi-Turn Conversation (No Tools)

**Purpose:** Verify message history accumulation and formatting.

**Input (3 turns):**
```
Turn 1 — User: What is 2+2?
Turn 1 — Assistant: 4
Turn 2 — User: What did I just ask?
Turn 2 — Assistant: You asked what 2+2 is.
Turn 3 — User: Summarize our conversation.
```

**What to verify:**
- `messages` array has 4 entries before turn 3 request (2 user + 2 assistant)
- Roles are correctly alternating: user → assistant → user → assistant
- Content blocks are `{"type":"text","text":"..."}` for plain text
- System prompt is identical to Scenario 1 (no variation from history)

---

### Scenario 3: Tool Call + Result

**Purpose:** Verify tool use/result pair formatting in the messages array.

**Input:**
```
User: What files are in /tmp?
```

**Expected behavior:** Agent calls `exec` tool with `ls /tmp`, receives result, replies.

**What to verify in the turn-3 request (after tool use):**
- Turn 2 assistant message has `content: [{"type":"tool_use","id":"<id>","name":"exec","input":{"command":"ls /tmp"}}]`
- Turn 3 user message has `content: [{"type":"tool_result","tool_use_id":"<id>","content":"<output>"}]`
- `tool_use_id` in tool_result matches `id` in tool_use
- No extra fields, no wrapping

---

### Scenario 4: Multiple Tools in One Turn

**Purpose:** Verify parallel tool call formatting (when agent calls multiple tools simultaneously).

**Input:**
```
User: Read /tmp/a.txt and /tmp/b.txt
```

**Expected behavior:** Agent calls `read` twice in one assistant turn (parallel).

**What to verify:**
- Single assistant message with `content` array containing 2 `tool_use` blocks
- Each has a unique `id`
- Followed by a user message with 2 `tool_result` blocks, each referencing the correct `tool_use_id`

---

### Scenario 5: Workspace File with Special Characters

**Purpose:** Verify workspace file content is not escaped, truncated, or mangled during injection.

**Fixture:** Modify `SOUL.md` in the fixture to include:
- Unicode characters (emoji, CJK)
- Code blocks with backticks
- Nested markdown headers
- A line matching a known pattern we can grep for

**What to verify:**
- The specific test strings appear verbatim in the system prompt
- No HTML entity encoding, no backslash-escaping, no truncation

---

### Scenario 6: Tool Definitions — Schema Completeness

**Purpose:** Verify all expected tools appear with correct schemas.

**Input:** (any single message, doesn't matter — just need the tools array)

**What to verify:**
- Core tools all present: `exec`, `read`, `write`, `edit`, `web_search`, `web_fetch`, `memory_search`, `memory_get`, `message`, `session_status`, `sessions_spawn`, `sessions_list`, `sessions_history`, `sessions_send`, `subagents`, `image`, `pdf`, `tts`, `voice_call`, `canvas`, `browser`, `process`, `agents_list`
- Each tool has: `name`, `description`, `input_schema` with `type: "object"` and `properties`
- Required fields correctly specified
- No duplicate tool names

---

### Scenario 7: Channel-Gated Tools

**Purpose:** Verify that tool availability varies correctly by channel.

**Sub-scenario A:** Channel = `telegram` → `message` tool should be present  
**Sub-scenario B:** Channel = `signal` → `message` tool should be present  
**Sub-scenario C:** No channel (CLI direct) → `message` tool should be absent (or present but gated)

**What to verify:** `tools` array differs between sub-scenarios in the expected way.

---

### Scenario 8: Skills Injection

**Purpose:** Verify that available skills appear in the system prompt.

**Setup:** Place a test skill at `workspace-minimal/skills/test-skill/SKILL.md`:
```yaml
---
name: test-skill
description: A test skill for behavioral testing
---
# Test Skill
Do something with the test-skill tool.
```

**What to verify:**
- `## Available Skills` section in system prompt includes the test-skill entry
- Description appears correctly
- Location path is correct

---

### Scenario 9: Inbound Context Metadata

**Purpose:** Verify that trusted inbound context (chat_id, channel, provider, chat_type) is injected correctly.

**Setup:** Simulate different inbound contexts:
- Telegram direct: `{"channel":"telegram","chat_type":"direct","chat_id":"telegram:12345"}`
- Telegram group: `{"channel":"telegram","chat_type":"group","chat_id":"telegram:-99999"}`
- Signal direct: `{"channel":"signal","chat_type":"direct"}`

**What to verify:**
- `## Inbound Context` block in system prompt contains the correct JSON
- `chat_type` is correct for each variant
- Group chat context block is present/absent depending on chat_type

---

### Scenario 10: Context Compaction / Long History

**Purpose:** Verify that when session history is long, compaction produces a valid summary that fits within context limits, and the messages array structure after compaction is correct.

**Setup:** Inject 100+ synthetic turns into the session history to force compaction.

**What to verify:**
- Messages array before compaction: raw turns
- Messages array after compaction: summary block + recent uncompacted turns
- Total token count stays within model context limit
- No turns dropped without being summarized

*Note: This scenario is more complex to automate — may start as manual/semi-manual.*

---

## 4. Normalization Rules

Before diffing OpenClaw and PureClaw requests, apply these normalizations to eliminate legitimate non-semantic differences:

| Field / Pattern | Normalization |
|----------------|---------------|
| `tool_use_id` values | Replace with `TOOL_ID_<N>` (sequential, matched by position) |
| Session UUIDs | Replace with `SESSION_UUID` |
| Message IDs | Replace with `MSG_ID_<N>` |
| Timestamps (ISO 8601 in system prompt) | Replace with `TIMESTAMP_PLACEHOLDER` |
| `## Current Date & Time` block | Replace content with `DATE_TIME_PLACEHOLDER` |
| `## Runtime` line | Normalize model name, strip session-specific parts |
| `## Inbound Context` → `"message_id"` | Replace with `MSG_ID` |
| API token values | Replace with `REDACTED_TOKEN` |
| Absolute file paths in injected content | Replace `~/.openclaw/workspace` with `WORKSPACE_ROOT` |
| Tool descriptions that reference local paths | Normalize paths |
| Newline style | Normalize to `\n` |
| Trailing whitespace | Strip |

After normalization, the two files should be identical if behavior is equivalent. Any remaining diff is a real discrepancy to investigate.

---

## 5. Comparison Tool

A small Haskell or Python script (`tools/compare-requests.py`) that:

1. Takes two JSONL capture files (OpenClaw and PureClaw)
2. Applies normalization to each request pair
3. Produces a structured diff for each field:
   - `system`: character-level diff with context
   - `messages`: structural diff (role/type matches, content diff per block)
   - `tools`: set-level diff (missing/extra tools, schema diffs per tool)
4. Outputs a pass/fail summary per scenario

**Usage:**
```bash
python3 tools/compare-requests.py \
  --openclaw test/captures/scenario-1-openclaw.jsonl \
  --pureclaw test/captures/scenario-1-pureclaw.jsonl \
  --scenario "cold-start-single-message"
```

---

## 6. Implementation Plan

### Phase 1 — Capture Infrastructure (1-2 days)

- [ ] Write `tools/proxy.py`: HTTPS-transparent logging proxy (~30 lines Python)
- [ ] Write `tools/mock-provider.py`: returns canned Anthropic response, logs request
- [ ] Add `--dump-request <path>` flag to PureClaw binary
- [ ] Verify proxy intercepts OpenClaw correctly (test with `curl`)
- [ ] Verify proxy intercepts PureClaw correctly

### Phase 2 — Fixture + Capture (1 day)

- [ ] Create `test/fixtures/workspace-minimal/` with all 5 files
- [ ] Write `test/scripts/capture-scenario.sh`: sets up workspace, runs agent, captures to JSONL
- [ ] Manually capture all 10 scenarios from OpenClaw → `test/captures/openclaw/`
- [ ] Note: OpenClaw captures are the **golden baseline**

### Phase 3 — PureClaw Gaps (ongoing)

- [ ] Run all 10 scenarios through PureClaw (as each scenario's features are implemented)
- [ ] Capture to `test/captures/pureclaw/`
- [ ] Run comparison tool, log discrepancies

### Phase 4 — Comparison Tool (1 day)

- [ ] Write `tools/compare-requests.py` with normalization + structured diff
- [ ] Add to `Makefile`: `make test-behavioral` runs all scenario comparisons
- [ ] Green on Scenario 1 first (simplest), expand from there

### Phase 5 — CI Integration (after Phase 4 stable)

- [ ] Add behavioral test step to GitHub Actions: run mock provider + compare
- [ ] Scenarios 1–6 automated (deterministic tool-less or with mock tool results)
- [ ] Scenarios 7–10 as manual/semi-manual initially

---

## 7. Known Intentional Differences

Some differences between OpenClaw and PureClaw are *deliberate design choices*, not bugs. Document them here to avoid false positives in the comparison tool.

| Area | OpenClaw | PureClaw | Reason |
|------|----------|----------|--------|
| Tool definition order | Undefined | Alphabetical | PureClaw sorts for determinism |
| `model` in request | From config | From config | Should match; diff is a bug |
| Auth header | OAuth token (`sk-ant-oat01-...`) | API key (`sk-ant-api03-...`) | Different auth flow |
| Skills section | OpenClaw format | TBD | May simplify |
| Context injection format | `## FileName.md\n<content>` | TBD | Should match exactly |

This table grows as implementation proceeds. Each intentional difference must be explicitly documented with a rationale.

---

## 8. Reference: Anthropic Messages API Shape

The canonical request PureClaw must match:

```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 8096,
  "system": "<assembled system prompt>",
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "..."}]},
    {"role": "assistant", "content": [
      {"type": "text", "text": "..."},
      {"type": "tool_use", "id": "toolu_01...", "name": "exec", "input": {"command": "ls"}}
    ]},
    {"role": "user", "content": [
      {"type": "tool_result", "tool_use_id": "toolu_01...", "content": "file1\nfile2"}
    ]}
  ],
  "tools": [
    {
      "name": "exec",
      "description": "Execute shell commands...",
      "input_schema": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "Shell command to execute"},
          "timeout": {"type": "number", "description": "Timeout in seconds"}
        },
        "required": ["command"]
      }
    }
  ],
  "stream": true,
  "thinking": {"type": "enabled", "budget_tokens": 8000}
}
```

Streaming and thinking parameters may vary by model and session config — normalize these when comparing.
