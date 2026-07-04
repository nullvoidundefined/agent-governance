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

# Case 3 (reverse direction, P2-1): a manifest missing an enforcer the rule
# files cite in an Enforcement line -> warns naming the enforcer.
FIX2=$(mktemp)
jq '.rules |= map(select(.enforcer != "hook:no-em-dash"))' "$HOME/.claude/enforce/manifest.json" > "$FIX2"
OUT3=$(CLAUDE_MANIFEST_FILE="$FIX2" "$HOOK" < /dev/null)
printf '%s' "$OUT3" | grep -q "hook:no-em-dash" || { echo "FAIL: expected warning naming hook:no-em-dash as cited-but-unmapped"; exit 1; }

echo "enforcement-guard-check.test.sh PASS"
