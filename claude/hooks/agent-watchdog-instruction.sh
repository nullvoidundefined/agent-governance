#!/usr/bin/env bash
# agent-watchdog-instruction.sh: PostToolUse hook on Agent (and Task) for
# R-708. After a background subagent launch it names the exact watchdog
# command for that agent, so the main session can start it as a background
# Bash command and be woken on a stall or the time limit (IAN-605). A hook
# cannot start the command itself; it can only tell the model.
#
# The launch's tool response carries the agent's transcript path on a line
# `output_file: <path>`; the response may arrive as a string or as structured
# content, so the whole response is flattened to text before the line is
# found. The response text is untrusted (a foreground agent's report can quote
# fetched content), and the path is pasted into a command the model will run,
# so the hook answers only an async-launch response and only a plain absolute
# path of letters, digits, dot, underscore, slash and hyphen, which it still
# single-quotes (R-517 r1 on PR #184). Anything else gets nothing.
#
# A background launch is run_in_background exactly true, or the flag ABSENT on
# a long-running agent type: the current Agent tool has no such parameter and
# always runs subagents in the background (same type list and normalization as
# agent-dispatch-guard.sh; both read agent-types.sh). A present non-true flag
# stays silent.
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

TYPES_HELPER="$(dirname "${BASH_SOURCE[0]}")/agent-types.sh"
# shellcheck disable=SC1090
[ -f "$TYPES_HELPER" ] && source "$TYPES_HELPER" || exit 0

RESPONSE_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_response
  | if type == "string" then .
    else [.. | strings] | join("\n")
    end
' 2>/dev/null || true)
OUTPUT_FILE=$(printf '%s\n' "$RESPONSE_TEXT" \
  | sed -n 's/^[[:space:]]*output_file:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' \
  | head -n 1)
[ -n "$OUTPUT_FILE" ] || exit 0
# The call itself must have been a background launch: the response text is
# untrusted and can quote a launch message, so the phrase alone proves nothing
# (R-109 r1 #1 on PR #184).
if ! printf '%s' "$INPUT" | jq -e '.tool_input.run_in_background == true' >/dev/null 2>&1; then
  printf '%s' "$INPUT" | jq -e '(.tool_input | type == "object") and (.tool_input | has("run_in_background") | not)' >/dev/null 2>&1 || exit 0
  RAW_TYPE=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.subagent_type | type) == "string" then .tool_input.subagent_type else "" end' 2>/dev/null || echo "")
  AGENT_TYPE=$(normalize_agent_type "$RAW_TYPE")
  is_long_running_type "$AGENT_TYPE" || exit 0
fi
printf '%s\n' "$RESPONSE_TEXT" | grep -q 'Async agent launched' || exit 0
# Only the harness's own launch shape, a `.../tasks/<name>.output` file, with
# no empty or `..` segment: never a device, a key file or a traversal (r1 #3).
printf '%s' "$OUTPUT_FILE" | grep -Eq '^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/tasks/[A-Za-z0-9_-]+\.output$' || exit 0
case "$OUTPUT_FILE" in */../*|*/./*|*//*) exit 0 ;; esac

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
# shellcheck disable=SC1090
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-708" "agent-watchdog-instruction" "instruct"
jq -n --arg file "$OUTPUT_FILE" --arg quote "'" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("R-708 (watchdog): start this as a background Bash command now: bash ~/.claude/enforce/agent-watchdog.sh " + $quote + $file + $quote + "\nIt exits 0 when the agent finishes, 3 after 10 minutes with no transcript growth, and 4 at 45 minutes. On 3 or 4 its report line names the agent last entry; never read the transcript itself. Stop the agent with TaskStop unless that line shows it plainly making progress, and say which you did.")
  }
}'
exit 0
