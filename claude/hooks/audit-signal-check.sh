#!/usr/bin/env bash
# audit-signal-check.sh: PreToolUse advisory on `git push` (R-801/R-904). Counts
# commits per surface (first two path segments) since the newest
# docs/audits/YYYY-MM-DD-engineering.md and injects a non-blocking
# additionalContext note when any surface crosses the R-801 signal threshold,
# so the audit trigger no longer depends on recall. With no audit on record it
# falls back to a 30-day window. Commits on the audit's own date count as
# covered; docs/ and root-level files are excluded. Never blocks, never sets a
# permission decision; silent outside git repos.
set -euo pipefail

SIGNAL_THRESHOLD=5
FALLBACK_WINDOW='30 days ago'

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
TOP=$(git rev-parse --show-toplevel)

LAST_AUDIT=$(ls "$TOP/docs/audits" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-engineering\.md$' | sort | tail -1 || true)
if [ -n "$LAST_AUDIT" ]; then
  AUDIT_DATE=${LAST_AUDIT%-engineering.md}
  SINCE="$AUDIT_DATE 23:59:59"
  BASELINE="the $AUDIT_DATE engineering audit"
else
  SINCE=$FALLBACK_WINDOW
  BASELINE="the last 30 days (no engineering audit on record)"
fi

HOT_SURFACES=$(git -C "$TOP" log --no-merges --since="$SINCE" --name-only --pretty=format:'@%H' -- . ':(exclude)docs' 2>/dev/null | awk -v threshold="$SIGNAL_THRESHOLD" '
  /^@/ { for (surface in seen_in_commit) delete seen_in_commit[surface]; next }
  !NF { next }
  {
    segment_count = split($0, segments, "/")
    if (segment_count < 2) next
    surface = segments[1] "/" segments[2]
    if (surface in seen_in_commit) next
    seen_in_commit[surface] = 1
    commit_count[surface]++
  }
  END {
    for (surface in commit_count)
      if (commit_count[surface] >= threshold)
        printf "%s (%d commits), ", surface, commit_count[surface]
  }' || true)
HOT_SURFACES=${HOT_SURFACES%, }

[ -z "$HOT_SURFACES" ] && exit 0

jq -nc --arg surfaces "$HOT_SURFACES" --arg baseline "$BASELINE" --arg threshold "$SIGNAL_THRESHOLD" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("audit-signal-check (R-801/R-904): the engineering-audit signal (" + $threshold + "+ commits on a surface) is met since " + $baseline + ": " + $surfaces + ". Consider dispatching an Engineering audit scoped to those surfaces. Advisory only; the push proceeds.")}}'
exit 0
