#!/usr/bin/env bash
# Covers: hook:redact-output
# Verifies redact-output.sh suppresses raw output and injects a [REDACTED]
# replacement when Bash output carries a secret pattern, and stays silent for
# clean output (R-102). The fake token is built at runtime.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/redact-output.sh"
FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 40))"

OUT=$(jq -n --arg s "remote: $FAKE_TOKEN pushed" '{tool_name:"Bash",tool_response:{stdout:$s}}' | "$HOOK")
printf '%s' "$OUT" | jq -e '.suppressOutput == true' >/dev/null || { echo "FAIL: expected suppressOutput"; exit 1; }
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q '\[REDACTED\]' || { echo "FAIL: expected [REDACTED] in context"; exit 1; }
grep -qF "$FAKE_TOKEN" <<< "$OUT" && { echo "FAIL: raw token survived redaction"; exit 1; }

# Regression (2026-09-18): the detection used `printf '%s' "$RESPONSE" | grep -qE`.
# On output larger than the pipe buffer, grep exits at the first-line match while
# printf is still writing, printf dies of SIGPIPE, and under pipefail the `if`
# read the match as a miss, so a leaked token in long output went unreported.
LARGE_RESPONSE_PAYLOAD=$({
  printf 'remote: %s pushed\n' "$FAKE_TOKEN"
  awk 'BEGIN { for (i = 0; i < 8192; i++) print "filler line of ordinary build output" }'
} | jq -Rs '{tool_name:"Bash",tool_response:{stdout:.}}')
[ "${#LARGE_RESPONSE_PAYLOAD}" -gt 65536 ] || { echo "FAIL: the large-output payload must exceed 64KB"; exit 1; }
OUT=$(printf '%s' "$LARGE_RESPONSE_PAYLOAD" | "$HOOK")
grep -qF '[REDACTED]' <<< "$OUT" || { echo "FAIL: a token on the first line of output over 64KB went undetected"; exit 1; }
grep -qF "$FAKE_TOKEN" <<< "$OUT" && { echo "FAIL: raw token survived redaction in large output"; exit 1; }

OUT=$(jq -n '{tool_name:"Bash",tool_response:{stdout:"all clean, nothing sensitive"}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for clean output"; exit 1; }
echo "redact-output.test.sh PASS"
