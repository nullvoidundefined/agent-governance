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
echo "credential-mutation-guard.test.sh PASS"
