#!/usr/bin/env bash
# Shard: slow
# Verifies enforce/tdd.sh (R-412): open writes the lock, red accepts only a
# test that fails for an assertion or missing-module reason with the rest of
# the suite green, green requires the named tests to pass with the suite at or
# above baseline and the locked files byte-identical to the lock and the RED
# commit, close removes the lock only from green. Drives the REAL Vitest
# bundled in enforce/node_modules (pinned in enforce/package.json), linked into
# a throwaway project, so the JSON-reporter parsing is exercised against live
# output rather than a stub.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

# tdd.sh is the implementation under test and comes from the checkout, but
# enforce/node_modules is gitignored machine state that `npm ci --prefix
# enforce` writes wherever it was run, so it is looked for in the checkout
# first and in the live install second rather than demanded from either. CI
# symlinks the checkout at ~/.claude and installs into it, so both paths are
# the same tree there; on a developer's machine the install usually sits in
# the synced copy alone.
VITEST_PKG="$CLAUDE_HARNESS_ROOT/enforce/node_modules/vitest"
[ -d "$VITEST_PKG" ] || VITEST_PKG="$HOME/.claude/enforce/node_modules/vitest"
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

# validate (skills audit S-9): the test author's return is red with only
# test-tree writes; a production write or the wrong phase is refused.
bash "$TDD" validate test-author | grep -q 'VALID: test-author' || { echo "FAIL: validate test-author must accept a red return with only test writes"; exit 1; }
expect_fail "validate implementer while red" bash "$TDD" validate implementer | grep -q 'expected green' || { echo "FAIL: validate implementer while red must name the expected phase"; exit 1; }
mkdir -p src/services && printf 'export const stray = 1;\n' > src/services/stray.ts
expect_fail "validate test-author with a production write" bash "$TDD" validate test-author | grep -q 'R-411' || { echo "FAIL: a production write by the test author must cite R-411"; exit 1; }
rm src/services/stray.ts
expect_fail "validate an unknown role" bash "$TDD" validate nobody | grep -q 'unknown role' || { echo "FAIL: an unknown role must be refused by name"; exit 1; }

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

# validate (skills audit S-9): the implementer's return is green with no
# test, spec, or lock writes, and its GREEN is re-run; a test write is
# refused; after the GREEN commit the read-only critic's return is a clean
# tree, and any write at all is refused.
bash "$TDD" validate implementer | grep -q 'VALID: implementer' || { echo "FAIL: validate implementer must accept a green return with production writes only"; exit 1; }
printf '// touched\n' >> src/__tests__/baseline.test.ts
expect_fail "validate implementer after a test write" bash "$TDD" validate implementer | grep -q 'R-411' || { echo "FAIL: a test write by the implementer must cite R-411"; exit 1; }
git checkout -q -- src/__tests__/baseline.test.ts
git add src/services/score.ts && git commit -qm "feat(score): B-1 score returns 2"
bash "$TDD" validate slice-critic | grep -q 'VALID: slice-critic' || { echo "FAIL: validate slice-critic must accept a clean tree"; exit 1; }
printf 'note\n' > docs/notes.md
expect_fail "validate slice-critic after any write" bash "$TDD" validate slice-critic | grep -q 'docs/notes.md' || { echo "FAIL: a critic write must be named"; exit 1; }
rm docs/notes.md

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

