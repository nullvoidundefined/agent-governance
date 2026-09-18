#!/usr/bin/env bash
# audit-signal-check.sh: PreToolUse advisory on `git push` (R-801/R-904). Counts
# commits per surface (first two path segments) since the newest
# docs/audits/YYYY-MM-DD-engineering.md and injects a non-blocking
# additionalContext note when any surface crosses the R-801 signal threshold,
# so the audit trigger no longer depends on recall. With no audit on record it
# falls back to a 30-day window. Commits on the audit's own date count as
# covered; docs/ trees at any depth and root-level files are excluded. Never
# blocks, never sets a permission decision; silent outside git repos.
set -euo pipefail

SIGNAL_THRESHOLD=5
FALLBACK_WINDOW='30 days ago'

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`
# (2026-09-16 audit P2-1; the normalizer lives once in git-invocation.sh),
# then recover which repository the push names so that every query below
# runs against THAT repository (2026-09-18 audit, defect 4).
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), which is a silent
# fail-open for a guard.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  # The target is read from the UNSTRIPPED command, because stripping is
  # exactly what throws it away (2026-09-18 audit, defect 4).
  parse_git_target_options "$RAW_CMD" push
fi
# Fallback for an unreachable helper: every query runs against the ambient
# repository, which is exactly the behaviour this hook had before targeting
# existed. Declared here rather than inside the branch above so that the
# function is defined on both paths.
declare -f run_git_on_target >/dev/null 2>&1 || run_git_on_target() { git "$@"; }
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

run_git_on_target rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
TOP=$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOP" ] || exit 0

# Repo exemption (2026-07-27, Ian-approved): repos listed by origin URL in
# enforce/exempt-repos.txt skip this advisory entirely. Repo-wide audit signals
# are noise in a team codebase, where surface commit counts reflect the whole
# team's work rather than one operator's. Matching by remote URL covers all
# worktrees.
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

# Suffixed reports count too (e.g. -engineering-harness.md, 2026-07-31).
LAST_AUDIT=$(ls "$TOP/docs/audits" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-engineering(-[a-z-]+)?\.md$' | sort | tail -1 || true)
if [ -n "$LAST_AUDIT" ]; then
  AUDIT_DATE=${LAST_AUDIT:0:10}
  SINCE="$AUDIT_DATE 23:59:59"
  BASELINE="the $AUDIT_DATE engineering audit"
else
  SINCE=$FALLBACK_WINDOW
  BASELINE="the last 30 days (no engineering audit on record)"
fi

# The glob-magic exclude covers a docs/ tree at any depth, e.g. claude/docs
# post-migration (2026-09-16 audit P1-3; plain `*/docs` does not cross the
# slash and excluded nothing).
HOT_SURFACES=$(git -C "$TOP" log --no-merges --since="$SINCE" --name-only --pretty=format:'@%H' -- . ':(exclude)docs' ':(glob,exclude)**/docs/**' 2>/dev/null | awk -v threshold="$SIGNAL_THRESHOLD" '
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
