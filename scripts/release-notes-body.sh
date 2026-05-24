#!/usr/bin/env bash
# Print the body of a single version entry from docs/RELEASE_NOTES.md.
#
#   scripts/release-notes-body.sh 1.2.0
#     →  prints everything between `## v1.2.0` and the next `## v…` line.
#
# Used by ship-testflight.sh and ship-playstore.js to push the right "What's
# New" text to TestFlight and Play Console.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
VERSION="$1"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="$REPO_ROOT/docs/RELEASE_NOTES.md"
[[ -f "$NOTES" ]] || { echo "missing $NOTES" >&2; exit 1; }

# Stream the file; print everything from the matching `## vX.Y.Z` header up
# to (but not including) the next `## v…` header or `---` separator. Skip
# the header line itself, leading blank lines, and trailing separators.
awk -v ver="$VERSION" '
  BEGIN { in_block = 0; printed_any = 0 }
  /^## v[0-9]/ {
    if (in_block) exit
    if ($0 ~ "^## v" ver "([ ]|$|\\.)") in_block = 1
    next
  }
  in_block {
    if (!printed_any && $0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^---[[:space:]]*$/) exit
    printed_any = 1
    print
  }
' "$NOTES"
