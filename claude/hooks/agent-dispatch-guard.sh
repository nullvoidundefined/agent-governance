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
# IAN-605) unless its `run_in_background` is exactly true: test-author,
# implementer, slice-critic, pr-reviewer, security-reviewer, general-purpose
# (also the type an omitted or empty subagent_type means), and every audit-*
# role. The type is read case-insensitively, without whitespace, and after
# any `plugin:` namespace.
# An omitted flag is denied too: the tool's default has differed between
# versions, and only an explicit true is certainly a background run (R-517 r1
# on PR #184). Quick lookups (Explore, claude-code-guide, Plan,
# statusline-setup) and any other type may still run in the foreground.
# set -uo, no -e: a guard must emit its decision, and an unexpected error under
# -e would exit before it, which a PreToolUse hook reads as allow
# (convention in enforce/README.md).
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
# settings.json registers this hook for Agent and Task only, so a payload jq
# cannot parse is still a subagent dispatch: it is judged, never waved through
# (R-109 r1 #5 on PR #184). A parsed payload naming another tool is ignored.
# A missing, null or differently cased name is judged too; only a payload that
# names another tool outright is ignored (R-109 r2 #2 on PR #184).
# Only a plain ASCII identifier that names another tool (Bash, an mcp__ tool)
# is ignored. Anything else is judged as a dispatch: a non-string or empty
# name, padding of any kind, or a homoglyph such as a fullwidth or Cyrillic
# letter, whatever the locale. Allowlisting the ignore branch closes the
# class that reducing or stripping the name kept reopening (R-109 r3 #1, r4 #1
# and r5 #1 on PR #184).
if TOOL=$(printf '%s' "$INPUT" | jq -er 'if (.tool_name | type) == "string" then .tool_name else "" end' 2>/dev/null); then
  if printf '%s' "$TOOL" | LC_ALL=C grep -Eqx '[A-Za-z_][A-Za-z0-9_]*'; then
    case "$(printf '%s' "$TOOL" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in agent|task) ;; *) exit 0 ;; esac
  fi
fi

# A jq failure reads as "not background" and "general-purpose", so a payload
# the hook cannot parse is judged as the riskiest dispatch, never waved through.
IS_BACKGROUND=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background == true' 2>/dev/null || echo false)
[ "$IS_BACKGROUND" = "true" ] && exit 0
RAW_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
AGENT_TYPE=$(printf '%s' "${RAW_TYPE##*:}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
[ -n "$AGENT_TYPE" ] || AGENT_TYPE=general-purpose

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
    permissionDecisionReason: ("R-708: a " + $type + " subagent may not run in the foreground, because a foreground agent blocks the session and nothing can stop it if it stalls. Dispatch it again with run_in_background: true. After the launch, start the watchdog the PostToolUse hook names (bash ~/.claude/enforce/agent-watchdog.sh <output_file>, as a background Bash command), and stop the agent with TaskStop if the watchdog reports a stall or the time limit.")
  }
}'
exit 0
