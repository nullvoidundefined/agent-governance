#!/usr/bin/env bash
# Verifies the half of `enforce/tdd.sh expected-red` that looks at the locked
# tests themselves rather than at everything around them: the locked files on
# disk must still be byte-identical to the sha256 the lock recorded at the RED,
# and at least one of them must actually be failing in the run. Membership,
# which is the question "is anything outside the locked files failing?", is
# covered by the sibling fixture tdd-expected-red.test.sh and is not retested
# here beyond the one control case below.
#
# Why this matters now: hooks/verification-gate.sh was wired to expected-red in
# commit 6aa8d2a, so a yes from this subcommand ends a turn that R-509 would
# otherwise block on a red suite. The R-517 review of PR #91 found that
# expected-red never verifies the locked files at all: it runs the suite and
# asks outside_pass_count whether anything outside the locked files failed, and
# it neither compares the recorded hashes nor requires a locked test to still
# be failing. The reviewer rewrote a locked fixture to `echo garbage; exit 3`
# after its RED and expected-red still exited 0. That was harmless while
# nothing called the subcommand; now it means a test author that mangled its
# own locked fixture after proving RED would end its turn clean, which defeats
# both R-410, under which the tests are the contract from RED until close, and
# R-509 (IAN-184).
#
# The three situations driven here, each against one phase-red lock produced by
# running the real `tdd.sh open` and `tdd.sh red` in a throwaway repository
# laid out the way this checkout is (a repository root holding
# claude/enforce/tests/), never in the checkout itself. Every one of them
# leaves the suite with nothing failing outside the locked files, so a
# membership-only implementation exits 0 on all three:
#
#   1. the locked fixture has started passing, because the script its RED said
#      was missing now exists beside it and nothing else in the suite fails:
#      non-zero, since membership is satisfied vacuously, no failure is left
#      for the lock to claim, and a green suite needs no excusing from the gate
#      in the first place;
#   2. the locked fixture was rewritten after its RED and is still the suite's
#      only failure: non-zero, because its bytes no longer match the sha256 the
#      lock recorded for it. check_hashes in the same script already makes
#      exactly this comparison for `tdd.sh green`, and is read-only, so the
#      implementation is expected to reuse it rather than restate it;
#   3. the locked fixture was deleted after its RED: non-zero, because the
#      shell runner reports only the files it can find, so the report holds
#      nothing but passing siblings and a membership-only check sees a clean
#      suite. A lock whose test is gone records a RED that can no longer be
#      shown.
#
# A control case runs first, on the untouched RED, and requires exit 0. It is
# there so that a refusal in the three cases below can only be the mutation
# each one makes: if this fixture's own setup were broken, the control would
# fail instead and say so.
#
# Every invocation is also checked for writing nothing at all, refusals
# included: the gate runs expected-red on a tree it is about to block or
# release, so the subcommand must leave the lock byte-identical (the phase in
# particular must not advance) and must leave `git status` exactly as it found
# it, untracked files included, which catches a stray report or a leftover lock
# temporary beside it.
#
# This is deliberately a separate file from tdd-expected-red.test.sh rather
# than more cases inside it. Editing that tracked fixture makes
# hook-hashes-closure.test.sh report content drift between the installed tree
# and the committed manifest, and that line names no path, while
# drift_is_confined in tdd.sh tolerates drift only when a reverse-closure line
# names a path the lock records. An edit to the existing fixture therefore
# could never reach a clean RED: the turn-end gate would block the test author
# and expected-red itself would refuse the drift. A new file under
# enforce/tests/ produces the reverse-closure line naming that new path, which
# is the tolerated case (IAN-184, measured 2026-09-20).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

fail() { echo "FAIL: $*"; exit 1; }

