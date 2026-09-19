#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# Copilot's second review round on PR #79, 2026-09-19, found commits the scan
# still misread: env's split-string option (-S, --split-string) that runs an
# embedded command, sudo options that take a value (-R, -T), and unquoted
# heredocs whose body holds an expansion the shell runs before cat reads it,
# which makes the body uncountable. Each case below pins one.
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

# Case 1: env's split-string option runs an embedded command.
expect deny "$(printf "env --split-string 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect deny "$(printf "env -S 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect deny "$(printf "env --split-string='git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect none "$(printf "env -S 'git commit -m \"%s\"'" "$GOOD_SUBJECT")"

# Case 2: sudo options that take a value.
expect deny "$(printf 'sudo -R /root git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'sudo -T 30 git commit -m "%s"' "$BAD_SUBJECT")"

# Case 3: an unquoted heredoc expands its body, so an expansion there is uncountable.
expect ask "$(printf "git commit -m \"\$(cat <<EOF\n%s\n\n\$(printf 'One')\nEOF\n)\"" "$GOOD_SUBJECT")"
expect ask "$(printf "git commit -m \"\$(cat <<EOF\n%s\n\n\`printf 'One'\`\nEOF\n)\"" "$GOOD_SUBJECT")"
expect none "$(printf "git commit -m \"\$(cat <<'EOF'\n%s\n\n\$(printf 'One')\nEOF\n)\"" "$GOOD_SUBJECT")"
expect none "$(printf "git commit -m \"\$(cat <<EOF\n%s\n\nOne body line.\nEOF\n)\"" "$GOOD_SUBJECT")"
expect deny "$(printf "git commit -m \"\$(cat <<EOF\n%s\n\n\$(printf 'One')\nEOF\n)\"" "$BAD_SUBJECT")"

# Case 4: -F - fed by an unquoted heredoc whose body holds an expansion.
expect ask "$(printf "git commit -F - <<MSG\n%s\n\n\$(printf 'One')\nMSG" "$GOOD_SUBJECT")"
expect none "$(printf "git commit -F - <<MSG\n%s\n\nOne body line.\nMSG" "$GOOD_SUBJECT")"

echo "commit-message-guard-copilot-round2.test.sh PASS"
