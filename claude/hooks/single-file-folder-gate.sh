#!/usr/bin/env bash
# single-file-folder-gate.sh: on git push, warn (advisory, never blocks) when a changed
# source folder holds exactly one source module (R-223 prefers a flat file over a
# single-file folder). Respects per-repo exemptions in .enforce.json
# (singleFileFolderExemptions). Tests, index, constants, and types modules do not count
# as the folder's source module.
set -euo pipefail
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

TOP="$(git rev-parse --show-toplevel)"
FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.tsx?$' || true)
[ -z "$FILES" ] && exit 0

EXEMPT=""
[ -f "$TOP/.enforce.json" ] && EXEMPT=$(jq -r '.singleFileFolderExemptions[]? // empty' "$TOP/.enforce.json" 2>/dev/null || true)

is_source() {
  case "$1" in
    *.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx) return 1 ;;
    index.ts|index.tsx|constants.ts|types.ts) return 1 ;;
    *.ts|*.tsx) return 0 ;;
    *) return 1 ;;
  esac
}

DIRS=$(printf '%s\n' "$FILES" | xargs -n1 dirname | sort -u)
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  printf '%s\n' "$EXEMPT" | grep -qx "$dir" && continue
  count=0
  for path in "$TOP/$dir"/*; do
    [ -f "$path" ] || continue
    is_source "$(basename "$path")" && count=$((count + 1))
  done
  if [ "$count" -eq 1 ]; then
    echo "single-file-folder-gate: '$dir' holds one source module; R-223 prefers a flat file. Add a second module or exempt the folder in .enforce.json." >&2
  fi
done <<< "$DIRS"
exit 0
