#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# On 2026-09-19, the raw-command grep denied a heredoc that wrote commit text
# as test data. Quoted arguments and unrelated heredocs must remain data,
# while real commits still receive subject and body validation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2"; exit 1; }
}

GOOD_SUBJECT="feat(auth)$(printf ':') add login handler"
BAD_SUBJECT="update stuff"

# Cases 1-2: Heredoc bodies contain fixture data, not commands to execute.
expect none "$(printf "cat > /tmp/x.test.sh <<'EOF'\ngit commit -m \"%s\"\nEOF" "$BAD_SUBJECT")"
expect none "$(printf "cat > /tmp/x.test.sh <<TEST\nexpect deny 'git commit -m \"%s\"'\nTEST" "$BAD_SUBJECT")"

# Cases 3-6: Quoted arguments and git log searches are data.
expect none "$(printf 'echo "git commit -m '\''%s'\''"' "$BAD_SUBJECT")"
expect none "$(printf "printf '%%s\\\\n' 'git commit -m \"%s\"' > /tmp/out" "$BAD_SUBJECT")"
expect none 'grep -n "git commit" claude/hooks/commit-message-guard.sh'
expect none "$(printf 'git log --grep "git commit -m %s"' "$BAD_SUBJECT")"

# Case 7: Ignore a bad subject in data before a valid real commit.
expect none "$(printf "cat > /tmp/x <<'EOF'\ngit commit -m \"%s\"\nEOF\ngit commit -m \"%s\"" "$BAD_SUBJECT" "$GOOD_SUBJECT")"

# Cases 8-9: Assignment prefixes and env still invoke a real commit.
expect deny "$(printf 'GIT_AUTHOR_NAME=x git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'env GIT_AUTHOR_NAME=x git commit -m "%s"' "$BAD_SUBJECT")"

# Cases 10-11: Git global options precede the commit subcommand.
expect deny "$(printf 'git -C /tmp commit -m "%s"' "$BAD_SUBJECT")"
expect none "$(printf 'git -C /tmp commit -m "%s"' "$GOOD_SUBJECT")"
expect deny "$(printf 'git -c user.name=x commit -m "%s"' "$BAD_SUBJECT")"

# Case 12: Command wrappers must preserve commit validation.
expect deny "$(printf 'time git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'command git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'nice -n 5 git commit -m "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'timeout 30 git commit -m "%s"' "$BAD_SUBJECT")"

# Cases 13-14: Subshells and command chains contain real commits.
expect deny "$(printf '(cd /tmp && git commit -m "%s")' "$BAD_SUBJECT")"
expect deny "$(printf 'git add -A && git commit -q -m "%s"' "$BAD_SUBJECT")"

# Case 15: A heredoc feeding -F - supplies the actual commit message.
expect deny "$(printf "git commit -F - <<'MSG'\n%s\nMSG" "$BAD_SUBJECT")"
expect none "$(printf "git commit -F - <<'MSG'\n%s\nMSG" "$GOOD_SUBJECT")"

# Case 16: A cat heredoc inside command substitution supplies -m.
expect deny "$(printf 'git commit -m "$(cat <<'\''EOF'\''\n%s\n\nbody\nEOF\n)"' "$BAD_SUBJECT")"
expect none "$(printf 'git commit -m "$(cat <<'\''EOF'\''\n%s\n\nbody\nEOF\n)"' "$GOOD_SUBJECT")"

# Case 17: A valid subject in preceding data cannot hide a bad real commit.
expect deny "$(printf "cat > /tmp/x <<'EOF'\ngit commit -m \"%s\"\nEOF\ngit commit -m \"%s\"" "$GOOD_SUBJECT" "$BAD_SUBJECT")"

# Cases 18-19: Preserve body-length asks and message-free amendments.
expect ask "$(printf 'env A=1 git commit -m "%s\n\nOne.\nTwo.\nThree.\nFour."' "$GOOD_SUBJECT")"
expect none 'git commit --amend --no-edit'

echo "commit-message-guard-shell-scan.test.sh PASS"
