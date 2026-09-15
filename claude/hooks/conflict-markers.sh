#!/usr/bin/env bash
# conflict-markers.sh
#
# PreToolUse hook. Blocks `git commit` when staged files contain
# conflict markers. Enforces R-507.

# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

if ! printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+commit[[:space:]]'; then
  exit 0
fi

MARKERS=$(git diff --cached 2>/dev/null | grep -E '^[+](<{7}|={7}|>{7})' || true)

# Chained `git add X && git commit` reaches this hook before staging, so the
# cached diff is empty (2026-07-31 engineering audit P1). Also scan the
# working-tree content of files named in git add segments of this command.
ADD_SEGMENTS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+add[[:space:]]+[^;&|]+' || true)
if [ -n "$ADD_SEGMENTS" ]; then
  while IFS= read -r add_path; do
    [ -f "$add_path" ] || continue
    FILE_MARKERS=$(grep -E '^(<{7}( |$)|={7}$|>{7}( |$))' "$add_path" 2>/dev/null || true)
    [ -n "$FILE_MARKERS" ] && MARKERS="$MARKERS
$FILE_MARKERS"
  done < <(printf '%s\n' "$ADD_SEGMENTS" | sed -E 's/^git[[:space:]]+add[[:space:]]+//' | tr ' ' '\n' | grep -vE '^$|^-')
fi

if [ -z "$MARKERS" ]; then
  exit 0
fi

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-507" "conflict-markers" "deny"
jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "conflict-markers hook BLOCKED: staged files contain unresolved conflict markers (<<<<<<< / ======= / >>>>>>>). Resolve all conflicts before committing."
  }
}'

exit 0
