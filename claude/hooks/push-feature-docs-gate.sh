#!/usr/bin/env bash
# push-feature-docs-gate.sh: on `git push`, run the harness's canonical
# product-doc checks over the outgoing diff of the repository being pushed and
# deny the push when either reports a gap; the reports become the deny reason.
#   R-607 enforce/require-feature-checklist.sh: a branch that adds a
#         user-facing route also changes docs/feature-list/features.md, a
#         story under docs/user-stories/, and an e2e spec.
#   R-608 enforce/require-stack-observability-docs.sh: a branch that adds or
#         removes a manifest dependency also changes docs/stack.md, and one
#         that adds or removes an analytics event, an error code, or a log
#         event name also changes docs/observability.md.
#
# Trust boundary: this gate always runs the harness copy and never the target
# repository's scripts/require-feature-checklist.sh, because push gates do not
# execute target-repository code (2026-07-31 security audit; the same reason
# `bundle exec` is banned in push-rubocop-gate). Per-repository tuning is data
# in .enforce.json, which the script reads and never evaluates.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
# Spec: docs/superpowers/specs/2026-09-18-product-docs-design.md (R-607);
# rulebook/reference.md R-608.
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"
CHECKLIST="$ENFORCE_DIR/require-feature-checklist.sh"
STACK_OBSERVABILITY_CHECK="$ENFORCE_DIR/require-stack-observability-docs.sh"

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`,
# then recover which repository the push names, from the UNSTRIPPED command
# (2026-09-18 audit, defect 4). A -f guard rather than `source ... || true`,
# which aborts under set -e regardless of the ||.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  parse_git_target_options "$RAW_CMD" push
fi
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

# Repo exemption: the allowlist every push gate shares (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -n "$BASE" ] || exit 0
TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0

# run_doc_check <rule> <label> <script>: runs one canonical check from the
# repository top; prints "<rule> (<label>): <report>" when it reports a gap
# (exit 1) and nothing otherwise. The caller joins the reports, since command
# substitution strips any trailing separator printed here (PR #124 review). A
# missing script is named on stderr and skipped, so one absent file never
# disables the other check.
run_doc_check() {
  local report status
  [ -f "$3" ] || { echo "push-feature-docs-gate: $3 is missing; $1 not checked" >&2; return 0; }
  report=$(cd "$TOP" && bash "$3" "$BASE" 2>&1)
  status=$?
  [ "$status" -eq 1 ] || return 0
  log_rule_fire "$1" "push-feature-docs-gate" "deny"
  printf '%s (%s): %s\n' "$1" "$2" "$report"
}

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }

FEATURE_REPORT=$(run_doc_check "R-607" "features list and user stories" "$CHECKLIST")
STACK_REPORT=$(run_doc_check "R-608" "stack and observability docs" "$STACK_OBSERVABILITY_CHECK")
if [ -n "$FEATURE_REPORT" ] && [ -n "$STACK_REPORT" ]; then
  REASON="$FEATURE_REPORT"$'\n\n'"$STACK_REPORT"
else
  REASON="$FEATURE_REPORT$STACK_REPORT"
fi
[ -n "$REASON" ] || exit 0
jq -n --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
