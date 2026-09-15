#!/usr/bin/env bash
# task-commit-reminder.sh: PostToolUse advisory on TaskUpdate (R-504). When a
# task is marked completed while the working tree still holds uncommitted
# changes, injects a non-blocking reminder to commit that task's work now (one
# commit per task), so the commit-per-task rule no longer depends on recall.
# Never blocks; silent for non-completed updates and outside git repos.
set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "TaskUpdate" ] || exit 0
STATUS=$(printf '%s' "$INPUT" | jq -r '.tool_input.status // ""')
[ "$STATUS" = "completed" ] || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "$DIRTY_COUNT" -eq 0 ] && exit 0

REPO_TOP=$(git rev-parse --show-toplevel)
jq -nc --arg count "$DIRTY_COUNT" --arg repo "$REPO_TOP" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("task-commit-reminder (R-504): a task was just marked completed while " + $count + " paths in " + $repo + " are uncommitted. Commit the completed task now (one commit per discrete task) before starting the next one. Advisory only.")}}'
exit 0
