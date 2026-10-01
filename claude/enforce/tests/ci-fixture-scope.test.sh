#!/usr/bin/env bash
# Shard: slow
# ci-fixture-scope.test.sh: verifies enforce/ci-fixture-scope.sh, the script
# that decides whether the fixture suites in .github/workflows/enforce.yml run
# for one CI event (IAN-552).
#
# Contract under test: the script reads EVENT_NAME, IS_DRAFT, BASE_SHA and
# HEAD_SHA from the environment, runs inside the git checkout, prints exactly
# one line, `should_run=true` or `should_run=false`, and exits 0 in every case,
# an error included, because any error answers true.
#
# Fixture: one sandbox repository whose main commit (BASE) holds
# hooks/x.sh, src/app.ts and docs/a.md. Each case builds its own head commit on
# a throwaway branch from BASE and the checkout returns to main afterwards, so
# HEAD always names BASE while the script runs; that makes an empty BASE_SHA
# (which git would read as HEAD in `...HEAD_SHA`) produce a docs-only diff
# unless the script refuses it.
#
# Behaviours asserted:
# - A non-pull_request event (push, workflow_dispatch, empty) answers true,
#   even over a docs-only range and even with IS_DRAFT=true.
# - A draft pull_request answers false, even over a code change.
# - A non-draft pull_request answers false only when the three-dot diff
#   succeeds, is non-empty, and every path starts with docs/: adding,
#   modifying, or deleting a docs/ file answers false.
# - Insecure values answer true (R-109 review): a code file renamed into docs/
#   with unchanged content; docsx/, Docs/ and foo/docs/ lookalike paths; a
#   mixed docs/ plus code change; a deleted code file; a docs/ file whose name
#   holds a newline (git quotes it); an empty diff (base equals head); a
#   BASE_SHA naming no commit; an empty BASE_SHA; a base sharing no merge base
#   with the head (an orphan history); IS_DRAFT empty or `null` on a
#   pull_request with a code change; and a plain non-draft code change.
# - Every case also asserts exit status 0 and that stdout is exactly the one
#   expected line.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCOPE="$CLAUDE_HARNESS_ROOT/enforce/ci-fixture-scope.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset EVENT_NAME IS_DRAFT BASE_SHA HEAD_SHA

fail=0

[ -f "$SCOPE" ] || { echo "FAIL: no script at $SCOPE"; echo "ci-fixture-scope.test.sh FAIL"; exit 1; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home"; export HOME="$SB/home"
export GIT_CONFIG_NOSYSTEM=1
REPO="$SB/repo"
mkdir -p "$REPO/hooks" "$REPO/src" "$REPO/docs"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf '#!/usr/bin/env bash\necho x\n' > "$REPO/hooks/x.sh"
printf 'export const app = 1;\n' > "$REPO/src/app.ts"
printf '# a\n' > "$REPO/docs/a.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "base"
BASE=$(git -C "$REPO" rev-parse HEAD)

# startCase <branch>: checks out a fresh branch at BASE for one case's edits.
startCase() {
  git -C "$REPO" checkout -q -B "$1" "$BASE"
}

# finishCase: commits every pending change (allowing an empty commit), prints
# the new head SHA, and returns the checkout to main so HEAD names BASE again.
finishCase() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q --allow-empty -m "case"
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
}

# writeFile <path> <content>: writes <content> to <path> inside the sandbox
# repository, creating parent directories.
writeFile() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "$2" > "$REPO/$1"
}

