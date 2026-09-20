#!/usr/bin/env bash
# Verifies `enforce/tdd.sh expected-red`, the read-only question
# hooks/verification-gate.sh will ask before it blocks a turn on a red suite
# (R-509, IAN-156, owner decision 2026-09-20): it exits 0 when a slice lock is
# open in phase "red" and every failure in the suite is one of the test files
# that lock records, and exits non-zero in every other situation.
#
# Why the subcommand has to exist: a test author's whole job is to end its turn
# on the RED its slice asked for, so the stop gate blocks it every single time,
# and it blocked all fifteen test-author runs of the hook-bypass-deny PR. The
# gate cannot answer "is this red the expected one?" without parsing four test
# runners, while tdd.sh already normalizes every runner into one report and
# already holds the list of test files the RED named, so the gate asks tdd.sh
# instead of learning the runners. This slice builds the question only; wiring
# the gate to it is a later slice.
#
# The situations this fixture drives, each through the real tdd.sh in throwaway
# repositories laid out the way this one is (a repository root holding
# claude/enforce/tests/), never in the checkout:
#
#   1. no lock on disk at all: non-zero, because nothing records which failure
#      was expected;
#   2. phase open: non-zero, because the failing test has not been proven to
#      fail for the right reason yet;
#   3. phase red with the locked fixture as the suite's only failure: 0;
#   4. phase red with an unrelated sibling fixture failing beside it:
#      non-zero, and the reason names that sibling so a human reading the
#      gate's output can see which file has to be fixed;
#   5. phase red where the only other failure is hook-hashes-closure.test.sh
#      reporting integrity-manifest drift confined to the locked test file: 0,
#      because writing the slice's own fixture is what put an unhashed file
#      under enforce/tests/ in the first place (slice B-1, commit bcf40a1),
#      while drift naming any other path stays non-zero;
#   6. phase refactor and phase green: non-zero even though every failure in
#      the suite does lie inside the locked files, because a slice past its
#      RED, or one that never had a RED, has no expected failure left. Those
#      two phases are reached honestly, by running a refactor slice in a
#      throwaway repository of its own rather than by editing a lock, and the
#      failure is placed inside the locked set on purpose: an implementation
#      that checked only the file list and skipped the phase would exit 0
#      there.
#
# Every invocation is also checked for writing nothing at all: the gate runs
# this on a tree it is about to block or release, so the subcommand must leave
# the lock byte-identical (the phase in particular must not advance) and must
# leave `git status` exactly as it found it, temporary files included. The mode
# file that selects each situation lives beside the repository rather than
# inside it, so it can never disturb that comparison.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

# The two lines the real hook-hashes-closure.test.sh prints when a new file
# appears under enforce/tests/: the reverse-closure line, which names the
# drifting path, and the content-drift line, which names a hook to run and
# carries no drifting path at all.
CLOSURE_REVERSE_LINE='FAIL: %s is covered by the R-203 guard but absent from the manifest (new file without a --update)\n'
CLOSURE_CONTENT_LINE='FAIL: the guard reports content drift between the installed tree and the committed manifest; run hooks/hook-integrity-check.sh --update and commit the manifest with the change\n'

fail() { echo "FAIL: $*"; exit 1; }

