#!/usr/bin/env bash
# Verifies the one-export-per-file rule's pure-barrel exemption (2026-07-10):
# a re-export-only index.ts passes, a mixed index.ts still fails, and a
# multi-re-export file NOT named index still fails. Fixtures live under a
# services/ tree because the rule is path-scoped to services|api|clients.
set -euo pipefail
LINT="$HOME/.claude/enforce/lint.mjs"

DIR=$(mktemp -d); cd "$DIR"; git init -q
mkdir -p services/voiceContext services/mixed

# Pure re-export barrel named index.ts -> allowed.
printf "export { a } from './a.js';\nexport { b } from './b.js';\nexport type { C } from './c.js';\n" > services/voiceContext/index.ts
node "$LINT" services/voiceContext/index.ts

# index.ts with a local declaration alongside re-exports -> still flagged.
printf "export const local = 1;\nexport { a } from './a.js';\n" > services/mixed/index.ts
if node "$LINT" services/mixed/index.ts; then
  echo "FAIL: mixed barrel index.ts was not flagged" >&2; exit 1
fi

# Multi-re-export module not named index -> still flagged.
printf "export { a } from './a.js';\nexport { b } from './b.js';\n" > services/notBarrel.ts
if node "$LINT" services/notBarrel.ts; then
  echo "FAIL: non-index multi-re-export was not flagged" >&2; exit 1
fi

echo "one-export-barrel.test.sh PASS"
