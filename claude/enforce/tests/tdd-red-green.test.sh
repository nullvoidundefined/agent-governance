#!/usr/bin/env bash
# Verifies enforce/tdd.sh (R-412): open writes the lock, red accepts only a
# test that fails for an assertion or missing-module reason with the rest of
# the suite green, green requires the named tests to pass with the suite at or
# above baseline and the locked files byte-identical to the lock and the RED
# commit, close removes the lock only from green. Drives the REAL Vitest
# bundled in enforce/node_modules (pinned in enforce/package.json), linked into
# a throwaway project, so the JSON-reporter parsing is exercised against live
# output rather than a stub.
set -euo pipefail
TDD="$HOME/.claude/enforce/tdd.sh"
VITEST_PKG="$HOME/.claude/enforce/node_modules/vitest"
[ -d "$VITEST_PKG" ] || { echo "FAIL: vitest is not installed under enforce/node_modules; run npm ci --prefix enforce"; exit 1; }

new_project() {
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  mkdir -p "$dir/src/__tests__" "$dir/node_modules" "$dir/docs/specs"
  ln -s "$VITEST_PKG" "$dir/node_modules/vitest"
  mkdir -p "$dir/node_modules/.bin" && ln -s "$VITEST_PKG/vitest.mjs" "$dir/node_modules/.bin/vitest"
  printf '{ "name": "fixture", "private": true, "type": "module", "scripts": { "test": "vitest run" } }\n' > "$dir/package.json"
  printf 'node_modules\n' > "$dir/.gitignore"
  printf 'import { it, expect } from "vitest";\nit("baseline passes", () => { expect(1).toBe(1); });\n' > "$dir/src/__tests__/baseline.test.ts"
  printf '# score\n' > "$dir/docs/specs/score.md"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}
red_test() { printf 'import { it, expect } from "vitest";\nimport { score } from "../services/score";\nit("scores a job at 2", () => { expect(score()).toBe(2); });\n' > "$1"; }
impl() { printf 'export function score() { return %s; }\n' "$2" > "$1"; }
lock_field() { jq -r "$2" "$1/.claude/tdd-lock.json"; }
expect_fail() {
  local label="$1"; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}

P=$(new_project); cd "$P"

# red before open is refused with the hint.
red_test src/__tests__/score.test.ts
expect_fail "red without open" bash "$TDD" red src/__tests__/score.test.ts | grep -q 'tdd.sh open' || { echo "FAIL: red-without-open must name tdd.sh open"; exit 1; }
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: red without open must not write a lock"; exit 1; }

# open writes the lock in phase open with the spec locked; a second open is refused.
bash "$TDD" open "B-1 score returns 2" --spec docs/specs/score.md >/dev/null
[ "$(lock_field . .phase)" = "open" ] || { echo "FAIL: open must write phase open"; exit 1; }
[ "$(lock_field . '.locked[0]')" = "docs/specs/score.md" ] || { echo "FAIL: open must lock the spec"; exit 1; }
expect_fail "second open" bash "$TDD" open "B-2" >/dev/null

# red: a passing test is refused and the phase stays open.
printf 'import { it, expect } from "vitest";\nit("already green", () => { expect(1).toBe(1); });\n' > src/__tests__/score.test.ts
expect_fail "red on a passing test" bash "$TDD" red src/__tests__/score.test.ts | grep -qi 'pass' || { echo "FAIL: passing-test refusal must say so"; exit 1; }
[ "$(lock_field . .phase)" = "open" ] || { echo "FAIL: a refused red must leave the phase open"; exit 1; }

# red: a skipped test is refused.
printf 'import { it, expect } from "vitest";\nit.skip("parked", () => { expect(1).toBe(2); });\n' > src/__tests__/score.test.ts
expect_fail "red on a skipped test" bash "$TDD" red src/__tests__/score.test.ts | grep -qi 'skip' || { echo "FAIL: skipped-test refusal must say so"; exit 1; }

# red: a syntax error in the test is refused (that is not a RED, it is a broken test).
printf 'import { it } from "vitest";\nit("broken", () => {\n' > src/__tests__/score.test.ts
expect_fail "red on a syntax error" bash "$TDD" red src/__tests__/score.test.ts | grep -qiE 'syntax|parse' || { echo "FAIL: syntax refusal must say so"; exit 1; }

