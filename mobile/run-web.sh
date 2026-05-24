#!/usr/bin/env bash
# Run Familygram in Chrome on a fixed port so Ory CORS stays predictable.
set -e
cd "$(dirname "$0")"

API_BASE="${API_BASE:-http://localhost:8787}"
# Set ORY_BASE in your env (e.g. via scripts/dev.env.mk for `make dev`) or
# inline before running this script. No real default — keeps the URL out of
# the committed source.
ORY_BASE="${ORY_BASE:-https://<your-ory-project>.projects.oryapis.com}"

exec flutter run \
  -d chrome \
  --web-port=5050 \
  --web-hostname=localhost \
  --no-web-resources-cdn \
  --dart-define=API_BASE="$API_BASE" \
  --dart-define=ORY_BASE="$ORY_BASE"
