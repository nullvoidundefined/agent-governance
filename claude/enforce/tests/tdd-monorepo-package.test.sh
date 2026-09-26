#!/usr/bin/env bash
# Shard: slow
# Verifies enforce/tdd.sh in a pnpm-style monorepo (IAN-405): the repository
# root has no vitest of its own, and each package owns its vitest and config.
# red and green must run the nearest package's vitest from that package's
# directory, so its config decides what the suite is, rather than falling back
# to the harness-bundled vitest over the whole repository, which collects a
# sibling e2e spec the package never runs and refuses every RED as "the rest of
# the suite is red". Tests named from two packages are refused, because one run
# cannot report both. Drives the REAL Vitest bundled in enforce/node_modules,
# linked into a throwaway project, as tdd-red-green.test.sh does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

VITEST_PKG="$CLAUDE_HARNESS_ROOT/enforce/node_modules/vitest"
[ -d "$VITEST_PKG" ] || { echo "FAIL: vitest is not installed under enforce/node_modules; run npm ci --prefix enforce"; exit 1; }

# link_vitest <package dir>: gives the package its own vitest, as pnpm does.
link_vitest() {
  mkdir -p "$1/node_modules/.bin"
  ln -s "$VITEST_PKG" "$1/node_modules/vitest"
  ln -s "$VITEST_PKG/vitest.mjs" "$1/node_modules/.bin/vitest"
}

# new_package <repo> <name>: a package whose vitest config includes only its
# own src/__tests__, holding one passing baseline test.
new_package() {
  local dir="$1/packages/$2"
  mkdir -p "$dir/src/__tests__"
  link_vitest "$dir"
  printf '{ "name": "%s", "private": true, "type": "module" }\n' "$2" > "$dir/package.json"
  printf 'export default { test: { include: ["src/__tests__/**/*.test.ts"] } };\n' > "$dir/vitest.config.mjs"
  printf 'import { it, expect } from "vitest";\nit("baseline passes", () => { expect(1).toBe(1); });\n' > "$dir/src/__tests__/baseline.test.ts"
}

new_monorepo() {
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  printf '{ "name": "monorepo", "private": true }\n' > "$dir/package.json"
  printf 'node_modules\n' > "$dir/.gitignore"
  new_package "$dir" app
  new_package "$dir" other
  # A Playwright spec at the root: no package's vitest includes it, and a
  # root-level vitest run collects it and fails on the missing module.
  mkdir -p "$dir/e2e"
  printf 'import { test } from "@playwright/test";\ntest("home", async () => {});\n' > "$dir/e2e/home.spec.ts"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}
lock_field() { jq -r "$2" "$1/.claude/tdd-lock.json"; }
expect_fail() {
  local label="$1"; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}

P=$(new_monorepo); cd "$P"
APP=packages/app

bash "$TDD" open "score returns 2" >/dev/null
printf 'import { it, expect } from "vitest";\nimport { score } from "../services/score";\nit("scores a job at 2", () => { expect(score()).toBe(2); });\n' > "$APP/src/__tests__/score.test.ts"

# Tests named from two packages are refused by name.
printf 'import { it, expect } from "vitest";\nit("other fails", () => { expect(1).toBe(2); });\n' > packages/other/src/__tests__/other.test.ts
expect_fail "red across two packages" bash "$TDD" red "$APP/src/__tests__/score.test.ts" packages/other/src/__tests__/other.test.ts \
  | grep -q 'packages/other' || { echo "FAIL: tests from two packages must be refused, naming the second package"; exit 1; }
rm packages/other/src/__tests__/other.test.ts

# red runs the app package's own vitest: the root e2e spec is outside its
# suite, so the missing-module failure is a clean RED and the baseline counts
# only the app package's passing test.
out=$(bash "$TDD" red "$APP/src/__tests__/score.test.ts" 2>&1) || { echo "FAIL: red in a package must succeed; output: $out"; exit 1; }
[ "$(lock_field . .phase)" = "red" ] || { echo "FAIL: red must move the phase to red"; exit 1; }
[ "$(lock_field . '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: expected missing-module class, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "1" ] || { echo "FAIL: the baseline must count only the package's own passing tests, got $(lock_field . '.baseline.passed')"; exit 1; }

# green runs the same package's vitest.
git add -A && git commit -qm "test(score): score returns 2"
mkdir -p "$APP/src/services"
printf 'export function score() { return 2; }\n' > "$APP/src/services/score.ts"
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green in a package must succeed; output: $out"; exit 1; }
[ "$(lock_field . .phase)" = "green" ] || { echo "FAIL: green must move the phase to green"; exit 1; }

echo "PASS: tdd.sh runs the nearest package's vitest in a monorepo"
