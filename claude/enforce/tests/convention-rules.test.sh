#!/usr/bin/env bash
# Verifies the two rules moved off the llm-judge tier on 2026-09-04, both of
# which are pure AST questions and were previously decided by nothing.
#
# R-320 file-header-comment:
#   0. R-320 is off without the .enforce.json fileHeaders opt-in.
#   1. With it on, a file with no leading comment reports.
#   2. A leading block comment passes.
#   3. A leading line comment passes (agrees with new-file-header-reminder.sh,
#      which accepts either; two enforcers of one rule must not disagree).
#   4. A pure re-export barrel is exempt.
#   5. A single-constant module is exempt.
#   6. A .d.ts is exempt.
#
# R-325 destructure-object-reads:
#   7. Two property reads off one object in a scope report and name the properties.
#   8. One property read passes.
#   9. Method calls are NOT counted: destructuring a method off its object is the
#      thing R-325 forbids, so the rule must never advise it.
#  10. Reads in separate function scopes do not accumulate.
#  11. Property writes are not reads.
set -euo pipefail
E="$HOME/.claude/enforce"

TMP=$(mktemp -d)
cd "$TMP"
mkdir -p src/services src/types
# R-320 is opt-in per repo (see eslintOptions.mjs); R-325 is default-on.
printf '{"fileHeaders":true}\n' > .enforce.json

run() { node "$E/lint.mjs" "$TMP/$1" >/dev/null 2>&1; }
reports() {
  local report
  report=$(node "$E/lint.mjs" "$TMP/$1" 2>&1 || true)
  printf '%s' "$report" | grep -q "$2"
}

# --- R-320 ---------------------------------------------------------------
# 0. Off without the opt-in.
printf 'export function getNote() { return 1; }\n' > src/services/no-header.ts
printf '{}\n' > .enforce.json
run src/services/no-header.ts || { echo "FAIL: R-320 must be off without the fileHeaders opt-in"; exit 1; }
printf '{"fileHeaders":true}\n' > .enforce.json
run src/services/no-header.ts && { echo "FAIL: expected an R-320 report for a headerless file"; exit 1; } || true
reports src/services/no-header.ts 'R-320' || { echo "FAIL: header report must cite R-320"; exit 1; }

printf '/** What and why. */\nexport function getNote() { return 1; }\n' > src/services/block-header.ts
run src/services/block-header.ts || { echo "FAIL: a block header must pass"; exit 1; }

printf '// What and why.\nexport function getNote() { return 1; }\n' > src/services/line-header.ts
run src/services/line-header.ts || { echo "FAIL: a line header must pass (the reminder hook accepts it)"; exit 1; }

printf 'export * from "./getNote";\nexport { getJob } from "./getJob";\n' > src/services/index.ts
run src/services/index.ts || { echo "FAIL: a pure re-export barrel must be exempt from R-320"; exit 1; }

printf 'export const MAX_RETRY_COUNT = 5;\n' > src/services/single.ts
run src/services/single.ts || { echo "FAIL: a single-constant module must be exempt from R-320"; exit 1; }

printf 'export declare function getNote(): number;\n' > src/types/ambient.d.ts
run src/types/ambient.d.ts || { echo "FAIL: a .d.ts must be exempt from R-320"; exit 1; }

# --- R-325 ---------------------------------------------------------------
HEADER='/** Header. */'

printf '%s\nexport function getNoteText(note: { title: string; body: string }) {\n  return note.title + note.body;\n}\n' "$HEADER" > src/services/two-reads.ts
run src/services/two-reads.ts && { echo "FAIL: expected an R-325 report for two property reads"; exit 1; } || true
reports src/services/two-reads.ts 'R-325' || { echo "FAIL: destructure report must cite R-325"; exit 1; }
reports src/services/two-reads.ts 'body, title' || { echo "FAIL: report must name the properties read"; exit 1; }

printf '%s\nexport function getNoteTitle(note: { title: string }) {\n  return note.title;\n}\n' "$HEADER" > src/services/one-read.ts
run src/services/one-read.ts || { echo "FAIL: a single property read must pass"; exit 1; }

# Method calls must not be counted: `const { start } = server` detaches the
# receiver, which is the half of R-325 that forbids destructuring a method.
printf '%s\nexport function startServer(server: { start(): void; stop(): void }) {\n  server.start();\n  server.stop();\n}\n' "$HEADER" > src/services/methods.ts
run src/services/methods.ts || { echo "FAIL: method calls must not be counted as property reads"; exit 1; }

printf '%s\nexport function getNotePair(note: { title: string; body: string }) {\n  const readTitle = () => note.title;\n  const readBody = () => note.body;\n  return [readTitle, readBody];\n}\n' "$HEADER" > src/services/separate-scopes.ts
run src/services/separate-scopes.ts || { echo "FAIL: reads in separate function scopes must not accumulate"; exit 1; }

printf '%s\nexport function updateNote(note: { title: string; body: string }) {\n  note.title = "a";\n  note.body = "b";\n}\n' "$HEADER" > src/services/writes.ts
run src/services/writes.ts || { echo "FAIL: property writes are not reads"; exit 1; }

echo "convention-rules.test.sh PASS"
