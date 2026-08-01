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

# Repo exemption (2026-07-22, Ian-approved): repos listed by origin URL in
# enforce/exempt-repos.txt skip this gate entirely. Team repos with their own
# lint conventions opt out here; matching by remote URL covers all worktrees.
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.tsx?$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(git rev-parse --show-toplevel)"
# --added-only: deny only on violations in lines the outgoing diff adds (2026-07-10,
# Ian-approved). Pre-existing debt elsewhere in a touched file no longer blocks.
REPORT=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs node "$HOME/.claude/enforce/lint.mjs" --added-only "$BASE" 2>&1 || true)

if [ -n "$REPORT" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "eslint-ast" "push-eslint-gate" "deny"
  jq -n --arg r "ESLint enforcement failed on the outgoing diff (R-323/R-321/R-319). Fix the violations or run eslint --fix:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
