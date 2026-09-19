#!/usr/bin/env bash
# Shard: slow
# Verifies enforce/tdd.sh (R-412): open writes the lock, red accepts only a
# test that fails for an assertion or missing-module reason with the rest of
# the suite green, green requires the named tests to pass with the suite at or
# above baseline and the locked files byte-identical to the lock and the RED
# commit, close removes the lock only from green. Drives the REAL Vitest
# bundled in enforce/node_modules (pinned in enforce/package.json), linked into
# a throwaway project, so the JSON-reporter parsing is exercised against live
# output rather than a stub. A test node id (`path::<full test name>`) REDs a
# new test in a file that already holds a passing one; no Jest is bundled, so
# a stub writing Jest's report shape drives the same id path under Jest. A second throwaway
# project drives the bash *.test.sh runner through the real
# run-fixture-shards.sh, where a test id is refused because a fixture file is
# one test, and close from open before any test is locked.
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

# red: each test of a file named whole is classified on its own (IAN-160), so
# one throwing a plain error is refused by its full name even though the other
# test's assertion failure would classify the file's joined messages.
printf 'import { it, expect } from "vitest";\nit("asserts", () => { expect(1).toBe(2); });\nit("throws boom", () => { throw new Error("boom"); });\n' > src/__tests__/score.test.ts
expect_fail "red with one unclassified failure in the file" bash "$TDD" red src/__tests__/score.test.ts | grep -q 'src/__tests__/score.test.ts::throws boom fails for a reason this script does not classify: Error: boom' || { echo "FAIL: a test failing for an unclassified reason must be refused by its full name beside an assertion failure"; exit 1; }

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
# The refusal names the failing test, not an empty "failed to run" (PR #49 review).
expect_fail "green while the test still fails" bash "$TDD" green | grep -q 'scores a job at 2' || { echo "FAIL: a still-failing green must name the failing test"; exit 1; }
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

