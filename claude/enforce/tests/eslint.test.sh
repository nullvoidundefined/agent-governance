#!/usr/bin/env bash
# Verifies the bundled ESLint config flags R-323 (sort-keys) and R-319 (one export per file)
# and passes clean code. R-319 is scoped to the function-module trees (services/api/clients);
# constants and types modules group multiple exports per R-307 and are exempt.
set -euo pipefail
E="$HOME/.claude/enforce"
run() { node "$E/lint.mjs" "$1" >/dev/null 2>&1; }
TMP=$(mktemp -d)
mkdir -p "$TMP/services" "$TMP/constants"
printf 'export const a = { b: 2, a: 1 };\n' > "$TMP/keys.ts"
printf 'export const a = 1;\nexport const b = 2;\n' > "$TMP/services/two.ts"
printf 'export const a = 1, b = 2;\n' > "$TMP/services/multi.ts"
printf 'export const a = { a: 1, b: 2 };\n' > "$TMP/services/ok.ts"
printf 'export const a = 1;\nexport const b = 2;\n' > "$TMP/constants/many.ts"
printf 'export interface A { a: number }\nexport interface B { b: number }\n' > "$TMP/services/types.ts"
printf 'export const a = 1;\nexport const b = 2;\n' > "$TMP/services/constants.ts"
run "$TMP/keys.ts"          && { echo "FAIL: expected sort-keys violation"; exit 1; } || true
run "$TMP/services/two.ts"  && { echo "FAIL: expected one-export violation (two declarations) in services"; exit 1; } || true
run "$TMP/services/multi.ts" && { echo "FAIL: expected one-export violation (multi-declarator) in services"; exit 1; } || true
run "$TMP/services/ok.ts"   || { echo "FAIL: expected clean services file to pass"; exit 1; }
run "$TMP/constants/many.ts" || { echo "FAIL: expected multi-export constants file to pass (R-319 scoped to function trees)"; exit 1; }
run "$TMP/services/types.ts" || { echo "FAIL: expected services/types.ts to be exempt from one-export (R-307)"; exit 1; }
run "$TMP/services/constants.ts" || { echo "FAIL: expected services/constants.ts to be exempt from one-export (R-307)"; exit 1; }
# R-321 member-ordering: a method before a property should be flagged in a class.
printf 'interface Foo { greet(): void; name: string; }\n' > "$TMP/ordering.ts"
run "$TMP/ordering.ts" && { echo "FAIL: expected member-ordering violation"; exit 1; } || true
# R-326 no-IIFE: an immediately-invoked arrow function should be flagged.
printf 'const x = (() => "y")();\n' > "$TMP/iife.ts"
run "$TMP/iife.ts" && { echo "FAIL: expected no-IIFE violation"; exit 1; } || true
# R-327 no-nested-ternary: a chained ternary should be flagged; a plain ternary should pass.
printf 'const x = a ? 1 : b ? 2 : 3;\n' > "$TMP/nested-ternary.ts"
run "$TMP/nested-ternary.ts" && { echo "FAIL: expected no-nested-ternary violation"; exit 1; } || true
printf 'const y = a ? 1 : 2;\n' > "$TMP/plain-ternary.ts"
run "$TMP/plain-ternary.ts" || { echo "FAIL: expected plain ternary to pass"; exit 1; }
echo "eslint.test.sh PASS"
