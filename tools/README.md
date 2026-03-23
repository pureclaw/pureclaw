# Behavioral Test Tools

Capture infrastructure for comparing LLM requests between OpenClaw and PureClaw.
See `docs/BEHAVIORAL_TEST_PLAN.md` for the full plan.

## proxy.py — Logging Proxy

Transparent HTTP proxy that logs the full Anthropic API request body as JSONL,
then forwards to the real API and returns the response.

```bash
# Start the proxy (defaults: port 9999, log to captures.jsonl)
python3 tools/proxy.py

# Custom port and log file
python3 tools/proxy.py --port 9999 --log test/captures/session.jsonl

# Custom upstream (e.g. for chaining with another proxy)
python3 tools/proxy.py --upstream https://custom-api.example.com
```

Point your client at the proxy:

```bash
# OpenClaw
export ANTHROPIC_BASE_URL=http://localhost:9999

# PureClaw
export PURECLAW_ANTHROPIC_BASE_URL=http://localhost:9999
```

Each request is logged as one JSONL line with a `ts` timestamp prepended:

```json
{"ts":"2026-03-22T12:00:00Z","model":"claude-sonnet-4-6","system":"...","messages":[...],"tools":[...]}
```

## mock-provider.py — Mock Anthropic API

Returns a canned assistant response without hitting the real API.
Logs requests in the same JSONL format as the proxy, so captures are
directly comparable.

```bash
# Start the mock (defaults: port 9998, log to mock-captures.jsonl)
python3 tools/mock-provider.py

# Custom response text
python3 tools/mock-provider.py --response "I am a test response"

# Custom port and log
python3 tools/mock-provider.py --port 9998 --log test/captures/mock.jsonl
```

The mock handles both streaming (`"stream": true`) and non-streaming requests.
Streaming responses use Anthropic's SSE format (`event:` + `data:` lines).

## Typical Workflow

**Cost-free development** — use the mock to capture what PureClaw sends:

```bash
python3 tools/mock-provider.py --log pureclaw-capture.jsonl &
export PURECLAW_ANTHROPIC_BASE_URL=http://localhost:9998
# run PureClaw scenario...
```

**Live validation** — use the proxy to capture real OpenClaw requests:

```bash
python3 tools/proxy.py --log openclaw-capture.jsonl &
export ANTHROPIC_BASE_URL=http://localhost:9999
# run OpenClaw scenario...
```

**Compare** — diff the two capture files:

```bash
python3 tools/compare-requests.py \
    --openclaw openclaw-capture.jsonl \
    --pureclaw pureclaw-capture.jsonl \
    --scenario cold-start
```

## compare-requests.py — Normalization + Structured Diff

Compares captured Anthropic API requests between OpenClaw and PureClaw.
Applies normalization rules (timestamps, tool IDs, UUIDs, paths, tokens)
then produces a structured diff with pass/fail per field.

```bash
# Cross-comparison
python3 tools/compare-requests.py \
    --openclaw test/captures/openclaw/scenario-cold-start.jsonl \
    --pureclaw test/captures/pureclaw/scenario-cold-start.jsonl \
    --scenario cold-start

# Self-comparison (sanity check — omit --pureclaw)
python3 tools/compare-requests.py \
    --openclaw test/captures/openclaw/scenario-cold-start.jsonl \
    --scenario cold-start

# Compare only a specific turn (1-indexed)
python3 tools/compare-requests.py \
    --openclaw test/captures/openclaw/scenario-multi-turn-no-tools.jsonl \
    --pureclaw test/captures/pureclaw/scenario-multi-turn-no-tools.jsonl \
    --turn 3 --scenario multi-turn

# Machine-readable JSON output
python3 tools/compare-requests.py \
    --openclaw openclaw.jsonl --pureclaw pureclaw.jsonl \
    --scenario cold-start --json
```

**Normalization rules applied** (Section 4 of the behavioral test plan):
- `tool_use_id` → `TOOL_ID_<N>`
- UUIDs → `SESSION_UUID`
- Message IDs → `MSG_ID_<N>`
- ISO timestamps → `TIMESTAMP_PLACEHOLDER`
- `## Current Date & Time` block → `DATE_TIME_PLACEHOLDER`
- `## Runtime` line → `RUNTIME_PLACEHOLDER`
- API tokens → `REDACTED_TOKEN`
- Workspace paths → `WORKSPACE_ROOT`
- Trailing whitespace stripped, newlines normalized

**Output fields**: `system` (unified diff), `messages` (structural diff),
`tools` (set diff — missing/extra tools + schema diffs), `other` (model, max_tokens, etc.)


## Test Fixtures

Workspace fixtures for behavioral test scenarios live in `test/fixtures/`:

- `workspace-minimal/` — 5 files (SOUL.md, AGENTS.md, MEMORY.md, USER.md, IDENTITY.md)
  providing a stable, known baseline for all test scenarios.
