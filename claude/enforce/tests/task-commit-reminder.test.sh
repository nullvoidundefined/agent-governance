#!/usr/bin/env bash
# Verifies task-commit-reminder.sh: marking a task completed with a dirty
# working tree emits an R-504 commit-now reminder; clean trees, non-completed
# updates, and non-repo directories stay silent.
set -euo pipefail
HOOK="$HOME/.claude/hooks/task-commit-reminder.sh"

advisory() {
  OUT=$(jq -n --arg s "$1" '{tool_name:"TaskUpdate",tool_input:{taskId:"1",status:$s}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // "none"'; fi
}

TMP=$(mktemp -d)
cd "$TMP"
git init -q
git config user.email t@t && git config user.name t
echo base > tracked.txt
git add -A && git commit -qm "chore: init"

# Dirty tree + completed -> reminder citing R-504.
echo change > tracked.txt
echo new > untracked.txt
GOT=$(advisory completed)
printf '%s' "$GOT" | grep -q 'R-504' || { echo "FAIL: expected R-504 reminder on dirty completion, got: $GOT"; exit 1; }

# Dirty tree + non-completed status -> silent.
GOT=$(advisory in_progress)
[ "$GOT" = "none" ] || { echo "FAIL: expected silence for in_progress, got: $GOT"; exit 1; }

# Clean tree + completed -> silent.
git add -A && git commit -qm "chore: work"
GOT=$(advisory completed)
[ "$GOT" = "none" ] || { echo "FAIL: expected silence on clean tree, got: $GOT"; exit 1; }

# Outside a git repo -> silent.
NONREPO=$(mktemp -d)
cd "$NONREPO"
GOT=$(advisory completed)
[ "$GOT" = "none" ] || { echo "FAIL: expected silence outside a repo, got: $GOT"; exit 1; }

cd / && rm -rf "$TMP" "$NONREPO"
echo "task-commit-reminder.test.sh PASS"
