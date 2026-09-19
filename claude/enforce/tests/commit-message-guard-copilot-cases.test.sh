#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# Copilot's review of PR #79 on 2026-09-19 found commits the quote-aware scan
# misread: shell options that take a value before -c (bash -O extglob), long
# wrapper options that take a separate value (sudo --user root), redirections
# ahead of the command word, and command substitutions embedded in a message
# that the guard cannot read. Each case below pins one.
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

# Case 1: shell options that take a value before -c.
expect deny "$(printf "bash -O extglob -c 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect deny "$(printf "bash -o pipefail -c 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect none "$(printf "bash +O extglob -c 'git commit -m \"%s\"'" "$GOOD_SUBJECT")"

# Case 2: long wrapper options that take a separate value.
expect deny "$(printf 'sudo --user root git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'env --chdir /tmp git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'timeout --signal KILL 30 git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'nice --adjustment 5 git commit -m "%s"' "$BAD_SUBJECT")"

# Case 3: redirections before the command word.
expect deny "$(printf '< /dev/null git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf '2>/dev/null git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf '>/tmp/commit-guard-log git commit -m "%s"' "$BAD_SUBJECT")"
expect none "$(printf 'A=1 < /dev/null git commit -m "%s"' "$GOOD_SUBJECT")"

# Case 4: an unreadable substitution makes the body uncountable, so the guard asks.
expect ask "$(printf "git commit -m \"%s \$(printf 'x')\"" "$GOOD_SUBJECT")"
expect ask "$(printf 'git commit -m "%s" -m "$(date)"' "$GOOD_SUBJECT")"
expect ask 'git commit -m "$(git log -1 --format=%s)"'
expect ask "$(printf 'git commit -m "%s" -m "`date`"' "$GOOD_SUBJECT")"

# Case 4 regressions: the heredoc form stays readable; deny beats ask.
expect none "$(printf "git commit -m \"\$(cat <<'EOF'\n%s\n\nOne body line.\nEOF\n)\"" "$GOOD_SUBJECT")"
expect deny "$(printf 'git commit -m "%s" -m "$(date)"' "$BAD_SUBJECT")"

echo "commit-message-guard-copilot-cases.test.sh PASS"
