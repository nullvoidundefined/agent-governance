#!/usr/bin/env bash
# mcp-action-guard.sh: R-105. Every other guard in this tree matches Bash or
# Write/Edit, so an MCP tool call reaches the outside world with no gate at all:
# mail sent, issues and pages written or deleted, files created in a design
# tool. This hook asks before any MCP call whose action names a mutating or
# transmitting verb, and stays silent on the read-only majority (get, list,
# search, read, fetch, query, download). Two servers are exempt: the browser,
# whose tab actions carry their own site permission model, and the Linear
# server for the write class only, narrowed by the operator on 2026-09-17 and
# documented at the case below, which is why some mutating calls are silent.
#
# Ask, never deny: R-105 wants explicit confirmation, not prohibition. Choosing
# "don't ask again" for one tool is the user's own pre-authorization.
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
# A session can start this hook with HOME unset; under set -u every $HOME
# expansion below would abort before a decision, which is an allow (IAN-436).
: "${HOME:=$(cd ~ 2>/dev/null && pwd)}"
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in mcp__*) ;; *) exit 0 ;; esac

SERVER=$(printf '%s' "$TOOL" | awk -F'__' '{print $2}')
case "$SERVER" in claude-in-chrome) exit 0 ;; esac

# camelCase is as common as snake_case in MCP tool names (createIssue,
# chat_postMessage), so split on the case boundary before lowercasing. Folding
# case first would weld the verb to its object and match nothing.
ACTION=$(printf '%s' "${TOOL##*__}" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr 'A-Z-' 'a-z_')

# Every token is classified, and the strongest class an action names decides.
# Breaking on the first match instead let a leading write verb speak for the
# whole call, so `save_share_issue` and `save_delete_comment` read as ordinary
# writes; on a server whose write class is exempt below they then passed
# silently, which is the opposite of what this hook is for. Order here is the
# order of consequence: state destroyed cannot be undone by us, content already
# transmitted cannot be recalled, a database statement reaches data R-101
# governs, and a write is the mildest of the four.
HAS_TRANSMIT=0 HAS_WRITE=0 HAS_DESTROY=0 HAS_DATABASE=0
for token in $(printf '%s' "$ACTION" | tr '_' ' '); do
  case "$token" in
    send | post | reply | forward | publish | share | invite | notify | respond)
      HAS_TRANSMIT=1 ;;
    create | save | update | edit | write | add | apply | upload | move | duplicate | rename | submit | merge | generate | mark | use)
      HAS_WRITE=1 ;;
    delete | remove | trash | drop | archive | revoke | rotate | cancel | unmark | unlabel | retire | retract)
      HAS_DESTROY=1 ;;
    # Database MCP servers (neon, supabase) reach a managed Postgres that
    # R-101's Bash-only guard never sees. 'run' and 'query' stay out: too
    # generic to carry the meaning on their own.
    sql | migration | migrate | execute | ddl)
      HAS_DATABASE=1 ;;
  esac
done

REASON=""
if [ "$HAS_DESTROY" -eq 1 ]; then
  REASON="destroys or retracts external state"
elif [ "$HAS_TRANSMIT" -eq 1 ]; then
  REASON="transmits content outside this machine"
elif [ "$HAS_DATABASE" -eq 1 ]; then
  REASON="runs statements against a database (R-101 applies to the data they touch)"
elif [ "$HAS_WRITE" -eq 1 ]; then
  REASON="writes to an external system of record"
fi
[ -z "$REASON" ] && exit 0

