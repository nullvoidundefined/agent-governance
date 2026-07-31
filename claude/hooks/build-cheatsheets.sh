#!/usr/bin/env bash
# build-cheatsheets.sh: on `git push` in a TRUSTED repo, regenerate the
# cheatsheet docs if the repo ships a builder script. Replaces the former
# inline settings.json hook, which executed docs/features/build-all-cheatsheets.sh
# from whatever repo the cwd happened to be in (2026-07-31 engineering audit
# P1: auto-exec decided by working-directory contents). The script now runs
# only when the repo's origin URL is listed in enforce/gate-trusted-repos.txt.
# Advisory: never blocks, output discarded.
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

TRUSTED_FILE="$HOME/.claude/enforce/gate-trusted-repos.txt"
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
[ -n "$ORIGIN_URL" ] || exit 0
[ -f "$TRUSTED_FILE" ] || exit 0
grep -qxF "$ORIGIN_URL" "$TRUSTED_FILE" || exit 0

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
BUILDER="$TOP/docs/features/build-all-cheatsheets.sh"
[ -x "$BUILDER" ] || exit 0
(cd "$TOP" && "$BUILDER" >/dev/null 2>&1) || true
exit 0
