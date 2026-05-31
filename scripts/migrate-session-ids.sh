#!/usr/bin/env bash
#
# migrate-session-ids.sh — migrate existing session directories from the
# legacy "<prefix>-<timestamp>" naming scheme to the new
# "<timestamp>-<prefix>" scheme (GitHub issue #69).
#
# The timestamp segment is always "YYYYMMDD-HHMMSS-mmm" (8 digits, 6
# digits, 3 digits, hyphen-separated). Under the OLD scheme it trails an
# optional prefix; under the NEW scheme it leads. Prefix-less sessions
# (just the bare timestamp) are identical in both schemes and are left
# untouched.
#
# The script is idempotent: directories already in the new scheme, and
# names it does not recognise, are skipped. Re-running it is a no-op.
#
# Usage:
#   scripts/migrate-session-ids.sh [--dry-run] [SESSIONS_DIR]
#
#   --dry-run     Print the renames that WOULD happen; change nothing.
#   SESSIONS_DIR  Directory holding the per-session subdirectories.
#                 Defaults to "$HOME/.pureclaw/sessions".
#
# Exit status:
#   0  success (including "nothing to do")
#   1  usage error or a rename failed
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
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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

# --- Migration --------------------------------------------------------

# A bare timestamp: YYYYMMDD-HHMMSS-mmm (anchored).
TS_RE='[0-9]{8}-[0-9]{6}-[0-9]{3}'
# New scheme: <timestamp>-<prefix>  (timestamp leads, prefix follows).
NEW_RE="^${TS_RE}-.+$"
# Bare timestamp, no prefix (identical in both schemes).
BARE_RE="^${TS_RE}$"
# Old scheme: <prefix>-<timestamp>  (prefix leads, timestamp trails).
# The prefix is captured greedily; the timestamp is the final segment.
OLD_RE="^(.+)-(${TS_RE})$"

renamed=0
skipped=0

# Iterate over immediate subdirectories only.
for entry in "$SESSIONS_DIR"/*; do
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"

  # Already new scheme, or a bare timestamp: nothing to do.
  if [[ "$name" =~ $NEW_RE ]] || [[ "$name" =~ $BARE_RE ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  # Old scheme: split prefix and trailing timestamp.
  if [[ "$name" =~ $OLD_RE ]]; then
    prefix="${BASH_REMATCH[1]}"
    timestamp="${BASH_REMATCH[2]}"
    newname="${timestamp}-${prefix}"
    target="$SESSIONS_DIR/$newname"

    if [ -e "$target" ]; then
      echo "warn: target already exists, skipping: $name -> $newname" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would rename: $name -> $newname"
    else
      mv -- "$entry" "$target"
      echo "renamed: $name -> $newname"
    fi
    renamed=$((renamed + 1))
    continue
  fi

  # Unrecognised name: leave it alone.
  echo "warn: unrecognised session directory, skipping: $name" >&2
  skipped=$((skipped + 1))
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $renamed would be renamed, $skipped skipped"
else
  echo "done: $renamed renamed, $skipped skipped"
fi
