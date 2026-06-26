#!/usr/bin/env bash
# Verifies the bundled ESLint config flags R-231 (sort-keys) and R-235 (one export per file)
# and passes clean code.
set -euo pipefail
E="$HOME/.claude/enforce"
run() { node "$E/lint.mjs" "$1" >/dev/null 2>&1; }
TMP=$(mktemp -d)
printf 'export const a = { b: 2, a: 1 };\n' > "$TMP/keys.ts"
printf 'export const a = 1;\nexport const b = 2;\n' > "$TMP/two.ts"
printf 'export const a = 1, b = 2;\n' > "$TMP/multi.ts"
printf 'export const a = { a: 1, b: 2 };\n' > "$TMP/ok.ts"
run "$TMP/keys.ts"  && { echo "FAIL: expected sort-keys violation"; exit 1; } || true
run "$TMP/two.ts"   && { echo "FAIL: expected one-export violation (two declarations)"; exit 1; } || true
run "$TMP/multi.ts" && { echo "FAIL: expected one-export violation (multi-declarator)"; exit 1; } || true
run "$TMP/ok.ts"    || { echo "FAIL: expected clean file to pass"; exit 1; }
# R-218 member-ordering: a method before a property should be flagged in a class.
printf 'interface Foo { greet(): void; name: string; }\n' > "$TMP/ordering.ts"
run "$TMP/ordering.ts" && { echo "FAIL: expected member-ordering violation"; exit 1; } || true
echo "eslint.test.sh PASS"
