#!/usr/bin/env bash
# Verifies secret-scan.sh blocks mutation of protected credential files (R-103)
# while allowing reads and throwaway /tmp fixtures, and still blocks raw secrets (R-102).
set -euo pipefail
HOOK="$HOME/.claude/hooks/secret-scan.sh"

deny() {
  jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" \
    | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || { echo "FAIL: expected deny for: $1"; exit 1; }
}
allow() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  [ -z "$OUT" ] || { echo "FAIL: expected allow for: $1"; exit 1; }
}

ENVFILE=.env
# R-103 mutations: deny
deny "echo 'API_KEY=x' >> $ENVFILE"
deny "echo foo > $ENVFILE.production"
deny "rm ./$ENVFILE"
deny "rm -f ~/.ssh/id_rsa"
deny "mv $ENVFILE /backups/env-backup"
deny "cp $ENVFILE.example $ENVFILE"
deny "echo x > ~/.aws/credentials"
deny "tee ~/.config/gh/hosts.yml < payload.yml"
deny "sed -i '' 's/a/b/' server/$ENVFILE"
deny "truncate -s 0 ~/.gnupg/trustdb.gpg"
# Reads and unrelated commands: allow
allow "cat $ENVFILE"
allow "grep API_KEY $ENVFILE"
allow "ls -la ~/.ssh"
allow "git status"
allow "rm -rf node_modules"
# Throwaway fixtures under /tmp: allow (R-103 Spec)
allow "echo 'X=1' >> /tmp/fixture-8213/$ENVFILE"
allow "rm /private/tmp/claude-501/scratch/$ENVFILE.test"
# R-102 raw secret on argv still denied
deny "railway variables --set KEY=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

# Write/Edit surface (P1-1): secrets in file payloads and writes to protected
# credential paths are denied; clean writes and /tmp fixtures pass.
FAKE_KEY="sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
deny_json() {
  printf '%s' "$1" | "$HOOK" \
    | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || { echo "FAIL: expected deny for payload: $1"; exit 1; }
}
allow_json() {
  OUT=$(printf '%s' "$1" | "$HOOK")
  [ -z "$OUT" ] || { echo "FAIL: expected allow for payload: $1"; exit 1; }
}
deny_json "$(jq -nc --arg k "$FAKE_KEY" '{tool_name:"Write",tool_input:{file_path:"/x/src/config.ts",content:("const KEY = \"" + $k + "\";")}}')"
deny_json "$(jq -nc --arg k "$FAKE_KEY" '{tool_name:"Edit",tool_input:{file_path:"/x/src/config.ts",old_string:"placeholder",new_string:("apiKey: \"" + $k + "\"")}}')"
deny_json '{"tool_name":"Write","tool_input":{"file_path":"/repo/.env","content":"API_KEY=x"}}'
deny_json '{"tool_name":"Write","tool_input":{"file_path":"/repo/.env.production","content":"API_KEY=x"}}'
deny_json '{"tool_name":"Edit","tool_input":{"file_path":"/Users/someone/.ssh/config","old_string":"a","new_string":"b"}}'
allow_json '{"tool_name":"Write","tool_input":{"file_path":"/tmp/fixture-9911/.env","content":"X=1"}}'
allow_json '{"tool_name":"Write","tool_input":{"file_path":"/x/src/config.ts","content":"const NAME = \"placeholder sk-ant-api03-...\";"}}'
echo "credential-mutation-guard.test.sh PASS"
