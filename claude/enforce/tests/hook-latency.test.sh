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

BASH_HOOKS="secret-scan.sh no-em-dash.sh fix-commit-requires-test.sh conflict-markers.sh commit-message-guard.sh destructive-db-guard.sh global-repo-push-guard.sh git-workflow-guard.sh push-eslint-gate.sh push-ruff-gate.sh push-rubocop-gate.sh push-golangci-gate.sh constant-change-guard.sh audit-signal-check.sh llm-rule-judge.sh single-file-folder-gate.sh"
WRITE_HOOKS="secret-scan.sh no-em-dash.sh migration-defaults-guard.sh structure-gate.sh content-gate.sh"

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
