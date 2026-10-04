#!/usr/bin/env bash
# site.test.sh: the tdd.sh entry point for the site. Builds with fixed test
# release details, serves the build in the nginx container when a Dockerfile
# exists, runs Playwright, and always stops the container.
set -euo pipefail
SITE="$(cd "$(dirname "$0")/.." && pwd)"
export SITE_TEST_VERSION=v0.0.1
export SITE_TEST_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
# 3100, not the compose default 3000, so a dev server on 3000 never collides.
export SITE_PORT="${SITE_PORT:-3100}"
cd "$SITE"
[ -d node_modules ] || npm ci --silent
bash scripts/build-site.sh "$SITE_TEST_VERSION" "$SITE_TEST_SHA256"
if [ -f Dockerfile ]; then
  trap 'docker compose down >/dev/null 2>&1 || true' EXIT
  docker compose up -d --build --wait
  # The served container runs nginx as uid 101 on a read-only filesystem.
  container_uid=$(docker compose exec -T site id -u | tr -d '\r')
  [ "$container_uid" = "101" ] || { echo "FAIL: the site container runs as uid '$container_uid', not 101"; exit 1; }
  read_only_root=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$(docker compose ps -q site)")
  [ "$read_only_root" = "true" ] || { echo "FAIL: the site container's root filesystem is writable"; exit 1; }
fi
# The test runner reads a FAIL line as a failed assertion and needs a PASS
# line, besides exit 0, to count the test as passing.
if ! npx playwright test --reporter=list > playwright.log 2>&1; then
  cat playwright.log
  grep -E '✘|failed' playwright.log | sed 's/^/FAIL: /'
  exit 1
fi
cat playwright.log
echo "site.test.sh PASS"
