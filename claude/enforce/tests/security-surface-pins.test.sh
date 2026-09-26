#!/usr/bin/env bash
# Pins behaviors of the security-surface detector, hooks/security-surface.sh
# (IAN-381, B-8b), that security-surface.test.sh does not cover:
#
#   1. A Semgrep report with a non-empty `.errors` marks the range, and
#      list_security_surface_hits returns 2.
#   2. A Semgrep report with a non-empty `.paths.skipped` does the same.
#   3. A range that deletes a security-path file is marked by a path hit.
#   4. A range cannot exclude itself: an `.enforce.json` exclude list added by
#      the range is ignored, because the list is read from the base commit.
#   5. When no Semgrep resolves, list_security_surface_hits returns 2 and names
#      the failure on stderr, and is_security_surface marks the range.
#
# Every case builds its repositories under mktemp -d and runs the helper under
# a scratch HOME.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
HELPER="$CLAUDE_HARNESS_ROOT/hooks/security-surface.sh"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# A Semgrep stand-in that scans nothing and reports no findings.
CLEAN_STUB="$WORK/clean-semgrep"
# Reports a complete clean scan the way real Semgrep does: every target it was
# given is listed under paths.scanned (IAN-381: an empty scanned list is a skip).
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

# A Semgrep stand-in that exits 0 with no findings but reports a parse error.
ERRORS_STUB="$WORK/errors-semgrep"
printf '#!/bin/sh\necho '"'"'{"results":[],"errors":[{"path":"app/x.py","type":"PartialParsing","message":"m"}],"paths":{"scanned":["app/x.py"]}}'"'"'\nexit 0\n' > "$ERRORS_STUB"
chmod +x "$ERRORS_STUB"

# A Semgrep stand-in that exits 0 with no findings but reports a skipped path.
SKIPPED_STUB="$WORK/skipped-semgrep"
printf '#!/bin/sh\necho '"'"'{"results":[],"errors":[],"paths":{"scanned":[],"skipped":[{"path":"app/x.py","reason":"exceeded_size_limit"}]}}'"'"'\nexit 0\n' > "$SKIPPED_STUB"
chmod +x "$SKIPPED_STUB"

# A PATH carrying only bash, git, and jq plus the system dirs, so neither
# semgrep nor uvx resolves on it.
TOOLS_DIR="$WORK/tools"
mkdir -p "$TOOLS_DIR"
ln -s "$(command -v bash)" "$TOOLS_DIR/bash"
ln -s "$(command -v git)" "$TOOLS_DIR/git"
ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
BARE_PATH="$TOOLS_DIR:/usr/bin:/bin"
if PATH="$BARE_PATH" command -v semgrep >/dev/null 2>&1 || PATH="$BARE_PATH" command -v uvx >/dev/null 2>&1; then
  report_failure "precondition: semgrep or uvx still resolves on the stub PATH $BARE_PATH"
fi

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

# expect_hit_line <label> <line> <repo> <base> [VAR=value ...]: the hit list
# must contain the line.
expect_hit_line() {
  local label="$1" wanted="$2"; shift 2
  local actual status
  actual=$(run_detector list_security_surface_hits /dev/null "$@")
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  printf '%s\n' "$actual" | grep -Fxq -- "$wanted" \
    || report_failure "$label: list_security_surface_hits must print '$wanted'; got '${actual:-<nothing>}'"
}

# --- Shared innocuous range for cases 1, 2, and 5 ----------------------------
# app/x.py matches no path or content pattern; the clean control proves it.
INNOCUOUS_REPO=$(new_repo innocuous)
INNOCUOUS_BASE=$(head_of "$INNOCUOUS_REPO")
write_file "$INNOCUOUS_REPO" app/x.py $'VALUE = 1\n'
commit_all "$INNOCUOUS_REPO" "add x module"
expect_unmarked "innocuous control with a clean Semgrep" "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_list_status "innocuous control with a clean Semgrep" 0 "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 1. Semgrep report with errors -------------------------------------------
expect_marked "Semgrep report with errors" "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$ERRORS_STUB"
expect_list_status "Semgrep report with errors" 2 "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$ERRORS_STUB"

# --- 2. Semgrep report with skipped paths ------------------------------------
expect_marked "Semgrep report with skipped paths" "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$SKIPPED_STUB"
expect_list_status "Semgrep report with skipped paths" 2 "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  CLAUDE_SEMGREP_CMD="$SKIPPED_STUB"

# --- 3. Deleting a security-path file ----------------------------------------
REPO=$(new_repo delete-path)
write_file "$REPO" app/middleware/cors_config.py $'VALUE = 1\n'
commit_all "$REPO" "add cors config module"
BASE=$(head_of "$REPO")
git -C "$REPO" rm -q app/middleware/cors_config.py
git -C "$REPO" commit -q -m "delete cors config module"
expect_marked "deleted security-path file" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hit_line "deleted security-path file" "app/middleware/cors_config.py:0 path" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 4. A range cannot exclude itself ----------------------------------------
REPO=$(new_repo self-exclude)
BASE=$(head_of "$REPO")
write_file "$REPO" .enforce.json '{"securitySurfaceExclude":["app/**"]}'
write_file "$REPO" app/middleware/cors_config.py $'VALUE = 1\n'
commit_all "$REPO" "exclude app and change cors config"
expect_marked "range adding its own exclude list" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hit_line "range adding its own exclude list" "app/middleware/cors_config.py:0 path" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 5. Semgrep cannot be resolved -------------------------------------------
MISSING_STDERR="$WORK/missing-semgrep.stderr"
run_detector list_security_surface_hits "$MISSING_STDERR" "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  PATH="$BARE_PATH" CLAUDE_SEMGREP_CMD="$WORK/no-such-semgrep" >/dev/null
MISSING_STATUS=$?
[ "$MISSING_STATUS" -eq 2 ] \
  || report_failure "Semgrep unresolved: list_security_surface_hits must return 2; got $MISSING_STATUS"
[ -s "$MISSING_STDERR" ] \
  || report_failure "Semgrep unresolved: list_security_surface_hits must name the failure on stderr; stderr was empty"
expect_marked "Semgrep unresolved" "$INNOCUOUS_REPO" "$INNOCUOUS_BASE" \
  PATH="$BARE_PATH" CLAUDE_SEMGREP_CMD="$WORK/no-such-semgrep"

if [ "$failures" -gt 0 ]; then
  echo "security-surface-pins.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-surface-pins.test.sh PASS"
