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

# Go: an oversized func flags; a short one stays silent.
mkdir -p "$TMP/internal/services"
{
  printf 'package services\n\nfunc ScoreMatch(total int) int {\n'
  for i in $(seq 1 30); do printf '\ttotal += %s\n' "$i"; done
  printf '\treturn total\n}\n'
} > "$TMP/internal/services/score_match.go"
OUT=$(jq -n --arg f "$TMP/internal/services/score_match.go" '{tool_input:{file_path:$f}}' | "$HOOK")
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'ScoreMatch' || { echo "FAIL: expected R-322 reminder for long Go func"; exit 1; }

printf 'package services\n\nfunc AddNumbers(a, b int) int {\n\treturn a + b\n}\n' > "$TMP/internal/services/add.go"
OUT=$(jq -n --arg f "$TMP/internal/services/add.go" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for short Go func"; exit 1; }

# Ruby: an oversized def flags; a short one stays silent.
mkdir -p "$TMP/app/services/jobs"
{
  printf 'class ScoreMatch\n  def call\n    total = 0\n'
  for i in $(seq 1 30); do printf '    total += %s\n' "$i"; done
  printf '    total\n  end\nend\n'
} > "$TMP/app/services/jobs/score_match.rb"
OUT=$(jq -n --arg f "$TMP/app/services/jobs/score_match.rb" '{tool_input:{file_path:$f}}' | "$HOOK")
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'call' || { echo "FAIL: expected R-322 reminder for long Ruby method"; exit 1; }

printf 'class AddNumbers\n  def call(a, b)\n    a + b\n  end\nend\n' > "$TMP/app/services/jobs/add_numbers.rb"
OUT=$(jq -n --arg f "$TMP/app/services/jobs/add_numbers.rb" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for short Ruby method"; exit 1; }

# Exclusions: Go test files and Rails migrations never nag.
printf 'package services\n\nfunc TestScoreMatch(t *testing.T) {\n}\n' > "$TMP/internal/services/score_match_test.go"
OUT=$(jq -n --arg f "$TMP/internal/services/score_match_test.go" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for _test.go"; exit 1; }

rm -rf "$TMP"
echo "clean-code-reminder.test.sh PASS"
