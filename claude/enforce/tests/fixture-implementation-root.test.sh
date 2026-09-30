#!/usr/bin/env bash
# fixture-implementation-root.test.sh: the static half of the proof that the
# fixture suites verify the implementation carried by THIS checkout and not
# the copy installed under ~/.claude (2026-09-18 audit, verification-integrity
# defect 3). Every fixture in both trees must resolve its subject through
# enforce/harness-root.sh, and the handful of files still allowed to name
# $HOME/.claude are listed here one by one with the reason each is
# legitimate. harness-root.sh must also leave the write-side runtime state
# (CLAUDE_FIRE_LOG, CLAUDE_SESSION_LOCK_DIR) unbound, or the suites would
# write into the working tree.
#
# Both checks are cheap, so this file stays in the fast tier and runs on every
# Stop and every tdd.sh red and green, which keeps a new fixture that reads
# its subject through $HOME from slipping past a local run. The dynamic half,
# which runs real fixtures against a sabotaged install and takes minutes, is
# fixture-implementation-root-sabotage.test.sh (split out under IAN-510).
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

# Succeeds when sourcing harness-root.sh in a clean shell leaves every runtime
# state variable unset. Runs in a child shell with the whole binding set and
# the runtime names cleared first, so the answer describes what the helper
# exports rather than what this process happened to inherit.
runtime_state_stays_unbound() {
  local reset_flags=() binding
  while IFS= read -r flag; do reset_flags+=("$flag"); done < <(harness_binding_reset_flags)
  for binding in "${HARNESS_UNBOUND_RUNTIME_STATE[@]}"; do
    reset_flags+=("-u" "$binding")
  done
  local leaked
  leaked=$(env "${reset_flags[@]}" bash -c \
    '. "$1/enforce/harness-root.sh"; for name in "${@:2}"; do
       [ -z "${!name:-}" ] || printf "%s=%s\n" "$name" "${!name}"
     done' _ "$CLAUDE_HARNESS_ROOT" "${HARNESS_UNBOUND_RUNTIME_STATE[@]}")
  [ -z "$leaked" ] && return 0
  printf '%s\n' "$leaked" | while IFS= read -r line; do
    echo "  harness-root.sh bound runtime state it must leave alone: $line"
  done
  return 1
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
#   fixture-implementation-root.test.sh  this file, which names the pattern
#   fixture-implementation-root-sabotage.test.sh  builds the sabotaged install
#                                 the proof depends on
#   settings-permission-rules.test.sh  exercises tilde expansion in permission
#                                 rules, so $HOME is the DATA under test (the
#                                 fixture overrides HOME to a sandbox first);
#                                 the helper it drives comes from the harness
#                                 root like every other subject
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
  "fixture-implementation-root-sabotage.test.sh"
  "settings-permission-rules.test.sh"
)

check "no fixture outside the recorded allowlist selects its subject through \$HOME" \
  no_unlisted_home_reference
check "harness-root.sh leaves the write-side runtime state unbound" \
  runtime_state_stays_unbound

[ "$fail" -eq 0 ] && echo "fixture-implementation-root.test.sh PASS"
exit "$fail"
