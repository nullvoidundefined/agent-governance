#!/usr/bin/env bash
# Covers: hook:verification-gate
#
# Verifies slice B-3 of IAN-156: hooks/verification-gate.sh stops blocking a
# Stop or SubagentStop whose only failure is the RED the open slice already
# recorded, and goes on blocking everything else.
#
# Why the exemption exists: R-509 refuses to let a turn or a writing subagent
# end on a red suite, which is the one outcome a test author's role exists to
# produce, so the gate blocked all fifteen test-author runs of the
# hook-bypass-deny PR (IAN-141). Slice B-2 built the question the gate needs
# (`enforce/tdd.sh expected-red`, commit 9d6b0eb): it exits 0 when the slice
# lock is in phase "red" and every failure in the suite is one of the test
# files that lock records, and non-zero in every other situation, writing
# nothing either way. This slice wires the gate to that answer.
#
# The contract this fixture pins, case by case:
#
#   1. a failing check whose `expected-red` answers 0 releases the turn: the
#      gate writes nothing at all on stdout (that channel carries the block
#      JSON, so the subcommand's own "tdd.sh: EXPECTED RED: ..." line must not
#      leak into it) and exits 0;
#   2. the same failing check whose `expected-red` answers non-zero still
#      blocks, with the reason text the gate already emits (R-509, the check
#      command, and the check's own output);
#   3. a passing check never asks the question at all, so a green turn does
#      not pay for a whole extra suite run;
#   4. an `expected-red` that is missing, that is not executable, or that
#      errors out is not an answer of "yes", so the gate blocks. The exemption
#      fails closed: a broken or absent tdd.sh must never become a way to end
#      a turn on a red suite;
#   5. the SubagentStop exemption for a role whose enforce/role-policy.json
#      entry is deny ["any"] is untouched, and the roles that are gated
#      (test-author, implementer) get the new exemption like the main session.
#
# How the situation is built. The gate resolves its siblings from its own
# BASH_SOURCE (RELATED_HELPER and PORT_CHECKS_HELPER already do), and this
# fixture assumes it resolves tdd.sh the same way, as
# <hook dir>/../enforce/tdd.sh. So every case runs a sandbox copy of the hook:
# verification-gate.sh and the helpers it sources are copied into a throwaway
# harness tree, and a stand-in enforce/tdd.sh sits beside them whose answer a
# file selects, whose invocations are logged with the directory they ran in,
# and which refuses any subcommand other than `expected-red`. That stand-in is
# how a missing, non-executable, or erroring tdd.sh can be presented at all,
# and it keeps these cases off the real suite: what B-2 already proves about
# which red suites are expected is not re-proven here, only that the gate asks
# and obeys.
#
# Every assertion is on what the gate emits (the block object and its reason)
# and on its exit status. The one thing read off the stand-in is whether it ran
# at all, which is the only observable form of "a passing run must not pay for
# it" and of "a deny-any role is exempted before any check runs".
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
REAL_HARNESS="$CLAUDE_HARNESS_ROOT"

# Pin the policy the SubagentStop branch reads to this checkout, and keep the
# telemetry log out of the live tree.
export CLAUDE_ROLE_POLICY_FILE="$REAL_HARNESS/enforce/role-policy.json"
export CLAUDE_VERIFY_RETRY_DELAY=0
CLAUDE_FIRE_LOG=$(mktemp)
export CLAUDE_FIRE_LOG

# The marker the project's own check prints, so a block can be shown to carry
# the real command output rather than a summary of it.
CHECK_MARKER="GATE_CHECK_MARKER"

fail() { echo "FAIL: $*"; exit 1; }

