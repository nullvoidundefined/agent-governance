#!/usr/bin/env bash
# fixture-implementation-root.test.sh: proves that the fixture suites verify
# the implementation carried by THIS checkout and not the copy that happens to
# be installed under ~/.claude (2026-09-18 audit, verification-integrity
# defect 3).
#
# The defect this closes was not theoretical. Most fixtures opened their
# subject as "$HOME/.claude/hooks/<name>.sh", and neither runner bound that
# location to the checkout, so a pre-push run on one branch could verify the
# hooks that a different branch had last synced into the live tree. The suite
# went green or red according to which branch ran ./sync.sh most recently
# rather than according to the code being pushed. Continuous integration
# symlinks the checkout at ~/.claude, so the drift never showed up there.
#
# The proof is a deliberate divergence rather than an inspection. A sandbox
# home receives a complete copy of the checkout's hooks with exactly one of
# them sabotaged into a no-op, the real fixtures for that hook are then run
# against that sandbox home, and they must still pass, which they can only do
# by reading the checkout's correct copy. A positive control runs the same
# fixture with CLAUDE_HARNESS_ROOT pointed at the sabotaged tree and requires
# it to fail, so a fixture that silently stopped exercising the hook at all
# cannot make the first assertion pass for the wrong reason.
#
# A third assertion keeps the sweep swept: every fixture in both trees must
# resolve its subject through enforce/harness-root.sh, and the handful of
# files still allowed to name $HOME/.claude are listed here one by one with
# the reason each is legitimate.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

fail=0

# Reports one named assertion and records a failure without aborting, so a
# single run reports every problem rather than only the first.
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# Runs one fixture file against the sabotaged sandbox home and succeeds when
# that fixture still passes. CLAUDE_HARNESS_ROOT is stripped from the child's
# environment so the child resolves its own root from its own location, which
# is the behaviour under test; HOME points at the sabotaged install.
fixture_passes_against_sabotaged_home() {
  local fixture="$1" out
  out=$(env -u CLAUDE_HARNESS_ROOT HOME="$SANDBOX" CLAUDE_FIRE_LOG=/dev/null \
    bash "$fixture" 2>&1)
  printf '%s' "$out" | grep -q 'PASS' && ! printf '%s' "$out" | grep -q 'FAIL'
}

# Runs one fixture file with CLAUDE_HARNESS_ROOT aimed at the sabotaged tree
# and succeeds when that fixture fails. This is the positive control: it shows
# the fixture really does read its subject out of the root it is given, so the
# assertion above is a statement about resolution and not about a fixture that
# quietly asserts nothing.
fixture_fails_against_sabotaged_root() {
  local fixture="$1" out
  out=$(CLAUDE_HARNESS_ROOT="$SANDBOX/.claude" CLAUDE_FIRE_LOG=/dev/null \
    bash "$fixture" 2>&1)
  printf '%s' "$out" | grep -q 'FAIL' || [ -z "$out" ]
}

# Succeeds when no fixture outside the recorded allowlist names $HOME/.claude
# on a line of code. Comment lines are skipped: prose explaining the live tree
# cannot select an implementation, and several fixture headers legitimately
# describe how the install relates to the checkout. Prints every offending file
# and line so the fix is obvious from the output.
no_unlisted_home_reference() {
  local offenders
  offenders=$(grep -rn '\$HOME/\.claude' "$CLAUDE_HARNESS_ROOT/enforce/tests" \
    "$CLAUDE_HARNESS_ROOT/hooks/tests" 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -vE "/($(printf '%s|' "${HOME_REFERENCE_ALLOWLIST[@]}" | sed 's/|$//')):")
  [ -z "$offenders" ] && return 0
  printf '%s\n' "$offenders" | while IFS= read -r line; do
    echo "  unlisted \$HOME reference: $line"
  done
  return 1
}

# Every fixture permitted to spell $HOME/.claude, with the reason it is not an
# instance of the defect. Anything not on this list must resolve its subject
# through CLAUDE_HARNESS_ROOT instead.
#
#   hook-latency.test.sh          measures the INSTALLED hooks on purpose;
#                                 that is the diagnostic it exists to provide
#   build-cheatsheets.test.sh     writes its trust list into a sandbox HOME
#   pre-push-sample.test.sh       builds and removes installs under a sandbox HOME
#   global-repo-push-guard.test.sh builds the legacy ~/.claude repo layout in a
#                                 sandbox HOME as fixture data
#   task-state-tracker.test.sh    asserts that the REAL home was not written to
#   post-compact-rules.test.sh    names the retired sentinel, which is runtime
#                                 state under the live home rather than code
#   install-git-hooks.test.sh     the path appears inside the hook body the
#                                 script writes, as text, not as a lookup
#   tdd-red-green.test.sh         falls back to the live install only to LOCATE
#                                 enforce/node_modules, which is gitignored
#                                 machine state; tdd.sh itself comes from the
#                                 harness root
#   fixture-implementation-root.test.sh  this file, which builds the sabotaged
#                                 install the proof depends on
HOME_REFERENCE_ALLOWLIST=(
  "hook-latency.test.sh"
  "build-cheatsheets.test.sh"
  "pre-push-sample.test.sh"
  "global-repo-push-guard.test.sh"
  "task-state-tracker.test.sh"
  "post-compact-rules.test.sh"
  "install-git-hooks.test.sh"
  "tdd-red-green.test.sh"
  "fixture-implementation-root.test.sh"
)

mkdir -p "$SANDBOX/.claude"
cp -R "$CLAUDE_HARNESS_ROOT/hooks" "$SANDBOX/.claude/hooks"
# The sabotage: an installed no-em-dash.sh that approves everything. A fixture
# reading the installed copy sees a hook that never denies and fails; a fixture
# reading the checkout sees the real hook and passes.
printf '#!/usr/bin/env bash\n# sabotaged installed copy: never denies\nexit 0\n' \
  > "$SANDBOX/.claude/hooks/no-em-dash.sh"
chmod +x "$SANDBOX/.claude/hooks/no-em-dash.sh"

check "the enforce-tree no-em-dash fixture tests the checkout, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/enforce/tests/no-em-dash.test.sh"
check "the hooks-tree log-rule-fire fixture tests the checkout, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/hooks/tests/log-rule-fire.test.sh"
check "the no-em-dash fixture does fail when its root really is the sabotaged tree" \
  fixture_fails_against_sabotaged_root "$CLAUDE_HARNESS_ROOT/enforce/tests/no-em-dash.test.sh"
check "no fixture outside the recorded allowlist selects its subject through \$HOME" \
  no_unlisted_home_reference

[ "$fail" -eq 0 ] && echo "fixture-implementation-root.test.sh PASS"
exit "$fail"
