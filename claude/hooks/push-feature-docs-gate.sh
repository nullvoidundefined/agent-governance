#!/usr/bin/env bash
# push-feature-docs-gate.sh: on `git push`, run the harness's canonical R-607
# feature checklist (enforce/require-feature-checklist.sh) over the outgoing
# diff of the repository being pushed, and deny the push when the branch adds
# a user-facing route without also changing docs/feature-list/features.md, a
# story under docs/user-stories/, and an e2e spec. The report the script
# prints becomes the deny reason.
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
# Spec: docs/superpowers/specs/2026-09-18-product-docs-design.md.
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"
CHECKLIST="$ENFORCE_DIR/require-feature-checklist.sh"

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
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

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
[ -f "$CHECKLIST" ] || { echo "push-feature-docs-gate: $CHECKLIST is missing; R-607 not checked" >&2; exit 0; }

REPORT=$(cd "$TOP" && bash "$CHECKLIST" "$BASE" 2>&1)
STATUS=$?
[ "$STATUS" -eq 1 ] || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-607" "push-feature-docs-gate" "deny"
jq -n --arg r "R-607 (features list and user stories): $REPORT" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
