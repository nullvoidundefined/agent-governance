#!/usr/bin/env bash
# push-eslint-gate.sh: on `git push`, run the bundled enforcement ESLint over the
# TypeScript files added/changed in the outgoing diff. Deny the push on any
# error-level violation of the AST-tier rules (R-323/R-321/R-319/R-326/R-327/
# R-324, plus R-303 in repos with .enforce.json import zones). Heavy work runs
# once per push, not per edit.
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
  jq -n --arg r "ESLint enforcement failed on the outgoing diff (R-323/R-321/R-319). Fix the violations or run eslint --fix:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
