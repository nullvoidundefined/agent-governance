#!/usr/bin/env bash
# model-switch-guard.sh: PreModelSwitch hook for R-903 (route work to the
# cheapest capable model). Until 2026-09-05 nothing enforced the rule from
# the harness side: the Sonnet-default memory could only ask Claude to notice.
# This warns on any switch UP the price ladder (haiku -> sonnet -> opus ->
# fable) and stays silent on lateral or downward switches and on model names
# it cannot rank. Warns, never blocks: PreModelSwitch carries no
# permissionDecision channel (that is a tool-event concept; this event blocks
# only via exit 2, which would veto rather than confirm), stepping up is often
# right, and the point is that it is a decision someone made.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
FROM=$(printf '%s' "$INPUT" | jq -r '.from_model // ""' 2>/dev/null || true)
TO=$(printf '%s' "$INPUT" | jq -r '.to_model // ""' 2>/dev/null || true)

rank() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *haiku*) echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*) echo 3 ;;
    *fable*|*best*) echo 4 ;;
    *) echo 0 ;;
  esac
}
FROM_RANK=$(rank "$FROM"); TO_RANK=$(rank "$TO")
[ "$FROM_RANK" -gt 0 ] && [ "$TO_RANK" -gt 0 ] || exit 0
[ "$TO_RANK" -gt "$FROM_RANK" ] || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-903" "model-switch-guard" "warn"
jq -n --arg from "$FROM" --arg to "$TO" '{
  systemMessage: ("R-903: this switches up the price ladder (" + $from + " to " + $to + "). Confirm the next stretch needs it: complex refactor, security-sensitive logic, ambiguous design, audit, or multi-step planning. Mechanical work stays on the cheaper tier.")
}'
exit 0
