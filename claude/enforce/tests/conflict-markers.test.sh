#!/usr/bin/env bash
# Verifies conflict-markers.sh blocks `git commit` when staged content carries
# conflict markers and passes clean stages (R-507). Markers are constructed at
# runtime so this test file never contains one.
set -euo pipefail
HOOK="$HOME/.claude/hooks/conflict-markers.sh"
LEFT=$(printf '<%.0s' 1 2 3 4 5 6 7)
RIGHT=$(printf '>%.0s' 1 2 3 4 5 6 7)

TMP=$(mktemp -d)
cd "$TMP"
git init -q
git config user.email t@t && git config user.name t

printf 'clean line\n%s ours\ntheirs\n%s branch\n' "$LEFT" "$RIGHT" > conflicted.txt
git add conflicted.txt
OUT=$(printf '{"tool_input":{"command":"git commit -m \\"chore: x\\""}}' | "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null || { echo "FAIL: expected deny on staged markers"; exit 1; }

printf 'clean line only\n' > conflicted.txt
git add conflicted.txt
OUT=$(printf '{"tool_input":{"command":"git commit -m \\"chore: x\\""}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected allow on clean stage"; exit 1; }

OUT=$(printf '{"tool_input":{"command":"git status"}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected allow on non-commit"; exit 1; }

cd / && rm -rf "$TMP"
echo "conflict-markers.test.sh PASS"
