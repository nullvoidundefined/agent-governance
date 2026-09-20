#!/usr/bin/env bash
# Verifies that `enforce/tdd.sh red` records the RED when the only failure
# outside the named test files is hook-hashes-closure.test.sh reporting
# integrity-manifest drift, and every path that fixture names as drifting is
# one of the test files named in that same red command (IAN-156).
#
# Why the exemption has to exist: enforce/hook-hashes.txt covers
# enforce/tests/*.sh, so the act of writing a slice's own fixture puts a file
# on disk that the committed manifest does not carry. The closure fixture
# reports that as reverse-closure drift ("<path> is covered by the R-203 guard
# but absent from the manifest") and, because the integrity guard also sees the
# unhashed file, as content drift; outside_pass_count then refuses the red with
# "the rest of the suite is red, so nothing here is a clean RED", and a test
# author working in this repository can never reach a RED for a new fixture.
# The owner's decision of 2026-09-20 is that drift confined to the test files
# the red command names is the expected consequence of writing those tests and
# must not block the RED, while drift naming any other path, and any other
# failure outside the named files, must still refuse.
#
# The situation is built in a throwaway git repository laid out the way this
# one is (a repository root holding claude/enforce/tests/), never in the
# checkout: a stand-in hook-hashes-closure.test.sh prints the real fixture's
# own FAIL wording under the control of a mode file, so each direction is
# driven through the real tdd.sh without touching the real manifest. Both drift
# lines are printed together in every mode, the path-naming reverse-closure
# line and the path-less content-drift line, because that pair is exactly what
# the real fixture prints when a new file appears under enforce/tests/; the
# content-drift line names hooks/hook-integrity-check.sh as the command to run,
# which is a path-shaped token that is not a drifting path and must not be read
# as one.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

CLOSURE_REVERSE_LINE='FAIL: %s is covered by the R-203 guard but absent from the manifest (new file without a --update)\n'
CLOSURE_CONTENT_LINE='FAIL: the guard reports content drift between the installed tree and the committed manifest; run hooks/hook-integrity-check.sh --update and commit the manifest with the change\n'

fail() { echo "FAIL: $*"; exit 1; }

# Lays out a throwaway repository mirroring this checkout: the slice's RED
# fixture, a passing sibling, a second sibling that fails only in one mode, and
# the stand-in closure fixture. The drift paths the stand-in prints are written
# relative to claude/, as the real fixture prints them (its paths are relative
# to CLAUDE_DIR, which is the claude/ directory, while tdd.sh names its test
# files relative to the repository root one level above).
new_drift_project() {
  local dir tests
  dir=$(cd "$(mktemp -d)" && pwd -P)
  tests="$dir/claude/enforce/tests"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  mkdir -p "$tests" "$dir/claude/enforce/scripts"
  printf 'node_modules\n.drift-mode\n' > "$dir/.gitignore"
  printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$tests/baseline.test.sh"
  # The RED fixture: the script it calls is not written yet, so bash's own
  # "No such file or directory" is the missing-module RED for a shell slice.
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > "$tests/score.test.sh"
  cat > "$tests/other.test.sh" <<STUB
#!/usr/bin/env bash
if [ "\$(cat "$dir/.drift-mode")" = sibling-red ]; then
  echo "FAIL: other.test.sh broke for its own reasons"
  exit 1
fi
echo "other.test.sh PASS"
STUB
  cat > "$tests/hook-hashes-closure.test.sh" <<STUB
#!/usr/bin/env bash
case "\$(cat "$dir/.drift-mode")" in
  foreign) drifting="enforce/tests/other.test.sh" ;;
  same-basename) drifting="hooks/tests/score.test.sh" ;;
  named-exact) drifting="claude/enforce/tests/score.test.sh" ;;
  *) drifting="enforce/tests/score.test.sh" ;;
esac
printf '$CLOSURE_REVERSE_LINE' "\$drifting"
printf '$CLOSURE_CONTENT_LINE'
exit 1
STUB
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

lock_field() { jq -r "$1" .claude/tdd-lock.json; }

