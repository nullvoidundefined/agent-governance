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
printf 'const y = a ? 1 : 0;\n' > "$TMP/plain-ternary.ts"
run "$TMP/plain-ternary.ts" || { echo "FAIL: expected plain ternary to pass"; exit 1; }
# R-324 no-magic-numbers: a bare numeric literal in an expression should be flagged;
# named consts, 0/1/-1, array indexes, and test files stay exempt.
printf 'declare function setTimeout(f: () => void, ms: number): void;\nsetTimeout(() => {}, 5000);\n' > "$TMP/magic.ts"
run "$TMP/magic.ts" && { echo "FAIL: expected no-magic-numbers violation"; exit 1; } || true
printf 'const TIMEOUT_MS = 5000;\ndeclare function setTimeout(f: () => void, ms: number): void;\nsetTimeout(() => {}, TIMEOUT_MS);\n' > "$TMP/named.ts"
run "$TMP/named.ts" || { echo "FAIL: expected named-constant file to pass"; exit 1; }
printf 'const LIMIT = 9;\ndeclare const xs: number[];\nconst first = xs[0];\nconst count = xs.length - 1;\n' > "$TMP/small.ts"
run "$TMP/small.ts" || { echo "FAIL: expected 0/1/-1 and const-assigned literals to pass"; exit 1; }
mkdir -p "$TMP/__tests__"
printf 'declare function expectValue(n: number): void;\nexpectValue(4242);\n' > "$TMP/__tests__/magic.test.ts"
run "$TMP/__tests__/magic.test.ts" || { echo "FAIL: expected test file to be exempt from no-magic-numbers (R-324)"; exit 1; }
# Projects overriding R-314 with a top-level tests/ or e2e/ tree get the same exemption.
mkdir -p "$TMP/tests" "$TMP/e2e"
printf 'declare function expectValue(n: number): void;\nexpectValue(4242);\n' > "$TMP/tests/magic.test.ts"
run "$TMP/tests/magic.test.ts" || { echo "FAIL: expected tests/ file to be exempt from no-magic-numbers (R-324)"; exit 1; }
printf 'declare function expectValue(n: number): void;\nexpectValue(4242);\n' > "$TMP/e2e/magic.spec.ts"
run "$TMP/e2e/magic.spec.ts" || { echo "FAIL: expected e2e/ file to be exempt from no-magic-numbers (R-324)"; exit 1; }
# Declarative modules (types/, schemas/) legitimately hold literal-type unions
# and Zod validation literals; they are exempt from no-magic-numbers, while a
# runtime literal in the same file's non-declarative sibling stays flagged.
mkdir -p "$TMP/types" "$TMP/schemas"
printf 'export type PriceLevel = 1 | 2 | 3 | 4;\n' > "$TMP/types/priceLevel.ts"
run "$TMP/types/priceLevel.ts" || { echo "FAIL: expected types/ literal-type union to be exempt from no-magic-numbers (R-324/R-307)"; exit 1; }
printf 'declare const z: { literal: (n: number) => unknown; union: (a: unknown[]) => unknown };\nexport const priceLevelSchema = z.union([z.literal(2), z.literal(3), z.literal(4)]);\n' > "$TMP/schemas/priceLevel.ts"
run "$TMP/schemas/priceLevel.ts" || { echo "FAIL: expected schemas/ validation literals to be exempt from no-magic-numbers (R-324/R-304)"; exit 1; }
# import/order: "@/..." aliases are internal (import/internal-regex), so the
# prettier importOrder sequence external -> @/ alias -> relative must pass and
# the reverse (relative before alias) must fail.
printf 'import { E } from "docx";\n\nimport { A } from "@/data/thing";\n\nimport { S } from "./sibling";\n' > "$TMP/import-order-ok.ts"
run "$TMP/import-order-ok.ts" || { echo "FAIL: expected external -> alias -> relative import order to pass"; exit 1; }
printf 'import { E } from "docx";\n\nimport { S } from "./sibling";\n\nimport { A } from "@/data/thing";\n' > "$TMP/import-order-bad.ts"
run "$TMP/import-order-bad.ts" && { echo "FAIL: expected relative-before-alias import order to be flagged"; exit 1; } || true
# Prettier's @trivago layout keeps a "next" type import adjacent to and before
# its "next/link" subpath with no blank line; the gate must accept that instead
# of demanding "next/link" first (the deadlock the pathGroups reconcile).
printf 'import type { Metadata } from "next";\nimport Link from "next/link";\n\nimport { A } from "@/data/thing";\n\nimport S from "./sibling";\n' > "$TMP/import-order-next-type.ts"
run "$TMP/import-order-next-type.ts" || { echo "FAIL: expected next type import before next/link (Prettier layout) to pass"; exit 1; }
# R-329 no-explicit-any: any annotations and as-any assertions are flagged;
# unknown with narrowing passes.
printf 'export const x: any = JSON.parse("1");\n' > "$TMP/any-annotation.ts"
run "$TMP/any-annotation.ts" && { echo "FAIL: expected no-explicit-any violation for annotation"; exit 1; } || true
printf 'declare const raw: unknown;\nexport const y = raw as any;\n' > "$TMP/any-assertion.ts"
run "$TMP/any-assertion.ts" && { echo "FAIL: expected no-explicit-any violation for as-any"; exit 1; } || true
printf 'declare const raw: unknown;\nexport const z = typeof raw === "string" ? raw : "";\n' > "$TMP/unknown-narrowed.ts"
run "$TMP/unknown-narrowed.ts" || { echo "FAIL: expected unknown-with-narrowing to pass"; exit 1; }
# R-329 ban-ts-comment: @ts-ignore and @ts-nocheck are flagged; @ts-expect-error
# with a description passes.
printf '// @ts-ignore\nexport const a = 1;\n' > "$TMP/ts-ignore.ts"
run "$TMP/ts-ignore.ts" && { echo "FAIL: expected ban-ts-comment violation for @ts-ignore"; exit 1; } || true
printf '// @ts-nocheck\nexport const b = 1;\n' > "$TMP/ts-nocheck.ts"
run "$TMP/ts-nocheck.ts" && { echo "FAIL: expected ban-ts-comment violation for @ts-nocheck"; exit 1; } || true
printf '// @ts-expect-error vendor types lag the runtime shape\nexport const c = 1;\n' > "$TMP/ts-expect-error.ts"
run "$TMP/ts-expect-error.ts" || { echo "FAIL: expected described @ts-expect-error to pass"; exit 1; }
echo "eslint.test.sh PASS"