# --- test node ids: a new failing test in a file that already holds a passing one
# `path::<full test name>` names one test by the full name Vitest and Jest
# report and filter on with -t (describe titles and the test title joined by
# spaces). The file as a whole cannot be RED, since one of its tests passes.
N=$(new_project); cd "$N"
mkdir -p src/services && impl src/services/score.ts 2
cat > src/__tests__/score.test.ts <<'TS'
import { describe, it, expect } from "vitest";
import * as scoring from "../services/score";
it("scores a job at 2", () => { expect(scoring.score()).toBe(2); });
describe("boost", () => {
  it("doubles the score", () => { expect((scoring as any).boost()).toBe(4); });
});
TS
git add -A && git commit -qm "chore: score exists"
NODE="src/__tests__/score.test.ts::boost doubles the score"
bash "$TDD" open "B-3 boost doubles the score" >/dev/null
expect_fail "file-level red on a file with a passing test" bash "$TDD" red src/__tests__/score.test.ts | grep -q 'scores a job at 2' || { echo "FAIL: file-level red must still refuse a file holding a passing test"; exit 1; }
expect_fail "node red on an unknown name" bash "$TDD" red "src/__tests__/score.test.ts::doubles the score" | grep -q 'no test in src/__tests__/score.test.ts matches doubles the score' || { echo "FAIL: a bare title that is not the full name must be refused as matching no test"; exit 1; }
expect_fail "node red on a passing test" bash "$TDD" red "src/__tests__/score.test.ts::scores a job at 2" | grep -q 'already passes' || { echo "FAIL: a named passing test must be refused as passing"; exit 1; }
# An unnamed test that fails, or is skipped, beside the named one is refused
# by its full name (PR review): the file's other tests keep their status.
cp src/__tests__/score.test.ts "$N/score.test.ts.saved"
sed -i.bak 's/toBe(2)/toBe(5)/' src/__tests__/score.test.ts && rm -f src/__tests__/score.test.ts.bak
expect_fail "node red beside a failing unnamed test" bash "$TDD" red "$NODE" | grep -q 'src/__tests__/score.test.ts::scores a job at 2 fails but was not named' || { echo "FAIL: a failing unnamed test in an id-named file must be refused by its full name"; exit 1; }
cp "$N/score.test.ts.saved" src/__tests__/score.test.ts
sed -i.bak 's/^it("scores/it.skip("scores/' src/__tests__/score.test.ts && rm -f src/__tests__/score.test.ts.bak
expect_fail "node red beside a skipped unnamed test" bash "$TDD" red "$NODE" | grep -q 'src/__tests__/score.test.ts::scores a job at 2 is skipped' || { echo "FAIL: a skipped unnamed test in an id-named file must be refused by its full name"; exit 1; }
cp "$N/score.test.ts.saved" src/__tests__/score.test.ts && rm "$N/score.test.ts.saved"
out=$(bash "$TDD" red "$NODE" 2>&1) || { echo "FAIL: node red on the new failing test must succeed; output: $out"; exit 1; }
[ "$(lock_field . '.tests[0].path')" = "src/__tests__/score.test.ts" ] || { echo "FAIL: the lock must carry the containing file"; exit 1; }
[ "$(lock_field . '.tests[0].ids[0]')" = "boost doubles the score" ] || { echo "FAIL: the lock must record the named test, got $(lock_field . '.tests[0].ids')"; exit 1; }
[ "$(lock_field . '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: a function not written yet must be the missing-module RED, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field . '.tests[0].tests')" = "1" ] || { echo "FAIL: node red must count the one named test, got $(lock_field . '.tests[0].tests')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "2" ] || { echo "FAIL: the baseline must count the passing test beside the named one, got $(lock_field . '.baseline.passed')"; exit 1; }
git add -A && git commit -qm "test(score): B-3 boost doubles the score"
printf 'export function score() { return 2; }
export function boost() { return 3; }
' > src/services/score.ts
expect_fail "node green with the named test failing" bash "$TDD" green | grep -q 'doubles the score' || { echo "FAIL: node green must name the still-failing named test"; exit 1; }
printf 'export function score() { return 1; }
export function boost() { return 4; }
' > src/services/score.ts
expect_fail "node green with the unnamed test regressed" bash "$TDD" green | grep -q 'the rest of the suite is red.*src/__tests__/score.test.ts' || { echo "FAIL: node green must refuse a regression in the named file's other test"; exit 1; }
printf 'export function score() { return 2; }
export function boost() { return 4; }
' > src/services/score.ts
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: node green must pass once the named test passes; output: $out"; exit 1; }
bash "$TDD" close >/dev/null
cd / && rm -rf "$N"

# --- the assertion class is Vitest's own assertion output, not a word ----------
# A plain Error whose message happens to say "expected" or name a matcher is
# not an assertion RED (IAN-161): it is refused as unclassified. Every shape
# real Vitest writes for a failed assertion stays the assertion RED, including
# those that arrive as a plain Error: `.resolves`, `.rejects`, `expect.poll`,
# an `expect.extend` matcher, a snapshot mismatch, `expect.assertions`, and
# `expect.hasAssertions`, and the ANSI-coloured hint `toSatisfy` writes.
A=$(new_project); cd "$A"
bash "$TDD" open "A-1 assertion markers" >/dev/null
for body in 'throw new Error("timeout: expected reply");' \
            'throw new Error("expected reply to arrive");' \
            'throw new Error("toBe or not toBe");'; do
  printf 'import { it } from "vitest";\nit("plain", () => { %s });\n' "$body" > src/__tests__/marker.test.ts
  expect_fail "red on a plain error: $body" bash "$TDD" red src/__tests__/marker.test.ts | grep -q 'does not classify' || { echo "FAIL: a plain error is not an assertion RED: $body"; exit 1; }
done
[ "$(lock_field . .phase)" = "open" ] || { echo "FAIL: a refused plain-error red must leave the phase open"; exit 1; }
for body in 'expect(1).toBe(2);' \
            'expect(vi.fn()).toHaveBeenCalled();' \
            'assert.equal(1, 2);' \
            'await expect(Promise.resolve(1)).resolves.toBe(2);' \
            'expect.assertions(1);' \
            'expect.hasAssertions();' \
            'await expect(Promise.reject(new Error("boom"))).rejects.toThrow("other");' \
            'await expect(Promise.resolve(1)).rejects.toThrow();' \
            'await expect.poll(() => 1, { timeout: 50 }).toBe(2);' \
            '(expect(10) as any).toBeWithinRange(1, 3);' \
            'expect(1).toMatchInlineSnapshot(`2`);' \
            'expect(1).toSatisfy((n: number) => n > 1);'; do
  printf 'import { it, expect, assert, vi } from "vitest";\nexpect.extend({ toBeWithinRange(r: number, a: number, b: number) { return { pass: r >= a && r <= b, message: () => `expected ${r} to be within range ${a} - ${b}` }; } });\nit("marker", async () => { %s });\n' "$body" > src/__tests__/marker.test.ts
  out=$(bash "$TDD" red src/__tests__/marker.test.ts 2>&1) || { echo "FAIL: a Vitest assertion failure must be accepted: $body; output: $out"; exit 1; }
  [ "$(lock_field . '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: $body must be the assertion RED, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
done
cd / && rm -rf "$A"

# --- a file-level failure with every assertion passed -------------------------
# Vitest and Jest mark a file failed for a suite-level error (a throwing
# afterAll, for instance) while each assertion in it passed. Green must refuse
# that and carry the file's message (PR #57 review). Real Vitest cannot be made
# to emit it without editing the locked test, which the hash check refuses, so
# a stub runner writes the report shape for each step from a mode file.
T=$(cd "$(mktemp -d)" && pwd -P)
git -C "$T" init -q
git -C "$T" config user.email t@t; git -C "$T" config user.name t
mkdir -p "$T/src/__tests__" "$T/node_modules/.bin"
printf 'it("scores", () => {});\n' > "$T/src/__tests__/score.test.ts"
cat > "$T/node_modules/.bin/vitest" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do case "$arg" in --outputFile=*) report="${arg#--outputFile=}" ;; esac; done
name="$PWD/src/__tests__/score.test.ts"
case "$(cat "$PWD/.stub-mode")" in
  red) jq -n --arg n "$name" '{testResults:[{name:$n, status:"failed", message:"", assertionResults:[{title:"scores", status:"failed", failureMessages:["AssertionError: expected 1 to be 2"]}]}]}' ;;
  teardown) jq -n --arg n "$name" '{testResults:[{name:$n, status:"failed", message:"Error: teardown broke", assertionResults:[{title:"scores", status:"passed", failureMessages:[]}]}]}' ;;
  green) jq -n --arg n "$name" '{testResults:[{name:$n, status:"passed", message:"", assertionResults:[{title:"scores", status:"passed", failureMessages:[]}]}]}' ;;