# expectScope <name> <expected line> <EVENT_NAME> <IS_DRAFT> <BASE_SHA> <HEAD_SHA>:
# runs the script inside the sandbox repository with exactly those four
# variables set and asserts stdout is the one expected line and the exit
# status is 0.
expectScope() {
  local name="$1" expected="$2" out rc
  out=$(cd "$REPO" && EVENT_NAME="$3" IS_DRAFT="$4" BASE_SHA="$5" HEAD_SHA="$6" \
    bash "$SCOPE" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name: exit status $rc, expected 0"; fail=1; return
  fi
  if [ "$out" != "$expected" ]; then
    echo "FAIL: $name: stdout was [$out], expected [$expected]"; fail=1; return
  fi
  echo "PASS: $name"
}

# ---- Head commits, one per case --------------------------------------------

startCase docs-add; writeFile docs/new.md '# new'; DOCS_ADD=$(finishCase)
startCase docs-modify; writeFile docs/a.md '# a changed'; DOCS_MODIFY=$(finishCase)
startCase docs-delete; git -C "$REPO" rm -q docs/a.md; DOCS_DELETE=$(finishCase)
startCase code; writeFile src/app.ts 'export const app = 2;'; CODE=$(finishCase)
startCase mixed; writeFile docs/a.md '# a mixed'; writeFile src/app.ts 'export const app = 3;'; MIXED=$(finishCase)
startCase code-delete; git -C "$REPO" rm -q hooks/x.sh; CODE_DELETE=$(finishCase)
startCase rename-into-docs; mkdir -p "$REPO/docs/archive"
git -C "$REPO" mv hooks/x.sh docs/archive/x.sh; RENAME_INTO_DOCS=$(finishCase)
startCase docsx; writeFile docsx/a.md '# lookalike'; DOCSX=$(finishCase)
# Docs/ goes straight into the index: on a case-insensitive filesystem
# (macOS) a Docs/ directory written to the working tree lands in docs/.
startCase docs-upper
UPPER_BLOB=$(printf '# upper\n' | git -C "$REPO" hash-object -w --stdin)
git -C "$REPO" update-index --add --cacheinfo "100644,$UPPER_BLOB,Docs/upper.md"
git -C "$REPO" commit -qm "case"; DOCS_UPPER=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -f main
startCase nested-docs; writeFile foo/docs/a.md '# nested'; NESTED_DOCS=$(finishCase)
startCase newline-name; printf '# nl\n' > "$REPO/docs/a
b.md"; NEWLINE_NAME=$(finishCase)

git -C "$REPO" checkout -q --orphan orphan
git -C "$REPO" rm -rq --cached .
git -C "$REPO" clean -fdq
writeFile docs/orphan.md '# orphan'
git -C "$REPO" add -A
git -C "$REPO" commit -qm "orphan"
ORPHAN=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -f main
git -C "$REPO" clean -fdq

MISSING_SHA=0123456789abcdef0123456789abcdef01234567

[ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ] \
  || { echo "FAIL: sandbox checkout is not at BASE"; exit 1; }

# ---- Non-pull_request events answer true -----------------------------------

expectScope "push over a docs-only range" "should_run=true" push false "$BASE" "$DOCS_ADD"
expectScope "workflow_dispatch over a docs-only range" "should_run=true" workflow_dispatch false "$BASE" "$DOCS_ADD"
expectScope "empty EVENT_NAME over a docs-only range" "should_run=true" "" false "$BASE" "$DOCS_ADD"
expectScope "push with IS_DRAFT=true" "should_run=true" push true "$BASE" "$DOCS_ADD"
expectScope "push with IS_DRAFT=true over a code change" "should_run=true" push true "$BASE" "$CODE"

# ---- Cases that answer false -----------------------------------------------

expectScope "draft PR with a code change" "should_run=false" pull_request true "$BASE" "$CODE"
expectScope "non-draft PR adding a docs/ file" "should_run=false" pull_request false "$BASE" "$DOCS_ADD"
expectScope "non-draft PR modifying a docs/ file" "should_run=false" pull_request false "$BASE" "$DOCS_MODIFY"
expectScope "non-draft PR deleting a docs/ file" "should_run=false" pull_request false "$BASE" "$DOCS_DELETE"

# ---- Non-draft pull_request ranges that answer true ------------------------

expectScope "non-draft PR with a code change" "should_run=true" pull_request false "$BASE" "$CODE"
expectScope "mixed docs/ plus code change" "should_run=true" pull_request false "$BASE" "$MIXED"
expectScope "deletion of a code file" "should_run=true" pull_request false "$BASE" "$CODE_DELETE"
expectScope "code file renamed into docs/ unchanged" "should_run=true" pull_request false "$BASE" "$RENAME_INTO_DOCS"
expectScope "docsx/ lookalike path" "should_run=true" pull_request false "$BASE" "$DOCSX"
expectScope "Docs/ uppercase path" "should_run=true" pull_request false "$BASE" "$DOCS_UPPER"
expectScope "foo/docs/ nested path" "should_run=true" pull_request false "$BASE" "$NESTED_DOCS"
expectScope "docs/ file whose name holds a newline" "should_run=true" pull_request false "$BASE" "$NEWLINE_NAME"
expectScope "empty diff (base equals head)" "should_run=true" pull_request false "$BASE" "$BASE"

# ---- Diff errors answer true -----------------------------------------------

expectScope "BASE_SHA naming no commit" "should_run=true" pull_request false "$MISSING_SHA" "$DOCS_ADD"
expectScope "empty BASE_SHA" "should_run=true" pull_request false "" "$DOCS_ADD"
expectScope "base with no merge base (orphan history)" "should_run=true" pull_request false "$ORPHAN" "$DOCS_ADD"

# ---- IS_DRAFT values that are not exactly true -----------------------------

expectScope "IS_DRAFT empty on a PR with a code change" "should_run=true" pull_request "" "$BASE" "$CODE"
expectScope "IS_DRAFT null on a PR with a code change" "should_run=true" pull_request null "$BASE" "$CODE"

[ "$fail" -eq 0 ] || { echo "ci-fixture-scope.test.sh FAIL"; exit 1; }
echo "ci-fixture-scope.test.sh PASS"
