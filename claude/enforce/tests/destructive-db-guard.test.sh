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

# MCP database servers reach the same managed Postgres with no shell command.
# The target is named by identifier, so the classification comes from the file.
TARGETS=$(mktemp)
printf 'production ep-prod-frost-9931\nstaging ep-stage-dawn-2210\nlocal br-dev-local\n' >"$TARGETS"
export CLAUDE_MCP_DB_TARGETS="$TARGETS"
mcp_decision() {
  OUT=$(jq -n --arg t "$1" --argjson i "$2" '{tool_name:$t,tool_input:$i}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
mcp_expect() {
  GOT=$(mcp_decision "$2" "$3")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2 $3"; exit 1; }
}

mcp_expect deny mcp__neon__run_sql '{"projectId":"ep-prod-frost-9931","sql":"DROP TABLE users"}'          # R-101 hard block
mcp_expect deny mcp__supabase__execute_sql '{"project_id":"ep-prod-frost-9931","query":"TRUNCATE users"}' # second server, same rule
mcp_expect ask  mcp__neon__run_sql '{"projectId":"ep-stage-dawn-2210","sql":"DELETE FROM users"}'         # staging asks
mcp_expect ask  mcp__neon__run_sql '{"projectId":"ep-unlisted-0000","sql":"DROP TABLE users"}'            # unknown target asks, never passes
mcp_expect none mcp__neon__run_sql '{"projectId":"br-dev-local","sql":"DROP TABLE users"}'                # a local branch is the developer's own
mcp_expect none mcp__neon__run_sql '{"projectId":"ep-prod-frost-9931","sql":"SELECT count(*) FROM users"}' # read-only
mcp_expect none mcp__neon__run_sql '{"projectId":"ep-prod-frost-9931","sql":"INSERT INTO users VALUES (1)"}' # non-destructive: R-105 owns the ask
mcp_expect none mcp__claude_ai_Notion__notion-update-page '{"content":"the runbook says DELETE FROM users"}' # prose quoting SQL is not a statement
mcp_expect none mcp__claude_ai_Gmail__send_message '{"body":"DROP TABLE users"}'                          # non-database server untouched
unset CLAUDE_MCP_DB_TARGETS
rm -f "$TARGETS"

# With no targets file at all, a destructive MCP statement still asks.
export CLAUDE_MCP_DB_TARGETS="/nonexistent/targets.txt"
mcp_expect ask mcp__neon__run_sql '{"projectId":"ep-prod-frost-9931","sql":"DROP TABLE users"}'
unset CLAUDE_MCP_DB_TARGETS

echo "destructive-db-guard.test.sh PASS"
