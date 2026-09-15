#!/usr/bin/env bash
# model-switch-guard.sh: PreModelSwitch hook for R-903 (route work to the
# cheapest capable model). Until 2026-09-05 nothing enforced the rule from
# the harness side: the Sonnet-default memory could only ask Claude to notice.
# This asks the human to confirm any switch UP the price ladder (haiku ->
# sonnet -> opus -> fable) and stays silent on lateral or downward switches
# and on model names it cannot rank. Asks, never blocks: stepping up is often
# right, and the point is that it is a decision someone made.
set -euo pipefail
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

source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-903" "model-switch-guard" "ask"
jq -n --arg from "$FROM" --arg to "$TO" '{
  hookSpecificOutput: {
    hookEventName: "PreModelSwitch",
    permissionDecision: "ask",
    permissionDecisionReason: ("R-903: this switches up the price ladder (" + $from + " to " + $to + "). Confirm the next stretch needs it: complex refactor, security-sensitive logic, ambiguous design, audit, or multi-step planning. Mechanical work stays on the cheaper tier.")
  }
}'
exit 0
