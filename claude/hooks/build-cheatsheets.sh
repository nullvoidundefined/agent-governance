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
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

TRUSTED_FILE="$HOME/.claude/enforce/gate-trusted-repos.txt"
ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
[ -n "$ORIGIN_URL" ] || exit 0
[ -f "$TRUSTED_FILE" ] || exit 0
grep -qxF "$ORIGIN_URL" "$TRUSTED_FILE" || exit 0

TOP=$(run_git_on_target rev-parse --show-toplevel 2>/dev/null) || exit 0
BUILDER="$TOP/docs/features/build-all-cheatsheets.sh"
[ -x "$BUILDER" ] || exit 0
(cd "$TOP" && "$BUILDER" >/dev/null 2>&1) || true
exit 0
