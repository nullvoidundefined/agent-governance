#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# The 2026-09-19 adversarial review of IAN-152 found commits the quote-aware
# scan let through: bundled short options (-am), an unreadable -m discarding a
# literal one, a second commit in the same Bash call, commits run by a shell
# (bash -c, sh -c, eval, a heredoc fed to bash), `time -p`, and missing helpers
# that denied commands with no commit in them. Each case below pins one.
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

# Case 1: bundled short options carry the message.
expect deny "$(printf 'git commit -am "%s"' "$BAD_SUBJECT")"
expect deny "$(printf 'git commit -qm "%s"' "$BAD_SUBJECT")"
expect none "$(printf 'git commit -am "%s"' "$GOOD_SUBJECT")"
expect deny "$(printf 'git commit -am"%s"' "$BAD_SUBJECT")"

# Case 2: one unreadable -m must not discard a literal one.
expect deny "$(printf 'git commit -m "%s" -m "$(date)"' "$BAD_SUBJECT")"
expect deny "$(printf "git commit -m '%s \$(x)'" "$BAD_SUBJECT")"

# Case 3: every commit in one Bash call is checked; a deny beats an earlier ask.
expect deny "$(printf 'git commit -m "%s" && git commit -m "%s"' "$GOOD_SUBJECT" "$BAD_SUBJECT")"
expect deny "$(printf 'git commit -m "%s\n\nOne.\nTwo.\nThree.\nFour." && git commit -m "%s"' "$GOOD_SUBJECT" "$BAD_SUBJECT")"
expect none "$(printf 'git commit -m "%s" && git commit -m "%s"' "$GOOD_SUBJECT" "$GOOD_SUBJECT")"

# Case 4: a commit run by a shell is still a commit; a heredoc fed to cat is data.
expect deny "$(printf "bash -c 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect deny "$(printf "sh -c \"git commit -m '%s'\"" "$BAD_SUBJECT")"
expect deny "$(printf "eval 'git commit -m \"%s\"'" "$BAD_SUBJECT")"
expect none "$(printf "bash -c 'git commit -m \"%s\"'" "$GOOD_SUBJECT")"
expect deny "$(printf "bash <<'EOF'\ngit commit -m \"%s\"\nEOF" "$BAD_SUBJECT")"
expect none "$(printf "cat <<'EOF'\ngit commit -m \"%s\"\nEOF" "$BAD_SUBJECT")"

# Case 5: time with its own option still runs the commit.
expect deny "$(printf 'time -p git commit -m "%s"' "$BAD_SUBJECT")"

# Case 6: missing helpers fail closed on a real commit and stay silent otherwise.
HOOK_ONLY_DIR=$(mktemp -d)
SCAN_ONLY_DIR=$(mktemp -d)
trap 'rm -rf "$HOOK_ONLY_DIR" "$SCAN_ONLY_DIR"' EXIT
cp "$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh" "$HOOK_ONLY_DIR/"
cp "$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh" "$SCAN_ONLY_DIR/"
cp "$CLAUDE_HARNESS_ROOT/hooks/shell-command-scan.sh" "$SCAN_ONLY_DIR/"

HOOK="$HOOK_ONLY_DIR/commit-message-guard.sh"
expect deny "$(printf 'git commit -m "%s"' "$GOOD_SUBJECT")"
expect none 'git status'
expect none 'grep -n commit README.md'

HOOK="$SCAN_ONLY_DIR/commit-message-guard.sh"
expect deny "$(printf 'git commit -m "%s"' "$GOOD_SUBJECT")"

echo "commit-message-guard-review-cases.test.sh PASS"
