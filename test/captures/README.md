# Behavioral Test Captures

Captured Anthropic API request payloads for behavioral comparison between OpenClaw and PureClaw.

## Directory Structure

```
captures/
├── openclaw/              # Golden baselines from OpenClaw
│   ├── scenario-cold-start.jsonl
│   └── scenario-multi-turn-no-tools.jsonl
├── pureclaw/              # PureClaw captures (generated during testing)
└── README.md
```

## Current Baseline Status

The OpenClaw baselines are **synthetic** — constructed from the documented OpenClaw
request format (see `docs/BEHAVIORAL_TEST_PLAN.md` Section 1). They represent the
*expected* structure and content, but have not yet been captured from a live OpenClaw
instance.

**To capture real baselines**, the OpenClaw gateway must be running with device pairing
configured. See the commands below.

## Capturing Real OpenClaw Baselines

### Prerequisites

1. OpenClaw gateway running: `openclaw gateway --bind loopback`
2. Gateway paired (device auth configured)
3. `behavioral-test` agent registered (see below)
4. Mock provider running on port 9998

### Agent Setup

```bash
# Register the agent (if not already done)
openclaw agents add behavioral-test
# The interactive wizard will ask for workspace path — use the fixture:
#   Workspace: ~/.openclaw/workspace-behavioral-test

# Copy fixture files
cp test/fixtures/workspace-minimal/*.md ~/.openclaw/workspace-behavioral-test/

# Configure mock provider in agent models.json
cat > ~/.openclaw/agents/behavioral-test/agent/models.json << 'EOF'
{
  "providers": {
    "mock": {
      "baseUrl": "http://127.0.0.1:9998",
      "apiKey": "sk-ant-test-placeholder",
      "auth": "api-key",
      "api": "anthropic",
      "models": [{
        "id": "claude-sonnet-4-20250514",
        "name": "Claude Sonnet 4 (Mock)",
        "reasoning": false,
        "input": ["text"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 200000,
        "maxTokens": 8192
      }]
    }
  }
}
EOF

# Set the agent's model to the mock provider
openclaw config set agents.list.behavioral-test.model.primary mock/claude-sonnet-4-20250514
```

### Capturing Scenarios

```bash
# Start mock provider
python3 tools/mock-provider.py --port 9998 --log /tmp/capture.jsonl &

# Scenario 1: Cold Start
> /tmp/capture.jsonl
openclaw agent --agent behavioral-test \
    --message "Hello, who are you?" \
    --session-id "capture-cold-start" \
    --timeout 30 --json
cp /tmp/capture.jsonl test/captures/openclaw/scenario-cold-start.jsonl

# Scenario 2: Multi-Turn (3 turns)
> /tmp/capture.jsonl
SID="capture-multi-turn-$$"
openclaw agent --agent behavioral-test --message "What is 2+2?" --session-id "$SID" --timeout 30 --json
openclaw agent --agent behavioral-test --message "What did I just ask?" --session-id "$SID" --timeout 30 --json
openclaw agent --agent behavioral-test --message "Summarize our conversation." --session-id "$SID" --timeout 30 --json
cp /tmp/capture.jsonl test/captures/openclaw/scenario-multi-turn-no-tools.jsonl
```

### Using the Capture Script

```bash
# Automated capture (requires gateway + pairing)
./test/scripts/capture-scenario.sh cold-start openclaw
./test/scripts/capture-scenario.sh multi-turn-no-tools openclaw
```

## Comparing Captures

```bash
# Self-comparison (sanity check — should always pass)
python3 tools/compare-requests.py \
    --openclaw test/captures/openclaw/scenario-cold-start.jsonl \
    --scenario cold-start

# Cross-comparison (once PureClaw captures exist)
python3 tools/compare-requests.py \
    --openclaw test/captures/openclaw/scenario-cold-start.jsonl \
    --pureclaw test/captures/pureclaw/scenario-cold-start.jsonl \
    --scenario cold-start
```
