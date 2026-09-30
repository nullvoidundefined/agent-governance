#!/usr/bin/env bash
# linear-todo-label-gate.sh: R-605. The tracker config maps the canonical
# `specced` and `planned` states onto one Linear status (Todo) and tells them
# apart with a same-named label. A Todo ticket with neither label is therefore
# a state the config cannot name, and on 2026-09-27 31 of 32 Todo tickets were
# in it, turning Todo into a second priority list beside the Priority field
# (IAN-473). This hook denies a save on the active tracker's create or update
# tool that moves a ticket to that status unless the same call adds `specced`
# or `planned`.
#
# The label must travel with the move because a hook sees only the call's
# input: it cannot read the labels a ticket already carries. `addLabels` is
# append-only in the Linear tool, so re-adding an existing label is harmless.
#
# Scope and limits:
# - The tool is matched exactly against the active tracker's `create` and
#   `update` entries in ~/.claude/TICKET-TRACKER.json, the same authority
#   mcp-action-guard.sh uses, so a server registered under a UUID still matches.
# - The target status name comes from the config's `states.specced` and
#   `states.planned`; the `unstarted` state type is gated too, since the tool
#   accepts a state by type.
# - A state passed as a raw UUID is not classified; nothing maps UUIDs here.
# - Edits made in the Linear UI never reach a hook. The weekday
#   `linear-todo-sweep` scheduled task reports those.
#
# Silent without a tracker config: the rule has nothing to govern then.
# set -uo, no -e: an internal error under -e kills the hook before it can emit
# a decision (enforce/README.md). A failing jq below yields empty values, which
# read as "not a gated move", so a malformed payload allows; the rule this
# protects is bookkeeping, not a safety floor.
set -uo pipefail
: "${HOME:=$(cd ~ 2>/dev/null && pwd)}"
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
case "$TOOL" in mcp__*) ;; *) exit 0 ;; esac

CONFIG="${CLAUDE_TICKET_TRACKER_FILE:-$HOME/.claude/TICKET-TRACKER.json}"
[ -f "$CONFIG" ] || exit 0

# readTrackerRule(): prints the specced status name, the planned status name,
# and the two label names as four lines, lowercased, when the tool is the
# active tracker's create or update tool; prints nothing otherwise. Both status
# names are read because a tracker may map the two canonical states apart.
readTrackerRule() {
  jq -r --arg tool "$TOOL" '
    .trackers[.active] as $t
    | select($t.tools.create == $tool or $t.tools.update == $tool)
    | [$t.states.specced, $t.states.planned, $t.state_labels.specced, $t.state_labels.planned]
    | map(ascii_downcase) | .[]
  ' "$CONFIG" 2>/dev/null
}

RULE=$(readTrackerRule)
[ -n "$RULE" ] || exit 0
SPECCED_STATE=$(printf '%s\n' "$RULE" | sed -n 1p)
PLANNED_STATE=$(printf '%s\n' "$RULE" | sed -n 2p)
SPECCED_LABEL=$(printf '%s\n' "$RULE" | sed -n 3p)
PLANNED_LABEL=$(printf '%s\n' "$RULE" | sed -n 4p)

STATE=$(printf '%s' "$INPUT" | jq -r '.tool_input.state // "" | ascii_downcase' 2>/dev/null)
case "$STATE" in
  "$SPECCED_STATE" | "$PLANNED_STATE" | unstarted) ;;
  *) exit 0 ;;
esac

# The same call may name labels through the append-only addLabels or the
# replacing labels field; either carrying one of the two labels satisfies it.
if printf '%s' "$INPUT" | jq -e --arg s "$SPECCED_LABEL" --arg p "$PLANNED_LABEL" '
    [(.tool_input.addLabels // []), (.tool_input.labels // [])]
    | flatten | map(ascii_downcase) | any(. == $s or . == $p)
  ' >/dev/null 2>&1; then
  exit 0
fi

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-605" "linear-todo-label-gate" "deny"

jq -n --arg s "$SPECCED_LABEL" --arg p "$PLANNED_LABEL" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("R-605 (IAN-473): Todo holds only specced or planned tickets. Add addLabels: [\"" + $s + "\"] or [\"" + $p + "\"] to this same call, or move the ticket to Backlog instead; the Priority field orders the backlog.")}}'
exit 0