# Builds a throwaway harness tree holding the hook under test and a stand-in
# enforce/tdd.sh beside it, and prints its path. `kind` is one of:
#   present       a working stand-in whose answer the sandbox's answer file
#                 selects (expected -> exit 0 with a line on stdout, like the
#                 real `say`; unexpected -> exit 1 with the reason on stderr,
#                 like the real `die`; erroring -> exit 3, a tdd.sh that broke
#                 rather than one that answered);
#   missing       no enforce/tdd.sh at all;
#   unexecutable  a stand-in that would answer "expected" but carries no
#                 execute bit, which is a tdd.sh the gate cannot trust to have
#                 answered anything.
# The stand-in refuses any subcommand but `expected-red`, so a gate that asked
# a different question would be caught by its own fail-closed path.
new_harness() {
  local kind="$1" sandbox
  sandbox=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "$sandbox/hooks" "$sandbox/enforce"
  cp "$REAL_HARNESS/hooks/verification-gate.sh" "$sandbox/hooks/verification-gate.sh"
  cp "$REAL_HARNESS/hooks/log-rule-fire.sh" "$sandbox/hooks/log-rule-fire.sh"
  cp "$REAL_HARNESS/enforce/related-tests.sh" "$sandbox/enforce/related-tests.sh"
  cp "$REAL_HARNESS/enforce/port-checks.sh" "$sandbox/enforce/port-checks.sh"
  printf 'expected\n' > "$sandbox/answer"
  if [ "$kind" != missing ]; then
    cat > "$sandbox/enforce/tdd.sh" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$PWD" "\$*" >> "$sandbox/invocations.log"
if [ "\${1:-}" != expected-red ]; then
  printf 'tdd.sh: usage: tdd.sh open | red | green | expected-red | close | status | validate\n' >&2
  exit 1
fi
case "\$(cat "$sandbox/answer")" in
  expected) printf 'tdd.sh: EXPECTED RED: every failure is one of the 1 locked test file(s)\n'; exit 0 ;;
  unexpected) printf 'tdd.sh: other.test.sh is red and the lock does not record it\n' >&2; exit 1 ;;
  *) printf 'tdd.sh: jq: command not found\n' >&2; exit 3 ;;
esac
STUB
    chmod +x "$sandbox/enforce/tdd.sh"
    [ "$kind" != unexecutable ] || chmod -x "$sandbox/enforce/tdd.sh"
  fi
  echo "$sandbox"
}

set_answer() { printf '%s\n' "$2" > "$1/answer"; }

# The invocations the stand-in recorded, one "<directory> <arguments>" line
# per call, or nothing when it was never asked.
invocations() { cat "$1/invocations.log" 2>/dev/null || true; }

# A throwaway project whose only check is the project verify script (it wins
# over all discovery), exiting with the given status after printing the
# marker, and which carries a phase-red slice lock the way a test author's
# tree does. The lock is there so that a gate which looks for one before
# asking still asks; nothing in this fixture reads it, because judging it is
# tdd.sh's job.
new_project() {
  local check_status="$1" dir
  dir=$(cd "$(mktemp -d)" && pwd -P)/repo
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo base > "$dir/tracked.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "chore: init"
  printf 'echo %s\nexit %s\n' "$CHECK_MARKER" "$check_status" > "$dir/.claude/verify.sh"
  cat > "$dir/.claude/tdd-lock.json" <<LOCK
{
  "slice": "B-3 the stop gate releases a turn whose red is the slice's own",
  "phase": "red",
  "tests": [
    { "path": "claude/enforce/tests/score.test.sh", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "failureClass": "assertion", "tests": 1 }
  ],
  "baseline": { "passed": 2, "runner": "bash" }
}
LOCK
  echo "$dir"
}

# Drives the sandboxed gate over one project, leaving its stdout in
# GATE_OUTPUT and its exit status in GATE_STATUS. Each run gets its own memo
# directory: the gate's pass memo would otherwise let one case's outcome
# silence the next case on the same tree, and whether an excused red tree may
# be memoized at all is not part of this slice.
run_gate() {
  local sandbox="$1" dir="$2" event="${3:-Stop}" agent="${4:-}" memo
  memo=$(mktemp -d)
  GATE_STATUS=0
  GATE_OUTPUT=$(jq -n --arg c "$dir" --arg e "$event" --arg g "$agent" \
    '{hook_event_name:$e,cwd:$c,stop_hook_active:false} + (if $g=="" then {} else {agent_type:$g} end)' \
    | CLAUDE_VERIFY_MEMO_DIR="$memo" bash "$sandbox/hooks/verification-gate.sh" 2>/dev/null) || GATE_STATUS=$?
}

# The gate released the turn: nothing on the decision channel, exit 0.
assert_released() {
  [ "$GATE_STATUS" -eq 0 ] || fail "$1: the gate must exit 0, it exited $GATE_STATUS"
  [ -z "$GATE_OUTPUT" ] || fail "$1: the gate must emit no decision at all, it emitted: $GATE_OUTPUT"
}