# Lays out a throwaway repository mirroring this checkout, and prints its path.
# It always carries a passing baseline fixture, a sibling that fails only in
# the sibling-red mode, and a stand-in closure fixture that reports manifest
# drift only in the two drift modes; with "with-red" it also carries the
# slice's RED fixture, whose script is never written, so that fixture fails for
# the whole run. A single mode file, written beside the repository so git never
# sees it, selects the situation. The drift paths the stand-in prints are
# spelled relative to claude/, as the real fixture spells them, while tdd.sh
# names its test files relative to the repository root one level above.
new_suite_project() {
  local variant="$1" dir tests mode
  dir=$(cd "$(mktemp -d)" && pwd -P)/repo
  tests="$dir/claude/enforce/tests"
  mode="$dir.mode"
  mkdir -p "$tests" "$dir/claude/enforce/scripts"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$tests/baseline.test.sh"
  if [ "$variant" = with-red ]; then
    # The locked RED fixture: the script it calls is never written, so bash's
    # own "No such file or directory" keeps it failing for the whole run, and
    # it is the one failure a phase-red lock expects.
    printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > "$tests/score.test.sh"
  fi
  cat > "$tests/other.test.sh" <<STUB
#!/usr/bin/env bash
if [ "\$(cat "$mode")" = sibling-red ]; then
  echo "FAIL: other.test.sh broke for its own reasons"
  exit 1
fi
echo "other.test.sh PASS"
STUB
  cat > "$tests/hook-hashes-closure.test.sh" <<STUB
#!/usr/bin/env bash
case "\$(cat "$mode")" in
  drift-named) drifting="enforce/tests/score.test.sh" ;;
  drift-foreign) drifting="enforce/tests/other.test.sh" ;;
  *) echo "hook-hashes-closure.test.sh PASS"; exit 0 ;;
esac
printf '$CLOSURE_REVERSE_LINE' "\$drifting"
printf '$CLOSURE_CONTENT_LINE'
exit 1
STUB
  printf 'clean\n' > "$mode"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

lock_field() { jq -r "$1" .claude/tdd-lock.json; }

# Everything `expected-red` is forbidden to change: the exact bytes of the lock
# (so the phase cannot advance and no field can be rewritten) and the whole
# working tree as git sees it, untracked files included, which catches a stray
# report or a leftover lock temporary beside it.
tree_snapshot() {
  if [ -f .claude/tdd-lock.json ]; then shasum -a 256 .claude/tdd-lock.json | awk '{print $1}'; else echo "no lock"; fi
  git status --porcelain --untracked-files=all
}

# Runs `tdd.sh expected-red` in one suite mode, leaving its combined output in
# EXPECTED_OUTPUT and its exit status in EXPECTED_STATUS, and failing outright
# when the run changed anything on disk.
run_expected_red_in_mode() {
  local before after
  printf '%s\n' "$1" > "$PROJECT.mode"
  before=$(tree_snapshot)
  EXPECTED_STATUS=0
  EXPECTED_OUTPUT=$(bash "$TDD" expected-red 2>&1) || EXPECTED_STATUS=$?
  after=$(tree_snapshot)
  [ "$before" = "$after" ] || fail "expected-red must write nothing: the gate runs it on a tree it is about to block or release. Before: $before. After: $after"
}

# Phase refactor and phase green are driven first, in a repository of their
# own: a refactor slice opens on a green suite with all three fixtures locked,
# and `tdd.sh green` moves it on from there, so both phases are reached by
# running tdd.sh rather than by editing a lock behind its back. In both phases
# the fixture that then fails is one of the locked files, so an implementation
# that checked the file list and skipped the phase would wrongly exit 0.
PROJECT=$(new_suite_project all-green); cd "$PROJECT"
bash "$TDD" open --refactor "B-2 phases other than red are never an expected RED" \
  --lock claude/enforce/tests/baseline.test.sh \
  --lock claude/enforce/tests/other.test.sh \
  --lock claude/enforce/tests/hook-hashes-closure.test.sh >/dev/null \
  || fail "the setup refactor slice must open on the green suite"
[ "$(lock_field .phase)" = refactor ] || fail "the setup left phase $(lock_field .phase), not refactor"

run_expected_red_in_mode sibling-red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "a refactor slice has no RED to expect, so a failing locked fixture must still refuse; expected-red exited 0: $EXPECTED_OUTPUT"
grep -q 'refactor' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the phase it found (refactor); got: $EXPECTED_OUTPUT"

