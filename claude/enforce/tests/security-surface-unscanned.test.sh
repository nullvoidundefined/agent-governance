#!/usr/bin/env bash
# Verifies that the security-surface detector, hooks/security-surface.sh
# (IAN-381, B-8d), marks a range when Semgrep's report leaves an exported code
# file out of `.paths.scanned`. Real Semgrep does this without `--verbose` for
# a file over its 1 MB default size limit: it exits 0, reports no errors, and
# simply omits the file, so a detector that reads only `.results`, `.errors`,
# and `.paths.skipped` would pass a file nobody scanned.
#
# The range changes one innocuous code file, app/x.py, which matches no path
# or content pattern. Three cases run over it:
#
#   control     a Semgrep stand-in that lists every target it was given under
#               `.paths.scanned`, as real Semgrep does: the range is not marked.
#   empty       a stand-in that reports `"scanned": []`: the range is marked,
#               list_security_surface_hits returns 2, and stderr names app/x.py.
#   other file  a stand-in that reports `"scanned": ["app/other.py"]`: the same.
#
# Every repository is built under mktemp -d and every case runs the helper
# under a scratch HOME.
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

# Exits 0 with no findings, no errors, and no skipped paths, but scanned
# nothing: the shape real Semgrep emits for an over-limit file without
# --verbose.
EMPTY_SCANNED_STUB="$WORK/empty-scanned-semgrep"
printf '#!/bin/sh\necho '"'"'{"results":[],"errors":[],"paths":{"scanned":[]}}'"'"'\nexit 0\n' > "$EMPTY_SCANNED_STUB"
chmod +x "$EMPTY_SCANNED_STUB"

# Exits 0 with no findings and reports a file other than the target as scanned.
OTHER_SCANNED_STUB="$WORK/other-scanned-semgrep"
printf '#!/bin/sh\necho '"'"'{"results":[],"errors":[],"paths":{"scanned":["app/other.py"]}}'"'"'\nexit 0\n' > "$OTHER_SCANNED_STUB"
chmod +x "$OTHER_SCANNED_STUB"

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

# write_file <repo> <relative path> <content>
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all <repo> <message>
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

head_of() { git -C "$1" rev-parse HEAD; }

# run_detector <function> <stderr file> <repo> <base> [VAR=value ...]: sources
# the helper in a subshell under a fresh scratch HOME, from a working
# directory outside the repository, and calls the function. Prints its stdout,
# writes its stderr to the stderr file, and exits with its status; 97 means
# the helper could not be sourced.
run_detector() {
  local function_name="$1" stderr_file="$2" repo="$3" base="$4"; shift 4
  local case_home
  case_home=$(mktemp -d "$WORK/home.XXXXXX")
  (
    cd "$WORK" || exit 96
    export HOME="$case_home"
    local assignment
    for assignment in "$@"; do export "${assignment?}"; done
    . "$HELPER" 2>/dev/null || exit 97
    "$function_name" "$repo" "$base" 2>"$stderr_file"
  )
}

# expect_marked <label> <repo> <base> [VAR=value ...]
expect_marked() {
  local label="$1"; shift
  local status
  run_detector is_security_surface /dev/null "$@" >/dev/null
  status=$?
  [ "$status" -eq 0 ] || report_failure "$label: is_security_surface must exit 0 (marked); got $status"
}

# expect_unmarked <label> <repo> <base> [VAR=value ...]
expect_unmarked() {
  local label="$1"; shift
  local status
  run_detector is_security_surface /dev/null "$@" >/dev/null
  status=$?
  [ "$status" -eq 1 ] || report_failure "$label: is_security_surface must exit 1 (not marked); got $status"
}

# expect_list_status <label> <expected status> <repo> <base> [VAR=value ...]
expect_list_status() {
  local label="$1" expected="$2"; shift 2
  local status
  run_detector list_security_surface_hits /dev/null "$@" >/dev/null
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$status" -eq "$expected" ] \
    || report_failure "$label: list_security_surface_hits must return $expected; got $status"
}

# expect_unscanned_failure <label> <repo> <base> [VAR=value ...]: the range is
# marked, list_security_surface_hits returns 2, and its stderr names the
# unscanned file app/x.py.
expect_unscanned_failure() {
  local label="$1"; shift
  local stderr_file status
  expect_marked "$label" "$@"
  stderr_file=$(mktemp "$WORK/stderr.XXXXXX")
  run_detector list_security_surface_hits "$stderr_file" "$@" >/dev/null
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$status" -eq 2 ] \
    || report_failure "$label: list_security_surface_hits must return 2; got $status"
  grep -Fq -- "app/x.py" "$stderr_file" \
    || report_failure "$label: list_security_surface_hits must name the unscanned file app/x.py on stderr; stderr was '$(cat "$stderr_file")'"
}

# --- The innocuous range -----------------------------------------------------
REPO=$(new_repo unscanned)
BASE=$(head_of "$REPO")
write_file "$REPO" app/x.py $'VALUE = 1\n'
commit_all "$REPO" "add x module"

# --- Control: every target reported scanned ----------------------------------
expect_unmarked "every target scanned (control)" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_list_status "every target scanned (control)" 0 "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 1. Empty scanned list ---------------------------------------------------
expect_unscanned_failure "empty scanned list" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$EMPTY_SCANNED_STUB"

# --- 2. A different file scanned ---------------------------------------------
expect_unscanned_failure "a different file scanned" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$OTHER_SCANNED_STUB"

if [ "$failures" -gt 0 ]; then
  echo "security-surface-unscanned.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-surface-unscanned.test.sh PASS"