# Runs `tdd.sh red` on the slice's fixture in one drift mode, leaving tdd.sh's
# combined output in RED_OUTPUT and its exit status in RED_STATUS.
run_red_in_mode() {
  echo "$1" > "$PROJECT/.drift-mode"
  RED_STATUS=0
  RED_OUTPUT=$(bash "$TDD" red claude/enforce/tests/score.test.sh 2>&1) || RED_STATUS=$?
}

PROJECT=$(new_drift_project); cd "$PROJECT"
bash "$TDD" open "B-1 manifest drift confined to the named tests" >/dev/null

# Drift naming a path that is not one of the named test files still refuses,
# and the refusal names the fixture that is red.
run_red_in_mode foreign
[ "$RED_STATUS" -ne 0 ] || fail "drift naming enforce/tests/other.test.sh, which the red command did not name, must still refuse; tdd.sh exited 0: $RED_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$RED_OUTPUT" || fail "the refusal must name hook-hashes-closure.test.sh as the fixture that is red; got: $RED_OUTPUT"
[ "$(lock_field .phase)" = open ] || fail "a refused red must leave the phase open, got $(lock_field .phase)"

# A drifting path sharing the named file's basename in another tree is not the
# named file, so it refuses too: the match is on the path, not the basename.
run_red_in_mode same-basename
[ "$RED_STATUS" -ne 0 ] || fail "drift naming hooks/tests/score.test.sh must refuse: it is a different file from claude/enforce/tests/score.test.sh; tdd.sh exited 0: $RED_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$RED_OUTPUT" || fail "the basename-collision refusal must name hook-hashes-closure.test.sh; got: $RED_OUTPUT"
[ "$(lock_field .phase)" = open ] || fail "a refused red must leave the phase open, got $(lock_field .phase)"

# Any other failure outside the named files still refuses, even when the drift
# itself is confined to the named file: the exemption covers the closure
# fixture's manifest drift alone.
run_red_in_mode sibling-red
[ "$RED_STATUS" -ne 0 ] || fail "a failing sibling fixture beside the tolerated drift must still refuse; tdd.sh exited 0: $RED_OUTPUT"
grep -q 'other.test.sh' <<< "$RED_OUTPUT" || fail "the refusal must name the unrelated failing fixture other.test.sh; got: $RED_OUTPUT"
[ "$(lock_field .phase)" = open ] || fail "a refused red must leave the phase open, got $(lock_field .phase)"

# Drift confined to the test file the red command names records the RED.
run_red_in_mode named
[ "$RED_STATUS" -eq 0 ] || fail "drift confined to the named test file must not block the RED; tdd.sh exited $RED_STATUS: $RED_OUTPUT"
grep -q 'RED:' <<< "$RED_OUTPUT" || fail "an accepted red must report RED:; got: $RED_OUTPUT"
! grep -q 'the rest of the suite is red' <<< "$RED_OUTPUT" || fail "the tolerated drift must not be reported as a red suite; got: $RED_OUTPUT"
[ "$(lock_field .phase)" = red ] || fail "the tolerated drift must move the phase to red, got $(lock_field .phase)"
[ "$(lock_field '.tests[0].path')" = "claude/enforce/tests/score.test.sh" ] || fail "the lock must record the named fixture, got $(lock_field '.tests[0].path')"
[ "$(lock_field '.tests[0].failureClass')" = missing-module ] || fail "the missing script is the missing-module RED, got $(lock_field '.tests[0].failureClass')"
# The drifting closure fixture failed, so it contributes no passing test: the
# baseline is the two siblings that passed.
[ "$(lock_field '.baseline.passed')" = 2 ] || fail "the baseline must count the two passing siblings and not the failing closure fixture, got $(lock_field '.baseline.passed')"

# The drifting path may also arrive spelled from the repository root, the way
# tdd.sh itself names its test files; that is the same file and is tolerated.
run_red_in_mode named-exact
[ "$RED_STATUS" -eq 0 ] || fail "a drifting path spelled from the repository root names the same file and must be tolerated; tdd.sh exited $RED_STATUS: $RED_OUTPUT"
[ "$(lock_field .phase)" = red ] || fail "the repository-root spelling must record the RED, got $(lock_field .phase)"

cd / && rm -rf "$PROJECT"
echo "tdd-red-manifest-drift.test.sh PASS"
