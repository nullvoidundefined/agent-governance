#!/usr/bin/env bash
# Verifies enforcement-guard-check.sh is silent when every manifest-required hook is
# registered, and warns (naming the hook) when one is missing.
set -euo pipefail
HOOK="$HOME/.claude/hooks/enforcement-guard-check.sh"

# Case 1: real settings + manifest -> silent.
OUT=$("$HOOK" < /dev/null)
[ -z "$OUT" ] || { echo "FAIL: expected silent when all registered; got: $OUT"; exit 1; }

# Case 2: a settings file missing push-eslint-gate -> warns and names it.
FIX=$(mktemp)
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("push-eslint-gate") | not))' \
  "$HOME/.claude/settings.json" > "$FIX"
OUT2=$(CLAUDE_SETTINGS_FILE="$FIX" "$HOOK" < /dev/null)
printf '%s' "$OUT2" | grep -q "push-eslint-gate" || { echo "FAIL: expected warning naming push-eslint-gate"; exit 1; }

echo "enforcement-guard-check.test.sh PASS"
