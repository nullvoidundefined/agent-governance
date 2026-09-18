#!/usr/bin/env bash
# push-eslint-gate.sh: on `git push`, run the bundled enforcement ESLint over the
# TypeScript files added/changed in the outgoing diff. Deny the push on any
# error-level violation of the AST-tier rules (R-323/R-321/R-319/R-326/R-327/
# R-324, plus R-303 in repos with .enforce.json import zones). Heavy work runs
# once per push, not per edit.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
# shellcheck source=../enforce/resolve-outgoing-base.sh
source "$ENFORCE_DIR/resolve-outgoing-base.sh"

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`
# (2026-09-16 audit P2-1; the normalizer lives once in git-invocation.sh), then
# recover from the UNSTRIPPED command which repository the push actually names
# (2026-09-18 audit defect 4), so that recognition and targeting no longer pull
# in opposite directions.
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), which is a silent
# fail-open for a guard.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  parse_git_target_options "$RAW_CMD" push
fi
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

# Repo exemption (2026-07-22, Ian-approved): repos listed by origin URL in
# enforce/exempt-repos.txt skip this gate entirely. Team repos with their own
# lint conventions opt out here; matching by remote URL covers all worktrees.
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.(tsx?|vue)$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0
# --added-only: deny only on violations in lines the outgoing diff adds (2026-07-10,
# Ian-approved). Pre-existing debt elsewhere in a touched file no longer blocks.
REPORT=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs node "$ENFORCE_DIR/lint.mjs" --added-only "$BASE" 2>&1 || true)

if [ -n "$REPORT" ]; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "eslint-ast" "push-eslint-gate" "deny"
  jq -n --arg r "ESLint enforcement failed on the outgoing diff (R-323/R-321/R-319). Fix the violations or run eslint --fix:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
