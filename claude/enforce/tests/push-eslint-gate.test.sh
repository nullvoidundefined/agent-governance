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

# Changed-line scoping (2026-07-10): pre-existing violation on an UNTOUCHED line
# plus a clean added line -> allow; the same file gaining a violating added
# line -> deny.
printf 'const legacy = { b: 2, a: 1 };\nexport { legacy };\n' > debt.ts; git add debt.ts; git commit -q -m debt
printf 'const legacy = { b: 2, a: 1 };\nconst fresh = { a: 1, b: 2 };\nexport { legacy };\n' > debt.ts
git add debt.ts; git commit -q -m clean-addition
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT3" ]

printf 'const legacy = { b: 2, a: 1 };\nconst fresh = { a: 1, b: 2 };\nconst worse = { d: 4, c: 3 };\nexport { legacy };\n' > debt.ts
git add debt.ts; git commit -q -m violating-addition
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT4" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

echo "push-eslint-gate.test.sh PASS"
