#!/usr/bin/env bash
# Shard: slow
# Covers: hook:protected-path-guard
# Verifies `tdd.sh amend` (R-410, R-412): the author of a slice fixes a bug in
# the test it just proved RED without the user deleting the lock. The first
# `amend <test>` opens a window in which that one file, and nothing else, is
# writable; the second re-runs the suite, requires the amended test to still
# fail for a classified reason, re-hashes it, and records the amendment. It is
# refused for a test the slice did not lock, outside phase red (after green
# above all), and once the RED version of the test has been pushed. Drives the
# bash *.test.sh runner through the real run-fixture-shards.sh and the real
# protected-path-guard.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"

P=$(cd "$(mktemp -d)" && pwd -P)
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
mkdir -p "$P/tests" "$P/scripts"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

# A RED fixture calling scripts/score.sh, which does not exist yet, expecting $1.
score_test() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = %s ] || { echo "FAIL: expected %s, got $out"; exit 1; }\necho "score.test.sh PASS"\n' "$1" "$1" > tests/score.test.sh
}
lock_field() { jq -r "$1" .claude/tdd-lock.json; }
expect_fail() {
  local label="$1" out; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}
write_decision() {
  local out
  out=$(jq -nc --arg f "$P/$1" --arg d "$P" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"x"}}' | CLAUDE_FIRE_LOG=/dev/null "$HOOK")
  if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

# amend with no slice, and from phase open, is refused.
expect_fail "amend with no lock" bash "$TDD" amend tests/baseline.test.sh | grep -q 'tdd.sh open' || { echo "FAIL: amend without a lock must name tdd.sh open"; exit 1; }
bash "$TDD" open "A-1 score.sh prints 3" >/dev/null
score_test 2
expect_fail "amend while open" bash "$TDD" amend tests/score.test.sh | grep -q 'only while' || { echo "FAIL: amend from phase open must be refused"; exit 1; }

# The author proves a RED, then notices the test expects the wrong value.
bash "$TDD" red tests/score.test.sh >/dev/null
red_sha=$(lock_field '.tests[0].sha256')
expect_fail "amend of a test the slice did not lock" bash "$TDD" amend tests/baseline.test.sh | grep -q 'earlier slice' || { echo "FAIL: amending a test outside the lock must be refused as an earlier slice's test"; exit 1; }

# Opening the window: only the test under amendment is writable.
bash "$TDD" amend tests/score.test.sh | grep -q 'AMENDING' || { echo "FAIL: the first amend must open the window and say AMENDING"; exit 1; }
[ "$(lock_field .phase)" = "amending" ] || { echo "FAIL: amend must move the phase to amending, got $(lock_field .phase)"; exit 1; }
[ "$(lock_field .amending.path)" = "tests/score.test.sh" ] || { echo "FAIL: the lock must record the path under amendment"; exit 1; }
[ "$(write_decision tests/score.test.sh)" = allow ] || { echo "FAIL: the test under amendment must be writable"; exit 1; }
[ "$(write_decision tests/baseline.test.sh)" = deny ] || { echo "FAIL: another test must stay locked while amending"; exit 1; }
[ "$(write_decision scripts/score.sh)" = deny ] || { echo "FAIL: production must be read-only while amending"; exit 1; }
expect_fail "green while amending" bash "$TDD" green | grep -q 'amend' || { echo "FAIL: green must be refused while an amendment is open"; exit 1; }
expect_fail "close while amending" bash "$TDD" close >/dev/null

# An amendment that makes the test pass is not a RED: refused, window stays open.
printf '#!/usr/bin/env bash\necho "score.test.sh PASS"\n' > tests/score.test.sh
expect_fail "amend to a passing test" bash "$TDD" amend tests/score.test.sh | grep -qi 'already passes' || { echo "FAIL: an amended test that passes must be refused"; exit 1; }
[ "$(lock_field .phase)" = "amending" ] || { echo "FAIL: a refused amendment must leave the window open"; exit 1; }

# The real fix: expect 3. Still RED, re-hashed, recorded, phase red again.
score_test 3
bash "$TDD" amend tests/score.test.sh | grep -q 'RED' || { echo "FAIL: the second amend must re-prove the RED"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: a finished amendment must return the phase to red"; exit 1; }
[ "$(lock_field '.amending // "none"')" = "none" ] || { echo "FAIL: a finished amendment must clear the window"; exit 1; }
new_sha=$(shasum -a 256 tests/score.test.sh | awk '{print $1}')
[ "$(lock_field '.tests[0].sha256')" = "$new_sha" ] || { echo "FAIL: the lock must carry the amended test's hash"; exit 1; }
[ "$(lock_field '.amendments | length')" = "1" ] || { echo "FAIL: the lock must record one amendment"; exit 1; }
[ "$(lock_field '.amendments[0].fromSha256')" = "$red_sha" ] || { echo "FAIL: the amendment must record the RED hash it replaced"; exit 1; }
[ "$(lock_field '.amendments[0].toSha256')" = "$new_sha" ] || { echo "FAIL: the amendment must record the new hash"; exit 1; }
[ "$(lock_field '.amendments[0].failureClass')" = "missing-module" ] || { echo "FAIL: the amendment must record the failure class"; exit 1; }
[ "$(write_decision tests/score.test.sh)" = deny ] || { echo "FAIL: the amended test must be locked again once red"; exit 1; }

# The amended test is the contract green checks.
printf '#!/usr/bin/env bash\necho 3\n' > scripts/score.sh
bash "$TDD" green >/dev/null || { echo "FAIL: green must pass against the amended test"; exit 1; }
expect_fail "amend after green" bash "$TDD" amend tests/score.test.sh | grep -q 'only while' || { echo "FAIL: amend after green must be refused"; exit 1; }
bash "$TDD" close >/dev/null

# A RED that has been pushed is shared history: amend is refused.
REMOTE=$(cd "$(mktemp -d)" && pwd -P)
git init -q --bare "$REMOTE"
git remote add origin "$REMOTE"
git add -A && git commit -qm "feat: score prints 3"
bash "$TDD" open "A-2 score.sh rejects letters" >/dev/null
printf '#!/usr/bin/env bash\nset -euo pipefail\nbash "$(dirname "$0")/../scripts/reject.sh" && { echo "FAIL: letters accepted"; exit 1; }\necho "reject.test.sh PASS"\n' > tests/reject.test.sh
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/reject.sh
git add scripts/reject.sh && git commit -qm "chore: reject stub"
bash "$TDD" red tests/reject.test.sh >/dev/null
git add tests/reject.test.sh && git commit -qm "test: RED for letters"
git push -q origin HEAD:refs/heads/feature 2>/dev/null
expect_fail "amend after the RED is pushed" bash "$TDD" amend tests/reject.test.sh | grep -q 'pushed' || { echo "FAIL: amend after the RED commit is pushed must be refused"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: a refused amend must leave the phase red"; exit 1; }

cd /; rm -rf "$P" "$REMOTE"
echo "tdd-amend.test.sh PASS"
