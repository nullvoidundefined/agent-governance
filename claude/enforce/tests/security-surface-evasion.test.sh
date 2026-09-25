#!/usr/bin/env bash
# Evasion cases for the security-surface detector, hooks/security-surface.sh
# (IAN-381, B-8c, the R-517 findings on PR #142). Each range below touches a
# security surface in a way the detector must still see:
#
#   1. A security-path file renamed, unchanged, to an innocuous path.
#   2. (a) A content hit in a range that also adds a NUL-bearing file, and
#      (b) a content hit hidden behind a `.gitattributes` `-diff` attribute.
#   3. Moved to a follow-up slice (a code file absent from `.paths.scanned`).
#   4. A code file that does not parse, under a clean Semgrep report.
#   5. A removed security-control line.
#   6. Detector-config and container-build paths.
#   7. Security-control families the content patterns missed.
#   8. An explicit <head> argument to list_security_surface_hits.
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

# A Semgrep stand-in that reports a complete, clean scan: no findings, no
# errors, no skipped paths, and every target it was given listed as scanned.
SCANNED_STUB="$WORK/scanned-semgrep"
cat > "$SCANNED_STUB" <<'STUB'
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
chmod +x "$SCANNED_STUB"

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

# run_detector <semgrep command> <function> <argument>...: sources the helper
# in a subshell under a fresh scratch HOME, from a working directory outside
# the repository, with CLAUDE_SEMGREP_CMD set, and calls the function with the
# arguments. Prints its stdout and exits with its status; 97 means the helper
# could not be sourced.
run_detector() {
  local semgrep_command="$1" function_name="$2"; shift 2
  local case_home
  case_home=$(mktemp -d "$WORK/home.XXXXXX")
  (
    cd "$WORK" || exit 96
    export HOME="$case_home"
    export CLAUDE_SEMGREP_CMD="$semgrep_command"
    . "$HELPER" 2>/dev/null || exit 97
    "$function_name" "$@" 2>/dev/null
  )
}

# expect_marked <label> <semgrep command> <repo> <base>
expect_marked() {
  local label="$1"; shift
  local status
  run_detector "$1" is_security_surface "$2" "$3" >/dev/null
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$status" -eq 0 ] || report_failure "$label: is_security_surface must exit 0 (marked); got $status"
}

# expect_unmarked <label> <semgrep command> <repo> <base>
expect_unmarked() {
  local label="$1"; shift
  local status
  run_detector "$1" is_security_surface "$2" "$3" >/dev/null
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$status" -eq 1 ] || report_failure "$label: is_security_surface must exit 1 (not marked); got $status"
}

# expect_hit_line <label> <line> <semgrep command> <argument>...: the hit list
# from list_security_surface_hits <argument>... must contain the exact line.
expect_hit_line() {
  local label="$1" wanted="$2"; shift 2
  local actual status
  actual=$(run_detector "$1" list_security_surface_hits "${@:2}")
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  printf '%s\n' "$actual" | grep -Fxq -- "$wanted" \
    || report_failure "$label: list_security_surface_hits must print '$wanted'; got '${actual:-<nothing>}'"
}

# expect_hit_matching <label> <extended regex> <semgrep command> <repo> <base>:
# some line of the hit list must match the regex.
expect_hit_matching() {
  local label="$1" wanted_regex="$2"; shift 2
  local actual status
  actual=$(run_detector "$1" list_security_surface_hits "$2" "$3")
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  printf '%s\n' "$actual" | grep -Eq -- "$wanted_regex" \
    || report_failure "$label: list_security_surface_hits must print a line matching '$wanted_regex'; got '${actual:-<nothing>}'"
}

# --- Control: the scanned stub itself marks nothing --------------------------
REPO=$(new_repo control)
BASE=$(head_of "$REPO")
write_file "$REPO" app/x.py $'VALUE = 1\n'
commit_all "$REPO" "add x module"
expect_unmarked "innocuous control with a complete clean scan" "$SCANNED_STUB" "$REPO" "$BASE"

# --- 1. Rename of a security-path file (HIGH) --------------------------------
REPO=$(new_repo rename)
write_file "$REPO" app/middleware/cors_config.py $'VALUE = 1\n'
commit_all "$REPO" "add cors config module"
BASE=$(head_of "$REPO")
git -C "$REPO" mv app/middleware/cors_config.py app/c.py
git -C "$REPO" commit -q -m "move cors config module"
expect_marked "renamed security-path file" "$SCANNED_STUB" "$REPO" "$BASE"
expect_hit_line "renamed security-path file" "app/middleware/cors_config.py:0 path" \
  "$SCANNED_STUB" "$REPO" "$BASE"

# --- 2a. A NUL-bearing file beside a content hit (HIGH) ----------------------
REPO=$(new_repo nul-beside-content)
BASE=$(head_of "$REPO")
write_file "$REPO" app/main.py $'app.add_middleware(CORSMiddleware)\n'
printf 'first half\000second half\n' > "$REPO/notes.txt"
commit_all "$REPO" "add main module and notes"
expect_marked "content hit beside a NUL-bearing file" "$SCANNED_STUB" "$REPO" "$BASE"
expect_hit_line "content hit beside a NUL-bearing file" "app/main.py:1 content" \
  "$SCANNED_STUB" "$REPO" "$BASE"

