#!/usr/bin/env bash
# Covers: hook:model-switch-guard
# Verifies model-switch-guard.sh (PreModelSwitch, R-903). PreModelSwitch has
# no permissionDecision channel (that is a tool-event concept; this event
# blocks only via exit 2), so the guard warns through systemMessage and always
# allows. Five invariants:
#   1. sonnet -> opus warns via systemMessage, names both models, exits 0.
#   2. opus -> sonnet is silent (stepping down needs no confirmation).
#   3. opus -> opus[1m] is silent (lateral).
#   4. An unrankable target is silent (fail open on gateway or custom IDs).
#   5. The warn path never exits 2 (a warn must not block the switch).
set -euo pipefail
HOOK="$HOME/.claude/hooks/model-switch-guard.sh"
run() { jq -n --arg f "$1" --arg t "$2" '{hook_event_name:"PreModelSwitch",from_model:$f,to_model:$t}' | CLAUDE_FIRE_LOG=/dev/null "$HOOK"; }

OUT=$(run claude-sonnet-5 claude-opus-5) || { echo "FAIL: the warn path must exit 0, a nonzero exit would block the switch"; exit 1; }
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null || { echo "FAIL: sonnet -> opus must warn via systemMessage, got: $OUT"; exit 1; }
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1 && { echo "FAIL: PreModelSwitch has no permissionDecision channel"; exit 1; }
printf '%s' "$OUT" | grep -q 'claude-sonnet-5 to claude-opus-5' || { echo "FAIL: the warning must name both models"; exit 1; }
OUT=$(run claude-opus-5 claude-sonnet-5); [ -z "$OUT" ] || { echo "FAIL: stepping down must be silent"; exit 1; }
OUT=$(run "opus" "opus[1m]"); [ -z "$OUT" ] || { echo "FAIL: a lateral switch must be silent"; exit 1; }
OUT=$(run claude-sonnet-5 gateway-custom-model); [ -z "$OUT" ] || { echo "FAIL: an unrankable target must be silent"; exit 1; }
echo "model-switch-guard.test.sh PASS"
