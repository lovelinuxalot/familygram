#!/usr/bin/env bash
# Rebuild Familygram and push to TestFlight.
#
# Run this every ~80 days (or whenever you ship a feature) so the family's
# TestFlight build doesn't expire. One-time setup is in scripts/RELEASE.md.
#
# What it does:
#   1. Bumps the build number in pubspec.yaml (semver stays the same).
#   2. Runs `flutter build ipa --release` with prod dart-defines.
#   3. Uploads the .ipa to App Store Connect via xcrun altool.
#   4. Leaves the version bump uncommitted so you can review + commit yourself.

set -euo pipefail

# ─── 1. Locate the repo and load config ──────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="$REPO_ROOT/scripts/ship.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG. Copy scripts/ship.env.example and fill it in."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${API_BASE:?Set API_BASE in scripts/ship.env}"
: "${ORY_BASE:?Set ORY_BASE in scripts/ship.env}"
: "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID in scripts/ship.env}"
: "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID in scripts/ship.env}"

# Find Flutter if it isn't on PATH already.
if ! command -v flutter >/dev/null; then
  if [[ -x "$HOME/develop/flutter/bin/flutter" ]]; then
    export PATH="$HOME/develop/flutter/bin:$PATH"
  else
    echo "flutter not on PATH and not at \$HOME/develop/flutter/bin"; exit 1
  fi
fi

# ─── 2. Compute the new pubspec version ──────────────────────────────────
# Build number is always strictly greater than the previous upload (App
# Store requires this). Semver can be carried over OR overridden via the
# VERSION env var, e.g. VERSION=1.1.0 make ship.
PUBSPEC="$REPO_ROOT/mobile/pubspec.yaml"
CURRENT="$(awk '/^version: / { print $2 }' "$PUBSPEC")"
CURRENT_SEMVER="${CURRENT%+*}"
CURRENT_BUILD="${CURRENT#*+}"
NEW_BUILD=$((CURRENT_BUILD + 1))

if [[ -n "${VERSION:-}" ]]; then
  # Sanity check: must look like x.y.z (no leading "v", no build suffix).
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must be x.y.z (got: $VERSION)" >&2
    exit 2
  fi
  NEW_SEMVER="$VERSION"
else
  NEW_SEMVER="$CURRENT_SEMVER"
fi
NEW_VERSION="${NEW_SEMVER}+${NEW_BUILD}"

echo "▸ Bumping version: $CURRENT → $NEW_VERSION"
# In-place edit, BSD sed compatible.
sed -i '' "s/^version: .*/version: $NEW_VERSION/" "$PUBSPEC"

# ─── 3. Build the IPA ────────────────────────────────────────────────────
cd "$REPO_ROOT/mobile"
echo "▸ Running flutter build ipa…"
flutter build ipa --release \
  --dart-define=API_BASE="$API_BASE" \
  --dart-define=ORY_BASE="$ORY_BASE"

IPA="$(ls -t build/ios/ipa/*.ipa | head -n 1)"
[[ -f "$IPA" ]] || { echo "no .ipa produced under build/ios/ipa/"; exit 1; }
echo "▸ Built $IPA"

# ─── 4. Validate + upload to App Store Connect ───────────────────────────
echo "▸ Validating with altool…"
xcrun altool --validate-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_ISSUER_ID"

echo "▸ Uploading to App Store Connect…"
xcrun altool --upload-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_ISSUER_ID"

echo ""
echo "✅ Build #$NEW_BUILD ($NEW_SEMVER) uploaded."
echo "   It usually takes 5–15 minutes for App Store Connect to finish processing"
echo "   the build, then it appears on the TestFlight tab and is available to"
echo "   internal testers. External testers see it after Apple's beta review."

# If RELEASE_NOTES is set (the make ship orchestrator passes it), fire a
# background poller that waits for the build to finish processing and then
# attaches the notes via the App Store Connect API. The caller exits without
# blocking; "What's New" appears in TestFlight whenever Apple finishes.
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$REPO_ROOT/mobile/ios/Runner/Info.plist" 2>/dev/null || true)"
  BUNDLE_ID="${BUNDLE_ID:-cc.lovelinuxalot.familygram}"
  echo ""
  echo "▸ Backgrounding TestFlight notes-setter for $NEW_SEMVER+$NEW_BUILD (will run ~20 min)…"
  LOG="/tmp/familygram-testflight-notes-${NEW_SEMVER}-${NEW_BUILD}.log"
  (
    cd "$REPO_ROOT" && \
    nohup env \
      ASC_API_KEY_ID="$ASC_API_KEY_ID" \
      ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
      RELEASE_NOTES="$RELEASE_NOTES" \
      node scripts/set-testflight-notes.js "$BUNDLE_ID" "$NEW_SEMVER" "$NEW_BUILD" \
      > "$LOG" 2>&1 &
  )
  echo "   Logs: $LOG"
fi

echo ""
echo "Next: review the version bump and commit:"
echo "   git diff mobile/pubspec.yaml docs/RELEASE_NOTES.md"
echo "   git add mobile/pubspec.yaml docs/RELEASE_NOTES.md && git commit -m \"release: $NEW_VERSION\""
