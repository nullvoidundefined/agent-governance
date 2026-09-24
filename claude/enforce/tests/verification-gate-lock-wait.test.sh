#!/usr/bin/env bash
# Covers: hook:verification-gate
# Verifies that the R-509 Stop gate fits a queued fixture run inside the Stop
# hook's 660-second budget (IAN-351). The fixture runner queues behind a
# machine-wide lock and gives up after FIXTURE_SHARDS_LOCK_WAIT_SECONDS
# (default 1200, IAN-348), which the harness would cut off at 660 seconds
# before the runner could say why. So the gate exports a 480-second cap for
# every check it runs, whatever the caller's shell exported, and does not
# retry a check that exits 75, the runner giving up on the lock, because a
# retry would wait a second 480 seconds and overrun the budget anyway. The
# suite wrappers passing that 75 through is suite-wrappers-lock-give-up.test.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/verification-gate.sh"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
export CLAUDE_VERIFY_MEMO_DIR CLAUDE_VERIFY_RETRY_DELAY=0
CLAUDE_VERIFY_MEMO_DIR=$(mktemp -d)

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
not() { ! "$@"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/verification-gate-lock-wait.XXXXXX")
trap 'rm -rf "$SANDBOX" "$CLAUDE_VERIFY_MEMO_DIR"' EXIT

# gate_reason <repo>: runs the Stop gate on the repo and prints the block
# reason, or "none" when it lets the turn end.
gate_reason() {
  local gate_output
  gate_output=$(jq -n --arg c "$1" '{hook_event_name:"Stop",cwd:$c,stop_hook_active:false}' | "$HOOK")
  if [ -z "$gate_output" ]; then echo none; else printf '%s' "$gate_output" | jq -r '.reason // "none"'; fi
}

# new_governance_repo <name>: a dirty repo shaped like this one, whose enforce
# suite is the stub the case writes and whose hook suite passes.
new_governance_repo() {
  local repo="$SANDBOX/$1"
  mkdir -p "$repo/claude/enforce/tests" "$repo/claude/hooks/tests"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  touch "$repo/claude/CLAUDE.md"
  git -C "$repo" add -A && git -C "$repo" commit -qm "chore: init"
  printf 'exit 0\n' > "$repo/claude/hooks/tests/run-tests.sh"
  echo dirty > "$repo/dirty.txt"
  echo "$repo"
}

# Case 1: every check the gate runs sees the 480-second cap, even when the
# shell that started the session exported the runner's own default.
REPO=$(new_governance_repo cap)
printf 'echo "LOCK_WAIT[${FIXTURE_SHARDS_LOCK_WAIT_SECONDS:-unset}]"\nexit 1\n' > "$REPO/claude/enforce/tests/run-tests.sh"
reason=$(FIXTURE_SHARDS_LOCK_WAIT_SECONDS=1200 gate_reason "$REPO")
check "the gate runs the fixture suites with a 480-second lock wait" grep -qF 'LOCK_WAIT[480]' <<< "$reason"

# Case 2: a suite that exits 75, the runner giving up on the lock, runs once
# and blocks with a reason that says so, rather than retrying into a second wait.
REPO=$(new_governance_repo give-up)
RUN_LOG="$SANDBOX/give-up-runs"
: > "$RUN_LOG"
printf 'echo run >> "%s"\necho "fixture-shards: gave up after 480s waiting for PID 4242"\nexit 75\n' "$RUN_LOG" > "$REPO/claude/enforce/tests/run-tests.sh"
reason=$(gate_reason "$REPO")
check "a lock give-up blocks the turn" grep -q 'R-509' <<< "$reason"
check "a lock give-up runs the suite once, with no retry" test "$(wc -l < "$RUN_LOG" | tr -d ' ')" = 1
check "a lock give-up does not claim an automatic retry" not grep -q 'automatic retry' <<< "$reason"
check "a lock give-up says another fixture run held the lock" grep -q 'another fixture run held the machine-wide lock' <<< "$reason"
check "a lock give-up keeps the runner's own message" grep -q 'waiting for PID 4242' <<< "$reason"

# Case 3: a 75 from any other check is an ordinary failure. A project's own
# .claude/verify.sh may exit 75 (EX_TEMPFAIL) for its own reasons, so it keeps
# the one automatic retry and is never described as a fixture lock give-up
# (PR #133 review).
REPO="$SANDBOX/project-verify"
mkdir -p "$REPO/.claude"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo base > "$REPO/tracked.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "chore: init"
VERIFY_RUN_LOG="$SANDBOX/project-verify-runs"
: > "$VERIFY_RUN_LOG"
printf 'echo run >> "%s"\nexit 75\n' "$VERIFY_RUN_LOG" > "$REPO/.claude/verify.sh"
reason=$(gate_reason "$REPO")
check "a project check exiting 75 still blocks" grep -q 'R-509' <<< "$reason"
check "a project check exiting 75 keeps its automatic retry" test "$(wc -l < "$VERIFY_RUN_LOG" | tr -d ' ')" = 2
check "a project check exiting 75 is not called a fixture lock give-up" not grep -q 'another fixture run held the machine-wide lock' <<< "$reason"

if [ "$fail" -eq 0 ]; then echo "verification-gate-lock-wait: PASS"; else echo "verification-gate-lock-wait: FAIL"; exit 1; fi
