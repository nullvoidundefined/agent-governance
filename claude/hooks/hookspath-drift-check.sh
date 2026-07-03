#!/usr/bin/env bash
# hookspath-drift-check.sh
#
# SessionStart hook. Enforces R-107: a git core.hooksPath that points
# outside the repo tree is a supply-chain signal (hooks could be sourced
# from an attacker-controlled location). This hook WARNS via
# additionalContext; it never blocks. The session continues either way,
# but the operator is told to investigate before committing.
#
# Silent when: hooksPath is unset (git default), hooksPath resolves
# inside the repo tree, or the cwd is not a git work tree.
#
# Stdin JSON is the SessionStart payload (unused). Output, on drift, is
# { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext } }.

set -euo pipefail

cat >/dev/null

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

HOOKS_PATH=$(git config --get core.hooksPath 2>/dev/null || true)
[ -n "$HOOKS_PATH" ] || exit 0

ROOT_GIT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
ROOT_REAL=$(cd "$ROOT_GIT" 2>/dev/null && pwd -P) || ROOT_REAL="$ROOT_GIT"

# Make hooksPath absolute relative to the repo root.
case "$HOOKS_PATH" in
  /*) ABS="$HOOKS_PATH" ;;
  *)  ABS="$ROOT_GIT/$HOOKS_PATH" ;;
esac
ABS_REAL=$(cd "$ABS" 2>/dev/null && pwd -P) || ABS_REAL="$ABS"

# Inside if any absolute form of the path sits under any form of the root.
inside="no"
for root in "$ROOT_GIT" "$ROOT_REAL"; do
  for cand in "$ABS" "$ABS_REAL"; do
    case "$cand" in
      "$root"|"$root"/*) inside="yes" ;;
    esac
  done
done

[ "$inside" = "no" ] || exit 0

CTX="## Supply-chain warning (R-107)"$'\n\n'
CTX+="git core.hooksPath in this repo is set to \`$HOOKS_PATH\`, which resolves OUTSIDE the repo tree (\`$ROOT_GIT\`). "
CTX+="Git hooks would run from a location not tracked by this repository. Investigate before any commit: confirm the path is the expected lefthook location and was set intentionally, not injected."

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'

exit 0