# --- refactor mode: no RED, the green suite is the baseline --------------------
# open --refactor on a red tree is refused: a refactor starts from green.
impl src/services/score.ts 1
expect_fail "open --refactor on a red tree" bash "$TDD" open --refactor "R-1 extract scoring" --lock src/__tests__/score.test.ts | grep -qi 'green' || { echo "FAIL: refactor-open refusal must say the tree must be green"; exit 1; }
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: a refused refactor open must not leave a lock"; exit 1; }
impl src/services/score.ts 2
# open --refactor with named test files records their hashes and the outside baseline.
bash "$TDD" open --refactor "R-1 extract scoring" --lock src/__tests__/score.test.ts >/dev/null
[ "$(lock_field . .phase)" = "refactor" ] || { echo "FAIL: open --refactor must write phase refactor, got $(lock_field . .phase)"; exit 1; }
[ "$(lock_field . '.tests[0].path')" = "src/__tests__/score.test.ts" ] || { echo "FAIL: --lock must record the named test"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "1" ] || { echo "FAIL: refactor baseline must count the passing tests outside the locked files, got $(lock_field . '.baseline.passed')"; exit 1; }
# red is not a refactor step.
red_test src/__tests__/next.test.ts 2>/dev/null || true
expect_fail "red while refactoring" bash "$TDD" red src/__tests__/next.test.ts >/dev/null
rm -f src/__tests__/next.test.ts
# an equivalent implementation stays green; phase becomes green; close works.
printf 'const SCORE = 2;\nexport function score() { return SCORE; }\n' > src/services/score.ts
bash "$TDD" green >/dev/null
[ "$(lock_field . .phase)" = "green" ] || { echo "FAIL: green from refactor must move the phase to green"; exit 1; }
# a behavior change that breaks the locked test is refused.
impl src/services/score.ts 3
expect_fail "green after a behavior change" bash "$TDD" green >/dev/null
impl src/services/score.ts 2
# a tampered locked test is refused with R-410.
printf 'import { it, expect } from "vitest";\nimport { score } from "../services/score";\nit("scores a job at 2", () => { expect(score()).toBe(score()); });\n' > src/__tests__/score.test.ts
expect_fail "green after tampering a refactor-locked test" bash "$TDD" green | grep -q 'R-410' || { echo "FAIL: refactor tamper refusal must cite R-410"; exit 1; }
git checkout -q -- src/__tests__/score.test.ts
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null
# open --refactor with no --lock locks every test file the suite ran.
bash "$TDD" open --refactor "R-2 rename module" >/dev/null
[ "$(lock_field . '.tests | length')" = "2" ] || { echo "FAIL: open --refactor without --lock must lock every test file, got $(lock_field . '.tests | length')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "0" ] || { echo "FAIL: with every test locked the outside baseline is 0, got $(lock_field . '.baseline.passed')"; exit 1; }
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null

# status with no lock says so and exits 0.
bash "$TDD" status | grep -qi 'no slice' || { echo "FAIL: status without a lock must say no slice is open"; exit 1; }

cd / && rm -rf "$P"

# --- shell fixtures: a *.test.sh path runs with bash --------------------------
# The verdict is the fixture suite's own (enforce/run-fixture-shards.sh): exit
# 0 with a PASS line and no FAIL line passes. The suite is every *.test.sh in
# the named files' directories; fixtures elsewhere are not counted. The
# project has no node_modules, so nothing here can fall back to Vitest.
new_shell_project() {
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  mkdir -p "$dir/tests" "$dir/other/tests" "$dir/scripts"
  printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$dir/tests/baseline.test.sh"
  printf '#!/usr/bin/env bash\necho "FAIL: a fixture in another directory"\n' > "$dir/other/tests/unrelated.test.sh"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}
# The RED fixture calls scripts/score.sh, which does not exist yet.
shell_red_test() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > "$1"
}
shell_impl() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > scripts/score.sh; }

S=$(new_shell_project); cd "$S"
bash "$TDD" open "S-1 score.sh prints 2" >/dev/null

# red: a fixture that already passes, one that says nothing, and one that does
# not parse are each refused, and the phase stays open.
printf '#!/usr/bin/env bash\necho "early PASS"\n' > tests/score.test.sh
expect_fail "shell red on a passing fixture" bash "$TDD" red tests/score.test.sh | grep -qi 'already passes' || { echo "FAIL: a passing shell fixture must be refused as passing"; exit 1; }
printf '#!/usr/bin/env bash\necho "quiet"\n' > tests/score.test.sh
expect_fail "shell red on a silent fixture" bash "$TDD" red tests/score.test.sh | grep -qi 'no test' || { echo "FAIL: a fixture with no PASS or FAIL must be refused as containing no tests"; exit 1; }
printf '#!/usr/bin/env bash\nif then\n' > tests/score.test.sh
expect_fail "shell red on a syntax error" bash "$TDD" red tests/score.test.sh | grep -qi 'parse' || { echo "FAIL: a shell syntax error must be refused as not parsing"; exit 1; }
[ "$(lock_field . .phase)" = "open" ] || { echo "FAIL: refused shell reds must leave the phase open"; exit 1; }

