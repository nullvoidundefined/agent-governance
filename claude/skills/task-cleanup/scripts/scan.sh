#!/usr/bin/env bash
# scan.sh: task-cleanup Step 1 decided from the diff (2026-09-17 skills audit,
# S-4). The skill asks seven questions about what shipped; six are answerable
# from the change set, so this prints each answer with the files behind it,
# then the Step 4 report skeleton with N/A pre-filled where the answer is no.
# The seventh (is the session ending) is the user's; the ledger summary from
# task-start is printed beside it so the tier that scales cleanup is read
# from disk, not recalled.
#
# Usage: scan.sh [--range <rev>..<rev>] [--base <branch>]
# Range: --range as given; else on a feature branch, merge-base with the
# default branch (origin/HEAD, else main, else master) to HEAD; else on the
# default branch, the session-start SHA stamp when one exists, else the last
# five commits capped at what the repo has. Never writes anything.
set -uo pipefail

RANGE=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) RANGE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    *) printf 'task-cleanup scan: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "task-cleanup scan: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  if [ -z "$BASE" ]; then
    for candidate in main master; do git show-ref --verify --quiet "refs/heads/$candidate" && { BASE="$candidate"; break; }; done
  fi
fi
ON_FEATURE_BRANCH=no
if [ -n "$BRANCH" ] && [ -n "$BASE" ] && [ "$BRANCH" != "$BASE" ]; then ON_FEATURE_BRANCH=yes; fi

if [ -z "$RANGE" ]; then
  if [ "$ON_FEATURE_BRANCH" = yes ]; then
    MB=$(git merge-base "$BASE" HEAD 2>/dev/null || true)
    [ -n "$MB" ] && RANGE="$MB..HEAD"
  fi
  if [ -z "$RANGE" ]; then
    REPO_KEY=$(printf '%s' "$ROOT" | shasum | awk '{print $1}')
    STAMP="${TMPDIR:-/tmp}/claude-session-start-sha-$REPO_KEY"
    if [ -f "$STAMP" ] && git cat-file -e "$(cat "$STAMP")^{commit}" 2>/dev/null; then
      RANGE="$(cat "$STAMP")..HEAD"
    else
      TOTAL=$(git rev-list --count HEAD 2>/dev/null || echo 0)
      N=5; [ "$TOTAL" -lt 6 ] && N=$((TOTAL - 1)); [ "$N" -lt 0 ] && N=0
      RANGE="HEAD~$N..HEAD"
    fi
  fi
fi

CHANGED=$(git diff --name-only "$RANGE" 2>/dev/null | sort -u)
ADDED=$(git diff --name-only --diff-filter=A "$RANGE" 2>/dev/null | sort -u)
ADDED_LINES=$(git diff "$RANGE" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
COMMITS=$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)
FILE_COUNT=$(printf '%s\n' "$CHANGED" | grep -c . || true)

SURFACE_RE='(^|/)(routes|handlers)/|(^|/)page\.tsx$|(^|/)route\.ts$|(^|/)features/|(^|/)\.env\.example$|(^|/)docker-compose[^/]*\.ya?ml$|(^|/)Dockerfile$'
COMPONENT_RE='(^|/)components/([^/]+/)?[^/]+\.(tsx|jsx|vue|svelte)$'
ENDPOINT_RE='(^|/)(routes|handlers|api)/.*\.(ts|js|mjs|py|rb|go)$|(^|/)route\.ts$'
QUERY_RE='searchParams|req\.query|useSearchParams|query param'
SPEC_RE='^docs/superpowers/(specs|plans)/'

