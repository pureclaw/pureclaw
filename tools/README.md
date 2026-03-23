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

**Compare** — diff the two capture files (Phase 4 will add `tools/compare-requests.py`):

```bash
# For now, manual inspection:
cat openclaw-capture.jsonl | python3 -m json.tool
cat pureclaw-capture.jsonl | python3 -m json.tool
```

## Test Fixtures

Workspace fixtures for behavioral test scenarios live in `test/fixtures/`:

- `workspace-minimal/` — 5 files (SOUL.md, AGENTS.md, MEMORY.md, USER.md, IDENTITY.md)
  providing a stable, known baseline for all test scenarios.
