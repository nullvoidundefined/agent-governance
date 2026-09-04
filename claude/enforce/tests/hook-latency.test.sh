#!/usr/bin/env bash
# hook-latency.test.sh: fail if a per-event hook chain does heavy work. The
# guarded invariant: per-edit hooks stay bash+jq cheap (no Node startup, no
# network). Absolute wall-clock is load-dependent (a busy dev server inflates
# every process spawn), so the budget is normalized against a same-environment
# control: the chain may cost at most BUDGET_MULTIPLIER times the cost of the
# same number of bare bash+jq spawns, with an absolute floor so an idle
# machine never false-fails. A hook that grows a Node or network dependency
# costs 10-100x a bare spawn and blows the multiplier under any load.
set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
BUDGET_MULTIPLIER=6
BUDGET_FLOOR_MS=250
ROUNDS=3

# The chains are read from settings.json, not listed here: a hand-kept list
# drifted from the registered chain three audits running (2026-07-31, 2026-08-21
# P3-7, 2026-09-04 P2-7), each time leaving newly registered hooks unmeasured.
# The chain runs sequentially here while Claude Code runs matching hooks in
# parallel, so the budget bounds total spawn cost, not wall-clock.
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
registered_chain() {
  jq -r --arg m "$1" '.hooks.PreToolUse[] | select(.matcher==$m) | .hooks[].command' "$SETTINGS" | sed 's#.*/##' | tr '\n' ' '
}
BASH_HOOKS=$(registered_chain Bash)
WRITE_HOOKS=$(registered_chain "Write|Edit")
[ -n "$BASH_HOOKS" ] && [ -n "$WRITE_HOOKS" ] || { echo "FAIL: could not read the PreToolUse chains from $SETTINGS" >&2; exit 1; }

PAYLOAD_PLAIN='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
PAYLOAD_WRITE='{"tool_name":"Write","tool_input":{"file_path":"/x/src/services/format/formatDate.ts","content":"export function formatDate() {}"}}'

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

measure_control_ms() {
  local hook_count="$1"
  local started_ms
  started_ms=$(now_ms)
  for _ in $(seq $(( hook_count * ROUNDS ))); do
    printf '{}' | bash -c 'jq -r ".x // \"\"" >/dev/null' 2>/dev/null || true
  done
  echo $(( ($(now_ms) - started_ms) / ROUNDS ))
}

assert_chain_under_budget() {
  local label="$1" hooks="$2" payload="$3"
  local hook_count started_ms per_event_ms control_ms budget_ms hook
  hook_count=$(echo "$hooks" | wc -w | tr -d ' ')
  control_ms=$(measure_control_ms "$hook_count")
  budget_ms=$(( control_ms * BUDGET_MULTIPLIER ))
  [ "$budget_ms" -lt "$BUDGET_FLOOR_MS" ] && budget_ms=$BUDGET_FLOOR_MS
  started_ms=$(now_ms)
  for _ in $(seq "$ROUNDS"); do
    for hook in $hooks; do
      printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
    done
  done
  per_event_ms=$(( ($(now_ms) - started_ms) / ROUNDS ))
  if [ "$per_event_ms" -gt "$budget_ms" ]; then
    echo "FAIL: $label chain took ${per_event_ms}ms per event vs a ${control_ms}ms bare-spawn control (budget ${budget_ms}ms). A per-edit hook has grown expensive; find it and move the heavy work to the push boundary." >&2
    exit 1
  fi
  echo "  $label: ${per_event_ms}ms per event (control ${control_ms}ms, budget ${budget_ms}ms)"
}

assert_chain_under_budget "PreToolUse:Bash" "$BASH_HOOKS" "$PAYLOAD_PLAIN"
assert_chain_under_budget "PreToolUse:Write" "$WRITE_HOOKS" "$PAYLOAD_WRITE"

echo "hook-latency.test.sh PASS"