# The gate blocked, with the reason text it already emits: R-509, the failing
# check, and the check's own output.
assert_blocked() {
  local decision reason
  [ "$GATE_STATUS" -eq 0 ] || fail "$1: a blocking gate still exits 0, it exited $GATE_STATUS"
  decision=$(printf '%s' "$GATE_OUTPUT" | jq -r '.decision // ""' 2>/dev/null) \
    || fail "$1: the gate must emit one JSON decision object and nothing else, it emitted: $GATE_OUTPUT"
  [ "$decision" = block ] || fail "$1: expected a block decision, got: ${GATE_OUTPUT:-<nothing>}"
  reason=$(printf '%s' "$GATE_OUTPUT" | jq -r '.reason // ""')
  grep -q 'R-509' <<< "$reason" || fail "$1: the block must keep its R-509 reason text, got: $reason"
  grep -q "$CHECK_MARKER" <<< "$reason" || fail "$1: the block must keep the check's own output, got: $reason"
}

# 1. A failing check whose expected-red answers 0 is the slice's own RED, so
# the turn ends. The question is asked from the repository root, where the
# lock lives, and asked as exactly `expected-red`.
SANDBOX=$(new_harness present); PROJECT=$(new_project 1)
set_answer "$SANDBOX" expected
run_gate "$SANDBOX" "$PROJECT"
assert_released "1 a failing check confirmed as the expected RED"
CALLS=$(invocations "$SANDBOX")
[ -n "$CALLS" ] || fail "1: the gate must ask tdd.sh expected-red before blocking on a red suite; it never ran it"
while IFS= read -r call; do
  [ -n "$call" ] || continue
  [ "$call" = "$PROJECT expected-red" ] \
    || fail "1: expected-red must be asked from the repository root as 'tdd.sh expected-red'; got the call [$call], wanted [$PROJECT expected-red]"
done <<< "$CALLS"

# 2. The same failing check, with expected-red refusing: the suite is red for
# a reason this slice never claimed, so the gate blocks exactly as before.
set_answer "$SANDBOX" unexpected
run_gate "$SANDBOX" "$PROJECT"
assert_blocked "2 a failing check that expected-red refuses"

# 3. A passing check never asks: the exemption is consulted only once a check
# has actually failed, so a green turn pays nothing for it.
SANDBOX=$(new_harness present); PROJECT=$(new_project 0)
set_answer "$SANDBOX" expected
run_gate "$SANDBOX" "$PROJECT"
assert_released "3 a passing check"
[ -z "$(invocations "$SANDBOX")" ] \
  || fail "3: a passing check must not ask expected-red at all, but tdd.sh ran: $(invocations "$SANDBOX")"

# 4. Fail closed, three ways: a tdd.sh that is absent, one that cannot be
# executed, and one that errors out rather than answering. None of them is an
# answer of "this red is expected", so the red suite still blocks the turn.
SANDBOX=$(new_harness missing); PROJECT=$(new_project 1)
run_gate "$SANDBOX" "$PROJECT"
assert_blocked "4a a missing enforce/tdd.sh"

SANDBOX=$(new_harness unexecutable); PROJECT=$(new_project 1)
set_answer "$SANDBOX" expected
run_gate "$SANDBOX" "$PROJECT"
assert_blocked "4b an enforce/tdd.sh that cannot be executed"

SANDBOX=$(new_harness present); PROJECT=$(new_project 1)
set_answer "$SANDBOX" erroring
run_gate "$SANDBOX" "$PROJECT"
assert_blocked "4c an enforce/tdd.sh that errors instead of answering"

# 5. SubagentStop. The test author is the role the whole slice exists for, and
# it is gated like the main session, so its confirmed RED releases it; the
# implementer is gated too, so an unconfirmed red still blocks it; and the
# deny ["any"] roles keep their old exemption, which short-circuits before any
# check runs and therefore before any question is asked.
SANDBOX=$(new_harness present); PROJECT=$(new_project 1)
set_answer "$SANDBOX" expected
run_gate "$SANDBOX" "$PROJECT" SubagentStop test-author
assert_released "5a SubagentStop for the test author on its own expected RED"

set_answer "$SANDBOX" unexpected
run_gate "$SANDBOX" "$PROJECT" SubagentStop implementer
assert_blocked "5b SubagentStop for the implementer on an unconfirmed red"

SANDBOX=$(new_harness present); PROJECT=$(new_project 1)
set_answer "$SANDBOX" unexpected
run_gate "$SANDBOX" "$PROJECT" SubagentStop slice-critic
assert_released "5c SubagentStop for a deny-any role"
[ -z "$(invocations "$SANDBOX")" ] \
  || fail "5c: a deny-any role is exempted before any check runs, so nothing must have been asked; tdd.sh ran: $(invocations "$SANDBOX")"

echo "verification-gate-expected-red.test.sh PASS"