# red: no tests in the file is refused.
printf 'export const nothing = 1;\n' > src/__tests__/score.test.ts
expect_fail "red on an empty test file" bash "$TDD" red src/__tests__/score.test.ts | grep -qi 'no test' || { echo "FAIL: empty-file refusal must say so"; exit 1; }

# red: the rest of the suite being red is refused.
red_test src/__tests__/score.test.ts
printf 'import { it, expect } from "vitest";\nit("baseline passes", () => { expect(1).toBe(2); });\n' > src/__tests__/baseline.test.ts
expect_fail "red with a red suite" bash "$TDD" red src/__tests__/score.test.ts | grep -q 'baseline' || { echo "FAIL: red-suite refusal must name the file"; exit 1; }
git checkout -q -- src/__tests__/baseline.test.ts

# red: a missing-module failure is the expected RED for a new unit.
bash "$TDD" red src/__tests__/score.test.ts >/dev/null
[ "$(lock_field . .phase)" = "red" ] || { echo "FAIL: red must move the phase to red"; exit 1; }
[ "$(lock_field . '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: expected missing-module class, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "1" ] || { echo "FAIL: baseline must count the passing tests outside the RED files, got $(lock_field . '.baseline.passed')"; exit 1; }
[ "$(lock_field . '.tests[0].sha256' | wc -c | tr -d ' ')" = "65" ] || { echo "FAIL: red must record a sha256"; exit 1; }

# red: re-running red in phase red with an assertion failure reclassifies.
impl src/services/score.ts 1 2>/dev/null || { mkdir -p src/services; impl src/services/score.ts 1; }
bash "$TDD" red src/__tests__/score.test.ts >/dev/null
[ "$(lock_field . '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: expected assertion class, got $(lock_field . '.tests[0].failureClass')"; exit 1; }

# green: still failing is refused; the phase stays red.
expect_fail "green while the test still fails" bash "$TDD" green >/dev/null
[ "$(lock_field . .phase)" = "red" ] || { echo "FAIL: a refused green must leave the phase red"; exit 1; }

# green: implemented, everything passes, phase becomes green.
git add -A && git commit -qm "test(score): B-1 score returns 2"
impl src/services/score.ts 2
bash "$TDD" green >/dev/null
[ "$(lock_field . .phase)" = "green" ] || { echo "FAIL: green must move the phase to green"; exit 1; }

# green: a tampered RED test is refused by the hash against the lock and the RED commit.
printf 'import { it, expect } from "vitest";\nimport { score } from "../services/score";\nit("scores a job at 2", () => { expect(score()).toBe(score()); });\n' > src/__tests__/score.test.ts
expect_fail "green on a tampered test" bash "$TDD" green | grep -q 'R-410' || { echo "FAIL: tamper refusal must cite R-410"; exit 1; }
git checkout -q -- src/__tests__/score.test.ts

# green: a deleted baseline test drops the count below baseline and is refused.
rm src/__tests__/baseline.test.ts
expect_fail "green with a deleted baseline test" bash "$TDD" green | grep -q 'baseline' || { echo "FAIL: baseline-drop refusal must say baseline"; exit 1; }
git checkout -q -- src/__tests__/baseline.test.ts

# green: a skipped RED test is refused even though nothing fails.
sed -i.bak 's/^it(/it.skip(/' src/__tests__/score.test.ts && rm -f src/__tests__/score.test.ts.bak
expect_fail "green on a skipped RED test" bash "$TDD" green >/dev/null
git checkout -q -- src/__tests__/score.test.ts

# close: refused before green, removes the lock from green.
jq '.phase = "red"' .claude/tdd-lock.json > .claude/tmp.json && mv .claude/tmp.json .claude/tdd-lock.json
expect_fail "close while red" bash "$TDD" close >/dev/null
bash "$TDD" green >/dev/null
bash "$TDD" close >/dev/null
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: close must remove the lock"; exit 1; }

# status with no lock says so and exits 0.
bash "$TDD" status | grep -qi 'no slice' || { echo "FAIL: status without a lock must say no slice is open"; exit 1; }

cd / && rm -rf "$P"
echo "tdd-red-green.test.sh PASS"
