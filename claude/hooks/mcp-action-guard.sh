#!/usr/bin/env bash
# mcp-action-guard.sh: R-105. Every other guard in this tree matches Bash or
# Write/Edit, so an MCP tool call reaches the outside world with no gate at all:
# mail sent, issues and pages written or deleted, files created in a design
# tool. This hook asks before any MCP call whose action names a mutating or
# transmitting verb, and stays silent on the read-only majority (get, list,
# search, read, fetch, query, download).
#
# Ask, never deny: R-105 wants explicit confirmation, not prohibition. Choosing
# "don't ask again" for one tool is the user's own pre-authorization.
#
# Verbs are matched per token, not on the leading word: server prefixes are
# baked into several tool names (notion-create-pages), so the verb is rarely
# first. The browser server is exempt; tab and click actions carry their own
# site permission model and are not external systems of record.
set -euo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in mcp__*) ;; *) exit 0 ;; esac

SERVER=$(printf '%s' "$TOOL" | awk -F'__' '{print $2}')
case "$SERVER" in claude-in-chrome) exit 0 ;; esac

# camelCase is as common as snake_case in MCP tool names (createIssue,
# chat_postMessage), so split on the case boundary before lowercasing. Folding
# case first would weld the verb to its object and match nothing.
ACTION=$(printf '%s' "${TOOL##*__}" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr 'A-Z-' 'a-z_')

REASON=""
for token in $(printf '%s' "$ACTION" | tr '_' ' '); do
  case "$token" in
    send | post | reply | forward | publish | share | invite | notify | respond)
      REASON="transmits content outside this machine"; break ;;
    create | save | update | edit | write | add | apply | upload | move | duplicate | rename | submit | merge | generate | mark | use)
      REASON="writes to an external system of record"; break ;;
    delete | remove | trash | drop | archive | revoke | rotate | cancel | unmark | unlabel)
      REASON="destroys or retracts external state"; break ;;
    # Database MCP servers (neon, supabase) reach a managed Postgres that
    # R-101's Bash-only guard never sees. 'run' and 'query' stay out: too
    # generic to carry the meaning on their own.
    sql | migration | migrate | execute | ddl)
      REASON="runs statements against a database (R-101 applies to the data they touch)"; break ;;
  esac
done
[ -z "$REASON" ] && exit 0

source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-105" "mcp-action-guard" "ask"

jq -n --arg t "$TOOL" --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:("R-105: " + $t + " " + $r + ". Confirm this specific call, its recipient, and its payload before it runs. Approving one destructive MCP action does not pre-authorize the next.")}}'
exit 0
