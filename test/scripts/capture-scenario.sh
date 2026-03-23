#!/usr/bin/env bash
#
# capture-scenario.sh — Run a behavioral test scenario and capture the LLM request.
#
# Sets up the workspace-minimal fixture, points the agent at the mock provider,
# runs one or more conversation turns, and saves the captured request JSONL.
#
# Usage:
#   ./test/scripts/capture-scenario.sh <scenario-name> <system> [options]
#
# Arguments:
#   scenario-name   Scenario identifier (e.g., "cold-start", "multi-turn-no-tools")
#   system          Which agent runtime: "openclaw" or "pureclaw"
#
# Options:
#   --port PORT     Mock provider port (default: 9998)
#   --mock-response TEXT  Canned response text (default: MOCK_RESPONSE)
#   --no-start-mock Don't start a mock provider (assume one is already running)
#   --agent AGENT   OpenClaw agent name (default: behavioral-test)
#   --dry-run       Print commands without executing
#
# Output:
#   test/captures/<system>/scenario-<name>.jsonl
#
# Prerequisites:
#   - python3 available
#   - For openclaw: openclaw CLI installed, test profile set up
#   - For pureclaw: pureclaw binary built
#
# Examples:
#   ./test/scripts/capture-scenario.sh cold-start openclaw
#   ./test/scripts/capture-scenario.sh multi-turn-no-tools openclaw --no-start-mock
#   ./test/scripts/capture-scenario.sh cold-start pureclaw

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$PROJECT_ROOT/test/fixtures/workspace-minimal"
MOCK_SCRIPT="$PROJECT_ROOT/tools/mock-provider.py"
SCENARIOS_DIR="$PROJECT_ROOT/test/scripts/scenarios"

# Defaults
MOCK_PORT=9998
MOCK_RESPONSE="MOCK_RESPONSE"
START_MOCK=true
AGENT_NAME="behavioral-test"
DRY_RUN=false

# --- Argument parsing ---

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <scenario-name> <system> [options]" >&2
    echo "  system: openclaw | pureclaw" >&2
    exit 1
fi

SCENARIO_NAME="$1"
SYSTEM="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)       MOCK_PORT="$2"; shift 2 ;;
        --mock-response) MOCK_RESPONSE="$2"; shift 2 ;;
        --no-start-mock) START_MOCK=false; shift ;;
        --agent)      AGENT_NAME="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$SYSTEM" != "openclaw" && "$SYSTEM" != "pureclaw" ]]; then
    echo "Error: system must be 'openclaw' or 'pureclaw', got '$SYSTEM'" >&2
    exit 1
fi

CAPTURE_DIR="$PROJECT_ROOT/test/captures/$SYSTEM"
CAPTURE_FILE="$CAPTURE_DIR/scenario-${SCENARIO_NAME}.jsonl"
MOCK_LOG="/tmp/behavioral-test-mock-$$.jsonl"

mkdir -p "$CAPTURE_DIR"

# --- Cleanup ---

