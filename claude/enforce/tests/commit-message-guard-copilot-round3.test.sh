#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# Copilot's third review round on PR #79, 2026-09-19, found commits the scan
# still misread: command words spelled with backslash escapes or quotes, which
# the shell strips before it runs git commit, and the options of the command
# and exec builtins (-p, -a name, -c) placed ahead of the wrapped git commit.
# Each case below pins one.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2 (hook: $HOOK)"; exit 1; }
}

GOOD_SUBJECT="feat(auth)$(printf ':') add login handler"
BAD_SUBJECT="update stuff"

# Case 1: command words spelled with escapes or quotes still run git commit.
expect deny 'g\it c\ommit -m "'"$BAD_SUBJECT"'"'
expect deny '"g"it "com"mit -m "'"$BAD_SUBJECT"'"'
expect deny "'git' 'commit' -m \"$BAD_SUBJECT\""
expect none 'g\it c\ommit -m "'"$GOOD_SUBJECT"'"'

# Case 2: options of the command and exec builtins ahead of git commit.
expect deny "command -p git commit -m \"$BAD_SUBJECT\""
expect deny "exec -a name git commit -m \"$BAD_SUBJECT\""
expect deny "exec -c git commit -m \"$BAD_SUBJECT\""
expect none "command -p git commit -m \"$GOOD_SUBJECT\""

echo "commit-message-guard-copilot-round3.test.sh PASS"
