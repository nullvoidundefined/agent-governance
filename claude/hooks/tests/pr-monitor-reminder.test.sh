#!/usr/bin/env bash
# Covers: hook:pr-monitor-reminder
# Verifies hooks/pr-monitor-reminder.sh (R-518): after a Bash call that
# really ran `gh pr create` and printed the new pull request's URL, the hook
# tells the session to call mcp__ccd_pr__set_monitor with auto_fix,
# address_comments, and auto_archive_on_close for that URL, never to enable
# auto-merge unasked, and to skip silently where the tools are absent. A
# failed or interrupted create, a quoted "gh pr create", and any other
# command emit nothing. No gh runs here: the hook only reads the payload.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/pr-monitor-reminder.sh"
export CLAUDE_FIRE_LOG=/dev/null

fail=0
OUT=""
URL="https://github.com/example/app/pull/12"

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }
# is_silent: true when the hook emitted nothing.
is_silent() { [ -z "$OUT" ]; }
# output_has <text>: true when the PostToolUse context contains the text.
output_has() {
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 <<< "$OUT" &&
    jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$OUT" | grep -qF -- "$1"
}

# run_hook <command> <stdout> [interrupted]: feeds one PostToolUse payload.
run_hook() {
  OUT=$(jq -nc --arg c "$1" --arg o "$2" --argjson i "${3:-false}" \
    '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:$i}}' | bash "$HOOK" 2>/dev/null)
}

# A successful manual create emits the monitor instruction for its URL.
run_hook "gh pr create --title 'feat: x' --body 'Refs: IAN-137'" "$(printf 'Creating pull request\n%s\n' "$URL")"
check "successful gh pr create emits the instruction" output_has "mcp__ccd_pr__set_monitor"
check "instruction names the PR URL" output_has "url \"$URL\""
check "instruction sets auto_fix" output_has "auto_fix: true"
check "instruction sets address_comments" output_has "address_comments: true"
check "instruction sets auto_archive_on_close" output_has "auto_archive_on_close: true"
check "instruction forbids unasked auto-merge" output_has "Never call mcp__ccd_pr__set_auto_merge"
check "instruction says to skip without the tools" output_has "skip this silently"

# A cd-prefixed create with a heredoc body still counts.
run_hook "$(printf 'cd /tmp && gh pr create --title x --body "$(cat <<'"'"'EOF'"'"'\nBody.\nEOF\n)"')" "$URL"
check "cd-prefixed heredoc create emits the instruction" output_has "$URL"

# A failed create prints no URL on stdout: nothing.
run_hook "gh pr create --title x --body y" ""
check "failed gh pr create is silent" is_silent

# gh's "already exists" failure, merged into stdout by 2>&1: nothing.
run_hook "gh pr create --title x --body y 2>&1" "a pull request for branch \"feat/x\" into branch \"main\" already exists:
$URL"
check "already-exists failure is silent" is_silent

# An interrupted create: nothing.
run_hook "gh pr create --title x --body y" "$URL" true
check "interrupted gh pr create is silent" is_silent

# A quoted "gh pr create" is not an invocation, even with a URL in stdout.
run_hook "git commit -m 'next: gh pr create'" "$URL"
check "quoted gh pr create is silent" is_silent

# Other gh pr commands and unrelated commands: nothing.
run_hook "gh pr view 12" "$URL"
check "gh pr view is silent" is_silent
run_hook "ls -la" ""
check "unrelated command is silent" is_silent

if [ "$fail" -eq 0 ]; then echo "pr-monitor-reminder.test.sh PASS"; else echo "pr-monitor-reminder.test.sh FAIL"; fi
exit "$fail"
