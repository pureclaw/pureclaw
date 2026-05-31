#!/usr/bin/env bash
#
# test-migrate-session-ids.sh — shell-level test for
# scripts/migrate-session-ids.sh (GitHub issue #69).
#
# Builds a throwaway sessions tree in a temp dir, runs the migration, and
# asserts on the resulting directory names and on idempotency / dry-run
# behaviour. Exits 0 if all assertions pass, 1 otherwise.
#
# Run from anywhere:
#   bash scripts/test-migrate-session-ids.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATE="$ROOT/scripts/migrate-session-ids.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pureclaw-migrate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SESSIONS="$TMP/sessions"
mkdir -p "$SESSIONS"

fail=0
check() {
  # check <description> <condition-already-evaluated:0|1>
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1" >&2
    fail=1
  fi
}

exists()      { [ -d "$SESSIONS/$1" ] && return 0 || return 1; }
not_exists()  { [ ! -e "$SESSIONS/$1" ] && return 0 || return 1; }

# --- Fixture ----------------------------------------------------------
# Old scheme, simple prefix.
mkdir -p "$SESSIONS/zoe-20250325-143045-678"
echo '{"a":1}' > "$SESSIONS/zoe-20250325-143045-678/transcript.jsonl"
# Old scheme, hyphenated prefix.
mkdir -p "$SESSIONS/ops-team-20250325-143045-679"
# Bare timestamp, no prefix (identical in both schemes).
mkdir -p "$SESSIONS/20250325-143045-680"
# Already new scheme.
mkdir -p "$SESSIONS/20250325-143045-681-bob"
# Unrecognised name.
mkdir -p "$SESSIONS/totally-random"
# A stray file (not a directory) must be ignored.
touch "$SESSIONS/loose-file.txt"

# --- Dry run changes nothing ------------------------------------------
out="$(bash "$MIGRATE" --dry-run "$SESSIONS")"
echo "$out" | grep -q "would rename: zoe-20250325-143045-678 -> 20250325-143045-678-zoe"
check "dry-run reports the simple rename" $?
exists "zoe-20250325-143045-678"; check "dry-run does not actually rename" $?

# --- Real migration ---------------------------------------------------
bash "$MIGRATE" "$SESSIONS" >/dev/null

exists "20250325-143045-678-zoe";       check "simple prefix moved to suffix" $?
not_exists "zoe-20250325-143045-678";   check "old simple dir is gone" $?
exists "20250325-143045-679-ops-team";  check "hyphenated prefix preserved & moved" $?
not_exists "ops-team-20250325-143045-679"; check "old hyphenated dir is gone" $?
exists "20250325-143045-680";           check "bare timestamp untouched" $?
exists "20250325-143045-681-bob";       check "already-new dir untouched" $?
exists "totally-random";                check "unrecognised dir untouched" $?

# Transcript content travels with its directory.
content="$(cat "$SESSIONS/20250325-143045-678-zoe/transcript.jsonl" 2>/dev/null || echo MISSING)"
[ "$content" = '{"a":1}' ]; check "transcript file moved with the session dir" $?

# --- Idempotency ------------------------------------------------------
before="$(ls "$SESSIONS" | sort)"
bash "$MIGRATE" "$SESSIONS" >/dev/null
after="$(ls "$SESSIONS" | sort)"
[ "$before" = "$after" ]; check "second run is a no-op (idempotent)" $?

# --- Collision safety -------------------------------------------------
# If the new name already exists, the old dir must be left in place.
mkdir -p "$SESSIONS/alice-20250325-143045-682"
mkdir -p "$SESSIONS/20250325-143045-682-alice"
bash "$MIGRATE" "$SESSIONS" >/dev/null 2>&1
exists "alice-20250325-143045-682"; check "collision leaves old dir untouched" $?

# --- Missing directory exits 2 ----------------------------------------
set +e
bash "$MIGRATE" "$TMP/does-not-exist" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]; check "missing sessions dir exits 2" $?

# --- Unknown option exits 1 -------------------------------------------
set +e
bash "$MIGRATE" --bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ]; check "unknown option exits 1" $?

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED" >&2
  exit 1
fi
