#!/usr/bin/env bash
# single-file-folder-reminder.sh: on git push, warn (advisory, never blocks) when a changed
# source folder holds exactly one source module (R-309 prefers a flat file over a
# single-file folder). Respects per-repo exemptions in .enforce.json
# (singleFileFolderExemptions). Tests, index, constants, and types modules do not count
# as the folder's source module.
set -euo pipefail
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"

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
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0
# Go is deliberately absent: single-file packages are idiomatic Go, so the
# R-309 advisory does not apply to .go trees.
FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.(tsx?|py|rb)$' || true)
[ -z "$FILES" ] && exit 0

EXEMPT=""
[ -f "$TOP/.enforce.json" ] && EXEMPT=$(jq -r '.singleFileFolderExemptions[]? // empty' "$TOP/.enforce.json" 2>/dev/null || true)

is_source() {
  case "$1" in
    *.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx) return 1 ;;
    index.ts|index.tsx|constants.ts|types.ts) return 1 ;;
    __init__.py|constants.py|types.py|conftest.py|test_*.py|*_test.py) return 1 ;;
    *_spec.rb|constants.rb) return 1 ;;
    *.ts|*.tsx|*.py|*.rb) return 0 ;;
    *) return 1 ;;
  esac
}

DIRS=$(printf '%s\n' "$FILES" | xargs -n1 dirname | sort -u)
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  # Migration trees (Alembic versions/, node-pg-migrate) legitimately start at one file.
  case "$dir" in migrations|migrations/*|*/migrations|*/migrations/*) continue ;; esac
  printf '%s\n' "$EXEMPT" | grep -qx "$dir" && continue
  count=0
  lone_module=""
  for path in "$TOP/$dir"/*; do
    [ -f "$path" ] || continue
    if is_source "$(basename "$path")"; then
      count=$((count + 1))
      lone_module=$(basename "$path")
    fi
  done
  # R-305 orders exactly this shape: components/Header/Header.tsx paired with
  # Header.module.scss. Warning that the ordered layout breaks R-309 would point
  # two hooks in opposite directions on the same folder.
  case "$dir" in
    */components/*) [ "$lone_module" = "$(basename "$dir").tsx" ] && continue ;;
  esac
  if [ "$count" -eq 1 ]; then
    echo "single-file-folder-reminder: '$dir' holds one source module; R-309 prefers a flat file. Add a second module or exempt the folder in .enforce.json." >&2
  fi
done <<< "$DIRS"
exit 0
