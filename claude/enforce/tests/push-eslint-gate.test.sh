#!/usr/bin/env bash
# Verifies push-eslint-gate.sh denies a git push whose outgoing diff has an ESLint
# violation, and allows one whose diff is clean.
set -euo pipefail
HOOK="$HOME/.claude/hooks/push-eslint-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init

# Violating change in the outgoing diff -> deny.
printf 'export const a = { b: 2, a: 1 };\n' > bad.ts; git add bad.ts; git commit -q -m bad
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Clean change in the outgoing diff -> allow (no output).
printf 'export const a = { a: 1, b: 2 };\n' > bad.ts; git add bad.ts; git commit -q -m fix
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT2" ]

echo "push-eslint-gate.test.sh PASS"
