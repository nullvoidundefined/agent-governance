#!/usr/bin/env bash
# Verifies redact-output.sh suppresses raw output and injects a [REDACTED]
# replacement when Bash output carries a secret pattern, and stays silent for
# clean output (R-102). The fake token is built at runtime.
set -euo pipefail
HOOK="$HOME/.claude/hooks/redact-output.sh"
FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 40))"

OUT=$(jq -n --arg s "remote: $FAKE_TOKEN pushed" '{tool_name:"Bash",tool_response:{stdout:$s}}' | "$HOOK")
printf '%s' "$OUT" | jq -e '.suppressOutput == true' >/dev/null || { echo "FAIL: expected suppressOutput"; exit 1; }
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q '\[REDACTED\]' || { echo "FAIL: expected [REDACTED] in context"; exit 1; }
printf '%s' "$OUT" | grep -qF "$FAKE_TOKEN" && { echo "FAIL: raw token survived redaction"; exit 1; }

OUT=$(jq -n '{tool_name:"Bash",tool_response:{stdout:"all clean, nothing sensitive"}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for clean output"; exit 1; }
echo "redact-output.test.sh PASS"
