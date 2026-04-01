#!/usr/bin/env python3
"""Compare captured Anthropic API requests between OpenClaw and PureClaw.

Applies normalization rules (Section 4 of the behavioral test plan) to
eliminate legitimate non-semantic differences, then produces a structured
diff with pass/fail per field.

Usage:
    python3 tools/compare-requests.py \\
        --openclaw test/captures/openclaw/scenario-cold-start.jsonl \\
        --pureclaw test/captures/pureclaw/scenario-cold-start.jsonl \\
        --scenario cold-start

    python3 tools/compare-requests.py \\
        --openclaw test/captures/openclaw/scenario-cold-start.jsonl \\
        --pureclaw test/captures/pureclaw/scenario-cold-start.jsonl \\
        --turn 1          # Compare only the Nth request (1-indexed)

    python3 tools/compare-requests.py \\
        --openclaw test/captures/openclaw/scenario-cold-start.jsonl \\
        --pureclaw test/captures/pureclaw/scenario-cold-start.jsonl \\
        --json            # Machine-readable output
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Normalization (Section 4 of the behavioral test plan)
# ---------------------------------------------------------------------------

# Matches Anthropic tool_use IDs:  toolu_01... or similar
_TOOL_ID_RE = re.compile(r"toolu_[A-Za-z0-9]{20,}")

# UUIDs (v4 format: 8-4-4-4-12 hex)
_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)

# ISO 8601 timestamps: 2026-03-22T12:00:00Z or with fractional seconds/offset
_ISO_TS_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?"
    r"(?:Z|[+-]\d{2}:\d{2})"
)

# Message IDs: msg_<hex> (Anthropic format)
_MSG_ID_RE = re.compile(r"msg_[A-Za-z0-9]{20,}")

# API tokens / keys
_TOKEN_RE = re.compile(r"sk-ant-[A-Za-z0-9\-_]{10,}")

# OpenClaw workspace paths
_WORKSPACE_PATH_RE = re.compile(r"~?/[^\s]*\.openclaw/workspace[^\s]*")

# Home directory paths
_HOME_PATH_RE = re.compile(r"/(?:Users|home)/[^/\s]+/")

# Date/time block in system prompt
_DATETIME_BLOCK_RE = re.compile(
    r"(## Current Date & Time\s*\n).*?(?=\n##|\Z)",
    re.DOTALL,
)

# Runtime line in system prompt
_RUNTIME_LINE_RE = re.compile(r"(## Runtime\s*\n).*?(?=\n##|\Z)", re.DOTALL)


def normalize_string(s: str) -> str:
    """Apply text-level normalizations to a string."""
    # Normalize newlines
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    # Strip trailing whitespace per line
    s = "\n".join(line.rstrip() for line in s.split("\n"))

    # Replace date/time blocks
    s = _DATETIME_BLOCK_RE.sub(r"\1DATE_TIME_PLACEHOLDER", s)
    # Replace runtime lines
    s = _RUNTIME_LINE_RE.sub(r"\1RUNTIME_PLACEHOLDER", s)
    # Replace ISO timestamps
    s = _ISO_TS_RE.sub("TIMESTAMP_PLACEHOLDER", s)
    # Replace workspace paths
    s = _WORKSPACE_PATH_RE.sub("WORKSPACE_ROOT", s)
    # Replace home directory paths
    s = _HOME_PATH_RE.sub("/HOME/", s)
    # Replace API tokens
    s = _TOKEN_RE.sub("REDACTED_TOKEN", s)

    return s


def normalize_ids(obj: Any, tool_id_counter: list[int] | None = None,
                  msg_id_counter: list[int] | None = None) -> Any:
    """Recursively normalize tool_use_ids, message IDs, and UUIDs in a JSON structure."""
    if tool_id_counter is None:
        tool_id_counter = [0]
    if msg_id_counter is None:
        msg_id_counter = [0]

    # Track ID mappings for consistency within a single request
    if not hasattr(normalize_ids, "_id_map"):
        normalize_ids._id_map = {}  # type: ignore[attr-defined]

    if isinstance(obj, str):
        # Tool IDs
        def replace_tool_id(m: re.Match) -> str:
            original = m.group(0)
            if original not in normalize_ids._id_map:  # type: ignore[attr-defined]
                normalize_ids._id_map[original] = f"TOOL_ID_{tool_id_counter[0]}"  # type: ignore[attr-defined]
                tool_id_counter[0] += 1
            return normalize_ids._id_map[original]  # type: ignore[attr-defined]
        obj = _TOOL_ID_RE.sub(replace_tool_id, obj)

        # Message IDs
        def replace_msg_id(m: re.Match) -> str:
            original = m.group(0)
            if original not in normalize_ids._id_map:  # type: ignore[attr-defined]
                normalize_ids._id_map[original] = f"MSG_ID_{msg_id_counter[0]}"  # type: ignore[attr-defined]
                msg_id_counter[0] += 1
            return normalize_ids._id_map[original]  # type: ignore[attr-defined]
        obj = _MSG_ID_RE.sub(replace_msg_id, obj)

        # UUIDs
        obj = _UUID_RE.sub("SESSION_UUID", obj)

        # Timestamps and other string normalizations
        obj = normalize_string(obj)
        return obj

    if isinstance(obj, dict):
        return {k: normalize_ids(v, tool_id_counter, msg_id_counter) for k, v in obj.items()}
    if isinstance(obj, list):
        return [normalize_ids(item, tool_id_counter, msg_id_counter) for item in obj]
    return obj


def normalize_request(req: dict) -> dict:
    """Fully normalize a captured request for comparison."""
    # Reset ID map for each request
    normalize_ids._id_map = {}  # type: ignore[attr-defined]

    # Remove non-semantic fields
    normalized = {k: v for k, v in req.items() if k != "ts"}

    # Normalize all values recursively
    normalized = normalize_ids(normalized)

    # Sort tools by name for deterministic comparison
    if "tools" in normalized and isinstance(normalized["tools"], list):
        normalized["tools"] = sorted(normalized["tools"], key=lambda t: t.get("name", ""))

    return normalized


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def diff_system_prompts(a: str, b: str) -> tuple[bool, list[str]]:
    """Compare system prompts with character-level context diff."""
    if a == b:
        return True, []

    lines_a = a.splitlines(keepends=True)
    lines_b = b.splitlines(keepends=True)
    diff = list(difflib.unified_diff(lines_a, lines_b, fromfile="openclaw", tofile="pureclaw", n=3))
    return False, [line.rstrip("\n") for line in diff]


def diff_messages(a: list, b: list) -> tuple[bool, list[str]]:
    """Structural diff of the messages array."""
    issues: list[str] = []

    if len(a) != len(b):
        issues.append(f"Message count differs: openclaw={len(a)}, pureclaw={len(b)}")

    for i in range(min(len(a), len(b))):
        ma, mb = a[i], b[i]

        # Check role
        if ma.get("role") != mb.get("role"):
            issues.append(f"  msg[{i}] role: openclaw={ma.get('role')!r}, pureclaw={mb.get('role')!r}")

        # Check content blocks
        ca = ma.get("content", [])
        cb = mb.get("content", [])

        if isinstance(ca, str):
            ca = [{"type": "text", "text": ca}]
        if isinstance(cb, str):
            cb = [{"type": "text", "text": cb}]

        if len(ca) != len(cb):
            issues.append(f"  msg[{i}] content block count: openclaw={len(ca)}, pureclaw={len(cb)}")

        for j in range(min(len(ca), len(cb))):
            ba_, bb = ca[j], cb[j]
            if ba_.get("type") != bb.get("type"):
                issues.append(f"  msg[{i}].content[{j}] type: openclaw={ba_.get('type')!r}, pureclaw={bb.get('type')!r}")
            elif ba_ != bb:
                # Same type but different content — show a compact diff
                sa = json.dumps(ba_, indent=2, sort_keys=True)
                sb = json.dumps(bb, indent=2, sort_keys=True)
                diff = list(difflib.unified_diff(
                    sa.splitlines(), sb.splitlines(),
                    fromfile=f"openclaw msg[{i}].content[{j}]",
                    tofile=f"pureclaw msg[{i}].content[{j}]",
                    n=2,
                ))
                if diff:
                    issues.extend(diff)

    passed = len(issues) == 0
    return passed, issues


def diff_tools(a: list, b: list) -> tuple[bool, list[str]]:
    """Set-level diff of the tools array."""
    issues: list[str] = []

    names_a = {t["name"] for t in a if "name" in t}
    names_b = {t["name"] for t in b if "name" in t}

    only_a = names_a - names_b
    only_b = names_b - names_a
    common = names_a & names_b

    if only_a:
        issues.append(f"Tools only in openclaw: {sorted(only_a)}")
    if only_b:
        issues.append(f"Tools only in pureclaw: {sorted(only_b)}")

    # For common tools, compare schemas
    tools_a = {t["name"]: t for t in a if "name" in t}
    tools_b = {t["name"]: t for t in b if "name" in t}

    for name in sorted(common):
        ta = tools_a[name]
        tb = tools_b[name]
        if ta != tb:
            sa = json.dumps(ta, indent=2, sort_keys=True)
            sb = json.dumps(tb, indent=2, sort_keys=True)
            diff = list(difflib.unified_diff(
                sa.splitlines(), sb.splitlines(),
                fromfile=f"openclaw:{name}",
                tofile=f"pureclaw:{name}",
                n=2,
            ))
            if diff:
                issues.append(f"Tool '{name}' schema differs:")
                issues.extend(f"  {line}" for line in diff)

    passed = len(issues) == 0
    return passed, issues


def compare_requests(oc: dict, pc: dict, turn: int) -> dict:
    """Compare a single request pair, returning structured results."""
    results: dict[str, Any] = {"turn": turn, "fields": {}}

    # System prompt
    sys_oc = oc.get("system", "")
    sys_pc = pc.get("system", "")
    passed, diff = diff_system_prompts(sys_oc, sys_pc)
    results["fields"]["system"] = {"pass": passed, "diff": diff}

    # Messages
    msgs_oc = oc.get("messages", [])
    msgs_pc = pc.get("messages", [])
    passed, diff = diff_messages(msgs_oc, msgs_pc)
    results["fields"]["messages"] = {"pass": passed, "diff": diff}

    # Tools
    tools_oc = oc.get("tools", [])
    tools_pc = pc.get("tools", [])
    passed, diff = diff_tools(tools_oc, tools_pc)
    results["fields"]["tools"] = {"pass": passed, "diff": diff}

    # Other top-level fields (model, max_tokens, stream, thinking, etc.)
    other_issues: list[str] = []
    skip_keys = {"system", "messages", "tools", "ts"}
    all_keys = set(oc.keys()) | set(pc.keys())
    for key in sorted(all_keys - skip_keys):
        val_oc = oc.get(key)
        val_pc = pc.get(key)
        if val_oc != val_pc:
            other_issues.append(f"{key}: openclaw={json.dumps(val_oc)}, pureclaw={json.dumps(val_pc)}")
    results["fields"]["other"] = {"pass": len(other_issues) == 0, "diff": other_issues}

    results["pass"] = all(f["pass"] for f in results["fields"].values())
    return results


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

_PASS = "\033[32mPASS\033[0m"
_FAIL = "\033[31mFAIL\033[0m"


def print_results(results: list[dict], scenario: str) -> bool:
    """Print human-readable comparison results. Returns True if all passed."""
    all_passed = True

    print(f"\n{'=' * 60}")
    print(f"Behavioral Test: {scenario}")
    print(f"{'=' * 60}")

    for r in results:
        turn = r["turn"]
        status = _PASS if r["pass"] else _FAIL
        print(f"\n--- Turn {turn} [{status}] ---")

        for field_name, field in r["fields"].items():
            fs = _PASS if field["pass"] else _FAIL
            print(f"  {field_name}: [{fs}]")
            if not field["pass"] and field["diff"]:
                for line in field["diff"][:50]:  # Cap output
                    print(f"    {line}")
                if len(field["diff"]) > 50:
                    print(f"    ... ({len(field['diff']) - 50} more lines)")

        if not r["pass"]:
            all_passed = False

    print(f"\n{'=' * 60}")
    overall = _PASS if all_passed else _FAIL
    print(f"Overall: [{overall}]  ({len(results)} turn(s) compared)")
    print(f"{'=' * 60}\n")

    return all_passed


def print_json_results(results: list[dict], scenario: str) -> bool:
    """Print machine-readable JSON results. Returns True if all passed."""
    all_passed = all(r["pass"] for r in results)
    output = {
        "scenario": scenario,
        "pass": all_passed,
        "turns": results,
    }
    print(json.dumps(output, indent=2))
    return all_passed


# ---------------------------------------------------------------------------
# Self-comparison mode
# ---------------------------------------------------------------------------

def self_compare(file_path: str, scenario: str, output_json: bool) -> bool:
    """Compare a capture file against itself (sanity check)."""
    with open(file_path) as f:
        lines = [line.strip() for line in f if line.strip()]

    requests = [normalize_request(json.loads(line)) for line in lines]
    results = []
    for i, req in enumerate(requests):
        results.append(compare_requests(req, req, i + 1))

    if output_json:
        return print_json_results(results, scenario)
    return print_results(results, scenario)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare Anthropic API request captures between OpenClaw and PureClaw",
    )
    parser.add_argument("--openclaw", required=True, help="OpenClaw capture JSONL file")
    parser.add_argument("--pureclaw", help="PureClaw capture JSONL file (omit for self-comparison)")
    parser.add_argument("--scenario", default="unknown", help="Scenario name for reporting")
    parser.add_argument("--turn", type=int, help="Compare only the Nth request (1-indexed)")
    parser.add_argument("--json", dest="output_json", action="store_true", help="Machine-readable JSON output")
    args = parser.parse_args()

    # Self-comparison mode: only --openclaw provided
    if not args.pureclaw:
        print(f"Self-comparison mode: {args.openclaw}", file=sys.stderr)
        passed = self_compare(args.openclaw, args.scenario, args.output_json)
        sys.exit(0 if passed else 1)

    # Load captures
    with open(args.openclaw) as f:
        oc_lines = [line.strip() for line in f if line.strip()]
    with open(args.pureclaw) as f:
        pc_lines = [line.strip() for line in f if line.strip()]

    if not oc_lines:
        print(f"Error: {args.openclaw} is empty", file=sys.stderr)
        sys.exit(2)
    if not pc_lines:
        print(f"Error: {args.pureclaw} is empty", file=sys.stderr)
        sys.exit(2)

    # Parse and normalize
    oc_requests = [normalize_request(json.loads(line)) for line in oc_lines]
    pc_requests = [normalize_request(json.loads(line)) for line in pc_lines]

    if len(oc_requests) != len(pc_requests):
        print(
            f"Warning: request count differs: openclaw={len(oc_requests)}, "
            f"pureclaw={len(pc_requests)}. Comparing min({len(oc_requests)}, {len(pc_requests)}) pairs.",
            file=sys.stderr,
        )

    # Filter to specific turn if requested
    if args.turn:
        idx = args.turn - 1
        if idx >= len(oc_requests) or idx >= len(pc_requests):
            print(f"Error: turn {args.turn} out of range", file=sys.stderr)
            sys.exit(2)
        oc_requests = [oc_requests[idx]]
        pc_requests = [pc_requests[idx]]
        start_turn = args.turn
    else:
        start_turn = 1

    # Compare each pair
    results = []
    for i in range(min(len(oc_requests), len(pc_requests))):
        result = compare_requests(oc_requests[i], pc_requests[i], start_turn + i)
        results.append(result)

    # Output
    if args.output_json:
        passed = print_json_results(results, args.scenario)
    else:
        passed = print_results(results, args.scenario)

    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
