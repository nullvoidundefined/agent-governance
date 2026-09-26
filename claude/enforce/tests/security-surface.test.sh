#!/usr/bin/env bash
# Verifies the security-surface detector, hooks/security-surface.sh (IAN-381,
# B-7 and B-8). The detector is a sourced helper, not a hook, and exposes two
# functions over the range <base-oid>..HEAD of the repository at <repo-top>:
#
#   is_security_surface <repo-top> <base-oid>
#     exit 0 when the range touches a security surface, 1 when it does not.
#   list_security_surface_hits <repo-top> <base-oid>
#     prints one "path:line trigger" line per hit, trigger being path,
#     content, or semgrep; a path hit reports line 0.
#
# Its path and content patterns live in enforce/security-surface.json (the
# `paths` and `content` regex arrays), and its Semgrep trigger runs the rule
# pack in enforce/semgrep/ through CLAUDE_SEMGREP_CMD, else `semgrep`, else
# `uvx semgrep`. Each trigger is proven on its own, a range touching nothing is
# proven unmarked, files matching the repository's `.enforce.json`
# `securitySurfaceExclude` globs are skipped, a write adding that key is denied
# by protected-path-guard.sh (R-410), and a Semgrep that cannot be found or
# crashes marks the range, because a detector error must never excuse a PR
# from security review.
#
# The Semgrep-trigger case needs a real Semgrep, resolved the way the helper
# resolves it: `semgrep` on PATH, else `uvx semgrep`. Every other case wires in
# a stand-in that reports no findings, so the path and content triggers are
# each observed alone.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
HELPER="$CLAUDE_HARNESS_ROOT/hooks/security-surface.sh"
PATTERNS_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-surface.json"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# uvx keeps its downloaded tools in its cache, which lives under HOME by
# default. Every case runs under a scratch HOME, so the cache location is
# pinned here first, or each case would download Semgrep again.
if [ -z "${UV_CACHE_DIR:-}" ]; then
  if command -v uv >/dev/null 2>&1; then
    UV_CACHE_DIR=$(uv cache dir 2>/dev/null)
  fi
  UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
fi
export UV_CACHE_DIR

# The real Semgrep command, resolved before any HOME change.
REAL_SEMGREP=""
if command -v semgrep >/dev/null 2>&1; then
  REAL_SEMGREP=$(command -v semgrep)
elif command -v uvx >/dev/null 2>&1; then
  REAL_SEMGREP="$(command -v uvx) semgrep"
fi

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

# A Semgrep stand-in that crashes: exit 2 with unreadable output.
CRASH_STUB="$WORK/crashing-semgrep"
printf '#!/bin/sh\necho "garbage {{{ not json"\necho "Fatal: internal error" >&2\nexit 2\n' > "$CRASH_STUB"
chmod +x "$CRASH_STUB"

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

# expect_hits <label> <expected output> <repo> <base> [VAR=value ...]: the
# hit list must equal the expected lines exactly.
expect_hits() {
  local label="$1" expected="$2"; shift 2
  local actual status
  actual=$(run_detector list_security_surface_hits "$@")
  status=$?
  [ "$status" -ne 97 ] || { report_failure "$label: $HELPER could not be sourced"; return; }
  [ "$actual" = "$expected" ] \
    || report_failure "$label: list_security_surface_hits must print exactly '$expected'; got '${actual:-<nothing>}'"
}

# --- The pattern file --------------------------------------------------------
if ! jq -e '(.paths | type == "array" and length > 0 and all(type == "string"))
            and (.content | type == "array" and length > 0 and all(type == "string"))' \
    "$PATTERNS_FILE" >/dev/null 2>&1; then
  report_failure "pattern file: $PATTERNS_FILE must hold non-empty string arrays 'paths' and 'content'"
fi

# matches_any <kind> <text>: exit 0 when any regex in the pattern file's
# <kind> array matches the text, case-insensitively (the conservative reading:
# a pattern that misses case-insensitively misses case-sensitively too).
matches_any() {
  local kind="$1" text="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    grep -Eiq -- "$pattern" <<< "$text" && return 0
  done < <(jq -r --arg k "$kind" '.[$k][]?' "$PATTERNS_FILE" 2>/dev/null)
  return 1
}

# --- 1. Path trigger (B-7) ---------------------------------------------------
# A changed file whose path matches a path pattern, with innocuous content.
REPO=$(new_repo path-trigger)
BASE=$(head_of "$REPO")
write_file "$REPO" app/middleware/cors_config.py $'VALUE = 1\n'
commit_all "$REPO" "add cors config module"
expect_marked "path trigger" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hits "path trigger" "app/middleware/cors_config.py:0 path" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 2. Content trigger (B-7) ------------------------------------------------
# An added line matching a content pattern in a file whose path is ordinary.
# The added line is line 3 of the new file.
REPO=$(new_repo content-trigger)
write_file "$REPO" app/main.py $'app = build_app()\n\n'
commit_all "$REPO" "base main module"
BASE=$(head_of "$REPO")
write_file "$REPO" app/main.py $'app = build_app()\n\napp.add_middleware(CORSMiddleware, allow_credentials=True)\n'
commit_all "$REPO" "add middleware"
expect_marked "content trigger" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hits "content trigger" "app/main.py:3 content" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 3. Semgrep trigger (B-7) ------------------------------------------------
# A rule-pack finding (python.bcrypt-weak-cost: a bcrypt cost of 4, reported
# on line 3) in a file whose path and added lines match no pattern, so the
# only trigger that can mark it is the rule pack.
SEMGREP_SAMPLE_PATH="app/tuning.py"
SEMGREP_SAMPLE=$'import bcrypt\n\nROUND_PREFIX = bcrypt.gensalt(4)\n'
if matches_any paths "$SEMGREP_SAMPLE_PATH"; then
  report_failure "precondition: $SEMGREP_SAMPLE_PATH must match no path pattern, or case 3 does not isolate the Semgrep trigger"
