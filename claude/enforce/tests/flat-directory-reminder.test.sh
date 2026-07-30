#!/usr/bin/env bash
# Verifies flat-directory-reminder.sh nudges when a directory exceeds 20 source
# modules and stays silent below the threshold (R-310).
set -euo pipefail
HOOK="$HOME/.claude/hooks/flat-directory-reminder.sh"
TMP=$(mktemp -d)

mkdir -p "$TMP/over"
for i in $(seq 1 21); do printf 'export function f%s() {}\n' "$i" > "$TMP/over/module$i.ts"; done
OUT=$(jq -n --arg f "$TMP/over/module21.ts" '{tool_input:{file_path:$f}}' | "$HOOK")
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'R-310' || { echo "FAIL: expected R-310 reminder over threshold"; exit 1; }

mkdir -p "$TMP/small"
for i in 1 2 3; do printf 'export function f%s() {}\n' "$i" > "$TMP/small/module$i.ts"; done
OUT=$(jq -n --arg f "$TMP/small/module3.ts" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence below threshold"; exit 1; }

# Python: over-threshold package dir nudges; __init__.py/conftest.py do not count.
mkdir -p "$TMP/pyover"
for i in $(seq 1 21); do printf 'def f%s():\n    pass\n' "$i" > "$TMP/pyover/module_$i.py"; done
printf '\n' > "$TMP/pyover/__init__.py"
OUT=$(jq -n --arg f "$TMP/pyover/module_21.py" '{tool_input:{file_path:$f}}' | "$HOOK")
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'R-310' || { echo "FAIL: expected R-310 reminder for python over threshold"; exit 1; }

mkdir -p "$TMP/pysmall"
for i in 1 2 3; do printf 'def f%s():\n    pass\n' "$i" > "$TMP/pysmall/module_$i.py"; done
OUT=$(jq -n --arg f "$TMP/pysmall/module_3.py" '{tool_input:{file_path:$f}}' | "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence for small python dir"; exit 1; }

rm -rf "$TMP"
echo "flat-directory-reminder.test.sh PASS"