esac > "$report"
STUB
chmod +x "$T/node_modules/.bin/vitest"
printf 'node_modules\n.stub-mode\n' > "$T/.gitignore"
git -C "$T" add -A && git -C "$T" commit -qm "chore: init"
cd "$T"
echo red > .stub-mode
bash "$TDD" open "T-1 teardown" >/dev/null
bash "$TDD" red src/__tests__/score.test.ts >/dev/null || { echo "FAIL: the stub RED must be accepted"; exit 1; }
echo teardown > .stub-mode
expect_fail "green with a file-level failure" bash "$TDD" green | grep -q 'teardown broke' || { echo "FAIL: green must refuse a failed file whose assertions all passed, naming the file's message"; exit 1; }
[ "$(lock_field . .phase)" = "red" ] || { echo "FAIL: a refused green must leave the phase red"; exit 1; }
echo green > .stub-mode
bash "$TDD" green >/dev/null || { echo "FAIL: the stub GREEN must be accepted once the file passes"; exit 1; }
cd / && rm -rf "$T"

# --- test node ids under Jest, and a suite-level error beside them ------------
# No Jest is bundled, so a stub writes Jest's JSON report shape (fullName is
# the describe titles and the title joined by spaces) for each step from a
# mode file (PR #74 review). With ids named, a file whose own message carries
# a suite-level error (a throwing afterAll) is refused at red even though its
# results look like a clean RED beside a passing neighbour.
J=$(cd "$(mktemp -d)" && pwd -P)
git -C "$J" init -q
git -C "$J" config user.email t@t; git -C "$J" config user.name t
mkdir -p "$J/src/__tests__" "$J/node_modules/.bin"
printf 'test("scores", () => {});\ndescribe("boost", () => { test("doubles", () => {}); });\n' > "$J/src/__tests__/score.test.js"
cat > "$J/node_modules/.bin/jest" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do case "$arg" in --outputFile=*) report="${arg#--outputFile=}" ;; esac; done
name="$PWD/src/__tests__/score.test.js"
scores='{title:"scores", fullName:"scores", ancestorTitles:[], status:"passed", failureMessages:[]}'
case "$(cat "$PWD/.stub-mode")" in
  teardown) jq -n --arg n "$name" "{testResults:[{name:\$n, status:\"failed\", message:\"Error: teardown broke\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\"Error: expect(received).toBe(expected)\"]}]}]}" ;;
  red) jq -n --arg n "$name" "{testResults:[{name:\$n, status:\"failed\", message:\"\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\"Error: expect(received).toBe(expected)\"]}]}]}" ;;
  duplicate) jq -n --arg n "$name" "{testResults:[{name:\$n, status:\"failed\", message:\"\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\"Error: expect(received).toBe(expected)\"]}, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\"Error: thrown: Exceeded timeout of 5000 ms\"]}]}]}" ;;
  unreadable) jq -n --arg n "$name" "{testResults:[{name:\$n, status:\"failed\", message:\"\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\"Error: expect(received).toBe(expected)\"]}, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:null}]}]}" ;;
  plain|mock|assertions|alias|nodeassert|colour|custom)
    case "$(cat "$PWD/.stub-mode")" in
      plain) failure='Error: timeout: expected reply' ;;
      mock) failure='Error: expect(jest.fn()).toHaveBeenCalledWith(...expected)' ;;
      assertions) failure='Error: expect.assertions(1)' ;;
      alias) failure='Error: expect(jest.fn()).lastCalledWith(...expected)' ;;
      nodeassert) failure=$'assert.strictEqual(received, expected)\n\nExpected value to strictly be equal to:\n  2' ;;
      colour) failure=$'Error: \e[2mexpect(\e[22m\e[31mreceived\e[39m\e[2m).\e[22mtoBe\e[2m(\e[22m\e[32mexpected\e[39m\e[2m) // Object.is equality\e[22m' ;;
      custom) failure=$'Error: expected 10 to be within range 1 - 3\n    at Object.toBeWithinRange (/src/__tests__/score.test.js:4:35)' ;;
    esac
    jq -n --arg n "$name" --arg f "$failure" "{testResults:[{name:\$n, status:\"failed\", message:\"\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"failed\", failureMessages:[\$f]}]}]}" ;;
  green) jq -n --arg n "$name" "{testResults:[{name:\$n, status:\"passed\", message:\"\", assertionResults:[$scores, {title:\"doubles\", fullName:\"boost doubles\", ancestorTitles:[\"boost\"], status:\"passed\", failureMessages:[]}]}]}" ;;
