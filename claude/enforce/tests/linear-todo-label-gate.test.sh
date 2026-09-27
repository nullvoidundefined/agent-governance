#!/usr/bin/env bash
# Covers: hook:linear-todo-label-gate
# Verifies linear-todo-label-gate.sh denies a tracker save that moves a ticket to
# the status the config maps specced and planned onto (Todo) unless the same call
# adds the specced or planned label, and stays silent on every other state, on
# other tools, and without a tracker config (R-605, IAN-473).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/linear-todo-label-gate.sh"
SAVE="mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_issue"

TRACKER_HOME=$(mktemp -d)
EMPTY_HOME=$(mktemp -d)
trap 'rm -rf "$TRACKER_HOME" "$EMPTY_HOME"' EXIT
mkdir -p "$TRACKER_HOME/.claude"
cat >"$TRACKER_HOME/.claude/TICKET-TRACKER.json" <<TRACKER
{
  "active": "linear",
  "trackers": {
    "linear": {
      "states": {"backlog": "Backlog", "in-progress": "In Progress", "specced": "Todo", "planned": "Todo"},
      "state_labels": {"specced": "specced", "planned": "planned", "blocked": "blocked"},
      "tools": {"create": "$SAVE", "update": "$SAVE"}
    }
  }
}
TRACKER

FAILURES=0
# runHook(): feeds one PreToolUse payload to the hook under the given HOME.
runHook() {
  local home="$1" tool="$2" input="$3"
  printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$input" | HOME="$home" "$HOOK"
}
# expectDeny(): asserts the hook answers with a deny that names the missing label.
expectDeny() {
  local label="$1" output
  output=$(runHook "$TRACKER_HOME" "$2" "$3")
  if printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"
      and (.hookSpecificOutput.permissionDecisionReason | test("specced") and test("planned"))' >/dev/null 2>&1; then
    echo "ok: $label"
  else
    echo "FAIL: $label (got: ${output:-<no output>})"; FAILURES=$((FAILURES + 1))
  fi
}
# expectSilent(): asserts the hook emits nothing, which is an allow.
expectSilent() {
  local label="$1" home="$2" output
  output=$(runHook "$home" "$3" "$4")
  if [ -z "$output" ]; then
    echo "ok: $label"
  else
    echo "FAIL: $label (got: $output)"; FAILURES=$((FAILURES + 1))
  fi
}

expectDeny "Todo by name, no labels" "$SAVE" '{"id":"IAN-1","state":"Todo"}'
expectDeny "Todo in lowercase" "$SAVE" '{"id":"IAN-1","state":"todo"}'
expectDeny "Todo by the unstarted state type" "$SAVE" '{"id":"IAN-1","state":"unstarted"}'
expectDeny "Todo with an unrelated label" "$SAVE" '{"id":"IAN-1","state":"Todo","addLabels":["Bug"]}'
expectDeny "a new ticket created straight into Todo" "$SAVE" '{"team":"T","title":"x","state":"Todo"}'

expectSilent "Todo adding specced" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","state":"Todo","addLabels":["specced"]}'
expectSilent "Todo adding planned" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","state":"Todo","addLabels":["Planned"]}'
expectSilent "Todo replacing labels with a set holding specced" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","state":"Todo","labels":["Bug","specced"]}'
expectSilent "Backlog" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","state":"Backlog"}'
expectSilent "In Progress" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","state":"In Progress"}'
expectSilent "a save with no state change" "$TRACKER_HOME" "$SAVE" '{"id":"IAN-1","priority":2}'
expectSilent "a tool the tracker config does not name" "$TRACKER_HOME" "mcp__github__save_issue" '{"state":"Todo"}'
expectSilent "a non-MCP tool" "$TRACKER_HOME" "Bash" '{"command":"echo Todo"}'
expectSilent "no tracker config" "$EMPTY_HOME" "$SAVE" '{"id":"IAN-1","state":"Todo"}'

if [ "$FAILURES" -gt 0 ]; then
  echo "linear-todo-label-gate: $FAILURES failure(s)"; exit 1
fi
echo "linear-todo-label-gate: all passed"
