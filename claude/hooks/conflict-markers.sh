#!/usr/bin/env bash
# conflict-markers.sh
#
# PreToolUse hook. Blocks `git commit` when staged files contain
# conflict markers. Enforces R-507.

set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

if ! printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+commit[[:space:]]'; then
  exit 0
fi

MARKERS=$(git diff --cached 2>/dev/null | grep -E '^[+](<{7}|={7}|>{7})' || true)
if [ -z "$MARKERS" ]; then
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "conflict-markers hook BLOCKED: staged files contain unresolved conflict markers (<<<<<<< / ======= / >>>>>>>). Resolve all conflicts before committing."
  }
}'

exit 0
