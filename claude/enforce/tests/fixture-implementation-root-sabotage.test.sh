#!/usr/bin/env bash
# Shard: slow
# Watches: enforce/harness-root.sh enforce/tdd.sh enforce/role-policy.json hooks/no-em-dash.sh hooks/log-rule-fire.sh hooks/enforcement-guard-check.sh
# fixture-implementation-root-sabotage.test.sh: the dynamic half of the proof
# that the fixture suites verify THIS checkout and not the install under
# ~/.claude, split from fixture-implementation-root.test.sh under IAN-510 so
# that its runs, which take minutes, are paid only when the resolution they
# prove can have changed: harness-root.sh, tdd.sh, the role policy, or the
# hooks and fixtures run below. CI runs it on every push.
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
# The DATA half, added 2026-09-18 after the first sweep left it standing.
# Binding the code alone proved only half of what the suite needs to be worth
# running. Eleven hooks read a data file as "${OVERRIDE:-$HOME/.claude/<path>}"
# and only a handful of fixtures ever set one of those variables, so a fixture
# could exercise the checkout's enforcement-guard-check.sh against whichever
# manifest.json the last ./sync.sh had written, and the verdict depended on
# unrelated history in exactly the way the code binding had. The proof here is
# the same shape as the code proof: the sandbox home receives a manifest.json,
# a role-policy.json and a settings.json whose CONTENT differs from the
# checkout's, real fixtures that read those files are run against it, and they
# must still pass, which they can only do by reading the checkout's copies. A
# positive control aims the data overrides themselves at the sabotaged files
# and requires the same fixtures to fail, so a fixture that reads no data at
# all cannot satisfy the first assertion by accident.
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

# Every binding enforce/harness-root.sh exports into the environment. A child
# fixture must resolve each of these for itself out of its own location, so
# every one of them is stripped before the child runs; leaving even one in
# place would let the child inherit the correct answer from this process and
# the proof below would assert nothing.
HARNESS_EXPORTED_BINDINGS=(
  "CLAUDE_HARNESS_ROOT"
  "CLAUDE_MANIFEST_FILE"
  "CLAUDE_ROLE_POLICY_FILE"
  "CLAUDE_SETTINGS_FILE"
  "REDACTION_GUARD_SETTINGS"
  "REDACTION_GUARD_HOOKS_DIR"
  "CLAUDE_PROTOCOL_FILE"
  "CLAUDE_INTEGRITY_ROOT"
  "CLAUDE_TDD_HOME"
  "CLAUDE_RULES_FILES"
)

# Runtime state that harness-root.sh must never bind, with the reason. These
# name files and directories their readers write rather than read, so a
# checkout-relative value would turn a fixture run into a write into the
# working tree.
HARNESS_UNBOUND_RUNTIME_STATE=(
  "CLAUDE_FIRE_LOG"
  "CLAUDE_SESSION_LOCK_DIR"
)

# Prints the `env` flags that clear every harness binding, one -u per name, so
# a child process starts from the same blank slate a fresh shell would.
harness_binding_reset_flags() {
  local binding
  for binding in "${HARNESS_EXPORTED_BINDINGS[@]}"; do
    printf '%s\n%s\n' "-u" "$binding"
  done
}

# Runs one fixture file against the sabotaged sandbox home and succeeds when
# that fixture still passes. Every harness binding is stripped from the
# child's environment so the child resolves its own code root and its own data
# paths from its own location, which is the behaviour under test; HOME points
# at the sabotaged install.
fixture_passes_against_sabotaged_home() {
  local fixture="$1" out
  local reset_flags=()
  while IFS= read -r flag; do reset_flags+=("$flag"); done < <(harness_binding_reset_flags)
  out=$(env "${reset_flags[@]}" HOME="$SANDBOX" CLAUDE_FIRE_LOG=/dev/null \
    bash "$fixture" 2>&1)
  grep -q 'PASS' <<< "$out" && ! grep -q 'FAIL' <<< "$out"
}

# Runs one fixture file with the DATA overrides aimed at the sabotaged sandbox
# copies and succeeds when that fixture fails. This is the data-side positive
# control: it shows the fixture really does read those files, so the assertion
# that it passes against the sabotaged home is a statement about which copy
# won and not about a fixture that consults no data at all. The code root is
# left to resolve normally, which isolates the variable under test to the data.
fixture_fails_against_sabotaged_data() {
  local fixture="$1" out
  out=$(env -u CLAUDE_HARNESS_ROOT \
    CLAUDE_MANIFEST_FILE="$SANDBOX/.claude/enforce/manifest.json" \
    CLAUDE_ROLE_POLICY_FILE="$SANDBOX/.claude/enforce/role-policy.json" \
    CLAUDE_TDD_HOME="$SANDBOX/.claude" \
    CLAUDE_FIRE_LOG=/dev/null \
    bash "$fixture" 2>&1)
  grep -q 'FAIL' <<< "$out"
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
  grep -q 'FAIL' <<< "$out" || [ -z "$out" ]
}

mkdir -p "$SANDBOX/.claude"
cp -R "$CLAUDE_HARNESS_ROOT/hooks" "$SANDBOX/.claude/hooks"
# The sabotage: an installed no-em-dash.sh that approves everything. A fixture
# reading the installed copy sees a hook that never denies and fails; a fixture
# reading the checkout sees the real hook and passes.
printf '#!/usr/bin/env bash\n# sabotaged installed copy: never denies\nexit 0\n' \
  > "$SANDBOX/.claude/hooks/no-em-dash.sh"
chmod +x "$SANDBOX/.claude/hooks/no-em-dash.sh"

# The data sabotage. Each file is well-formed JSON that parses cleanly and
# says something different from the checkout's copy: a manifest that registers
# no rule at all, a role policy that knows no role, and settings that register
# no hook. A fixture reading any of these reports the absence as a gap and
# fails; a fixture reading the checkout's copies passes.
mkdir -p "$SANDBOX/.claude/enforce"
printf '{"rules":[]}\n' > "$SANDBOX/.claude/enforce/manifest.json"
printf '{"roles":{},"patterns":{}}\n' > "$SANDBOX/.claude/enforce/role-policy.json"
printf '{"hooks":{}}\n' > "$SANDBOX/.claude/settings.json"

check "the enforce-tree no-em-dash fixture tests the checkout, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/enforce/tests/no-em-dash.test.sh"
check "the hooks-tree log-rule-fire fixture tests the checkout, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/hooks/tests/log-rule-fire.test.sh"
check "the no-em-dash fixture does fail when its root really is the sabotaged tree" \
  fixture_fails_against_sabotaged_root "$CLAUDE_HARNESS_ROOT/enforce/tests/no-em-dash.test.sh"
check "the enforcement-guard-check fixture reads the checkout's manifest, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/enforce/tests/enforcement-guard-check.test.sh"
check "the tdd fixture reads the checkout's role policy, not the sabotaged install" \
  fixture_passes_against_sabotaged_home "$CLAUDE_HARNESS_ROOT/enforce/tests/tdd-red-green.test.sh"
check "the enforcement-guard-check fixture does fail when the sabotaged manifest really is its data" \
  fixture_fails_against_sabotaged_data "$CLAUDE_HARNESS_ROOT/enforce/tests/enforcement-guard-check.test.sh"
check "the tdd fixture does fail when the sabotaged role policy really is its data" \
  fixture_fails_against_sabotaged_data "$CLAUDE_HARNESS_ROOT/enforce/tests/tdd-red-green.test.sh"

[ "$fail" -eq 0 ] && echo "fixture-implementation-root-sabotage.test.sh PASS"
exit "$fail"
