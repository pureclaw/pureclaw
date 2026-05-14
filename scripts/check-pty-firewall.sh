#!/usr/bin/env bash
#
# check-pty-firewall.sh — enforce the posix-pty import firewall.
#
# Only PureClaw.Backend.Pty and PureClaw.Backend.Pty.Fake may import
# System.Posix.Pty. A path-based whitelist (NOT --exclude-dir) is used
# so the firewalled file itself is not accidentally allow-listed by
# directory.
#
# Exits 0 if no violations are found; exits 1 otherwise.

set -euo pipefail

# Match imports of System.Posix.Pty (or its shorter Posix.Pty / Pty
# aliases) in any qualification form. We use ERE (-E) consistently.
PATTERN='^[[:space:]]*import[[:space:]]+(qualified[[:space:]]+)?(System\.Posix\.Pty|Posix\.Pty)\b'

hits=$(grep -RInE "$PATTERN" src/ 2>/dev/null \
  | grep -v -E '^src/PureClaw/Backend/Pty(\.hs|/Fake\.hs):' \
  || true)

if [ -n "$hits" ]; then
  echo "::error::posix-pty firewall violated; only Backend/Pty.hs and Backend/Pty/Fake.hs may import posix-pty" >&2
  echo "$hits" >&2
  exit 1
fi

echo "posix-pty firewall OK"
