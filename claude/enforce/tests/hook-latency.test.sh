#!/usr/bin/env bash
# hook-latency.test.sh: fail if the per-event hook chains exceed the latency
# budget. Per-edit hooks must stay cheap (no Node, no network); this test is
# the regression guard for that invariant. Baseline 2026-07-29: ~6ms per event
# for the full PreToolUse:Bash chain of 12 scripts. Budget is set at 500ms to
# stay robust on a loaded machine while still catching a Node or network call
# accidentally added to the per-edit path (those cost seconds, not tens of ms).
set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
BUDGET_MS=500
ROUNDS=3

BASH_HOOKS="secret-scan.sh no-em-dash.sh fix-commit-requires-test.sh conflict-markers.sh commit-message-guard.sh destructive-db-guard.sh global-repo-push-guard.sh push-eslint-gate.sh constant-change-guard.sh audit-signal-check.sh llm-rule-judge.sh single-file-folder-gate.sh"
WRITE_HOOKS="secret-scan.sh no-em-dash.sh migration-defaults-guard.sh structure-gate.sh"

PAYLOAD_PLAIN='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
PAYLOAD_WRITE='{"tool_name":"Write","tool_input":{"file_path":"/x/src/services/format/formatDate.ts","content":"export function formatDate() {}"}}'

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

assert_chain_under_budget() {
  local label="$1" hooks="$2" payload="$3"
  local started_ms elapsed_ms per_event_ms hook
  started_ms=$(now_ms)
  for _ in $(seq "$ROUNDS"); do
    for hook in $hooks; do
      printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
    done
  done
  elapsed_ms=$(( $(now_ms) - started_ms ))
  per_event_ms=$(( elapsed_ms / ROUNDS ))
  if [ "$per_event_ms" -gt "$BUDGET_MS" ]; then
    echo "FAIL: $label chain took ${per_event_ms}ms per event (budget ${BUDGET_MS}ms). A per-edit hook has grown expensive; find it and move the heavy work to the push boundary." >&2
    exit 1
  fi
  echo "  $label: ${per_event_ms}ms per event (budget ${BUDGET_MS}ms)"
}

assert_chain_under_budget "PreToolUse:Bash" "$BASH_HOOKS" "$PAYLOAD_PLAIN"
assert_chain_under_budget "PreToolUse:Write" "$WRITE_HOOKS" "$PAYLOAD_WRITE"

echo "hook-latency.test.sh PASS"
