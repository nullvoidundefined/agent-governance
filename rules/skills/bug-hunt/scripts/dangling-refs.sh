#!/usr/bin/env bash
# dangling-refs.sh: bug-hunt's range resolution and its step 4 cross-reference,
# decided (2026-09-17 skills audit, S-6). Resolves the range the skill
# describes (merge base with the default branch on a feature branch; the last
# five commits, capped at what the repo has, on the default branch), then
# lists every file the range deleted or renamed and greps the tree for import
# specifiers that still name it: `from "…/<name>"`, `require("…/<name>")`,
# `import("…/<name>")`, and Python `from <module> import` / `import <module>`.
# A grep decides this more reliably than a reading pass does.
#
# Usage: dangling-refs.sh [<range>] [--base <branch>]
# Output: the range, then one DANGLING line per remaining reference
# (`<old path> <- <file>:<line>: <text>`); exits 0 either way, the hunt
# decides what matters. Never writes anything.
set -uo pipefail

RANGE=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    *) RANGE="$1"; shift ;;
  esac
done
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "dangling-refs: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2

if [ -z "$RANGE" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ -z "$BASE" ]; then
    BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    if [ -z "$BASE" ]; then
      for candidate in main master; do git show-ref --verify --quiet "refs/heads/$candidate" && { BASE="$candidate"; break; }; done
    fi
  fi
  if [ -n "$BRANCH" ] && [ -n "$BASE" ] && [ "$BRANCH" != "$BASE" ]; then
    MB=$(git merge-base "$BASE" HEAD 2>/dev/null || true)
    [ -n "$MB" ] && RANGE="$MB..HEAD"
  fi
  if [ -z "$RANGE" ]; then
    TOTAL=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    N=5; [ "$TOTAL" -le 5 ] && N=$((TOTAL - 1)); [ "$N" -lt 0 ] && N=0
    RANGE="HEAD~$N..HEAD"
  fi
fi
echo "dangling-refs: range $RANGE"

# Old paths of deleted (D) and renamed (R) files in the range.
OLD_PATHS=$(git diff --name-status -M "$RANGE" 2>/dev/null | awk '$1 ~ /^(D|R[0-9]*)$/ {print $2}' | sort -u)
[ -n "$OLD_PATHS" ] || { echo "dangling-refs: no files deleted or renamed in $RANGE"; exit 0; }

found=0
while IFS= read -r old; do
  [ -n "$old" ] || continue
  stem=$(basename "$old"); stem="${stem%.*}"
  noext="${old%.*}"
  # JS/TS-style specifiers ending in the stem (with or without extension),
  # and Python module paths built from the path without extension.
  pymod=$(printf '%s' "$noext" | tr '/' '.')
  pattern="(from|require\\(|import\\()[[:space:]]*['\"][^'\"]*/${stem}(\\.[a-z]+)?['\"]|(^|[[:space:]])(from|import)[[:space:]]+([a-z_.]+\\.)?${stem}([[:space:]]|$)|${pymod//./\\.}"
  hits=$(git grep -n -E "$pattern" -- . ":(exclude)$old" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | while IFS= read -r hit; do
      printf 'DANGLING: %s <- %s\n' "$old" "$(printf '%s' "$hit" | cut -c1-160)"
    done
    found=1
  fi
done <<< "$OLD_PATHS"

# The while loop above runs in a subshell; count from the output instead.
count=$(git diff --name-status -M "$RANGE" 2>/dev/null | awk '$1 ~ /^(D|R[0-9]*)$/ {print $2}' | sort -u | wc -l | tr -d ' ')
echo "dangling-refs: checked $count deleted or renamed path(s); DANGLING lines above are references the range left behind"
exit 0
