#!/usr/bin/env bash
# Verifies the lexicon/naming rule (R-316 plus the decidable half of R-317).
# The point of the rule is determinism, so every case here asserts a fixed
# verdict rather than a judgment: membership in a checked-in list.
#   1. No .enforce.json means the rule is off (no retroactive break).
#   2. A banned verb reports its canonical replacement.
#   3. A verb outside the lexicon reports.
#   4. A bare verb with no noun reports.
#   5. A compliant verb+noun passes.
#   6. A `: boolean` function not led by is/has/can/should reports.
#   7. A boolean-prefixed name passes.
#   8. With a glossary, an undeclared head noun reports; a declared one passes.
#   9. A bare adjective variable reports.
#  10. A collection bound to a singular name reports; the plural passes.
#  11. PascalCase (components, classes) is skipped.
#  12. Test trees are exempt.
#  13. extend.verbs adds to the shipped lexicon.
#  14. The read verb is the one its layer fixes: get by default, fetch under
#      clients/ and api/, load under repositories/ and database/. Using another
#      layer's read verb reports; list stays unrestricted.
#  15. A layer-bound verb (insert, drop) outside its tree reports its fallback.
set -euo pipefail
E="$HOME/.claude/enforce"

TMP=$(mktemp -d)
cd "$TMP"
mkdir -p src/services src/__tests__ src/clients src/repositories

# run <file> -> exits 0 when clean, 1 when the rule reports.
run() { node "$E/lint.mjs" "$TMP/$1" >/dev/null 2>&1; }
# reports <file> <substring> -> the report mentions the substring. The output is
# captured before grepping: under pipefail a pipeline inherits lint's exit 1 and
# would look like a miss even when grep matched.
reports() {
  local report
  report=$(node "$E/lint.mjs" "$TMP/$1" 2>&1 || true)
  printf '%s' "$report" | grep -q "$2"
}

# 1. Rule off without opt-in.
printf 'export function retrieveNote() { return 1; }\n' > src/services/optout.ts
run src/services/optout.ts || { echo "FAIL: the rule must be off with no .enforce.json"; exit 1; }

printf '{"naming":{"enabled":true}}\n' > .enforce.json

# 2. Banned verb names its replacement.
printf 'export function retrieveNote() { return 1; }\n' > src/services/banned.ts
run src/services/banned.ts && { echo "FAIL: expected a banned-verb report for retrieveNote"; exit 1; } || true
reports src/services/banned.ts 'use "get"' || { echo "FAIL: banned verb must name its canonical replacement"; exit 1; }

# 3. Verb outside the lexicon.
printf 'export function frobnicateNote() { return 1; }\n' > src/services/unknown.ts
run src/services/unknown.ts && { echo "FAIL: expected an out-of-lexicon report for frobnicateNote"; exit 1; } || true

# 4. Bare verb, no noun.
printf 'export function generate() { return 1; }\n' > src/services/bare.ts
run src/services/bare.ts && { echo "FAIL: expected a bare-verb report for generate"; exit 1; } || true
reports src/services/bare.ts 'noun is mandatory' || { echo "FAIL: bare verb must cite the mandatory noun"; exit 1; }

# 5. Compliant verb+noun passes.
printf 'export function generatePublicNote() { return 1; }\n' > src/services/ok.ts
run src/services/ok.ts || { echo "FAIL: expected generatePublicNote to pass"; exit 1; }

# 6/7. Boolean return annotation drives the prefix requirement.
printf 'export function validateNote(): boolean { return true; }\n' > src/services/bool-bad.ts
run src/services/bool-bad.ts && { echo "FAIL: expected a boolean-prefix report for validateNote"; exit 1; } || true
printf 'export function isValidNote(): boolean { return true; }\n' > src/services/bool-ok.ts
run src/services/bool-ok.ts || { echo "FAIL: expected isValidNote to pass"; exit 1; }

# 8. Glossary constrains the head noun.
printf '{"naming":{"enabled":true,"glossary":["note","job"]}}\n' > .enforce.json
printf 'export function generatePublicMemo() { return 1; }\n' > src/services/glossary-bad.ts
run src/services/glossary-bad.ts && { echo "FAIL: expected an undeclared head noun to report"; exit 1; } || true
reports src/services/glossary-bad.ts 'glossary' || { echo "FAIL: head-noun report must cite the glossary"; exit 1; }
printf 'export function generatePublicNote() { return 1; }\n' > src/services/glossary-ok.ts
run src/services/glossary-ok.ts || { echo "FAIL: expected a declared head noun to pass"; exit 1; }
printf '{"naming":{"enabled":true}}\n' > .enforce.json

