#!/usr/bin/env bash
#
# migrate-session-ids.sh — migrate existing session directories from the
# legacy "<prefix>-<timestamp>" naming scheme to the new
# "<timestamp>-<prefix>" scheme (GitHub issue #69).
#
# A session is stored as a directory whose NAME equals the session's "id"
# field in its session.json. PureClaw relies on that invariant: transcript
# paths, the recent/archived listings, resume, archive, and last-active
# updates all derive the on-disk path from the "id" field. So this script
# does TWO things for every session:
#
#   1. Renames the directory  <prefix>-<timestamp>  ->  <timestamp>-<prefix>
#   2. Rewrites session.json's "id" field to match the directory name.
#
# Step 2 also REPAIRS sessions that were renamed by an earlier, id-unaware
# version of this script (directory already new, but "id" still old): the
# script reconciles every session's "id" to its directory name regardless
# of whether a rename was needed this run.
#
# The timestamp segment is always "YYYYMMDD-HHMMSS-mmm" (8 digits, 6
# digits, 3 digits, hyphen-separated). Under the OLD scheme it trails an
# optional prefix; under the NEW scheme it leads. Prefix-less sessions
# (just the bare timestamp) have the same name in both schemes and are
# only ever touched if their "id" field needs reconciling.
#
# The script is idempotent: a second run changes nothing.
#
# Usage:
#   scripts/migrate-session-ids.sh [--dry-run] [SESSIONS_DIR]
#
#   --dry-run     Print what WOULD change; modify nothing.
#   SESSIONS_DIR  Directory holding the per-session subdirectories.
#                 Defaults to "$HOME/.pureclaw/sessions".
#
# Exit status:
#   0  success (including "nothing to do")
#   1  usage error or an operation failed
#   2  sessions directory does not exist

set -euo pipefail

# --- Argument parsing -------------------------------------------------

DRY_RUN=0
SESSIONS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "error: unknown option '$1'" >&2
      exit 1
      ;;
    *)
      if [ -n "$SESSIONS_DIR" ]; then
        echo "error: unexpected extra argument '$1'" >&2
        exit 1
      fi
      SESSIONS_DIR="$1"
      ;;
  esac
  shift
done

if [ -z "$SESSIONS_DIR" ]; then
  SESSIONS_DIR="${HOME}/.pureclaw/sessions"
fi

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "sessions directory does not exist: $SESSIONS_DIR" >&2
  exit 2
fi

# jq gives us a safe JSON edit; fall back to a targeted sed otherwise.
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
fi

# --- Helpers ----------------------------------------------------------

# Read the current "id" field from a session.json. Empty if absent.
read_session_id() {
  local meta="$1"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r '.id // empty' "$meta" 2>/dev/null || true
  else
    # Compact Aeson output: "id":"<value>". Tolerate optional spaces.
    sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$meta" | head -n1
  fi
}

# Reconcile session.json's "id" to the directory name. No-op when the
# field already matches or there is no session.json.
ids_updated=0
reconcile_id() {
  local dir="$1" wantid="$2"
  local meta="$dir/session.json"
  [ -f "$meta" ] || return 0

  local curid
  curid="$(read_session_id "$meta")"
  [ "$curid" = "$wantid" ] && return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would update id: $curid -> $wantid"
    ids_updated=$((ids_updated + 1))
    return 0
  fi

  local tmp="$meta.migrate.tmp"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq --arg id "$wantid" '.id = $id' "$meta" > "$tmp"
  else
    sed -E "s|\"id\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"id\":\"${wantid}\"|" "$meta" > "$tmp"
  fi
  mv -- "$tmp" "$meta"
  echo "updated id: $curid -> $wantid"
  ids_updated=$((ids_updated + 1))
}

# --- Migration --------------------------------------------------------

# A bare timestamp: YYYYMMDD-HHMMSS-mmm (anchored).
TS_RE='[0-9]{8}-[0-9]{6}-[0-9]{3}'
# New scheme: <timestamp>-<prefix>  (timestamp leads, prefix follows).
NEW_RE="^${TS_RE}-.+$"
# Bare timestamp, no prefix (same name in both schemes).
BARE_RE="^${TS_RE}$"
# Old scheme: <prefix>-<timestamp>  (prefix leads, timestamp trails).
OLD_RE="^(.+)-(${TS_RE})$"

renamed=0
skipped=0

for entry in "$SESSIONS_DIR"/*; do
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"
  meta="$entry/session.json"

  # Decide the directory's target name.
  if [[ "$name" =~ $NEW_RE ]] || [[ "$name" =~ $BARE_RE ]]; then
    # Already new / bare: keep the name; we still reconcile the id below.
    target="$name"
  elif [[ "$name" =~ $OLD_RE ]]; then
    prefix="${BASH_REMATCH[1]}"
    timestamp="${BASH_REMATCH[2]}"
    target="${timestamp}-${prefix}"
  else
    # Unrecognised name: only a real session (has session.json) is worth
    # reconciling; otherwise leave it entirely alone.
    if [ ! -f "$meta" ]; then
      echo "warn: unrecognised directory, skipping: $name" >&2
      skipped=$((skipped + 1))
      continue
    fi
    target="$name"
  fi

  # Rename the directory when the scheme changed.
  if [ "$target" != "$name" ]; then
    dest="$SESSIONS_DIR/$target"
    if [ -e "$dest" ]; then
      echo "warn: target already exists, skipping rename: $name -> $target" >&2
      skipped=$((skipped + 1))
      # Still attempt to reconcile the id of the existing dir in place.
      reconcile_id "$entry" "$name"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would rename: $name -> $target"
    else
      mv -- "$entry" "$dest"
      echo "renamed: $name -> $target"
      entry="$dest"
      meta="$entry/session.json"
    fi
    renamed=$((renamed + 1))
  fi

  # Reconcile session.json's "id" to the (possibly new) directory name.
  reconcile_id "$entry" "$target"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $renamed dir(s) would be renamed, $ids_updated id(s) would be updated, $skipped skipped"
else
  echo "done: $renamed renamed, $ids_updated id(s) updated, $skipped skipped"
fi
