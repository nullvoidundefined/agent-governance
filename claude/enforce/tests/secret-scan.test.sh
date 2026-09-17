#!/usr/bin/env bash
# Covers: hook:secret-scan
# Verifies secret-scan.sh's R-102 secret-pattern deny path: a full-length
# secret in any of the three scanned fields (Bash command, Write content,
# Edit new_string) denies, while placeholders under the length thresholds
# and clean commands stay silent. The R-103 credential-file mutation slice
# is covered separately by credential-mutation-guard.test.sh. Secret values
# are constructed at runtime, the PEM header included, so this file never
# carries a literal that the scan itself, or the publish guard, would flag
# (same convention as global-repo-push-guard.test.sh).
set -euo pipefail
HOOK="$HOME/.claude/hooks/secret-scan.sh"

decision() { # json payload on stdin -> deny|none
  local out
  out=$("$HOOK")
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

repeat() { printf "$1%.0s" $(seq 1 "$2"); }

ANTHROPIC_KEY="sk-ant-api03-$(repeat A 54)"
AWS_KEY="AKIA$(repeat Q 16)"
GITHUB_TOKEN="ghp_$(repeat a 36)"
SLACK_TOKEN="xoxb-$(repeat 1 42)"
PEM_HEADER="-----BEGIN RSA PRIVATE$(printf ' ')KEY-----"

# R-102: full-length secrets deny on every scanned field.
[ "$(jq -n --arg c "railway variables --set KEY=$ANTHROPIC_KEY" '{tool_name:"Bash",tool_input:{command:$c}}' | decision)" = "deny" ] || { echo "FAIL: Anthropic key on argv must deny"; exit 1; }
[ "$(jq -n --arg c "export AWS_ACCESS_KEY_ID=$AWS_KEY" '{tool_name:"Bash",tool_input:{command:$c}}' | decision)" = "deny" ] || { echo "FAIL: AWS access key on argv must deny"; exit 1; }
[ "$(jq -n --arg c "$GITHUB_TOKEN" '{tool_name:"Write",tool_input:{file_path:"/repo/notes.md",content:$c}}' | decision)" = "deny" ] || { echo "FAIL: GitHub token in Write content must deny"; exit 1; }
[ "$(jq -n --arg c "token = \"$SLACK_TOKEN\"" '{tool_name:"Edit",tool_input:{file_path:"/repo/config.py",new_string:$c}}' | decision)" = "deny" ] || { echo "FAIL: Slack token in Edit new_string must deny"; exit 1; }
[ "$(jq -n --arg c "echo '$PEM_HEADER' > /repo/key.pem" '{tool_name:"Bash",tool_input:{command:$c}}' | decision)" = "deny" ] || { echo "FAIL: private-key header must deny"; exit 1; }

# Placeholders under the thresholds and clean commands stay silent.
[ "$(jq -n '{tool_name:"Bash",tool_input:{command:"echo sk-ant-api03-... and whsec_REDACTED are placeholders"}}' | decision)" = "none" ] || { echo "FAIL: placeholders must not deny"; exit 1; }
[ "$(jq -n '{tool_name:"Bash",tool_input:{command:"ls -la && git status"}}' | decision)" = "none" ] || { echo "FAIL: a clean command must stay silent"; exit 1; }

echo "secret-scan.test.sh PASS"
