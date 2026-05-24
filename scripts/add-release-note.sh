#!/usr/bin/env bash
# Generate a new release-notes entry by reading commit subjects since the
# last release and computing the version bump from conventional-commit
# prefixes:
#
#   feat / feat(scope):  ...   → minor bump (e.g. 1.0.0 → 1.1.0). Added.
#   fix  / fix(scope):   ...   → patch bump (e.g. 1.0.0 → 1.0.1). Fixed.
#   <type>!:  …  OR  BREAKING CHANGE in body → major bump (1.0.0 → 2.0.0). Breaking.
#   anything else (chore/docs/refactor/…)    → patch bump. Changed.
#
# The highest level among the commits since the last release wins.
#
# Usage:
#   scripts/add-release-note.sh             # compute version from commits
#   scripts/add-release-note.sh 1.2.0        # force a specific version

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
NOTES="docs/RELEASE_NOTES.md"
[[ -f "$NOTES" ]] || { echo "missing $NOTES" >&2; exit 1; }

# ─── Current version ───────────────────────────────────────────────────────
CURRENT="$(grep -m1 -oE '^## v[0-9]+\.[0-9]+\.[0-9]+' "$NOTES" | sed 's/^## v//' || true)"
[[ -n "$CURRENT" ]] || { echo "no '## v…' line found in $NOTES" >&2; exit 1; }

# ─── Commit range since last release ───────────────────────────────────────
# Use the most recent commit that *modified* the notes as the boundary. If
# none (e.g. first run), consider every commit.
LAST_COMMIT="$(git log -1 --format=%H -- "$NOTES" 2>/dev/null || true)"
if [[ -z "$LAST_COMMIT" ]]; then
  RANGE_ARG=()
else
  RANGE_ARG=("${LAST_COMMIT}..HEAD")
fi

mapfile -t COMMITS < <(git log "${RANGE_ARG[@]}" --no-merges --format='%s%n%b%n--END--')
# Normalize: collapse multi-line entries to "subject\nbody" until --END--.
# Easier path: re-grab subjects + body separately.
mapfile -t SUBJECTS < <(git log "${RANGE_ARG[@]}" --no-merges --format='%s')

if [[ ${#SUBJECTS[@]} -eq 0 ]]; then
  echo "No new commits since the last release. Nothing to add." >&2
  exit 1
fi

# ─── Classify commits ──────────────────────────────────────────────────────
BREAKING=()
ADDED=()
FIXED=()
CHANGED=()
bump="patch"

# Regexes in variables so bash's [[ =~ ]] parser leaves them alone.
re_breaking='^[a-zA-Z]+(\([^)]+\))?!:'
re_feat='^feat(\([^)]+\))?:'
re_fix='^fix(\([^)]+\))?:'

for subj in "${SUBJECTS[@]}"; do
  [[ -n "$subj" ]] || continue
  if [[ "$subj" =~ $re_breaking ]]; then
    BREAKING+=("$subj")
    bump="major"
  elif [[ "$subj" =~ $re_feat ]]; then
    ADDED+=("$subj")
    [[ "$bump" == "patch" ]] && bump="minor"
  elif [[ "$subj" =~ $re_fix ]]; then
    FIXED+=("$subj")
  else
    CHANGED+=("$subj")
  fi
done

# Also check commit bodies for explicit "BREAKING CHANGE:" markers.
if git log "${RANGE_ARG[@]}" --no-merges --format='%b' | grep -q 'BREAKING CHANGE'; then
  bump="major"
fi

# ─── Allow explicit override ───────────────────────────────────────────────
if [[ $# -ge 1 && -n "$1" ]]; then
  NEW="$1"
  if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Explicit version must be x.y.z (got: $NEW)" >&2
    exit 2
  fi
else
  IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"
  case "$bump" in
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    patch) PAT=$((PAT + 1)) ;;
  esac
  NEW="${MAJ}.${MIN}.${PAT}"
fi

DATE="$(date +%F)"

# ─── Render the entry to a temp file (safer for awk insertion) ─────────────
ENTRY="$(mktemp)"
trap 'rm -f "$ENTRY"' EXIT

emit_section() {
  local heading="$1"; shift
  local items=("$@")
  (( ${#items[@]} == 0 )) && return
  echo "### $heading"
  for it in "${items[@]}"; do echo "- $it"; done
  echo
}

{
  echo "## v$NEW — $DATE"
  echo
  emit_section "Breaking" "${BREAKING[@]+"${BREAKING[@]}"}"
  emit_section "Added"    "${ADDED[@]+"${ADDED[@]}"}"
  emit_section "Fixed"    "${FIXED[@]+"${FIXED[@]}"}"
  emit_section "Changed"  "${CHANGED[@]+"${CHANGED[@]}"}"
  echo "---"
  echo
} > "$ENTRY"

# ─── Insert before the first existing "## v…" heading ──────────────────────
awk -v entry_file="$ENTRY" '
  /^## v/ && !done {
    while ((getline line < entry_file) > 0) print line
    close(entry_file)
    done = 1
  }
  { print }
' "$NOTES" > "${NOTES}.new"
mv "${NOTES}.new" "$NOTES"

echo "▸ bump: $bump"
echo "▸ from v$CURRENT to v$NEW ($DATE)"
echo "▸ ${#SUBJECTS[@]} commits classified"
echo "  · ${#BREAKING[@]} breaking"
echo "  · ${#ADDED[@]} added (feat)"
echo "  · ${#FIXED[@]} fixed (fix)"
echo "  · ${#CHANGED[@]} changed (other)"
echo "▸ Entry written to $NOTES — edit with: make release-note"
