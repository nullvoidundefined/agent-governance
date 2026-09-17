#!/usr/bin/env bash
# mcp-action-guard.sh: R-105. Every other guard in this tree matches Bash or
# Write/Edit, so an MCP tool call reaches the outside world with no gate at all:
# mail sent, issues and pages written or deleted, files created in a design
# tool. This hook asks before any MCP call whose action names a mutating or
# transmitting verb, and stays silent on the read-only majority (get, list,
# search, read, fetch, query, download).
#
# Ask, never deny: R-105 wants explicit confirmation, not prohibition. Choosing
# "don't ask again" for one tool is the user's own pre-authorization, and so is
# naming a tool under the active tracker in ~/.claude/TICKET-TRACKER.json: the
# ticket-lifecycle skill's own writes (create, update, comment, label, project)
# pass without a prompt, every other MCP write still asks (2026-09-17 decision).
#
# Verbs are matched per token, not on the leading word: server prefixes are
# baked into several tool names (notion-create-pages), so the verb is rarely
# first. The browser server is exempt; tab and click actions carry their own
# site permission model and are not external systems of record.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
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

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }

# Pre-authorized tracker tools. The per-machine ticket tracker config names the
# MCP tools the ticket-lifecycle skill writes through; a call to one of them is
# the user's standing authorization for ticket writes and passes silently.
TRACKER_CONFIG="${TICKET_TRACKER_CONFIG:-$HOME/.claude/TICKET-TRACKER.json}"

# is_tracker_tool <tool name>
# Returns 0 only when the tracker config exists, is exactly one JSON object,
# names an active tracker whose `tools` value is an object, and one of that
# object's string values equals the full tool name; returns 1 for every other
# shape (absent file, parse error, several top-level values, `tools` as an
# array or string, a non-string value), so a malformed config never widens the
# exemption. The match is the full server-qualified name only: a client that
# strips the server before this hook runs (the Cursor adapter today) cannot
# be pre-authorized, because a bare name cannot tell one server's tool from
# another's. Prints nothing.
is_tracker_tool() {
  [ -f "$TRACKER_CONFIG" ] || return 1
  jq -es --arg t "$1" '
    length == 1
    and (.[0] | type) == "object"
    and (.[0].active | type) == "string"
    and ((.[0].trackers[.[0].active].tools? // null) | type) == "object"
    and ([.[0].trackers[.[0].active].tools | to_entries[] | .value | select(type == "string")] | index($t) != null)
  ' "$TRACKER_CONFIG" >/dev/null 2>&1
}

if is_tracker_tool "$TOOL"; then
  log_rule_fire "R-105" "mcp-action-guard" "preauthorized-tracker-tool"
  exit 0
fi

log_rule_fire "R-105" "mcp-action-guard" "ask"

jq -n --arg t "$TOOL" --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:("R-105: " + $t + " " + $r + ". Confirm this specific call, its recipient, and its payload before it runs. Approving one destructive MCP action does not pre-authorize the next.")}}'
exit 0