surface=$(printf '%s\n' "$ADDED" | grep -E "$SURFACE_RE" || true)
components=$(printf '%s\n' "$ADDED" | grep -E "$COMPONENT_RE" || true)
endpoints=$(printf '%s\n' "$CHANGED" | grep -E "$ENDPOINT_RE" || true)
query=$(printf '%s\n' "$ADDED_LINES" | grep -E "$QUERY_RE" | head -3 || true)
specs=$(printf '%s\n' "$CHANGED" | grep -E "$SPEC_RE" || true)
if [ "$ON_FEATURE_BRANCH" = yes ]; then
  SLUG="${BRANCH#feat/}"; SLUG="${SLUG##*/}"
  slug_specs=$(ls docs/superpowers/specs/*"$SLUG"* docs/superpowers/plans/*"$SLUG"* 2>/dev/null || true)
  specs=$(printf '%s\n%s\n' "$specs" "$slug_specs" | grep . | sort -u || true)
else
  SLUG=""
fi

yn() { [ -n "$1" ] && printf 'yes' || printf 'no'; }
listing() { [ -n "$1" ] && printf ' (%s)' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ $//')"; }

LEDGER_LINE="no ledger (task-start did not record a tier)"
TIER_SCRIPT="$HOME/.claude/skills/task-start/scripts/task-tier.sh"
if [ -f "$ROOT/.claude/task-tier.json" ] && [ -f "$TIER_SCRIPT" ]; then
  LEDGER_LINE=$(bash "$TIER_SCRIPT" summary 2>/dev/null | sed 's/^task-tier: //' || echo "$LEDGER_LINE")
fi

cat <<EOF
task-cleanup scan: range $RANGE ($COMMITS commits, $FILE_COUNT files) on branch ${BRANCH:-detached}, base ${BASE:-unknown}
1. user-facing behavior shipped:  $(yn "$surface")$(listing "$surface")
2. new components created:        $(yn "$components")$(listing "$components")
3. API endpoints created/changed: $(yn "$endpoints")$(listing "$endpoints")
4. query parameters introduced:   $(yn "$query")$(listing "$(printf '%s' "$query" | cut -c1-80)")
5. spec or plan for this work:    $(yn "$specs")$(listing "$specs")
6. on a feature branch:           $ON_FEATURE_BRANCH${SLUG:+ (slug $SLUG)}
7. session ending:                you decide; ledger: $LEDGER_LINE

EOF

row() { printf '| %-19s | %-8s | %s |\n' "$1" "$2" "$3"; }
todo_or_na() { [ -n "$1" ] && printf 'TODO' || printf 'N/A'; }
echo "| Action              | Status   | Notes |"
echo "|---------------------|----------|-------|"
row "Feature list" "$(todo_or_na "$surface")" "$([ -n "$surface" ] && echo 'add or update the row, status Complete with today' || echo 'no user-facing surface added')"
row "User story" "$(todo_or_na "$surface")" "$([ -n "$surface" ] && echo 'docs/user-stories/<slug>.md, criteria match what shipped' || echo '-')"
row "E2E test" "$(todo_or_na "$surface")" "$([ -n "$surface" ] && echo 'RED slice now, or the user story says why it waits' || echo '-')"
row "Storybook stories" "$(todo_or_na "$components")" "$([ -n "$components" ] && echo 'only where the project CLAUDE.md defines the convention' || echo 'no new components')"
row "Query params doc" "$(todo_or_na "$query")" "$([ -n "$query" ] && echo 'docs/query-params.md, same commit as the code' || echo 'no new params')"
row "Spec/plan cleanup" "$(todo_or_na "$specs")" "$([ -n "$specs" ] && echo 'delete if fully shipped, else update checkboxes' || echo 'none for this work')"
row "Tests" "$([ "$ON_FEATURE_BRANCH" = yes ] && echo TODO || echo 'N/A')" "verification gate before any merge decision"
row "Build" "$([ "$ON_FEATURE_BRANCH" = yes ] && echo TODO || echo 'N/A')" "-"
row "Squash merge" "$([ "$ON_FEATURE_BRANCH" = yes ] && echo TODO || echo 'N/A')" "$([ "$ON_FEATURE_BRANCH" = yes ] && echo "confirm with the user, then squash feat/$SLUG onto $BASE" || echo 'not on a feature branch')"
row "Session handoff" "ASK" "if the session ends: session-metrics.sh for the numbers, handoff-check reminds on shape"
