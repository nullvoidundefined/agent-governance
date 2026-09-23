#!/usr/bin/env bash
# Covers: hook:codex-test-author-guard
# Verifies that codex-test-author-guard.sh reads the task-start ledger's tier
# (IAN-333). The owner's 2026-09-23 decision makes the independent test author
# a Complex and Saga requirement only: in Standard and Trivial the session
# writes the failing test itself under the R-412 lock, so the guard stays
# silent when the ledger in the test file's repository names the checked-out
# branch with one of those two tiers. Complex, Saga, a ledger for another
# branch, and a checkout with no ledger at all still ask.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/codex-test-author-guard.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/tests" "$REPO/.claude"
git -C "$REPO" init -q -b feat/ledger-tier
git -C "$REPO" -c user.email=fixture@example.invalid -c user.name=fixture commit -q --allow-empty -m init
TEST_FILE="$REPO/tests/test_score_posting.py"

# write_ledger <tier> <branch>: writes the untracked ledger task-tier.sh writes.
write_ledger() {
  jq -n --arg t "$1" --arg b "$2" '{tier:$t,branch:$b,ticket:"IAN-1",reason:"fixture"}' >"$REPO/.claude/task-tier.json"
}

# decision <path>: echoes the guard's permission decision, or "none".
decision() {
  local out
  out=$(jq -n --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}' |
    env -u CLAUDE_HOOK_RUNTIME CODEX_TEST_GUARD=on "$HOOK")
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask with no ledger in the checkout"; exit 1; }

write_ledger standard feat/ledger-tier
[ "$(decision "$TEST_FILE")" = "none" ] || { echo "FAIL: expected none for a Standard ledger on the checked-out branch"; exit 1; }

write_ledger trivial feat/ledger-tier
[ "$(decision "$TEST_FILE")" = "none" ] || { echo "FAIL: expected none for a Trivial ledger on the checked-out branch"; exit 1; }

write_ledger complex feat/ledger-tier
[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask for a Complex ledger"; exit 1; }

write_ledger saga feat/ledger-tier
[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask for a Saga ledger"; exit 1; }

write_ledger standard feat/another-task
[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask when the ledger names another branch"; exit 1; }

# A malformed ledger and a detached HEAD fail closed: the guard still asks.
printf 'not json' >"$REPO/.claude/task-tier.json"
[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask for a malformed ledger"; exit 1; }
write_ledger standard feat/ledger-tier
git -C "$REPO" checkout -q --detach
[ "$(decision "$TEST_FILE")" = "ask" ] || { echo "FAIL: expected ask on a detached HEAD"; exit 1; }
git -C "$REPO" checkout -q feat/ledger-tier

# A test file in a directory that does not exist yet resolves its repository
# through the nearest existing ancestor.
[ "$(decision "$REPO/tests/new_area/test_new.py")" = "none" ] || { echo "FAIL: expected none for a new directory under a Standard ledger"; exit 1; }

echo "PASS: codex-test-author-guard reads the ledger tier"
