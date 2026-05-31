#!/usr/bin/env bash
#
# test-migrate-session-ids.sh — shell-level test for
# scripts/migrate-session-ids.sh (GitHub issue #69).
#
# Builds a throwaway sessions tree in a temp dir, runs the migration, and
# asserts on directory names, on the reconciled session.json "id" field
# (the directory-name == id invariant), and on idempotency / dry-run /
# repair behaviour. Exits 0 if all assertions pass, 1 otherwise.
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

# Read the "id" field from a session's session.json (jq if available).
read_id() {
  local meta="$SESSIONS/$1/session.json"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.id // empty' "$meta"
  else
    sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$meta" | head -n1
  fi
}

# Write a minimal session.json with the given "id".
mk_session() {
  local dir="$1" id="$2"
  mkdir -p "$SESSIONS/$dir"
  printf '{"id":"%s","model":"m","channel":"cli"}\n' "$id" \
    > "$SESSIONS/$dir/session.json"
}

# --- Fixture ----------------------------------------------------------
# Old scheme, simple prefix (dir name == old id).
mk_session "zoe-20250325-143045-678" "zoe-20250325-143045-678"
echo '{"a":1}' > "$SESSIONS/zoe-20250325-143045-678/transcript.jsonl"
# Old scheme, hyphenated prefix.
mk_session "ops-team-20250325-143045-679" "ops-team-20250325-143045-679"
# Bare timestamp, no prefix (identical in both schemes).
mk_session "20250325-143045-680" "20250325-143045-680"
# Already-renamed by an id-unaware run: dir is NEW but "id" is STALE (old).
# This is the exact broken state the repair pass must fix.
mk_session "20250325-143045-681-bob" "bob-20250325-143045-681"
# Unrecognised dir WITHOUT session.json (stray) — must be ignored.
mkdir -p "$SESSIONS/totally-random"
# A stray file (not a directory) must be ignored.
touch "$SESSIONS/loose-file.txt"

# --- Dry run changes nothing ------------------------------------------
out="$(bash "$MIGRATE" --dry-run "$SESSIONS")"
echo "$out" | grep -q "would rename: zoe-20250325-143045-678 -> 20250325-143045-678-zoe"
check "dry-run reports the simple rename" $?
echo "$out" | grep -q "would update id: bob-20250325-143045-681 -> 20250325-143045-681-bob"
check "dry-run reports the stale-id repair" $?
exists "zoe-20250325-143045-678"; check "dry-run does not actually rename" $?
[ "$(read_id 20250325-143045-681-bob)" = "bob-20250325-143045-681" ]
check "dry-run does not actually rewrite id" $?

# --- Real migration ---------------------------------------------------
bash "$MIGRATE" "$SESSIONS" >/dev/null

exists "20250325-143045-678-zoe";       check "simple prefix moved to suffix" $?
not_exists "zoe-20250325-143045-678";   check "old simple dir is gone" $?
exists "20250325-143045-679-ops-team";  check "hyphenated prefix preserved & moved" $?

# The invariant: every session's dir name == its session.json "id".
[ "$(read_id 20250325-143045-678-zoe)" = "20250325-143045-678-zoe" ]
check "renamed dir: id field reconciled to dir name" $?
[ "$(read_id 20250325-143045-679-ops-team)" = "20250325-143045-679-ops-team" ]
check "hyphenated dir: id field reconciled to dir name" $?
[ "$(read_id 20250325-143045-680)" = "20250325-143045-680" ]
check "bare timestamp: id field unchanged & correct" $?
# The repair case — dir was already new, id was stale.
[ "$(read_id 20250325-143045-681-bob)" = "20250325-143045-681-bob" ]
check "already-renamed dir: stale id repaired to dir name" $?
exists "totally-random";                check "stray dir untouched" $?

# Transcript content travels with its directory.
content="$(cat "$SESSIONS/20250325-143045-678-zoe/transcript.jsonl" 2>/dev/null || echo MISSING)"
[ "$content" = '{"a":1}' ]; check "transcript file moved with the session dir" $?

# Other session.json fields are preserved through the id rewrite.
model="$( (command -v jq >/dev/null 2>&1 && jq -r '.model' "$SESSIONS/20250325-143045-678-zoe/session.json") || echo "" )"
if command -v jq >/dev/null 2>&1; then
  [ "$model" = "m" ]; check "other session.json fields preserved" $?
fi

# --- Idempotency ------------------------------------------------------
before="$(ls "$SESSIONS" | sort); $(read_id 20250325-143045-681-bob)"
bash "$MIGRATE" "$SESSIONS" >/dev/null
after="$(ls "$SESSIONS" | sort); $(read_id 20250325-143045-681-bob)"
[ "$before" = "$after" ]; check "second run is a no-op (idempotent)" $?

# --- Collision safety -------------------------------------------------
# If the new name already exists, the old dir must be left in place.
mk_session "alice-20250325-143045-682" "alice-20250325-143045-682"
mk_session "20250325-143045-682-alice" "20250325-143045-682-alice"
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
