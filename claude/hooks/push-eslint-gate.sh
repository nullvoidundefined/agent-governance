#!/usr/bin/env bash
# push-eslint-gate.sh: on `git push`, run the bundled enforcement ESLint over the
# TypeScript files added/changed in the outgoing diff. Deny the push on any
# error-level violation (R-231/R-218/R-235). Heavy work runs once per push, not
# per edit.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.tsx?$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(git rev-parse --show-toplevel)"
REPORT=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs node "$HOME/.claude/enforce/lint.mjs" 2>&1 || true)

if [ -n "$REPORT" ]; then
  jq -n --arg r "ESLint enforcement failed on the outgoing diff (R-231/R-218/R-235). Fix the violations or run eslint --fix:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