MOCK_PID=""
cleanup() {
    if [[ -n "$MOCK_PID" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    rm -f "$MOCK_LOG"
}
trap cleanup EXIT

# --- Helper functions ---

log() { echo "[capture] $*" >&2; }

run_cmd() {
    if $DRY_RUN; then
        echo "[dry-run] $*" >&2
    else
        "$@"
    fi
}

start_mock() {
    log "Starting mock provider on port $MOCK_PORT..."
    python3 "$MOCK_SCRIPT" \
        --port "$MOCK_PORT" \
        --log "$MOCK_LOG" \
        --response "$MOCK_RESPONSE" &
    MOCK_PID=$!
    # Wait for the mock to be ready
    for i in $(seq 1 20); do
        if curl -s "http://127.0.0.1:$MOCK_PORT" >/dev/null 2>&1; then
            log "Mock provider ready (PID $MOCK_PID)"
            return 0
        fi
        sleep 0.1
    done
    echo "Error: mock provider did not start within 2 seconds" >&2
    exit 1
}

# --- Scenario definitions ---
#
# Each scenario function sends messages and the mock captures the requests.
# The scenario functions receive the system type as $1.

scenario_cold_start() {
    local sys="$1"
    log "Scenario: cold-start (single message, no history)"

    if [[ "$sys" == "openclaw" ]]; then
        run_cmd openclaw agent \
            --local \
            --agent "$AGENT_NAME" \
            --message "Hello, who are you?" \
            --session-id "behavioral-test-cold-start" \
            --json
    else
        log "PureClaw capture not yet implemented"
        return 1
    fi
}

scenario_multi_turn_no_tools() {
    local sys="$1"
    log "Scenario: multi-turn-no-tools (3 turns, no tool use)"

    if [[ "$sys" == "openclaw" ]]; then
        local session_id="behavioral-test-multi-turn-$$"

        # Turn 1
        log "  Turn 1: What is 2+2?"
        run_cmd openclaw agent \
            --local \
            --agent "$AGENT_NAME" \
            --message "What is 2+2?" \
            --session-id "$session_id" \
            --json

        # Turn 2
        log "  Turn 2: What did I just ask?"
        run_cmd openclaw agent \
            --local \
            --agent "$AGENT_NAME" \
            --message "What did I just ask?" \
            --session-id "$session_id" \
            --json

        # Turn 3
        log "  Turn 3: Summarize our conversation."
        run_cmd openclaw agent \
            --local \
            --agent "$AGENT_NAME" \
            --message "Summarize our conversation." \
            --session-id "$session_id" \
            --json
    else
        log "PureClaw capture not yet implemented"
        return 1
    fi
}

# --- Workspace setup ---

setup_openclaw_workspace() {
    local workspace_dir="$HOME/.openclaw/workspace-${AGENT_NAME}"

    if [[ -d "$workspace_dir" ]]; then
        log "Workspace already exists: $workspace_dir"
    else
        log "Creating workspace: $workspace_dir"
        mkdir -p "$workspace_dir"
    fi

    # Copy fixture files into the workspace
    log "Copying fixture files to workspace..."
    cp "$FIXTURES_DIR"/SOUL.md "$workspace_dir/"
    cp "$FIXTURES_DIR"/AGENTS.md "$workspace_dir/"
    cp "$FIXTURES_DIR"/MEMORY.md "$workspace_dir/"
    cp "$FIXTURES_DIR"/USER.md "$workspace_dir/"
    cp "$FIXTURES_DIR"/IDENTITY.md "$workspace_dir/"
    log "Workspace ready: $workspace_dir"
}

# --- Main ---

log "Scenario: $SCENARIO_NAME"
log "System:   $SYSTEM"
log "Output:   $CAPTURE_FILE"

# Start mock if needed
if $START_MOCK; then
    start_mock
fi

# Set up workspace
if [[ "$SYSTEM" == "openclaw" ]]; then
    setup_openclaw_workspace

    # Check if agent exists, create if not
    if ! openclaw agents list 2>/dev/null | grep -q "$AGENT_NAME"; then
        log "Creating agent: $AGENT_NAME"
        run_cmd openclaw agents add "$AGENT_NAME" 2>/dev/null || true
    fi
fi

# Point the agent at the mock provider
export ANTHROPIC_BASE_URL="http://127.0.0.1:$MOCK_PORT"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-test-placeholder}"

# Remove any prior capture for this scenario
rm -f "$MOCK_LOG"
touch "$MOCK_LOG"

# Run the scenario
log "Running scenario..."
case "$SCENARIO_NAME" in
    cold-start)
        scenario_cold_start "$SYSTEM"
        ;;
    multi-turn-no-tools)
        scenario_multi_turn_no_tools "$SYSTEM"
        ;;
    *)
        # Check for a scenario script in the scenarios directory
        if [[ -f "$SCENARIOS_DIR/${SCENARIO_NAME}.sh" ]]; then
            # shellcheck disable=SC1090
            source "$SCENARIOS_DIR/${SCENARIO_NAME}.sh"
            "scenario_${SCENARIO_NAME//-/_}" "$SYSTEM"
        else
            echo "Error: unknown scenario '$SCENARIO_NAME'" >&2
            echo "Available: cold-start, multi-turn-no-tools" >&2
            echo "Or add a script at: $SCENARIOS_DIR/${SCENARIO_NAME}.sh" >&2
            exit 1
        fi
        ;;
esac

# Copy the mock's log to the capture file
if [[ -f "$MOCK_LOG" ]]; then
    cp "$MOCK_LOG" "$CAPTURE_FILE"
    LINES=$(wc -l < "$CAPTURE_FILE" | tr -d ' ')
    log "Captured $LINES request(s) → $CAPTURE_FILE"
else
    echo "Warning: no capture file produced" >&2
    exit 1
fi

log "Done."