# Lays out a throwaway repository mirroring this checkout, and prints its path.
# It carries a passing baseline fixture and the slice's RED fixture, whose
# script is never written, so bash's own "No such file or directory" keeps that
# fixture failing for the whole run and it is the one failure a phase-red lock
# expects. The empty scripts directory is where a later case drops the script
# that makes the RED fixture pass, exactly as the implementation it asked for
# would.
new_red_project() {
  local dir tests
  dir=$(cd "$(mktemp -d)" && pwd -P)/repo
  tests="$dir/claude/enforce/tests"
  mkdir -p "$tests" "$dir/claude/enforce/scripts"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$tests/baseline.test.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > "$tests/score.test.sh"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

lock_field() { jq -r "$1" .claude/tdd-lock.json; }

# Everything `expected-red` is forbidden to change: the exact bytes of the lock
# (so the phase cannot advance and no field can be rewritten) and the whole
# working tree as git sees it, untracked files included.
tree_snapshot() {
  if [ -f .claude/tdd-lock.json ]; then shasum -a 256 .claude/tdd-lock.json | awk '{print $1}'; else echo "no lock"; fi
  git status --porcelain --untracked-files=all
}

# Runs `tdd.sh expected-red` in the current repository, leaving its combined
# output in EXPECTED_OUTPUT and its exit status in EXPECTED_STATUS, and failing
# outright when the run changed anything on disk.
run_expected_red() {
  local before after
  before=$(tree_snapshot)
  EXPECTED_STATUS=0
  EXPECTED_OUTPUT=$(bash "$TDD" expected-red 2>&1) || EXPECTED_STATUS=$?
  after=$(tree_snapshot)
  [ "$before" = "$after" ] || fail "expected-red must write nothing: the gate runs it on a tree it is about to block or release. Before: $before. After: $after"
}

PROJECT=$(new_red_project); cd "$PROJECT"
bash "$TDD" open "B-3a expected-red verifies the locked tests, not only their membership" >/dev/null \
  || fail "the setup slice must open on the throwaway repository"
bash "$TDD" red claude/enforce/tests/score.test.sh >/dev/null \
  || fail "the setup red must be recorded before expected-red can be exercised in phase red"
[ "$(lock_field .phase)" = red ] || fail "the setup left phase $(lock_field .phase), not red"

# The control: the RED as it was recorded, untouched. Everything below mutates
# this state, so this case failing would mean the fixture's own setup is wrong
# rather than the behavior under test.
run_expected_red
[ "$EXPECTED_STATUS" -eq 0 ] || fail "control: the untouched RED this fixture just recorded must be an expected RED, or the cases below prove nothing; expected-red exited $EXPECTED_STATUS: $EXPECTED_OUTPUT"

# The locked fixture has started passing: score.sh, the script its RED said was
# missing, now exists beside it, so the suite is entirely green without anyone
# having touched a locked file. Nothing outside the locked files fails, yet no
# failure is left for this lock to claim.
printf '#!/usr/bin/env bash\necho 2\n' > claude/enforce/scripts/score.sh
run_expected_red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "every locked test passing leaves no RED for the slice to claim, so expected-red must refuse; it exited 0: $EXPECTED_OUTPUT"
grep -q 'score.test.sh' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the locked test that is no longer failing (score.test.sh); got: $EXPECTED_OUTPUT"

# The locked fixture rewritten after its RED: it still fails and it is still
# the suite's only failure, so a membership-only check sees the expected RED,
# but its bytes no longer match the sha256 the lock recorded for it. The lock
# is the contract from RED until close (R-410), so a test author that mangled
# its own fixture after proving RED must not have its turn released.
printf '#!/usr/bin/env bash\necho "FAIL: rewritten after the RED was recorded"\nexit 1\n' > claude/enforce/tests/score.test.sh
run_expected_red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "a locked test file edited after its RED no longer matches the lock (R-410), so expected-red must refuse even though nothing outside the locked files failed; it exited 0: $EXPECTED_OUTPUT"
grep -q 'score.test.sh' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the locked file whose bytes no longer match the lock (score.test.sh); got: $EXPECTED_OUTPUT"
grep -qE 'changed|differ|modified|R-410' <<< "$EXPECTED_OUTPUT" || fail "the refusal must say the locked file no longer matches what the lock recorded, so its reader can tell an integrity refusal from an unrelated failure; got: $EXPECTED_OUTPUT"

# The locked fixture deleted after its RED: the runner reports only the files
# it can find, so the report holds nothing but passing siblings and a
# membership-only check sees a clean suite.
rm claude/enforce/tests/score.test.sh
run_expected_red
[ "$EXPECTED_STATUS" -ne 0 ] || fail "a locked test file deleted after its RED leaves nothing that can fail, so expected-red must refuse; it exited 0: $EXPECTED_OUTPUT"
grep -q 'score.test.sh' <<< "$EXPECTED_OUTPUT" || fail "the refusal must name the locked file that is gone (score.test.sh); got: $EXPECTED_OUTPUT"

cd / && rm -rf "$(dirname "$PROJECT")"
echo "tdd-expected-red-integrity.test.sh PASS"
