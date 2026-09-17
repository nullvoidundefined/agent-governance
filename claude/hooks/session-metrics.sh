#!/usr/bin/env bash
# session-metrics.sh: the R-602 "Session metrics" block, computed on demand
# (2026-09-17 skills audit, S-12). session-end.sh used to compute these four
# numbers itself at SessionEnd and leave them in a temp file, which fires
# after the handoff is written and committed, so a handoff that read the file
# always carried the previous session's numbers. This prints the block to
# stdout from the same inputs, so the task-cleanup handoff step gets live
# numbers and session-end.sh calls it for the file it still writes.
#
# Usage: session-metrics.sh [--since <sha>]
# Inputs: the start SHA session-start.sh stamps under ${TMPDIR:-/tmp}, keyed
# by the repo toplevel (with the unkeyed name as a fallback), unless --since
# names one. Outside a git repository, or with no start SHA, prints the block
# with zeros and a note, and exits 0: a reminder hook must never fail a turn.
set -uo pipefail

SINCE=""
if [ "${1:-}" = "--since" ]; then SINCE="${2:-}"; fi

print_block() {
  local commits="$1" files="$2" rework="$3" flag="$4" note="${5:-}"
  cat <<METRICS_EOF
## Session metrics
- Commits this session: $commits
- Files changed: $files
- Rework commits (file touched by 2+ commits): $rework
- Velocity flag: $flag
METRICS_EOF
  [ -z "$note" ] || printf -- '- Note: %s\n' "$note"
  if [ "$flag" = "HIGH" ] || [ "$flag" = "REVIEW" ]; then
    printf '\n**Action required:** Review prior session for rework patterns before starting new work.\n'
  fi
}

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print_block 0 0 0 NORMAL "not inside a git repository"
  exit 0
fi

if [ -z "$SINCE" ]; then
  REPO_KEY=$(printf '%s' "$(git rev-parse --show-toplevel 2>/dev/null)" | shasum | awk '{print $1}')
  START_SHA_FILE="${TMPDIR:-/tmp}/claude-session-start-sha-$REPO_KEY"
  [ -f "$START_SHA_FILE" ] || START_SHA_FILE="${TMPDIR:-/tmp}/claude-session-start-sha"
  [ -f "$START_SHA_FILE" ] && SINCE=$(cat "$START_SHA_FILE")
fi

if [ -z "$SINCE" ] || ! git cat-file -e "${SINCE}^{commit}" 2>/dev/null; then
  print_block 0 0 0 NORMAL "no session start SHA recorded for this repository; pass --since <sha>"
  exit 0
fi

CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$CURRENT_SHA" ] || [ "$SINCE" = "$CURRENT_SHA" ]; then
  print_block 0 0 0 NORMAL
  exit 0
fi

COMMIT_COUNT=$(git rev-list --count "$SINCE..HEAD" 2>/dev/null || echo 0)
FILES_CHANGED=$(git diff --name-only "$SINCE..HEAD" 2>/dev/null | sort -u | wc -l | tr -d ' ')
REWORK_COUNT=0
if [ "$COMMIT_COUNT" -gt 1 ]; then
  REWORK_COUNT=$(git log --format="" --name-only "$SINCE..HEAD" 2>/dev/null \
    | grep -v '^$' | sort | uniq -c | awk '$1 > 1 { count++ } END { print count+0 }')
fi
if [ "$COMMIT_COUNT" -gt 80 ]; then FLAG="REVIEW"
elif [ "$COMMIT_COUNT" -gt 40 ]; then FLAG="HIGH"
else FLAG="NORMAL"; fi

print_block "$COMMIT_COUNT" "$FILES_CHANGED" "$REWORK_COUNT" "$FLAG"
exit 0
