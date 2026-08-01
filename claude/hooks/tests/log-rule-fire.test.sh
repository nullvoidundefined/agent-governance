#!/usr/bin/env bash
# Verifies log-rule-fire.sh appends pipe-delimited fire lines, honors the
# /dev/null silencer, and that a wired hook (no-em-dash) logs its deny.
set -euo pipefail
HELPER="$HOME/.claude/hooks/log-rule-fire.sh"
HOOK="$HOME/.claude/hooks/no-em-dash.sh"

LOG=$(mktemp)
# Direct helper call appends one well-formed line.
( source "$HELPER"; CLAUDE_FIRE_LOG="$LOG" log_rule_fire "R-999" "test-hook" "deny" )
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|R-999\|test-hook\|deny\|' "$LOG" || { echo "FAIL: malformed fire line: $(cat "$LOG")"; exit 1; }

# /dev/null silencer writes nothing and errors nothing.
( source "$HELPER"; CLAUDE_FIRE_LOG=/dev/null log_rule_fire "R-999" "test-hook" "deny" )

# A wired hook logs its fire on deny. The em dash is built from bytes so this
# test file never contains one.
LOG2=$(mktemp)
DASH=$(printf '\xe2\x80\x94')
printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.md","content":"a%sb"}}' "$DASH" \
  | CLAUDE_FIRE_LOG="$LOG2" "$HOOK" >/dev/null
grep -q 'R-207|no-em-dash|deny' "$LOG2" || { echo "FAIL: wired hook did not log its fire"; exit 1; }

rm -f "$LOG" "$LOG2"
echo "log-rule-fire.test.sh PASS"
