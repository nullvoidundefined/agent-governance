#!/usr/bin/env bash
# agent-dispatch-guard.sh: PreToolUse hook on Agent (and its older name, Task)
# for R-708. A foreground subagent blocks the main session until it returns,
# so nothing can watch or stop it: on voyager-2 PR 5 one foreground test author
# sat silent for six and a half hours (IAN-605). Claude Code has no subagent
# timeout and no hook can stop a subagent; only the main session can, with
# TaskStop, and only on a background agent. So the long-running agent types
# must dispatch in the background, where agent-watchdog.sh can wake the main
# session on a stall or the time limit.
#
# Denies an Agent call of a long-running type (owner decision 2026-10-03,
# IAN-605) unless its `run_in_background` is exactly true: the long-running
# type list (test-author, implementer, pr-reviewer, security-reviewer,
# general-purpose, and every audit-* role) and the normalization that strips
# namespace, lowercases, and trims whitespace live in agent-types.sh, sourced
# here. An ABSENT flag is allowed: the current Agent tool has no
# run_in_background parameter and always runs subagents in the background.
# "Absent" means tool_input is a JSON object without the key; a present flag
# must still be exactly true, so false, "true", null and the rest are denied,
# and so is a payload with no tool_input object or none that parses. Quick
# lookups (Explore, claude-code-guide, Plan, statusline-setup) and any other
# type may still run in the foreground.
#
# When agent-types.sh is missing the guard fails closed: every type is treated
# as long-running and denied when the flag is present and not true; the
# instruction hook stays silent when it needs the type but still names the
# watchdog for an explicit true flag. An omitted or empty subagent_type
# counts as general-purpose.
# set -uo, no -e: a guard must emit its decision, and an unexpected error under
# -e would exit before it, which a PreToolUse hook reads as allow
# (convention in enforce/README.md).
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
# The hook does not read tool_name at all. settings.json registers it for the
# Agent and Task tools only (agent-watchdog.test.sh pins that matcher), so
# every payload it receives is a dispatch and is judged. Six review rounds on
# PR #184 each found another way to disguise a name for an "is this another
# tool?" check (padding, Unicode spaces, homoglyphs, newlines, non-strings);
# with no such check there is nothing to disguise (owner decision 2026-10-03,
# R-109 r1 #5 to r6 #1).

# A jq failure reads as "not background" and "general-purpose", so a payload
# the hook cannot parse is judged as the riskiest dispatch, never waved through.
IS_BACKGROUND=$(printf '%s' "$INPUT" | jq -r '(.tool_input | type == "object") and ((.tool_input | has("run_in_background") | not) or .tool_input.run_in_background == true)' 2>/dev/null || echo false)
[ "$IS_BACKGROUND" = "true" ] && exit 0

# Fallbacks defined before sourcing so an exported function in the
# environment cannot replace the fail-closed defaults (env var names
# collide with shell function names: BASH_FUNC_foo%%).
normalize_agent_type() {
  local raw="${1##*:}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ -n "$raw" ] && printf '%s' "$raw" || printf '%s' "general-purpose"
}
is_long_running_type() { return 0; }

TYPES_HELPER="$(dirname "${BASH_SOURCE[0]}")/agent-types.sh"
# shellcheck disable=SC1090
[ -f "$TYPES_HELPER" ] && source "$TYPES_HELPER"

# A non-string type reads as empty, so it falls closed to general-purpose
# (R-109 r7 #1 on PR #184).
RAW_TYPE=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.subagent_type | type) == "string" then .tool_input.subagent_type else "" end' 2>/dev/null || echo "")
AGENT_TYPE=$(normalize_agent_type "$RAW_TYPE")

is_long_running_type "$AGENT_TYPE" || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
# shellcheck disable=SC1090
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-708" "agent-dispatch-guard" "deny"
jq -n --arg type "$AGENT_TYPE" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("R-708: the " + $type + " subagent must omit run_in_background (or pass true); the current Agent tool has no such parameter and always runs subagents in the background. After the launch, start the watchdog the PostToolUse hook names (bash ~/.claude/enforce/agent-watchdog.sh <output_file>, as a background Bash command), and stop the agent with TaskStop if the watchdog reports a stall or the time limit.")
  }
}'
exit 0
