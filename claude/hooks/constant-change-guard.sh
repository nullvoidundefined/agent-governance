#!/usr/bin/env bash
# constant-change-guard.sh: PreToolUse gate on `git push` (R-513). When the
# outgoing diff changes a constants module and removes a quoted value that still
# appears in test files, asks before pushing so stale assertions ship knowingly
# or get fixed. Fails open when no base ref resolves.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

CONST_FILES=$(git diff --name-only "$BASE"..HEAD 2>/dev/null | grep -E '(^|/)constants(\.[jt]sx?$|/)' || true)
[ -z "$CONST_FILES" ] && exit 0

TOP=$(git rev-parse --show-toplevel)
STALE=""
while IFS= read -r constants_file; do
  [ -z "$constants_file" ] && continue
  DIFF=$(git diff "$BASE"..HEAD -- "$constants_file" 2>/dev/null || true)
  REMOVED=$(printf '%s\n' "$DIFF" | grep '^-' | grep -oE "'[^']{3,}'|\"[^\"]{3,}\"" | sed "s/^[\"']//;s/[\"']$//" | sort -u)
  KEPT=$(printf '%s\n' "$DIFF" | grep '^+' | grep -oE "'[^']{3,}'|\"[^\"]{3,}\"" | sed "s/^[\"']//;s/[\"']$//" | sort -u)
  while IFS= read -r removed_value; do
    [ -z "$removed_value" ] && continue
    printf '%s\n' "$KEPT" | grep -qxF "$removed_value" && continue
    HITS=$(cd "$TOP" && git grep -lF "$removed_value" -- '*__tests__*' '*.test.*' '*.spec.*' 'tests/*' 2>/dev/null || true)
    if [ -n "$HITS" ]; then
      STALE="$STALE
  '$removed_value' (removed from $constants_file) still asserted in: $(printf '%s' "$HITS" | tr '\n' ' ')"
    fi
  done <<< "$REMOVED"
done <<< "$CONST_FILES"

if [ -n "$STALE" ]; then
  jq -n --arg r "constant-change-guard (R-513): the outgoing diff removes constant values that still appear in test assertions. Update every stale assertion in the same commit as the source change, or confirm to push anyway if the matches are coincidental:$STALE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi

exit 0