fi
while IFS= read -r sample_line; do
  [ -n "$sample_line" ] || continue
  if matches_any content "$sample_line"; then
    report_failure "precondition: the case 3 line '$sample_line' must match no content pattern, or case 3 does not isolate the Semgrep trigger"
  fi
done <<< "$SEMGREP_SAMPLE"
if [ -z "$REAL_SEMGREP" ]; then
  report_failure "precondition: the Semgrep-trigger case needs semgrep or uvx on PATH"
fi
REPO=$(new_repo semgrep-trigger)
BASE=$(head_of "$REPO")
write_file "$REPO" "$SEMGREP_SAMPLE_PATH" "$SEMGREP_SAMPLE"
commit_all "$REPO" "add tuning module"
expect_marked "semgrep trigger" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$REAL_SEMGREP"
expect_hits "semgrep trigger" "app/tuning.py:3 semgrep" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$REAL_SEMGREP"
# Real Semgrep must also complete cleanly (status 0): if its scanned-path form
# ever stopped matching the targets the detector passes, every PR with a code
# file would be marked with status 2 while the hit line above still printed
# (review finding 15 on PR #142).
run_detector list_security_surface_hits "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$REAL_SEMGREP" >/dev/null
real_scan_status=$?
[ "$real_scan_status" -eq 0 ] \
  || report_failure "semgrep trigger: list_security_surface_hits must return 0 on a complete real Semgrep scan; got $real_scan_status"

# --- 4. Nothing touched (B-7, negative) --------------------------------------
REPO=$(new_repo docs-only)
BASE=$(head_of "$REPO")
write_file "$REPO" docs/guide.md $'# Guide\n\nThis page explains how to run the project locally and where the logs go.\n'
commit_all "$REPO" "add guide"
expect_unmarked "docs-only range" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hits "docs-only range" "" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 5. securitySurfaceExclude (B-8) -----------------------------------------
# docs/auth-session.md matches a path pattern: without an exclude list the
# range is marked, and with docs/** excluded it is not.
REPO=$(new_repo exclude-control)
BASE=$(head_of "$REPO")
write_file "$REPO" docs/auth-session.md $'# Sessions\n\nNotes on how sign-in works.\n'
commit_all "$REPO" "add session notes"
expect_marked "auth doc without an exclude list" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hits "auth doc without an exclude list" "docs/auth-session.md:0 path" \
  "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

REPO=$(new_repo exclude-applied)
write_file "$REPO" .enforce.json $'{ "securitySurfaceExclude": ["docs/**"] }\n'
commit_all "$REPO" "exclude docs from the security surface"
BASE=$(head_of "$REPO")
write_file "$REPO" docs/auth-session.md $'# Sessions\n\nNotes on how sign-in works.\n'
commit_all "$REPO" "add session notes"
expect_unmarked "auth doc under an excluded glob" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_hits "auth doc under an excluded glob" "" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# --- 6. The exclude list is protected (B-8, R-410) ---------------------------
GUARD_REPO=$(new_repo guard)
GUARD_HOME=$(mktemp -d "$WORK/home.XXXXXX")
printf '{}\n' > "$GUARD_REPO/.enforce.json"
guard_decision() {
  local output
  output=$(HOME="$GUARD_HOME" CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json" "$GUARD" 2>/dev/null)
  if [ -z "$output" ]; then echo allow; else printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "unreadable"'; fi
}
WRITE_PAYLOAD=$(jq -nc --arg f "$GUARD_REPO/.enforce.json" --arg d "$GUARD_REPO" \
  --arg c $'{ "securitySurfaceExclude": ["**"] }\n' \
  '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:$c}}')
GOT=$(printf '%s' "$WRITE_PAYLOAD" | guard_decision)
[ "$GOT" = "deny" ] || report_failure "exclude-list Write: protected-path-guard must deny; got $GOT"
EDIT_PAYLOAD=$(jq -nc --arg f "$GUARD_REPO/.enforce.json" --arg d "$GUARD_REPO" \
  '{tool_name:"Edit",cwd:$d,tool_input:{file_path:$f,old_string:"{}",new_string:"{ \"securitySurfaceExclude\": [\"app/**\"] }"}}')
GOT=$(printf '%s' "$EDIT_PAYLOAD" | guard_decision)
[ "$GOT" = "deny" ] || report_failure "exclude-list Edit: protected-path-guard must deny; got $GOT"

# --- 7. Fail closed ----------------------------------------------------------
# A changed code file matching no pattern and carrying no finding. With a
# clean Semgrep it is not marked; with Semgrep missing or crashing it is.
REPO=$(new_repo fail-closed)
BASE=$(head_of "$REPO")
write_file "$REPO" app/numbers.py $'VALUE = 1\n'
commit_all "$REPO" "add numbers module"
expect_unmarked "clean Semgrep control" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CLEAN_STUB"
expect_marked "Semgrep missing" "$REPO" "$BASE" PATH="$BARE_PATH" CLAUDE_SEMGREP_CMD="$WORK/no-such-semgrep"
expect_marked "Semgrep crash" "$REPO" "$BASE" CLAUDE_SEMGREP_CMD="$CRASH_STUB"

if [ "$failures" -gt 0 ]; then
  echo "security-surface.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-surface.test.sh PASS"
