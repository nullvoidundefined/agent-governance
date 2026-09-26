#!/usr/bin/env bash
# Verifies that the security-surface detector, hooks/security-surface.sh
# (IAN-381, B-8e), does not mark a range for noise: review findings 12 and 13
# on PR #142.
#
#   dash-leading path   a range adding an innocuous code file named `-x.py` at
#                       the repository root is not marked, and
#                       list_security_surface_hits returns 0. A detector that
#                       hands the path to a tool which reads it as an option
#                       fails, and so marks the range, on every such file.
#   delimiter           an added line `DELIMITER = ","` is not marked, even
#                       though the word contains "limiter".
#   rate-limit control  `app.use(rateLimit({ max: 100 }));` in src/server.js
#                       and `limiter = RateLimiter()` in app/limits.py are each
#                       still marked with a content hit, so the fix for the
#                       delimiter case cannot simply drop the rate-limit
#                       pattern.
#
# Every case runs with a Semgrep stand-in that reports a complete clean scan,
# so the only way a range is marked is a path hit, a content hit, or a
# detector failure. Every repository is built under mktemp -d and every case
# runs the helper under a scratch HOME.
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

# --- 1. A dash-leading code file (finding 12) --------------------------------
# `-x.py` at the repository root, innocuous content, matching no path or
# content pattern.
REPO=$(new_repo dash-leading)
BASE=$(head_of "$REPO")
printf 'VALUE = 1\n' > "$REPO/-x.py"
git -C "$REPO" add -- -x.py
git -C "$REPO" commit -q -m "add dash-leading module"
if [ "$(git -C "$REPO" diff --name-only "$BASE" HEAD)" != "-x.py" ]; then
  report_failure "precondition: the dash-leading range must change exactly -x.py"
fi
expect_unmarked "dash-leading code file" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_clean_hits "dash-leading code file" "" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 2. A delimiter is not a rate limiter (finding 13) -----------------------
REPO=$(new_repo delimiter)
BASE=$(head_of "$REPO")
write_file "$REPO" app/csv_export.py $'DELIMITER = ","\n'
commit_all "$REPO" "add csv export delimiter"
expect_unmarked "DELIMITER line" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_clean_hits "DELIMITER line" "" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 3. Rate-limit controls stay marked (finding 13) -------------------------
REPO=$(new_repo rate-limit-js)
BASE=$(head_of "$REPO")
write_file "$REPO" src/server.js $'app.use(rateLimit({ max: 100 }));\n'
commit_all "$REPO" "add rate limit middleware"
expect_marked "rateLimit call" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_clean_hits "rateLimit call" "src/server.js:1 content" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

REPO=$(new_repo rate-limiter-py)
BASE=$(head_of "$REPO")
write_file "$REPO" app/limits.py $'limiter = RateLimiter()\n'
commit_all "$REPO" "add rate limiter"
expect_marked "RateLimiter construction" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_clean_hits "RateLimiter construction" "app/limits.py:1 content" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

if [ "$failures" -gt 0 ]; then
  echo "security-surface-noise.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-surface-noise.test.sh PASS"
