#!/usr/bin/env bash
# Covers: hook:verification-gate
# Verifies the R-509 related-test mapping (enforce/related-tests.sh) for the
# application stacks: vitest, jest, pytest, and Go. The governance repo's own
# fixtures are selected by run-tests.sh --affected instead (IAN-94).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
MAPPING="$CLAUDE_HARNESS_ROOT/enforce/related-tests.sh"

# Creates an empty sandbox repository and prints its path.
new_sandbox() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo "$dir"
}

# Commits everything in the sandbox.
commit_sandbox() { git -C "$1" add -A && git -C "$1" commit -qm "chore: base"; }

# Runs the mapping for a stack inside a sandbox; prints output, then "exit=<n>".
map_in() {
  local dir="$1" stack="$2" status=0 out
  out=$(cd "$dir" && . "$MAPPING" && buildRelatedTestCommands "$stack") || status=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  echo "exit=$status"
}

# M1. vitest: changed sources go to vitest related.
V=$(new_sandbox); mkdir -p "$V/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$V/package.json"
echo 'export const a = 1;' > "$V/src/a.ts"; commit_sandbox "$V"
echo 'export const b = 2;' >> "$V/src/a.ts"
OUT=$(map_in "$V" vitest)
[ "$OUT" = "npx --no-install vitest related --run --passWithNoTests src/a.ts
exit=0" ] || { echo "FAIL M1: $OUT"; exit 1; }

# M2. jest: changed sources go to --findRelatedTests, with pnpm's exec prefix.
J=$(new_sandbox); mkdir -p "$J/src"; touch "$J/pnpm-lock.yaml"
echo '{"devDependencies":{"jest":"^30.0.0"}}' > "$J/package.json"
echo 'module.exports = 1;' > "$J/src/b.js"; commit_sandbox "$J"
echo '// edit' >> "$J/src/b.js"
OUT=$(map_in "$J" jest)
[ "$OUT" = "pnpm exec jest --findRelatedTests --passWithNoTests src/b.js
exit=0" ] || { echo "FAIL M2: $OUT"; exit 1; }

# M3. pytest: a changed module runs its matching test file.
P=$(new_sandbox); mkdir -p "$P/pkg" "$P/tests"
echo 'X = 1' > "$P/pkg/mod.py"; echo 'def test_x(): pass' > "$P/tests/test_mod.py"
echo 'Y = 1' > "$P/pkg/lonely.py"; commit_sandbox "$P"
echo 'X = 2' >> "$P/pkg/mod.py"
OUT=$(map_in "$P" pytest)
[ "$OUT" = "pytest -q tests/test_mod.py
exit=0" ] || { echo "FAIL M3: $OUT"; exit 1; }

# M4. pytest: a changed module with no matching test falls back.
echo 'Y = 2' >> "$P/pkg/lonely.py"
OUT=$(map_in "$P" pytest)
[ "$OUT" = "exit=1" ] || { echo "FAIL M4: $OUT"; exit 1; }

# M5. go: changed files test and vet only their packages.
O=$(new_sandbox); mkdir -p "$O/pkg/x"
echo 'package x' > "$O/pkg/x/x.go"; commit_sandbox "$O"
echo '// edit' >> "$O/pkg/x/x.go"
OUT=$(map_in "$O" go)
[ "$OUT" = "go test ./pkg/x
go vet ./pkg/x
exit=0" ] || { echo "FAIL M5: $OUT"; exit 1; }

# M6. Negative input: a hostile filename is quoted, never executed.
H=$(new_sandbox); mkdir -p "$H/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$H/package.json"; commit_sandbox "$H"
HOSTILE='src/a b$(touch PWNED);x.ts'
echo 'export {}' > "$H/$HOSTILE"
CMD=$(cd "$H" && . "$MAPPING" && buildRelatedTestCommands vitest)
ECHOED=$(cd "$H" && bash -c "printf '%s\n' ${CMD#npx --no-install vitest related --run --passWithNoTests }")
[ "$ECHOED" = "$HOSTILE" ] || { echo "FAIL M6: filename not preserved: $ECHOED"; exit 1; }
[ ! -e "$H/PWNED" ] || { echo "FAIL M6: filename was executed"; exit 1; }

# M7. A stack the mapping does not know falls back to the full suite.
OUT=$(map_in "$O" rspec)
[ "$OUT" = "exit=1" ] || { echo "FAIL M7: $OUT"; exit 1; }

echo "PASS"