# red: a failing sibling fixture in the same directory is refused by name.
shell_red_test tests/score.test.sh
printf '#!/usr/bin/env bash\necho "FAIL: sibling broke"\n' > tests/baseline.test.sh
expect_fail "shell red with a red sibling" bash "$TDD" red tests/score.test.sh | grep -q 'tests/baseline.test.sh' || { echo "FAIL: a red sibling fixture must be named"; exit 1; }
git checkout -q -- tests/baseline.test.sh

# red: a named .test.sh beside a JavaScript test is refused; one runner per slice.
printf 'it("x", () => {});\n' > tests/mixed.test.ts
expect_fail "red mixing runners" bash "$TDD" red tests/score.test.sh tests/mixed.test.ts | grep -q 'test.sh' || { echo "FAIL: mixing shell and JavaScript tests must be refused naming the shell kind"; exit 1; }
rm tests/mixed.test.ts

# red: a missing script is the missing-module RED; the failing fixture in
# other/tests is outside the suite, so the baseline counts tests/ alone.
bash "$TDD" red tests/score.test.sh >/dev/null || { echo "FAIL: shell red on a missing script must succeed"; exit 1; }
[ "$(lock_field . .phase)" = "red" ] || { echo "FAIL: shell red must move the phase to red"; exit 1; }
[ "$(lock_field . '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: expected missing-module for a missing script, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "1" ] || { echo "FAIL: the shell baseline must count the passing sibling, got $(lock_field . '.baseline.passed')"; exit 1; }
[ "$(lock_field . '.baseline.runner')" = "shell" ] || { echo "FAIL: the shell runner must be recorded, got $(lock_field . '.baseline.runner')"; exit 1; }

# red again: a FAIL line from a wrong answer is the assertion RED.
shell_impl 1
bash "$TDD" red tests/score.test.sh >/dev/null
[ "$(lock_field . '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: expected assertion for a FAIL line, got $(lock_field . '.tests[0].failureClass')"; exit 1; }

# green: still wrong is refused; right is green; a dropped sibling is refused.
expect_fail "shell green while failing" bash "$TDD" green >/dev/null
git add -A && git commit -qm "test(score): S-1 score.sh prints 2"
shell_impl 2
bash "$TDD" green >/dev/null || { echo "FAIL: shell green must pass once score.sh prints 2"; exit 1; }
[ "$(lock_field . .phase)" = "green" ] || { echo "FAIL: shell green must move the phase to green"; exit 1; }
rm tests/baseline.test.sh
expect_fail "shell green with a deleted sibling" bash "$TDD" green | grep -q 'baseline' || { echo "FAIL: deleting a sibling fixture must drop below the baseline"; exit 1; }
git checkout -q -- tests/baseline.test.sh
# A fixture that exits non-zero after printing PASS fails, as in the suite.
printf '#!/usr/bin/env bash\necho "baseline PASS"\nexit 1\n' > tests/baseline.test.sh
expect_fail "shell green with a sibling exiting non-zero" bash "$TDD" green | grep -q 'tests/baseline.test.sh' || { echo "FAIL: a sibling exiting non-zero must be named"; exit 1; }
git checkout -q -- tests/baseline.test.sh
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: close after shell green must remove the lock"; exit 1; }

# refactor: --lock on a shell fixture runs the shell suite.
bash "$TDD" open --refactor "S-2 tidy score.sh" --lock tests/score.test.sh >/dev/null || { echo "FAIL: open --refactor on a shell fixture must succeed"; exit 1; }
[ "$(lock_field . '.baseline.runner')" = "shell" ] || { echo "FAIL: a shell refactor must record the shell runner"; exit 1; }
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null

# close from open: with no test ever locked nothing was written under the
# lock, so an abandoned slice can close; once a test is locked it cannot.
bash "$TDD" open "S-3 abandoned" >/dev/null
bash "$TDD" close >/dev/null || { echo "FAIL: close must work from open when no test was locked"; exit 1; }
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: close from open must remove the lock"; exit 1; }

cd / && rm -rf "$S"
echo "tdd-red-green.test.sh PASS"
