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

# M8. A deleted source file falls back: a deletion can break tests the
# mapping cannot see (PR #54 review).
D=$(new_sandbox); mkdir -p "$D/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$D/package.json"
echo 'export const gone = 1;' > "$D/src/gone.ts"; commit_sandbox "$D"
rm "$D/src/gone.ts"
OUT=$(map_in "$D" vitest)
[ "$OUT" = "exit=1" ] || { echo "FAIL M8: a deleted file must fall back, got: $OUT"; exit 1; }

# M9. A changed Python dependency manifest falls back (PR #54 review).
for manifest in requirements.txt requirements-dev.txt Pipfile.lock poetry.lock uv.lock setup.py; do
  Q=$(new_sandbox)
  echo 'X = 1' > "$Q/mod.py"; echo 'pin==1' > "$Q/$manifest"; commit_sandbox "$Q"
  echo 'pin==2' >> "$Q/$manifest"
  OUT=$(map_in "$Q" pytest)
  [ "$OUT" = "exit=1" ] || { echo "FAIL M9: a changed $manifest must fall back, got: $OUT"; exit 1; }
done

# M10. No commit to diff against: the change set is unknowable, so fall back
# (PR #54 re-review).
N=$(mktemp -d); git -C "$N" init -q; echo 'X = 1' > "$N/mod.py"
OUT=$(map_in "$N" pytest)
[ "$OUT" = "exit=1" ] || { echo "FAIL M10: no base commit must fall back, got: $OUT"; exit 1; }

# M11. A changed file the stack's mapper cannot place falls back, even when it
# is not source code (a template the tests render).
T=$(new_sandbox); mkdir -p "$T/templates"
echo 'X = 1' > "$T/mod.py"; echo '<p>hi</p>' > "$T/templates/page.html"; commit_sandbox "$T"
echo '<p>changed</p>' > "$T/templates/page.html"
OUT=$(map_in "$T" pytest)
[ "$OUT" = "exit=1" ] || { echo "FAIL M11: an unmapped template must fall back, got: $OUT"; exit 1; }

# M12. A docs-only change still runs nothing: prose cannot break a test.
W=$(new_sandbox); mkdir -p "$W/docs"
echo 'X = 1' > "$W/mod.py"; echo '# Readme' > "$W/README.md"; echo 'notes' > "$W/docs/notes.md"; commit_sandbox "$W"
echo 'more' >> "$W/README.md"; echo 'more' >> "$W/docs/notes.md"
OUT=$(map_in "$W" pytest)
[ "$OUT" = "exit=0" ] || { echo "FAIL M12: a docs-only change must run nothing, got: $OUT"; exit 1; }

# M13. vitest receives non-script files too, so its import graph decides.
C=$(new_sandbox); mkdir -p "$C/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$C/package.json"
echo '.a { color: red; }' > "$C/src/a.css"; commit_sandbox "$C"
echo '.b { color: blue; }' >> "$C/src/a.css"
OUT=$(map_in "$C" vitest)
[ "$OUT" = "npx --no-install vitest related --run --passWithNoTests src/a.css
exit=0" ] || { echo "FAIL M13: a changed stylesheet must reach vitest related, got: $OUT"; exit 1; }

# M14. Deleting a doc is still docs-only: it runs nothing.
rm "$W/docs/notes.md"
OUT=$(map_in "$W" pytest)
[ "$OUT" = "exit=0" ] || { echo "FAIL M14: a deleted doc must run nothing, got: $OUT"; exit 1; }

echo "PASS"