# --- 2b. A content hit behind a -diff attribute (HIGH) -----------------------
REPO=$(new_repo diff-attribute)
BASE=$(head_of "$REPO")
write_file "$REPO" .gitattributes $'*.py -diff\n'
write_file "$REPO" app/main.py $'app.add_middleware(CORSMiddleware)\n'
commit_all "$REPO" "add main module behind a -diff attribute"
expect_marked "content hit behind a -diff attribute" "$SCANNED_STUB" "$REPO" "$BASE"

# --- 3. Moves to a follow-up slice once the clean Semgrep stubs list their scanned targets.

# --- 4. A code file that does not parse (MEDIUM) -----------------------------
REPO=$(new_repo unparseable)
BASE=$(head_of "$REPO")
write_file "$REPO" app/broken.py $'def broken(:\n    return 1\n'
commit_all "$REPO" "add broken module"
expect_marked "unparseable code file under a clean scan" "$SCANNED_STUB" "$REPO" "$BASE"

# --- 5. A removed security-control line (MEDIUM) -----------------------------
REPO=$(new_repo removed-control)
write_file "$REPO" src/server.js $'const port = 3001;\napp.use(helmet());\napp.listen(port);\n'
commit_all "$REPO" "add server"
BASE=$(head_of "$REPO")
write_file "$REPO" src/server.js $'const port = 3001;\napp.listen(port);\n'
commit_all "$REPO" "drop helmet"
expect_marked "removed helmet line" "$SCANNED_STUB" "$REPO" "$BASE"
expect_hit_matching "removed helmet line" '^src/server\.js:[0-9]+ content$' \
  "$SCANNED_STUB" "$REPO" "$BASE"

# --- 6. Detector-config and container-build paths (MEDIUM, LOW 10) -----------
# expect_config_path_hit <slug> <relative path> <content>
expect_config_path_hit() {
  local repo base
  repo=$(new_repo "config-$1")
  base=$(head_of "$repo")
  write_file "$repo" "$2" "$3"
  commit_all "$repo" "add $2"
  expect_marked "config path $2" "$SCANNED_STUB" "$repo" "$base"
  expect_hit_line "config path $2" "$2:0 path" "$SCANNED_STUB" "$repo" "$base"
}
expect_config_path_hit enforce-json .enforce.json $'{}\n'
expect_config_path_hit gitattributes .gitattributes $'*.txt text\n'
expect_config_path_hit semgrepignore .semgrepignore $'build/\n'
expect_config_path_hit api-dockerfile api.Dockerfile $'FROM scratch\n'
expect_config_path_hit containerfile Containerfile $'FROM scratch\n'

# --- 7. Missing security-control families (LOW 9) ----------------------------
# expect_family_content_hit <slug> <relative path> <added line>
expect_family_content_hit() {
  local repo base
  repo=$(new_repo "family-$1")
  base=$(head_of "$repo")
  write_file "$repo" "$2" "$3"$'\n'
  commit_all "$repo" "add $2"
  expect_marked "family $1" "$SCANNED_STUB" "$repo" "$base"
  expect_hit_line "family $1" "$2:1 content" "$SCANNED_STUB" "$repo" "$base"
}
expect_family_content_hit rate-limit src/server.js 'app.use(rateLimit({ windowMs: 60000, max: 100 }));'
expect_family_content_hit reject-unauthorized src/client.js 'const agent = new https.Agent({ rejectUnauthorized: false });'
expect_family_content_hit insecure-skip-verify cmd/client.go 'var tlsSettings = &tls.Config{InsecureSkipVerify: true}'
expect_family_content_hit argon2 app/hasher.py 'import argon2'
expect_family_content_hit hsts src/server.js 'res.setHeader("Strict-Transport-Security", "max-age=63072000");'
expect_family_content_hit frame-options src/server.js 'res.setHeader("X-Frame-Options", "DENY");'
expect_family_content_hit csrf src/server.js 'app.use(csrf());'

# --- 8. Explicit head argument (LOW 11) --------------------------------------
# HEAD is checked out one commit behind HEAD_OID, the commit that adds the
# CORS line; the base is the initial commit.
REPO=$(new_repo explicit-head)
BASE=$(head_of "$REPO")
write_file "$REPO" app/x.py $'VALUE = 1\n'
commit_all "$REPO" "add x module"
BEHIND_OID=$(head_of "$REPO")
write_file "$REPO" app/main.py $'app.add_middleware(CORSMiddleware)\n'
commit_all "$REPO" "add cors middleware"
HEAD_OID=$(head_of "$REPO")
git -C "$REPO" checkout -q --detach "$BEHIND_OID"
expect_hit_line "explicit head argument" "app/main.py:1 content" \
  "$SCANNED_STUB" "$REPO" "$BASE" "$HEAD_OID"
IMPLICIT_HITS=$(run_detector "$SCANNED_STUB" list_security_surface_hits "$REPO" "$BASE")
IMPLICIT_STATUS=$?
[ "$IMPLICIT_STATUS" -eq 0 ] \
  || report_failure "omitted head argument: list_security_surface_hits must return 0; got $IMPLICIT_STATUS"
[ -z "$IMPLICIT_HITS" ] \
  || report_failure "omitted head argument: the checked-out HEAD has no hit; got '$IMPLICIT_HITS'"

if [ "$failures" -gt 0 ]; then
  echo "security-surface-evasion.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-surface-evasion.test.sh PASS"
