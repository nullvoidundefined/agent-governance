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
# The toleration is bounded on two sides, and both bounds are checked here. It
# applies only where a RED is being judged: by the time `tdd.sh green` runs, an
# unhashed file under enforce/tests/ is no longer the unfinished work the red
# command was asked to accept, and the only thing a tolerated hook-hash drift
# could hide at that point is an edited hook, which the owner's decision of
# 2026-09-20 refuses to accept, so green must refuse while the drift is still
# present and must succeed once it has been cleared. It also applies only to
# the two spellings that can really name a locked test file, the
# harness-relative one the closure fixture prints and the repository-root one
# tdd.sh uses; any shorter trailing run of path components (a bare basename, or
# an intermediate suffix such as tests/score.test.sh) names some other file in
# the tree, or no file at all, and must refuse.
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
# the stand-in closure fixture, which passes in the clean mode, standing for a
# manifest that has caught up with the tree, and reports drift in every other. The drift paths the stand-in prints are written
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
  clean) echo "hook-hashes-closure.test.sh PASS"; exit 0 ;;
  foreign) drifting="enforce/tests/other.test.sh" ;;
  same-basename) drifting="hooks/tests/score.test.sh" ;;
  basename-only) drifting="score.test.sh" ;;
  intermediate-suffix) drifting="tests/score.test.sh" ;;
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

# Runs `tdd.sh green` on the slice in one drift mode, leaving tdd.sh's combined
# output in GREEN_OUTPUT and its exit status in GREEN_STATUS.
run_green_in_mode() {
  echo "$1" > "$PROJECT/.drift-mode"
  GREEN_STATUS=0
  GREEN_OUTPUT=$(bash "$TDD" green 2>&1) || GREEN_STATUS=$?
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

# A drifting path that is only a trailing run of the named file's path
# components is not a spelling of that file. A bare basename would name any
# file of that name anywhere in the tree, so it cannot be read as the locked
# claude/enforce/tests/score.test.sh, and it refuses.
run_red_in_mode basename-only
[ "$RED_STATUS" -ne 0 ] || fail "drift naming the bare basename score.test.sh does not name the locked claude/enforce/tests/score.test.sh and must refuse; tdd.sh exited 0: $RED_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$RED_OUTPUT" || fail "the bare-basename refusal must name hook-hashes-closure.test.sh; got: $RED_OUTPUT"
[ "$(lock_field .phase)" = open ] || fail "a refused red must leave the phase open, got $(lock_field .phase)"

# An intermediate suffix is the same case one component further in:
# tests/score.test.sh is neither the harness-relative spelling the closure
# fixture prints nor the repository-root spelling tdd.sh uses, so it refuses
# too. Only those two spellings are legitimate, and matching on any trailing
# component sequence would tolerate drift in a file the red command never
# named.
run_red_in_mode intermediate-suffix
[ "$RED_STATUS" -ne 0 ] || fail "drift naming tests/score.test.sh is neither legitimate spelling of the locked file and must refuse; tdd.sh exited 0: $RED_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$RED_OUTPUT" || fail "the intermediate-suffix refusal must name hook-hashes-closure.test.sh; got: $RED_OUTPUT"
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

# With the RED recorded, the implementation the slice asked for arrives: the
# script the locked fixture calls now exists and prints the 2 it expects, so
# that fixture passes. The drift is still on disk and still names the locked
# test file, but a green is not a RED being judged, and tolerating hook-hash
# drift here would let an integrity change to the hooks ride out of the
# implementer's turn unnoticed, so green must refuse and must say which fixture
# is red.
printf '#!/usr/bin/env bash\necho 2\n' > "$PROJECT/claude/enforce/scripts/score.sh"
run_green_in_mode named
[ "$GREEN_STATUS" -ne 0 ] || fail "green must refuse while the manifest drift tolerated at red is still present; tdd.sh exited 0: $GREEN_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$GREEN_OUTPUT" || fail "the green refusal must name hook-hashes-closure.test.sh as the fixture that is red; got: $GREEN_OUTPUT"
! grep -q 'GREEN:' <<< "$GREEN_OUTPUT" || fail "a refused green must not report GREEN:; got: $GREEN_OUTPUT"
[ "$(lock_field .phase)" = red ] || fail "a refused green must leave the phase red, got $(lock_field .phase)"

# Clearing the drift, which is what committing the updated manifest does, is
# the only thing that changes, and the same green now succeeds: the refusal
# above was about the drift and not about the implementation or the lock.
run_green_in_mode clean
[ "$GREEN_STATUS" -eq 0 ] || fail "with the drift cleared the same green must succeed; tdd.sh exited $GREEN_STATUS: $GREEN_OUTPUT"
grep -q 'GREEN:' <<< "$GREEN_OUTPUT" || fail "an accepted green must report GREEN:; got: $GREEN_OUTPUT"
[ "$(lock_field .phase)" = green ] || fail "an accepted green must move the phase to green, got $(lock_field .phase)"

cd / && rm -rf "$PROJECT"
echo "tdd-red-manifest-drift.test.sh PASS"
