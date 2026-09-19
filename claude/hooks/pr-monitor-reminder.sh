#!/usr/bin/env bash
# pr-monitor-reminder.sh: PostToolUse Bash hook (R-517). After a Bash call
# that really ran `gh pr create` (or its alias `gh pr new`) and succeeded,
# tells the session to turn on the desktop app's PR monitor for the new pull
# request (mcp__ccd_pr__set_monitor with auto_fix, address_comments, and
# auto_archive_on_close) and never to enable auto-merge unasked. The monitor
# switches cannot be set from a shell, so the instruction is the mechanism;
# the wording lives in pr-monitor-instruction.sh, shared with
# draft-pr-on-first-push.sh, which covers the drafts it opens itself.
#
# The command is read as shell words (shell-command-scan.sh), so "gh pr
# create" quoted inside a commit message or an echo is not an invocation.
# Success is read from the tool response: the call was not interrupted and
# its stdout carries the pull request URL gh prints on success. A gh that
# failed ("a pull request already exists") prints no URL on stdout, so it
# emits nothing. Advisory: never blocks, always exits 0.
set -uo pipefail

PREFILTER_PATTERN='gh[[:space:]]+pr[[:space:]]+(create|new)'
PR_URL_PATTERN='https?://[^[:space:]]+/pull/[0-9]+'
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // "" | strings' 2>/dev/null <<< "$INPUT" || true)
grep -Eq -- "$PREFILTER_PATTERN" <<< "$CMD" || exit 0
for helper in shell-command-scan.sh pr-monitor-instruction.sh; do
  [ -f "$HOOK_DIR/$helper" ] || exit 0
  # shellcheck source=/dev/null
  source "$HOOK_DIR/$helper"
done

jq -e '.tool_response.interrupted == true' >/dev/null 2>&1 <<< "$INPUT" && exit 0
SESSION_DIR=$(jq -r '.cwd // "" | strings' 2>/dev/null <<< "$INPUT" || true)
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || SESSION_DIR="$PWD"
scan_command_tokens "$CMD"
find_simple_command "$SESSION_DIR" is_pr_create_command || exit 0

STDOUT=$(jq -r '.tool_response.stdout // .tool_response.output // "" | strings' 2>/dev/null <<< "$INPUT" || true)
PR_URL=$(grep -Eo -- "$PR_URL_PATTERN" <<< "$STDOUT" | tail -1 || true)
[ -n "$PR_URL" ] || exit 0

helper="$HOOK_DIR/log-rule-fire.sh"
# shellcheck source=log-rule-fire.sh
[ -f "$helper" ] && source "$helper"
type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-517" "pr-monitor-reminder" "remind"
jq -nc --arg m "$(print_monitor_instruction "$PR_URL")" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
exit 0
