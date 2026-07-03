#!/usr/bin/env bash
# Verifies clean-code-reminder.sh flags a function body over the ~25-line
# ceiling and stays silent for short functions (R-322).
set -euo pipefail
HOOK="$HOME/.claude/hooks/clean-code-reminder.sh"
TMP=$(mktemp -d)

{
  printf 'export function oversizedComputation(): number {\n'
  printf '    let total = 0;\n'
  for i in $(seq 1 30); do printf '    total += %s;\n' "$i"; done
  printf '    return total;\n}\n'
} > "$TMP/long.ts"
OUT=$(jq -n --arg f "$TMP/long.ts" '{tool_input:{file_path:$f}}' | "$HOOK")
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'R-322' || { echo "FAIL: expected R-322 reminder for long function"; exit 1; }

printf 'export function addNumbers(a: number, b: number): number {\n    return a + b;\n}\n' > "$TMP/short.ts"
OUT=$(jq -n --arg f "$TMP/short.ts" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for short function"; exit 1; }

rm -rf "$TMP"
echo "clean-code-reminder.test.sh PASS"
