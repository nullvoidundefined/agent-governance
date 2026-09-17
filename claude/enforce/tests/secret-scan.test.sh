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
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/secret-scan.sh"

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

# R-108: a credential-shaped literal denies even when fake; placeholder
# shapes and run-time assembly pass. The URI is built from parts here for
# the same reason the rule exists.
FAKE_URI="$(printf '%s://%s:%s@%s/%s' postgres app hunter22x db.example.invalid:5432 app)"
[ "$(jq -n --arg c "DATABASE_URL=$FAKE_URI" '{tool_name:"Write",tool_input:{file_path:"/repo/tests/fixture.sh",content:$c}}' | decision)" = "deny" ] || { echo "FAIL: a URI with an embedded password in Write content must deny (R-108)"; exit 1; }
[ "$(jq -n --arg c "psql $FAKE_URI" '{tool_name:"Bash",tool_input:{command:$c}}' | decision)" = "deny" ] || { echo "FAIL: a URI with an embedded password on argv must deny (R-108)"; exit 1; }
[ "$(jq -n '{tool_name:"Write",tool_input:{file_path:"/repo/README.md",content:"DATABASE_URL=postgres://app:<password>@db.example.invalid/app"}}' | decision)" = "none" ] || { echo "FAIL: an angle-bracket placeholder password must pass"; exit 1; }
[ "$(jq -n '{tool_name:"Write",tool_input:{file_path:"/repo/README.md",content:"DATABASE_URL=postgres://app:${DB_PASSWORD}@db.example.invalid/app"}}' | decision)" = "none" ] || { echo "FAIL: an env-reference password must pass"; exit 1; }
[ "$(jq -n --arg c "printf 'DATABASE_URL=%s://%s:%s@%s/%s\\n' postgres user \"\$PW\" host app > /tmp/fixture-env" '{tool_name:"Bash",tool_input:{command:$c}}' | decision)" = "none" ] || { echo "FAIL: run-time assembly with printf slots must pass"; exit 1; }
FAKE_PW="$(printf '%s%s' hunter 22x)"
[ "$(jq -n --arg c "password = \"$FAKE_PW\"" '{tool_name:"Edit",tool_input:{file_path:"/repo/config.py",new_string:$c}}' | decision)" = "deny" ] || { echo "FAIL: a password assignment with a literal value must deny (R-108)"; exit 1; }
[ "$(jq -n '{tool_name:"Edit",tool_input:{file_path:"/repo/config.py",new_string:"password = os.environ[\"DB_PASSWORD\"]"}}' | decision)" = "none" ] || { echo "FAIL: a password read from the environment must pass"; exit 1; }
[ "$(jq -n '{tool_name:"Edit",tool_input:{file_path:"/repo/app.ts",new_string:"  secret: process.env.SESSION_SECRET!,"}}' | decision)" = "none" ] || { echo "FAIL: a member-access expression must pass"; exit 1; }
[ "$(jq -n '{tool_name:"Write",tool_input:{file_path:"/repo/docs/setup.md",content:"api_key: <your key>\ntoken: changeme"}}' | decision)" = "none" ] || { echo "FAIL: placeholder words must pass"; exit 1; }
[ "$(jq -n '{tool_name:"Write",tool_input:{file_path:"/repo/docs/setup.md",content:"The token: field takes the value the dashboard shows."}}' | decision)" = "none" ] || { echo "FAIL: prose with a colon after token must pass"; exit 1; }

echo "secret-scan.test.sh PASS"