printf 'clean\n' > "$PROJECT.mode"
bash "$TDD" green >/dev/null 2>&1 || fail "the setup green must be recorded before expected-red can be exercised in phase green"
[ "$(lock_field .phase)" = green ] || fail "the setup left phase $(lock_field .phase), not green"

run_expected_red_in_mode sibling-red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "phase green is past the RED, so a failing locked fixture must refuse; expected-red exited 0: $EXPECTED_OUTPUT"
grep -q 'green' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the phase it found (green); got: $EXPECTED_OUTPUT"

cd / && rm -rf "$(dirname "$PROJECT")" "$PROJECT.mode"

# The rest of the fixture works in a repository that carries a genuinely
# failing locked fixture, which is the situation the gate meets on a test
# author's return.
PROJECT=$(new_suite_project with-red); cd "$PROJECT"

# No lock on disk: nothing records which failures were expected, so a red suite
# can never be the expected one, and the refusal says why.
run_expected_red_in_mode clean
[ "$EXPECTED_STATUS" -ne 0 ] || fail "with no lock on disk there is no record of an expected RED, so expected-red must exit non-zero; it exited 0: $EXPECTED_OUTPUT"
[ -n "$EXPECTED_OUTPUT" ] || fail "the refusal with no lock must state a reason, and it printed nothing"

bash "$TDD" open "B-2 expected-red asks whether a red suite is the slice's own" >/dev/null

# Phase open: the failing test has not been proven to fail for the right reason
# yet, so its failure is not an expected one.
run_expected_red_in_mode clean
[ "$EXPECTED_STATUS" -ne 0 ] || fail "phase open carries no recorded RED, so expected-red must exit non-zero; it exited 0: $EXPECTED_OUTPUT"
grep -q 'open' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the phase it found (open); got: $EXPECTED_OUTPUT"

printf 'clean\n' > "$PROJECT.mode"
bash "$TDD" red claude/enforce/tests/score.test.sh >/dev/null \
  || fail "the setup red must be recorded before expected-red can be exercised in phase red"

# Phase red with the locked fixture as the suite's only failure: this red is
# exactly the one the slice asked for, so the gate may release the turn.
run_expected_red_in_mode clean
[ "$EXPECTED_STATUS" -eq 0 ] || fail "phase red whose only failing file is the locked one is the expected RED; expected-red exited $EXPECTED_STATUS: $EXPECTED_OUTPUT"
[ "$(lock_field .phase)" = red ] || fail "expected-red must leave the phase at red, got $(lock_field .phase)"

# A second, unrelated fixture failing beside it: the suite is red for a reason
# this slice never claimed, and the refusal names the file to fix.
run_expected_red_in_mode sibling-red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "a failing fixture outside the locked files makes the suite red for an unexpected reason; expected-red exited 0: $EXPECTED_OUTPUT"
grep -q 'other.test.sh' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the unexpected failing fixture other.test.sh; got: $EXPECTED_OUTPUT"

# Integrity-manifest drift confined to the locked test file is the expected
# consequence of having written that test, so it does not make the suite
# unexpectedly red.
run_expected_red_in_mode drift-named
[ "$EXPECTED_STATUS" -eq 0 ] || fail "manifest drift confined to the locked test file must not make the RED unexpected; expected-red exited $EXPECTED_STATUS: $EXPECTED_OUTPUT"

# Drift naming a path the lock does not record is drift this slice cannot
# account for, so it refuses and names the fixture that is red.
run_expected_red_in_mode drift-foreign
[ "$EXPECTED_STATUS" -ne 0 ] || fail "drift naming enforce/tests/other.test.sh, which the lock does not record, must refuse; expected-red exited 0: $EXPECTED_OUTPUT"
grep -q 'hook-hashes-closure.test.sh' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name hook-hashes-closure.test.sh as the fixture that is red; got: $EXPECTED_OUTPUT"

cd / && rm -rf "$(dirname "$PROJECT")" "$PROJECT.mode"
echo "tdd-expected-red.test.sh PASS"
