#!/usr/bin/env bash
# Verifies destructive-db-guard.sh tiers (R-101): deny destructive-vs-production,
# ask destructive-vs-remote and remote writes, pass local and read-only commands.
set -euo pipefail
HOOK="$HOME/.claude/hooks/destructive-db-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2"; exit 1; }
}

expect deny 'railway run -e production -- npm run migrate:down'
expect deny 'NODE_ENV=production node scripts/wipe.js && psql -c "TRUNCATE users"'
expect ask  'psql postgres://user@db.neon.tech/app -c "DELETE FROM users WHERE stale"'
expect ask  'railway run -e staging -- npm run migrate:down'
expect ask  'psql postgres://user@db.neon.tech/app -c "UPDATE users SET plan = 1"'
expect none 'psql postgresql://localhost:5432/dev -c "DROP TABLE users"'
expect none 'psql postgres://user@db.neon.tech/app -c "SELECT count(*) FROM users"'
expect none 'git status'
echo "destructive-db-guard.test.sh PASS"