# The operator narrowed R-105 for the Linear server on 2026-09-17: the
# ticket-lifecycle skill writes at every state change, so a confirmation
# landed every few minutes, and each one bought little, because the tracker is
# private to the operator and a wrong field is editable in place. The narrowing
# stops at the write class and at writes that stay inside the tracker. A
# tracker call that lands code, submits for review, or carries a file out is
# not bookkeeping, so it still asks; so does anything the destroy or transmit
# classes matched, which is why this sits after REASON is decided rather than
# beside the browser exemption above.
# Cursor supplies bare MCP tool names, and its adapter prefixes a synthetic
# "cursor" server segment (cursor/hooks/claude-hook-adapter.sh), so the real
# server identity is gone by the time this hook sees the call and the
# narrowing below would never match under Cursor (PR #11 review). The tracker
# config is the one place that already names the tracker's own tools, so a
# synthetic-server call is resolved against it: a bare name listed under the
# active tracker's tools map is treated as that server's call, and anything
# else keeps the synthetic segment and stays subject to the full guard.
# isActiveTrackerTool(): true when the incoming tool is one the active tracker
# config names for itself. The config is the authority rather than a list of
# server names hardcoded here, because an MCP server's identifier is not
# stable: the same Linear server registers as `claude_ai_Linear` in one install
# and as a UUID such as `0ccea419-4dc2-4479-9c56-baefac2065ba` in another, and
# a name list silently stops matching on the second (2026-09-18: every ticket
# write prompted on a UUID-registered install, which is exactly the friction
# this exemption exists to remove). Matching the configured strings makes the
# exemption exactly as wide as what the operator wrote down and no wider.
#
# Two shapes match, and the second is deliberately narrow. An exact tool name is
# the rule. A bare-suffix match applies ONLY when the server segment is Cursor's
# synthetic `cursor`, because that adapter rewrites a bare MCP name to
# `mcp__cursor__<tool>` before any hook sees it and the real segment is gone.
# Allowing the suffix to match on any server would exempt `save_issue` on
# github or anywhere else, which is wider than the operator wrote down; CI
# caught exactly that, because a suffix match passed locally against a real
# config and the intended exact match did not exist there at all.
#
# Fails CLOSED by structure: a missing, unreadable, or schema-invalid config
# returns non-zero, the call is not exempt, and R-105 asks as it always would.
isActiveTrackerTool() {
  local config="${CLAUDE_TICKET_TRACKER_FILE:-$HOME/.claude/TICKET-TRACKER.json}"
  local bare="${TOOL##*__}"
  [ -f "$config" ] || return 1
  local allow_suffix=false
  case "$SERVER" in cursor) allow_suffix=true ;; esac
  jq -e --arg full "$TOOL" --arg bare "$bare" --argjson suffix "$allow_suffix" '
    (type == "object")
    and (.active | type == "string")
    and (.trackers[.active].tools | type == "object")
    and ([.trackers[.active].tools | to_entries[] | .value] as $tools
         | ($tools | index($full) != null)
           or ($suffix and ($tools | map(sub("^mcp__.*__"; "")) | index($bare) != null)))
  ' "$config" >/dev/null 2>&1
}

# The operator narrowed R-105 for their own tracker on 2026-09-17: the
# ticket-lifecycle skill writes at every state change, so a confirmation landed
# every few minutes, and each bought little because the tracker is private and
# a wrong field is editable in place. The narrowing stops at the write class
# and at writes that stay inside the tracker. A tracker call that lands code,
# submits for review, or carries a file out is not bookkeeping, so it still
# asks; so does anything the destroy or transmit classes matched, which is why
# this sits after REASON is decided rather than beside the browser exemption.
if isActiveTrackerTool && [ "$REASON" = "writes to an external system of record" ]; then
  case " $(printf '%s' "$ACTION" | tr '_' ' ') " in
    *" merge "* | *" submit "* | *" upload "* | *" apply "*) ;;
    *) exit 0 ;;
  esac
fi

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-105" "mcp-action-guard" "ask"

jq -n --arg t "$TOOL" --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:("R-105: " + $t + " " + $r + ". Confirm this specific call, its recipient, and its payload before it runs. Approving one destructive MCP action does not pre-authorize the next.")}}'
exit 0