esac > "$report"
STUB
chmod +x "$J/node_modules/.bin/jest"
printf 'node_modules\n.stub-mode\n' > "$J/.gitignore"
git -C "$J" add -A && git -C "$J" commit -qm "chore: init"
cd "$J"
bash "$TDD" open "J-1 boost doubles" >/dev/null
echo teardown > .stub-mode
expect_fail "jest node red with a suite-level error" bash "$TDD" red "src/__tests__/score.test.js::boost doubles" | grep -q 'teardown broke' || { echo "FAIL: node red must refuse a file whose suite-level message carries an error, naming it"; exit 1; }
# Two tests may share one full name; each result is classified on its own, so
# a timeout beside an assertion under the same name is refused (PR #74 review).
echo duplicate > .stub-mode
expect_fail "jest node red with a duplicate-named unclassified failure" bash "$TDD" red "src/__tests__/score.test.js::boost doubles" | grep -q 'boost doubles fails for a reason this script does not classify: Error: thrown: Exceeded timeout' || { echo "FAIL: each result sharing a full name must be classified on its own"; exit 1; }
# A failing result whose messages cannot be read (failureMessages null) is
# refused by name rather than left out, even after a classified result under
# the same name, so the file cannot be locked on the readable result alone
# (IAN-160 review, PR #81 Copilot review).
echo unreadable > .stub-mode
expect_fail "jest node red with unreadable failure messages" bash "$TDD" red "src/__tests__/score.test.js::boost doubles" | grep -q 'src/__tests__/score.test.js::boost doubles failed with no failure message to classify' || { echo "FAIL: a failing result with unreadable messages must be refused by name, not locked on the other result's assertion"; exit 1; }
# A plain Error mentioning "expected" is not the assertion RED under Jest
# either. Jest's own assertion output is, in the shapes real Jest 29 writes: a
# matcher hint (a mock matcher, a spy alias such as lastCalledWith, the hint
# ANSI-coloured under FORCE_COLOR), expect.assertions, node:assert reformatted
# by jest-circus, and an expect.extend matcher's frame (IAN-161).
echo plain > .stub-mode
expect_fail "jest node red on a plain error" bash "$TDD" red "src/__tests__/score.test.js::boost doubles" | grep -q 'does not classify: Error: timeout: expected reply' || { echo "FAIL: under Jest a plain error mentioning expected must be refused as unclassified"; exit 1; }
for mode in mock assertions alias nodeassert colour custom; do
  echo "$mode" > .stub-mode
  out=$(bash "$TDD" red "src/__tests__/score.test.js::boost doubles" 2>&1) || { echo "FAIL: the Jest $mode matcher hint must be the assertion RED; output: $out"; exit 1; }
  [ "$(lock_field . '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: the Jest $mode matcher hint must be the assertion RED, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
done
echo red > .stub-mode
expect_fail "jest node red on a bare title" bash "$TDD" red "src/__tests__/score.test.js::doubles" | grep -q 'no test in src/__tests__/score.test.js matches doubles' || { echo "FAIL: under Jest a bare title must be refused; the id is the full name"; exit 1; }
out=$(bash "$TDD" red "src/__tests__/score.test.js::boost doubles" 2>&1) || { echo "FAIL: jest node red must accept the named failing test; output: $out"; exit 1; }
[ "$(lock_field . '.baseline.runner')" = "jest" ] || { echo "FAIL: the jest runner must be recorded, got $(lock_field . '.baseline.runner')"; exit 1; }
[ "$(lock_field . '.tests[0].ids[0]')" = "boost doubles" ] || { echo "FAIL: the jest id must be recorded, got $(lock_field . '.tests[0].ids')"; exit 1; }
[ "$(lock_field . '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: a Jest expect failure must be the assertion RED, got $(lock_field . '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field . '.baseline.passed')" = "1" ] || { echo "FAIL: the jest baseline must count the passing neighbour, got $(lock_field . '.baseline.passed')"; exit 1; }
echo green > .stub-mode
bash "$TDD" green >/dev/null 2>&1 || { echo "FAIL: jest node green must accept once the named test passes"; exit 1; }
cd / && rm -rf "$J"

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

# red: a bash fixture is one test, so a test id after the path is refused;
# the fixture file itself is the unit.
expect_fail "shell red with a test id" bash "$TDD" red "tests/score.test.sh::expected 2" | grep -q 'name the fixture file' || { echo "FAIL: a test id on a bash fixture must be refused, saying the file is the unit"; exit 1; }

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
expect_fail "shell green while failing" bash "$TDD" green | grep -q 'expected 2, got 1' || { echo "FAIL: a still-failing shell green must carry the fixture's FAIL line"; exit 1; }
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

# A fixture that writes a relative path writes it outside the project: the
# suite runs from a scratch directory, so nothing lands in the slice's tree
# (PR #49 review).
printf '#!/usr/bin/env bash\ntouch leaked-by-fixture.txt\necho "writer PASS"\n' > tests/writer.test.sh
git add tests/writer.test.sh && git commit -qm "test: a fixture that writes a relative path"
bash "$TDD" open --refactor "S-4 containment" --lock tests/score.test.sh >/dev/null || { echo "FAIL: open --refactor with a writing sibling must succeed"; exit 1; }
[ ! -e leaked-by-fixture.txt ] || { echo "FAIL: a fixture's relative write must not land in the project root"; exit 1; }
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null
[ ! -e leaked-by-fixture.txt ] || { echo "FAIL: a fixture's relative write must not land in the project root during green"; exit 1; }

# close from open: with no test ever locked nothing was written under the
# lock, so an abandoned slice can close; once a test is locked it cannot.
bash "$TDD" open "S-3 abandoned" >/dev/null
bash "$TDD" close >/dev/null || { echo "FAIL: close must work from open when no test was locked"; exit 1; }
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: close from open must remove the lock"; exit 1; }

cd / && rm -rf "$S"
echo "tdd-red-green.test.sh PASS"