# 9. Bare adjective.
printf 'export const scored = 5;\n' > src/services/adjective.ts
run src/services/adjective.ts && { echo "FAIL: expected a bare-adjective report for scored"; exit 1; } || true

# 10. Collections are plural. String elements, not numbers: a numeric array
# literal also trips R-324 no-magic-numbers and would mask the plural verdict.
printf 'export const scoredJob = ["a", "b"];\n' > src/services/singular.ts
run src/services/singular.ts && { echo "FAIL: expected a plural report for a singular collection"; exit 1; } || true
reports src/services/singular.ts 'plural noun' || { echo "FAIL: singular collection must cite the plural requirement"; exit 1; }
printf 'export const scoredJobs = ["a", "b"];\n' > src/services/plural.ts
run src/services/plural.ts || { echo "FAIL: expected a plural collection name to pass"; exit 1; }

# 11. PascalCase is skipped (React components, classes).
printf 'export function Header() { return null; }\n' > src/services/Header.ts
run src/services/Header.ts || { echo "FAIL: PascalCase must be skipped"; exit 1; }

# 12. Test trees exempt.
printf 'export function retrieveNote() { return 1; }\n' > src/__tests__/exempt.ts
run src/__tests__/exempt.ts || { echo "FAIL: test trees must be exempt from naming enforcement"; exit 1; }

# 13. A repo-declared verb extends the shipped lexicon.
printf '{"naming":{"enabled":true,"extend":{"verbs":["frobnicate"]}}}\n' > .enforce.json
run src/services/unknown.ts || { echo "FAIL: extend.verbs must add to the shipped lexicon"; exit 1; }
printf '{"naming":{"enabled":true}}\n' > .enforce.json

# 14. Read verbs are bound to the layer that gives them meaning. Each case is a
# path predicate, so "remote" vs "in memory" is decided from the tree, not intent.
read_case() {
  local path="$1" expectation="$2"
  printf 'export function %sNote() { return 1; }\n' "$3" > "$path"
  if [ "$expectation" = "pass" ]; then
    run "$path" || { echo "FAIL: expected $3 to pass in $path"; exit 1; }
  else
    run "$path" && { echo "FAIL: expected $3 to report in $path"; exit 1; } || true
    reports "$path" 'bound to the layer' || { echo "FAIL: $3 in $path must cite the layer binding"; exit 1; }
  fi
}
read_case src/services/read-get.ts       pass   get
read_case src/services/read-fetch.ts     report fetch
read_case src/services/read-load.ts      report load
read_case src/clients/read-fetch.ts      pass   fetch
read_case src/clients/read-get.ts        report get
read_case src/repositories/read-load.ts  pass   load
read_case src/repositories/read-get.ts   report get

# list encodes cardinality, not transport, so it is free in every layer.
printf 'export function listNotes() { return 1; }\n' > src/clients/list.ts
run src/clients/list.ts || { echo "FAIL: list must stay unrestricted by layer"; exit 1; }

# 15. A layer-bound verb outside its tree names its fallback.
printf 'export function insertNote() { return 1; }\n' > src/repositories/insert.ts
run src/repositories/insert.ts || { echo "FAIL: expected insert to pass in repositories/"; exit 1; }
printf 'export function insertNote() { return 1; }\n' > src/services/insert.ts
run src/services/insert.ts && { echo "FAIL: expected insert to report outside repositories/"; exit 1; } || true
reports src/services/insert.ts 'use "create" here' || { echo "FAIL: scoped verb must name its fallback"; exit 1; }
printf 'export function dropNote() { return 1; }\n' > src/services/drop.ts
reports src/services/drop.ts 'use "delete" here' || { echo "FAIL: drop outside the persistence trees must suggest delete"; exit 1; }

# Bare synonyms banned in the 2026-09-04 tightening.
for pair in "removeNote:delete" "recordNote:save" "persistNote:save"; do
  fn=${pair%%:*}; canonical=${pair##*:}
  printf 'export function %s() { return 1; }\n' "$fn" > src/services/synonym.ts
  reports src/services/synonym.ts "use \"$canonical\"" || { echo "FAIL: $fn must resolve to $canonical"; exit 1; }
done

echo "naming-lexicon.test.sh PASS"
