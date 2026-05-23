#!/usr/bin/env bash
# Enforces D6 (live transcript streaming, WU2): direct use of
# `mkFileTranscriptHandle` is restricted to the allowlist below. Every other
# transcript write site must go through `mkBroadcastingFileTranscriptHandle`
# so the broker can observe the entry.
#
# Run from the repo root:
#
#     bash scripts/lint-transcript-handles.sh
#
# Exits 0 if compliant, non-zero with a diff message otherwise.

set -euo pipefail

# Resolve to repo root regardless of CWD.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOWED=(
  "src/PureClaw/Handles/Transcript.hs"
  "src/PureClaw/Frontend/BroadcastingTranscript.hs"
  "src/PureClaw/Tools/SessionSearch.hs"
)

# Grep the src/ tree for direct uses; sort for stable comparison.
FOUND=$(git grep -l 'mkFileTranscriptHandle' src/ | sort -u || true)

# Sort the allowlist the same way and compute the difference.
ALLOWED_SORTED=$(printf '%s\n' "${ALLOWED[@]}" | sort -u)
DIFF=$(comm -23 <(printf '%s\n' "$FOUND") <(printf '%s\n' "$ALLOWED_SORTED"))

if [[ -n "$DIFF" ]]; then
  echo "ERROR: mkFileTranscriptHandle found in non-allowlisted files in src/:"
  echo "$DIFF"
  echo ""
  echo "Allowlist (D6 — live transcript streaming):"
  for f in "${ALLOWED[@]}"; do
    echo "  $f"
  done
  echo ""
  echo "Route the new write site through 'mkBroadcastingFileTranscriptHandle'"
  echo "(see src/PureClaw/Frontend/BroadcastingTranscript.hs) so transcript"
  echo "entries reach the broker."
  exit 1
fi

exit 0
