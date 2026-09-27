#!/usr/bin/env bash
# site.test.sh: the tdd.sh entry point for the site. Builds with fixed test
# release details, serves the build in the nginx container when a Dockerfile
# exists, runs Playwright, and always stops the container.
set -euo pipefail
SITE="$(cd "$(dirname "$0")/.." && pwd)"
export SITE_TEST_VERSION=v0.0.1
export SITE_TEST_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cd "$SITE"
[ -d node_modules ] || npm ci --silent
bash scripts/build-site.sh "$SITE_TEST_VERSION" "$SITE_TEST_SHA256"
if [ -f Dockerfile ]; then
  trap 'docker compose down >/dev/null 2>&1 || true' EXIT
  docker compose up -d --build --wait
fi
npx playwright test
