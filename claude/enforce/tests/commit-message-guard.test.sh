#!/usr/bin/env bash
# Verifies commit-message-guard.sh: conventional subject and max-2 triage IDs (deny, R-505),
# oversized body (ask, R-506), everything else untouched.
set -euo pipefail
HOOK="$HOME/.claude/hooks/commit-message-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2"; exit 1; }
}

expect none 'git status'
expect none 'git commit -m "feat(auth): add login handler"'
expect none 'git commit -m "fix(B5, B12): repair pagination and sorting"'
expect none 'git commit --amend --no-edit'
expect none 'git add x && git commit -m "chore: bump deps" && git push'
expect deny 'git commit -m "update stuff"'
expect deny 'git commit -m "Fixed the login bug"'
expect deny 'git commit -m "fix(B1, B2, B3): three triage ids"'
MULTILINE='git commit -m "feat(core): add feature

First body sentence here.
Second body sentence here.
Third body sentence here.
Fourth body sentence here.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"'
expect ask "$MULTILINE"
SHORTBODY='git commit -m "feat(core): add feature

One sentence body.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"'
expect none "$SHORTBODY"
echo "commit-message-guard.test.sh PASS"
