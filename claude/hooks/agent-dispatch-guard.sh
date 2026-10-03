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
# Denies an Agent call whose `run_in_background` is explicitly false and whose
# type is a long-running one (owner decision 2026-10-03, IAN-605): test-author,
# implementer, slice-critic, pr-reviewer, security-reviewer, general-purpose
# (also the type an omitted subagent_type means), and every audit-* role.
# Quick lookups (Explore, claude-code-guide, Plan, statusline-setup) and any
# other type may still run in the foreground. Background is the tool's
# default, so an omitted `run_in_background` passes.
# set -uo, no -e: a guard must emit its decision, and an unexpected error under
# -e would exit before it, which a PreToolUse hook reads as allow
# (convention in enforce/README.md).
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

IS_FOREGROUND=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background == false' 2>/dev/null || echo false)
[ "$IS_FOREGROUND" = "true" ] || exit 0
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // "general-purpose"' 2>/dev/null || echo general-purpose)

# is_long_running_type <type>: true for the types R-708 keeps out of the
# foreground; an audit role is matched by its prefix.
is_long_running_type() {
  case "$1" in
    test-author|implementer|slice-critic|pr-reviewer|security-reviewer|general-purpose|audit-*) return 0 ;;
    *) return 1 ;;
  esac
}
is_long_running_type "$AGENT_TYPE" || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-708" "agent-dispatch-guard" "deny"
jq -n --arg type "$AGENT_TYPE" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("R-708: a " + $type + " subagent may not run in the foreground, because a foreground agent blocks the session and nothing can stop it if it stalls. Dispatch it again with run_in_background omitted or true. After the launch, start the watchdog the PostToolUse hook names (bash ~/.claude/enforce/agent-watchdog.sh <output_file>, as a background Bash command), and stop the agent with TaskStop if the watchdog reports a stall or the time limit.")
  }
}'
exit 0
