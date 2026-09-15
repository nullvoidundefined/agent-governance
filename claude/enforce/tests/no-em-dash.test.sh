#!/usr/bin/env bash
# Verifies no-em-dash.sh denies U+2014 in Write/Edit/Bash content, allows clean
# punctuation, and exempts search-tool commands (R-207). The em dash is built at
# runtime so this file stays em-dash-free.
set -euo pipefail
HOOK="$HOME/.claude/hooks/no-em-dash.sh"
DASH=$(printf '\xe2\x80\x94')

deny() { printf '%s' "$1" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null || { echo "FAIL: expected deny: $1"; exit 1; }; }
allow() { [ -z "$(printf '%s' "$1" | "$HOOK")" ] || { echo "FAIL: expected allow: $1"; exit 1; }; }

deny "$(jq -nc --arg c "hello $DASH world" '{tool_name:"Write",tool_input:{content:$c}}')"
deny "$(jq -nc --arg c "summary $DASH finding" '{tool_name:"Edit",tool_input:{new_string:$c}}')"
deny "$(jq -nc --arg c "git commit -m \"fix $DASH typo\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
allow '{"tool_name":"Write","tool_input":{"content":"hello - world; en dash ok"}}'
allow "$(jq -nc --arg c "grep '$DASH' notes.md" '{tool_name:"Bash",tool_input:{command:$c}}')"
allow '{"tool_name":"Read","tool_input":{"file_path":"/x.md"}}'
echo "no-em-dash.test.sh PASS"
